import Foundation
import Security
import Testing

@testable import vInput

/// 从 Keychain 读云端 API key。
///
/// # 这套用例真的会写 Keychain，写完立刻删
///
/// 只测「读不到时返回 nil」是**测不出任何东西**的：把 `read` 改成
/// `return nil` 一条不红。而 `read` 里真正会出错的地方全在查询字典上
/// （类别写错、忘了 `kSecReturnData`、多带了一个 account），那些错误的
/// 表现都是「永远读不到」，只有一条真的存进去过的记录能把它们分开。
///
/// 所以这里用随机服务名（`vinput-test-<uuid>`）存一条、读一条、删一条。
/// 2026-08-19 在本机实测过这条路径：`SecItemAdd` / `SecItemCopyMatching` /
/// `SecItemDelete` 三步的 OSStatus 全是 0，**不弹任何授权对话框**——同一个
/// 进程刚创建的条目，它自己读回来不需要授权。删除写在 `defer` 里，用例中途
/// 失败也会清掉。
///
/// 真 key 一个字都不会出现在这里：存进去的是明写的假串。
///
/// # 变异表（2026-08-19 实测）
///
/// | 变异 | 结果 |
/// |---|---|
/// | `read` 直接 `return nil` | 3 条红（读回、换 account、去空白） |
/// | 查询里加 `kSecAttrAccount: "vInput"` | `accountIsNotPartOfTheQuery` 红 |
@Suite("云端 API key 的 Keychain 读取")
struct TranslationKeyTests {
    /// 一条只在本用例存活的 Keychain 记录。
    ///
    /// 返回服务名而不是让调用方自己拼：服务名要随机（并行跑的用例之间不能
    /// 互相看见），而随机就意味着「忘了删」时留下的垃圾无法追溯——统一带
    /// `vinput-test-` 前缀，真出事时一条命令就能清干净：
    /// `security delete-generic-password -s <服务名>`。
    private func withStoredSecret(
        _ value: String,
        account: String = "vInput",
        _ body: (String) throws -> Void
    ) throws {
        let service = "vinput-test-\(UUID().uuidString)"
        let status = SecItemAdd(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: Data(value.utf8),
            ] as CFDictionary, nil)
        defer {
            SecItemDelete(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                ] as CFDictionary)
        }
        try #require(
            status == errSecSuccess,
            "往 Keychain 写测试记录失败，OSStatus=\(status)。这套用例没法证明 read 能读到东西。"
        )
        try body(service)
    }

    // MARK: - 计划要求的两条

    /// 没存过就是 nil。**随机服务名**，不是某个可能真的存在的名字——
    /// 用 `geminiService` 的话，开发机上真配了 key 时这条会红。
    @Test("没有存过 key 时返回 nil")
    func missingKeyReturnsNil() {
        #expect(TranslationKey.read(service: "vinput-absent-\(UUID().uuidString)") == nil)
    }

    /// 服务名是**写进用户机器**的标识符，不是内部命名。
    ///
    /// 用户按文档跑的是
    /// `security add-generic-password -a vInput -s vinput-gemini-api-key -w`，
    /// 改了这个常量等于让每个人已经存好的 key 凭空消失，而程序说的是
    /// 「没配 API key」——用户会照着提示再存一遍，还是读不到。
    /// 与 `Language` 的 rawValue 同一条理由。
    @Test("服务名稳定")
    func serviceNameIsStable() {
        #expect(TranslationKey.geminiService == "vinput-gemini-api-key")
    }

    // MARK: - 真的存一条进去，才谈得上「读得到」

    /// 存什么读回什么。**把 `read` 改成 `return nil` 时只有这一类用例会红。**
    @Test("存进去的 key 能原样读回来")
    func storedKeyIsReadBack() throws {
        try withStoredSecret("not-a-real-key-1234") { service in
            #expect(TranslationKey.read(service: service) == "not-a-real-key-1234")
        }
    }

    /// **查询里不带 account**：用户完全可能用别的 account 存
    /// （`-a` 写成邮箱、或从别的工具导入）。查询里钉死 `kSecAttrAccount`
    /// 的后果是 key 明明在 Keychain 里却读不到，而程序说的是「没配」。
    ///
    /// 往 `read` 的查询里加一行 `kSecAttrAccount: "vInput"`，这条立刻红。
    @Test("account 不参与查询：换个 account 存的也读得到")
    func accountIsNotPartOfTheQuery() throws {
        try withStoredSecret("not-a-real-key-abcd", account: "someone@example.com") { service in
            #expect(TranslationKey.read(service: service) == "not-a-real-key-abcd")
        }
    }

    /// 存了个空值等于没存。
    ///
    /// 空串返回出去的话，请求会带着空 key 发出去，用户看到的是一个看不懂的
    /// 401——「没配」被伪装成了「配错了」，而这两件事要做的动作不同。
    @Test("存的是空值时按没存处理")
    func emptyValueReadsAsNil() throws {
        try withStoredSecret("   \n ") { service in
            #expect(TranslationKey.read(service: service) == nil)
        }
    }

    /// 首尾空白要去掉。
    ///
    /// 用户很可能是 `-w "$(cat key.txt)"` 或从网页复制粘贴过来的，尾部带个
    /// 换行是常事。带着换行发出去同样是一个看不懂的 401，而他对着 Keychain
    /// 里那条记录怎么看都是对的。
    @Test("首尾空白与换行被去掉")
    func surroundingWhitespaceIsTrimmed() throws {
        try withStoredSecret("  not-a-real-key-efgh\n") { service in
            #expect(TranslationKey.read(service: service) == "not-a-real-key-efgh")
        }
    }
}
