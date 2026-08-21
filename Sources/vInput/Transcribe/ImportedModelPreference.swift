import Foundation

/// 「我已经有模型文件」导入进来的那些模型目录。
///
/// ## 为什么必须存
///
/// 向导第四步的「我已经有模型文件」和面板里的「其他目录…」，走的都是
/// `AppModel.selectModelFromFolder`。它只是把目录交给转写器换上去，
/// **没有任何人把这个路径记下来**；而 `bootstrap()` 每次启动都只用
/// `ModelCatalog.discover(modelRoot)` 重建列表。于是从 `~/Desktop/` 导入的
/// 模型这一次能用，下次启动就没了——直接掉进「零模型」那个状态。
///
/// 这条逃生口正是设计里写明给「把本机现成的模型目录拷给太太」用的那条路，
/// 也是产品经理打算用的那条。
///
/// ## 为什么是记路径，不是把目录拷进模型根目录
///
/// 拷贝对不懂技术的人更稳（源目录被删/被移走也不怕），但代价是真的：
///
/// - 盘上多出一份 1.5 GB。而这条路存在的**理由本身**就是「不想再来一次
///   1.5 GB」，转头又复制一份 1.5 GB，说不过去。
/// - 拷贝要多久没有上界。源可能在 U 盘、在外置硬盘、在网络卷上；要做对
///   就得有进度、能取消、失败要清掉半份残留——那是一整套新东西，而且
///   跟下载一样在测试进程里跑不到。
/// - 「目录被移走了怎么办」已经有现成且被验证过的答法：启动时复核一遍，
///   不合法就忘掉并记日志（`CorrectionActivation.revalidateAtLaunch()`
///   对校正模型做的就是这件事）。忘掉之后面板头部会**如实说**
///   「还没有语音模型」，不会再假装就绪——那正是同一批里 S-2 修掉的东西。
///
/// 存的是路径数组而不是单个路径：两个入口（向导、面板）都会往里加，
/// 而用户完全可能先导入一个 turbo、再导入一个 large-v3。
///
/// 注入 `UserDefaults` 而非直接用 `.standard`，理由同 `DownloadSourcePreference`：
/// 测试要互不干扰的独立存储。
struct ImportedModelPreference {
    /// **全仓唯一的一处。** 理由同 `DownloadSourcePreference.forcedKey`：
    /// 两边各写一遍字面量的话，拼错一个字母的表现是「导入的模型下次启动
    /// 就是没了」，而没有任何编译错误。
    static let foldersKey = "model.importedFolders"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 记着的那些目录，按记下来的先后。
    ///
    /// `stringArray(forKey:)` 读到非字符串数组时返回 nil（手改过 plist、
    /// 旧版本残留），退回空数组——失败方向是「当作没导入过」，
    /// 那只是回到没有这个功能之前，不会崩。
    var folders: [String] {
        get { defaults.stringArray(forKey: Self.foldersKey) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Self.foldersKey) }
    }

    /// 记下一个目录。已经记过就不动。
    /// - Returns: 这次是不是**新**记的。调用方据此决定要不要重扫列表。
    @discardableResult
    nonmutating func remember(_ folder: String) -> Bool {
        var current = folders
        guard !current.contains(folder) else { return false }
        current.append(folder)
        folders = current
        return true
    }

    /// 启动复核：记着的目录还在不在、还是不是模型目录。
    ///
    /// **不合法的当场忘掉**，否则它会一直挂在列表里，用户每次点它都得到
    /// 一句「这不是模型目录，缺少：…」，而他根本不记得自己导入过什么。
    ///
    /// - Returns: 被忘掉的那些，调用方拿去记日志（用户看不见这一步，
    ///   而「我导入的模型怎么没了」是会被问起的问题）。
    @discardableResult
    nonmutating func revalidate(isValid: (String) -> Bool) -> [String] {
        let current = folders
        let survivors = current.filter(isValid)
        guard survivors.count != current.count else { return [] }
        folders = survivors
        return current.filter { !isValid($0) }
    }
}
