import Foundation

/// 「校正能不能开」的判定与落库。
///
/// 单独拆出来而不是写在 `AppModel` 里，是因为这套规则要么依赖 UI
/// （`AppModel` 要弹 `NSOpenPanel`、要改 `phase`），要么依赖 `UserDefaults`
/// 的写入顺序——两者混在一个方法里就只能靠真机点菜单来验证。拆开之后：
/// 本类型只碰注入的 `CorrectionPreference`，可以在单元测试里穷举「目录非法
/// 时开关不该变成开」这类断言；`AppModel` 只负责把结果翻译成弹面板和错误
/// 提示，不再持有任何判定逻辑。
struct CorrectionActivation {
    /// 一次开启/选模型请求的结果。
    enum Outcome: Equatable {
        /// 目录合法，已记住（若是开启请求，开关同时置为开）。
        case accepted(CorrectionModelDescriptor)
        /// 当前没有合法的模型目录，需要用户选一个。
        case needsModelSelection
        /// 用户给的目录不是 MLX 模型目录，缺少这些文件。开关与偏好都没动。
        case rejected(missing: [String])
    }

    private let preference: CorrectionPreference

    init(preference: CorrectionPreference) {
        self.preference = preference
    }

    /// 校正当前是否开着。
    var isEnabled: Bool { preference.isEnabled }

    /// 当前记住的模型目录名，未指定时为 nil。
    var modelName: String? { preference.modelDirectory?.standardizedFileURL.lastPathComponent }

    /// 用已记住的模型目录开启校正。
    ///
    /// 没记过目录、或记的目录已失效（被移动/删除/根本不是模型），都返回
    /// `.needsModelSelection` 让调用方弹选择器——这两种情况对用户是同一件事：
    /// 「你还没给我一个能用的模型」。**开关在此期间不会被置为开**，
    /// 这正是「开了校正但静默无效」那个缺口的堵法。
    func enableUsingStoredModel() -> Outcome {
        guard let directory = preference.modelDirectory else { return .needsModelSelection }
        guard case .success(let descriptor) = CorrectionModelCatalog.validate(directory: directory) else {
            return .needsModelSelection
        }
        preference.isEnabled = true
        return .accepted(descriptor)
    }

    /// 用用户刚选的目录开启校正。目录非法时什么都不改。
    func enable(with directory: URL) -> Outcome {
        switch CorrectionModelCatalog.validate(directory: directory) {
        case .success(let descriptor):
            preference.modelDirectory = directory
            preference.isEnabled = true
            return .accepted(descriptor)
        case .failure(.notAModelFolder(let missing)):
            return .rejected(missing: missing)
        }
    }

    /// 只更换模型目录，不改开关。
    ///
    /// 校验同样不能省：菜单里的「指定校正模型…」是另一条能把无效路径写进
    /// 偏好的入口，放过它等于留了后门——校正开着、路径失效、界面无提示。
    func selectModel(directory: URL) -> Outcome {
        switch CorrectionModelCatalog.validate(directory: directory) {
        case .success(let descriptor):
            preference.modelDirectory = directory
            return .accepted(descriptor)
        case .failure(.notAModelFolder(let missing)):
            return .rejected(missing: missing)
        }
    }

    /// 关闭校正。不做任何校验——关掉一个失灵的开关永远是安全的。
    func disable() {
        preference.isEnabled = false
    }

    /// 启动时的自检：偏好为「开」但模型目录已失效时，把开关落回「关」。
    ///
    /// 真实发生过：模型目录被移动后，偏好里的路径失效，校正每次都静默走
    /// 降级路径而菜单一直显示「开」。宁可启动时明确关掉并记一行日志，
    /// 也不要带着一个注定失灵的开关运行。
    ///
    /// - Returns: 自检后校正是否仍然开着。
    @discardableResult
    func revalidateAtLaunch() -> Bool {
        guard preference.isEnabled else { return false }
        if let directory = preference.modelDirectory,
           case .success = CorrectionModelCatalog.validate(directory: directory) {
            return true
        }
        preference.isEnabled = false
        return false
    }
}
