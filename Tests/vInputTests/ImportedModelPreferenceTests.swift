import Foundation
import Testing

@testable import vInput

/// 「我已经有模型文件」导入进来的目录：**必须跨启动记得住**。
///
/// 失效链（QA 2026-08-22）：向导第四步导入 `~/Desktop/openai_whisper-...`
/// → `selectModelFromFolder` 换上去 → 这一次能用 → 关掉应用 →
/// `bootstrap()` 只用 `discover(modelRoot)` 重建列表 → 那个模型没了 →
/// 直接掉进「零模型」那个状态。而这条逃生口正是「把本机现成的模型目录
/// 拷给太太」那条路——产品经理打算用的就是它。
struct ImportedModelPreferenceTests {
    private func makeDefaults() -> UserDefaults {
        let name = "imported-models-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func startsEmpty() {
        #expect(ImportedModelPreference(defaults: makeDefaults()).folders.isEmpty)
    }

    /// 记下来的东西**换一个实例照样读得到**——那就是「下次启动」这件事在
    /// 单测里的样子。
    @Test func rememberedFolderSurvivesANewInstance() {
        let defaults = makeDefaults()
        ImportedModelPreference(defaults: defaults).remember("/Users/x/Desktop/turbo")
        #expect(
            ImportedModelPreference(defaults: defaults).folders == ["/Users/x/Desktop/turbo"])
    }

    /// 同一个目录记两次只算一次，并且第二次要**说出来它不是新的**——
    /// 调用方拿这个返回值决定要不要重扫列表。
    @Test func rememberIsIdempotentAndReportsWhetherItWasNew() {
        let preference = ImportedModelPreference(defaults: makeDefaults())
        let first = preference.remember("/a/turbo")
        let second = preference.remember("/a/turbo")
        #expect(first == true)
        #expect(second == false)
        #expect(preference.folders == ["/a/turbo"])
    }

    /// 记得住多个：用户完全可能先导一个 turbo、再导一个 large-v3。
    /// 顺序按记下来的先后（面板的排序另有一套，见 `ModelCatalog.merge`）。
    @Test func remembersSeveralInOrder() {
        let preference = ImportedModelPreference(defaults: makeDefaults())
        preference.remember("/a/turbo")
        preference.remember("/b/large")
        #expect(preference.folders == ["/a/turbo", "/b/large"])
    }

    /// 启动复核：目录搬走了/删了就忘掉，并且把忘掉的报出来记日志。
    ///
    /// 不忘的话它会一直挂在面板的模型列表里，用户每次点都得到一句
    /// 「这不是模型目录，缺少：…」，而他根本不记得自己导入过什么。
    @Test func revalidateForgetsFoldersThatAreGone() {
        let preference = ImportedModelPreference(defaults: makeDefaults())
        preference.remember("/still/here")
        preference.remember("/moved/away")

        let dropped = preference.revalidate { $0 == "/still/here" }

        #expect(dropped == ["/moved/away"])
        #expect(preference.folders == ["/still/here"])
    }

    /// 都还在时**一个都不许丢**，也不该报出任何东西。
    ///
    /// 反向的这一条是必要的：把 `revalidate` 写成「一律清空」也能让上面那条
    /// 绿（`dropped` 里确实有 `/moved/away`，`folders` 里确实没有它）。
    @Test func revalidateKeepsEverythingThatIsStillValid() {
        let preference = ImportedModelPreference(defaults: makeDefaults())
        preference.remember("/a")
        preference.remember("/b")

        let dropped = preference.revalidate { _ in true }

        #expect(dropped.isEmpty)
        #expect(preference.folders == ["/a", "/b"])
    }

    /// 忘掉这件事本身也要**留得住**：复核完就该是新的那一份，
    /// 不然下次启动又会把已经不在的目录读回来。
    @Test func revalidateResultIsPersisted() {
        let defaults = makeDefaults()
        let preference = ImportedModelPreference(defaults: defaults)
        preference.remember("/gone")
        preference.revalidate { _ in false }
        #expect(ImportedModelPreference(defaults: defaults).folders.isEmpty)
    }

    /// 存的不是字符串数组（手改过 plist、旧版本残留）时退回空数组，
    /// 失败方向是「当作没导入过」——那只是回到没有这个功能之前，不会崩。
    @Test func garbageInDefaultsReadsAsEmpty() {
        let defaults = makeDefaults()
        defaults.set(42, forKey: ImportedModelPreference.foldersKey)
        #expect(ImportedModelPreference(defaults: defaults).folders.isEmpty)
    }
}
