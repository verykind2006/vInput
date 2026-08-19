import Foundation
import MLXLMCommon

/// 「是哪一个模型」的身份，共用容器的缓存键。
///
/// 两格对应 `loadModelContainer` 的两个重载，缺一不可：键必须**唯一决定
/// 那次加载做什么**，否则共用就成了张冠李戴。
enum ModelContainerKey: Hashable, Sendable {
    /// 本地模型目录，路径已归一化（见 `local(_:)`）。
    case directory(path: String)
    /// Hugging Face 标识符，由内置下载器拉取。
    case identifier(String)

    /// 由本地目录构造键。
    ///
    /// **路径必须归一化，否则「同一个目录」判不出来。** 本机实测
    /// （2026-08-18，`standardizedFileURL.resolvingSymlinksInPath().path`）：
    ///
    /// - `/a/b/`、`/a/./b`、`/a/sub/../b` 一律收敛到 `/a/b`，与路径存不存在无关。
    /// - 符号链接段只在**路径真的存在**时才解开：`/private/tmp/x` 在该目录存在时
    ///   归一化成 `/tmp/x`（方向与直觉相反，是量出来的），目录不存在时原样保留
    ///   `/private/tmp/x`。生产上模型目录必然存在，落在能解开的那一侧；
    ///   但这条依赖不写下来的话，将来有人拿一个不存在的路径写测试会以为它坏了。
    ///
    /// 这不是吹毛求疵：判不出同一个目录的表现是**静默加载两份 2 GB 权重**，
    /// 没有任何报错，只有内存曲线知道。
    static func local(_ url: URL) -> ModelContainerKey {
        .directory(path: url.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    /// 只进日志的短描述。与报告头的写法一致，取目录名而非全路径。
    var logDescription: String {
        switch self {
        case .directory(let path): URL(fileURLWithPath: path).lastPathComponent
        case .identifier(let id): id
        }
    }
}

/// 「同一个模型在进程内只加载一次、只占一份权重」的登记处。
///
/// **存在的理由是内存，不是速度。** M8 第 0 步实测把翻译后端定成了
/// `qwen3-4b-instruct-2507-4bit`——正是校正层在用的那一个。两层各持一个
/// `OneShotLoader` 时，同一份 2 GB 权重会被加载两遍、常驻两份。目标机是
/// 16 GB 的 MacBook Air，逼近换页会让整机变慢（QA I6 记的是同一件事）。
///
/// ### 为什么用锁而不是 actor
///
/// 「查表 → 没有就建 → 写回」这三步之间**必须一个挂起点都没有**，否则两个
/// 并发调用会各建一个加载器，共用当场落空——这正是 `OneShotLoader` 注释里
/// 记着的 M4 那个坑（判重的 await 之间有空隙）在上一层的复现。actor 也能做到
/// 原子，但 actor 的取值只能是 async，而 `MLXCorrector.init` /
/// `MLXTranslator.init` 是同步构造器；改成异步取值就得把登记推迟到第一次用，
/// 平白多一条时序。同步锁把整段临界区压成一次不可中断的调用，
/// 连「插一个 await」的位置都没有。
///
/// ### 值是弱引用——为了不改变现有的生产行为
///
/// 表里存的是**弱引用**，容器的寿命仍归使用者（`MLXCorrector` /
/// `MLXTranslator`）持有。今天 `AppModel` 换校正模型时会新建一个
/// `MLXCorrector`，旧实例连同它的 `ModelContainer` 一起释放；登记处若强持有，
/// 旧模型就永远留在内存里——为省内存做的东西反过来成了泄漏，在这台机器上
/// 是净亏。弱引用下语义是「有人在用就共用，没人用就释放」，
/// 与今天逐字一致，只把「两个使用者各一份」换成了「两个使用者共一份」。
///
/// ### 失败不缓存，但加载器不摘
///
/// 表里缓存的是**加载器**，不是加载结果。失败的重试语义整个留在
/// `OneShotLoader`（它清掉在途任务，下次调用重来），登记处不做任何额外记忆
/// ——用户把指错的目录改对之后不该还要重启。反过来，失败后也**不**把加载器
/// 从表里摘掉：摘掉的话两层会在重试时各建一个新加载器，共用恰好在最需要它的
/// 那一刻（两层同时重试同一个模型）失效。
final class ModelContainerRegistry<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var loaders: [ModelContainerKey: WeakLoaderBox<Value>] = [:]

    init() {}

    /// 取这个模型的加载器，表里没有就建一个。
    ///
    /// - Parameter load: 只有真的要新建时才会被用到；命中已有加载器时整个
    ///   闭包被丢弃。**因此 `load` 必须由 `key` 唯一决定**，两个使用者对同一个
    ///   键给出行为不同的闭包时，谁先到算谁的。这也是两层的错误包装
    ///   （`CorrectorError` / `TranslatorError`）刻意留在各自 `prepare()` 里、
    ///   不写进本闭包的原因：否则「翻译报了个校正的错误类型」会取决于
    ///   哪一层先启动。
    func loader(
        for key: ModelContainerKey,
        load: @escaping @Sendable () async throws -> Value
    ) -> OneShotLoader<Value> {
        lock.lock()
        // 顺手清掉已经没人持有的条目，表不会随着反复换模型无限长大。
        loaders = loaders.filter { $0.value.loader != nil }
        let existing = loaders[key]?.loader
        let loader = existing ?? OneShotLoader(load: load)
        if existing == nil { loaders[key] = WeakLoaderBox(loader) }
        lock.unlock()

        // 日志放在锁外：`AppLogger` 自己也持锁，没必要嵌套。
        //
        // **这一行是真机上唯一能证明「第二层没有再读一遍权重」的证据。**
        // 单元测试注入的假闭包只证明得了共用机制本身，证明不了 2 GB 权重
        // 只落了一次盘。配合两条预热日志里的耗时看：命中的那一层预热耗时
        // 应当接近 0，而真实冷加载实测 14.1 秒、有页缓存时 3.7–8.0 秒
        // （M8 第 0 步）。两条对不上就说明共用没生效。
        AppLogger.shared.log(
            existing == nil
                ? "模型容器：新建加载器（\(key.logDescription)）"
                : "模型容器：共用已有加载器（\(key.logDescription)）"
        )
        return loader
    }

    /// 表里仍有人持有的加载器数量。
    ///
    /// 存在的唯一理由是让「弱引用」这条可测：使用者全部释放之后条目必须消失，
    /// 否则上面那段「不改变现有生产行为」的话就没有任何东西守着。
    var liveLoaderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loaders.values.filter { $0.loader != nil }.count
    }
}

/// 弱引用盒子。字典的值类型不能直接写 `weak`，得裹一层。
private final class WeakLoaderBox<Value: Sendable> {
    weak var loader: OneShotLoader<Value>?
    init(_ loader: OneShotLoader<Value>) { self.loader = loader }
}

/// 进程内唯一的模型容器登记处。
///
/// 单独一个命名空间而不是 `ModelContainerRegistry.shared`：泛型类型不能有
/// static 存储属性。
enum SharedModelContainers {
    static let registry = ModelContainerRegistry<ModelContainer>()
}
