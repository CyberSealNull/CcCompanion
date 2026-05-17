import Foundation
import Security

/// Server configuration used by the app and app group storage.
/// Phase multi-server fallback (2026-05-11): `serverURL` reads endpoint list and
/// current active index. `EndpointResolver` maintains the active endpoint.
nonisolated public enum CcServerConfig {
    public static let appGroup = "group.starryfield.cccompanion"

    private static let kServerURLList = "serverURLList"
    private static let kServerLabelList = "serverLabelList"
    private static let kServerActiveIndex = "serverActiveIndex"
    private static let kLegacySharedSecret = "sharedSecret"
    private static let keychainService = "com.starryfield.cccompanion"
    private static let keychainAccount = "ccc-shared-secret"

    private static let placeholderURL = URL(string: "http://example.com:8795")!
    public static let fallbackSession = "opia"

    public static var endpoints: [(url: String, label: String)] {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return [] }
        let urls = defaults.stringArray(forKey: kServerURLList) ?? []
        let labels = defaults.stringArray(forKey: kServerLabelList) ?? []
        return urls.enumerated().map { idx, u in
            (url: u, label: idx < labels.count ? labels[idx] : "endpoint \(idx + 1)")
        }
    }

    public static func setEndpoints(_ list: [(url: String, label: String)]) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(list.map(\.url), forKey: kServerURLList)
        defaults.set(list.map(\.label), forKey: kServerLabelList)
        let active = max(0, min(activeIndex, list.count - 1))
        defaults.set(active, forKey: kServerActiveIndex)
    }

    public static var activeIndex: Int {
        UserDefaults(suiteName: appGroup)?.integer(forKey: kServerActiveIndex) ?? 0
    }

    public static func setActiveIndex(_ idx: Int) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(max(0, idx), forKey: kServerActiveIndex)
    }

    public static var serverURL: URL {
        let list = endpoints
        if !list.isEmpty {
            let idx = max(0, min(activeIndex, list.count - 1))
            if let u = URL(string: list[idx].url) { return u }
        }
        if let s = UserDefaults(suiteName: appGroup)?.string(forKey: "serverURL"),
           let u = URL(string: s) {
            return u
        }
        if let s = Bundle.main.infoDictionary?["CC_PUSH_SERVER"] as? String,
           let u = URL(string: s) {
            return u
        }
        return placeholderURL
    }

    public static var sharedSecret: String? {
        if let s = keychainSharedSecret(), !s.isEmpty {
            return s
        }
        if let migrated = migrateLegacySharedSecretIfNeeded(), !migrated.isEmpty {
            return migrated
        }
        return Bundle.main.infoDictionary?["CC_PUSH_SECRET"] as? String
    }

    public static func setSharedSecret(_ secret: String?) {
        let trimmed = (secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteKeychainSharedSecret()
        } else {
            setKeychainSharedSecret(trimmed)
        }
        UserDefaults(suiteName: appGroup)?.removeObject(forKey: kLegacySharedSecret)
    }

    public static func authenticatedRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let secret = sharedSecret, !secret.isEmpty {
            request.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        return request
    }

    public static func fetchDefaultSession(using session: URLSession = .shared) async -> String {
        let url = serverURL.appendingPathComponent("health")
        do {
            let (data, _) = try await session.data(for: authenticatedRequest(url: url))
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = obj["default_session"] as? String {
                let trimmed = sid.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        } catch {
            // Older servers may not expose default_session. Use the public fallback.
        }
        return fallbackSession
    }

    @discardableResult
    public static func migrateLegacySharedSecretIfNeeded() -> String? {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let legacy = defaults.string(forKey: kLegacySharedSecret),
              !legacy.isEmpty else {
            return nil
        }
        setKeychainSharedSecret(legacy)
        defaults.removeObject(forKey: kLegacySharedSecret)
        return legacy
    }

    public static func syncToAppGroup() {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(serverURL.absoluteString, forKey: "serverURL")
        migrateLegacySharedSecretIfNeeded()
    }

    @discardableResult
    public static func migrateLegacySingleURLIfNeeded() -> Bool {
        guard endpoints.isEmpty else { return false }
        guard let defaults = UserDefaults(suiteName: appGroup) else { return false }
        var seed: [(url: String, label: String)] = []
        if let legacy = defaults.string(forKey: "serverURL"),
           !legacy.isEmpty,
           !legacy.contains("example.com") {
            seed.append((url: legacy, label: legacyLabel(for: legacy)))
        }
        guard !seed.isEmpty else { return false }
        setEndpoints(seed)
        setActiveIndex(0)
        return true
    }

    private static func legacyLabel(for url: String) -> String {
        if url.contains("100.") { return "Tailscale" }
        if url.contains("10.") || url.contains("192.168.") { return "LAN" }
        if url.contains("localhost") || url.contains("127.0.0.1") { return "Local" }
        return "Server"
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func keychainSharedSecret() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        return secret
    }

    private static func setKeychainSharedSecret(_ secret: String) {
        let data = Data(secret.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(keychainQuery() as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var query = keychainQuery()
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func deleteKeychainSharedSecret() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }
}
