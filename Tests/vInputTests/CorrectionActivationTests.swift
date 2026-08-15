import Foundation
import Testing

@testable import vInput

@Suite("校正开关的模型校验")
struct CorrectionActivationTests {
    /// 每个测试用独立的 suite，否则测试之间会通过 UserDefaults 互相污染。
    private func makeActivation() -> (CorrectionActivation, CorrectionPreference) {
        let defaults = UserDefaults(suiteName: "vinput.activation.tests.\(UUID().uuidString)")!
        let preference = CorrectionPreference(defaults: defaults)
        return (CorrectionActivation(preference: preference), preference)
    }

    private func makeValidModel() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vinput-activation-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in ["config.json", "tokenizer_config.json", "model.safetensors"] {
            try Data().write(to: dir.appendingPathComponent(file))
        }
        return dir
    }

    private func makeBogusFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vinput-not-a-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("照片.jpg"))
        return dir
    }

    private func remove(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    /// 比路径而不是比 URL：`UserDefaults` 存取一个**真实存在的目录** URL 时，
    /// 取回来的会多一个尾斜杠（`…/model` → `…/model/`），`==` 于是不成立。
    /// 指向的目录是同一个，对下游（校验取 `.path`、MLX 取目录）没有影响。
    private func isSameDirectory(_ lhs: URL?, _ rhs: URL?) -> Bool {
        lhs?.standardizedFileURL.path == rhs?.standardizedFileURL.path
    }

    // MARK: - 开启

    @Test("没指定过模型时，开启请求要求先选目录，且开关不变成开")
    func enableWithoutModelAsksForSelection() {
        let (activation, preference) = makeActivation()

        #expect(activation.enableUsingStoredModel() == .needsModelSelection)
        #expect(!preference.isEnabled, "没有合法模型就不该开着")
    }

    @Test("记住的目录已失效时，开启请求要求重选，且开关不变成开")
    func enableWithStaleModelAsksForSelection() throws {
        let (activation, preference) = makeActivation()
        let model = try makeValidModel()
        preference.modelDirectory = model
        // 模拟「模型目录被移走」——真实发生过的那个场景。
        remove(model)

        #expect(activation.enableUsingStoredModel() == .needsModelSelection)
        #expect(!preference.isEnabled)
    }

    @Test("选了合法目录：记住它并成功开启")
    func enableWithValidFolderSucceeds() throws {
        let (activation, preference) = makeActivation()
        let model = try makeValidModel()
        defer { remove(model) }

        guard case .accepted(let descriptor) = activation.enable(with: model) else {
            Issue.record("合法目录应被接受"); return
        }
        #expect(descriptor.directory == model)
        #expect(preference.isEnabled)
        #expect(isSameDirectory(preference.modelDirectory, model))
    }

    /// 第 7 条：目录非法时，开启校正的请求不应让偏好变成「开」。
    @Test("选了不是模型的目录：不开启、不保存，并报出缺了什么")
    func enableWithBogusFolderIsRejected() throws {
        let (activation, preference) = makeActivation()
        let bogus = try makeBogusFolder()
        defer { remove(bogus) }

        guard case .rejected(let missing) = activation.enable(with: bogus) else {
            Issue.record("非模型目录应被拒"); return
        }
        #expect(missing.contains("config.json"))
        #expect(missing.contains("tokenizer_config.json"))
        #expect(missing.contains(CorrectionModelCatalog.weightsLabel))
        #expect(!preference.isEnabled, "被拒的目录不该让校正开着")
        #expect(preference.modelDirectory == nil, "被拒的目录不该写进偏好")
    }

    @Test("已记住合法目录时，开启请求直接成功，不再追问")
    func enableWithStoredValidModelSucceeds() throws {
        let (activation, preference) = makeActivation()
        let model = try makeValidModel()
        defer { remove(model) }
        preference.modelDirectory = model

        guard case .accepted = activation.enableUsingStoredModel() else {
            Issue.record("已有合法模型时应直接开启"); return
        }
        #expect(preference.isEnabled)
    }

    // MARK: - 指定模型

    @Test("指定合法模型：保存目录，不改开关")
    func selectValidModelKeepsToggle() throws {
        let (activation, preference) = makeActivation()
        let model = try makeValidModel()
        defer { remove(model) }

        guard case .accepted = activation.selectModel(directory: model) else {
            Issue.record("合法目录应被接受"); return
        }
        #expect(isSameDirectory(preference.modelDirectory, model))
        #expect(!preference.isEnabled, "指定模型不该顺手把校正打开")
    }

    @Test("指定非模型目录：不保存，旧目录保持不变")
    func selectBogusModelKeepsOldDirectory() throws {
        let (activation, preference) = makeActivation()
        let model = try makeValidModel()
        let bogus = try makeBogusFolder()
        defer { remove(model); remove(bogus) }
        preference.modelDirectory = model

        guard case .rejected(let missing) = activation.selectModel(directory: bogus) else {
            Issue.record("非模型目录应被拒"); return
        }
        #expect(!missing.isEmpty)
        #expect(isSameDirectory(preference.modelDirectory, model), "被拒时不该覆盖掉原来能用的目录")
    }

    // MARK: - 关闭

    @Test("关闭不需要任何校验")
    func disableNeedsNoValidation() {
        let (activation, preference) = makeActivation()
        preference.isEnabled = true
        preference.modelDirectory = URL(fileURLWithPath: "/早就没了的路径")

        activation.disable()

        #expect(!preference.isEnabled)
    }

    // MARK: - 启动自检

    /// 第 8 条：启动时若偏好为「开」但模型已失效 → 变成「关」。
    @Test("启动自检：开着但模型已失效则自动关闭")
    func launchTurnsOffStaleCorrection() throws {
        let (activation, preference) = makeActivation()
        let model = try makeValidModel()
        preference.modelDirectory = model
        preference.isEnabled = true
        remove(model)   // 模型目录被移走

        #expect(activation.revalidateAtLaunch() == false)
        #expect(!preference.isEnabled, "带着一个注定失灵的开关运行是这次要堵的缺口")
    }

    @Test("启动自检：开着但从未指定模型也自动关闭")
    func launchTurnsOffWhenNoModelEverPicked() {
        let (activation, preference) = makeActivation()
        preference.isEnabled = true

        #expect(activation.revalidateAtLaunch() == false)
        #expect(!preference.isEnabled)
    }

    @Test("启动自检：模型仍在则保持开启")
    func launchKeepsValidCorrection() throws {
        let (activation, preference) = makeActivation()
        let model = try makeValidModel()
        defer { remove(model) }
        preference.modelDirectory = model
        preference.isEnabled = true

        #expect(activation.revalidateAtLaunch() == true)
        #expect(preference.isEnabled)
    }

    @Test("启动自检：本来就关着的不受影响")
    func launchLeavesDisabledAlone() {
        let (activation, preference) = makeActivation()

        #expect(activation.revalidateAtLaunch() == false)
        #expect(!preference.isEnabled)
    }
}
