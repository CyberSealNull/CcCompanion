//
//  SecureAPIKeyStore.swift
//  DirectAPICore
//
//  P0 直连: provider API key 只进 Keychain, 绝不落 UserDefaults/日志/commit。
//  二审要求把这条断言变成仓内可复跑的红绿测试(而不是只靠 grep 静态扫描)——纯 Security 框架调用,
//  不依赖任何 app 专属类型(CcServerConfig 等), 抽在这里用 `swift test` 直接验证:
//  写入后遍历 `UserDefaults.standard` 全量 dump, 断言 key 字符串不出现在里面。
//

import Foundation
import Security

public struct SecureAPIKeyStore {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public var apiKey: String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    public var hasApiKey: Bool {
        guard let k = apiKey else { return false }
        return !k.isEmpty
    }

    public func setApiKey(_ key: String?) {
        let trimmed = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            SecItemDelete(keychainQuery() as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(keychainQuery() as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = keychainQuery()
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
