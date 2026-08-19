import Foundation
import Security

/// 从 Keychain 读云端翻译的 API key。
///
/// # key 只由用户自己放进 Keychain，不进对话也不进仓库
///
/// 对话记录以明文长期留在 `~/.claude/projects/…/*.jsonl`；本仓库又在
/// OneDrive 下，提交即上云。两条都不是放密钥的地方。
///
/// 用户放 key 的命令（`-w` 后不带值，交互式输入，key 也不进 shell 历史）：
///
/// ```
/// security add-generic-password -a vInput -s vinput-gemini-api-key -w
/// ```
///
/// # 为什么这一层要单独存在
///
/// 它是**唯一**读密钥的地方。散在各处的话，「有没有哪条路径把 key 打进了
/// 日志」就得靠人逐处去看；收在这里之后，那件事只需要看这一个文件——
/// 本类型不记任何日志，也不把读到的值放进任何错误消息里。
enum TranslationKey {
    /// Gemini 的服务名。**改它等于让每个用户已经存好的 key 凭空消失**，
    /// 而表现是「配了 key 却说没配」——用户无从判断是自己存错了还是程序
    /// 换了地方找。`TranslationKeyTests.serviceNameIsStable` 钉住这个字面量，
    /// 与 `TranslationTarget` 的 rawValue 同一条理由：它是写进用户机器上的
    /// 标识符，不是内部命名。
    static let geminiService = "vinput-gemini-api-key"

    /// 读一个 generic password。读不到返回 nil。
    ///
    /// **读不到时返回 nil 而不是空字符串**——空字符串会让请求带着空 key
    /// 发出去，用户看到的是一个看不懂的 401。同理，Keychain 里存的就是空
    /// 值（或只有空白）时也返回 nil：那和没存是同一件事，而空 key 发出去
    /// 会把「没配」伪装成「配错了」。
    ///
    /// ## 查询里刻意**不带** account
    ///
    /// 上面那条命令用的是 `-a vInput`，但用户完全可能用别的 account 存
    /// （`-a` 写成邮箱、或从别的工具导入）。查询里钉死 account 的后果是
    /// key 明明在 Keychain 里却读不到，而程序说的是「没配 API key」——
    /// 用户会照着提示再存一遍，还是读不到。服务名本身
    /// （`vinput-gemini-api-key`）已经足够专属，不需要再靠 account 区分。
    ///
    /// 同一服务名下存了多条时 `kSecMatchLimitOne` 取其中一条（哪一条由
    /// Keychain 决定）。这不做特殊处理：真出现两条时用户要做的是删掉多余
    /// 的那条，而程序无从判断哪条是对的。
    ///
    /// ## 首尾空白要去掉
    ///
    /// 用户很可能是 `-w "$(cat key.txt)"` 或从网页复制粘贴过来的，尾部
    /// 带个换行是常事。带着换行发出去同样是一个看不懂的 401，而用户对着
    /// Keychain 里那条记录怎么看都是对的。
    /// 把 key 写进 Keychain。已有就覆盖。
    ///
    /// **写入路径存在的理由**：原来只能靠命令行
    /// `security add-generic-password -a vInput -s … -w`。让一个产品的
    /// 「用户显式开」动作只能在终端里完成，等于这个开关对多数人不存在。
    ///
    /// **key 一个字节都不进日志、不进错误信息。** 下面只回报成功与否，
    /// 连长度都不报——日志是会被贴进对话、贴进 issue 的东西。
    ///
    /// 存之前 trim 首尾空白：从网页复制 key 时带上换行是常事，而带着换行
    /// 发出去只会换回一个看不懂的 401。
    @discardableResult
    static func write(_ key: String, service: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        // 先试更新，没有再新建。反过来写的话，已存在时 SecItemAdd 会返回
        // errSecDuplicateItem，而那条路径很容易被当成「写失败」。
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insert = query
        insert[kSecValueData as String] = data
        // 账户名与文档里那条 security 命令保持一致，这样命令行存的和界面存的
        // 是同一条记录，用户换着用不会看到两份。
        insert[kSecAttrAccount as String] = "vInput"
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// 删掉 key。用户要撤回授权时用。
    @discardableResult
    static func delete(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        // 不区分 errSecItemNotFound 与其它失败：调用方能做的动作只有一个
        // （去存一个 key），而 OSStatus 的数字对用户没有意义。
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
