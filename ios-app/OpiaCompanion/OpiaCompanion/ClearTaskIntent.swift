//
//  ClearTaskIntent.swift
//  OpiaCompanion + OpiaWidget (shared)
//
//  长按灵动岛胶囊展开后 expanded 区域有 "清除" 按钮 点一下调 server /task/clear-history.
//  iOS 17+ LiveActivityIntent 让 button 在 widget 里直接 trigger 不需要切 app.
//
//  Important: Target Membership 必须同时勾上 OpiaCompanion 和 OpiaWidget Extension 两个 target.
//

import AppIntents
import Foundation

#if os(iOS)
@available(iOS 17.0, *)
public struct ClearTaskIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "清除任务历史"
    public static var description = IntentDescription("清空灵动岛上完成的任务历史")
    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        let url = OpiaServerConfig.serverURL.appendingPathComponent("task/clear-history")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = OpiaServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        req.httpBody = "{}".data(using: .utf8)
        req.timeoutInterval = 6

        // fire-and-forget — server 会自动 push 新状态回 widget
        _ = try? await URLSession.shared.data(for: req)
        return .result()
    }
}
#endif

/// Server 配置 — widget extension 也能拿到.
/// Phase multi-server fallback (2026-05-11) — `serverURL` 现读多 endpoint 列表 +
/// 当前 active index. `EndpointResolver` 后台 ping /health 维护 active. 全 app
/// 调用点不变 (sync getter), URL 路由透明切换.
nonisolated public enum OpiaServerConfig {
    public static let appGroup = "group.starryfield.opia"

    private static let kServerURLList = "serverURLList"     // [String] (URLs in priority order)
    private static let kServerLabelList = "serverLabelList" // [String] (matching labels)
    private static let kServerActiveIndex = "serverActiveIndex" // Int (which list[i] is active)

    /// Default 阉割版 onboarding placeholder — 用户没填任何 endpoint 时挡一下.
    private static let placeholderURL = URL(string: "http://example.com:8795")!

    /// 完整 endpoint 列表 (URL + label).
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
        // Clamp active index
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

    /// Currently active server URL — sync getter, callers don't care which endpoint won.
    public static var serverURL: URL {
        let list = endpoints
        if !list.isEmpty {
            let idx = max(0, min(activeIndex, list.count - 1))
            if let u = URL(string: list[idx].url) { return u }
        }
        // Legacy single-URL fallback (kept for backwards compat with older installs)
        if let s = UserDefaults(suiteName: appGroup)?.string(forKey: "serverURL"),
           let u = URL(string: s) {
            return u
        }
        if let s = Bundle.main.infoDictionary?["OPIA_PUSH_SERVER"] as? String,
           let u = URL(string: s) {
            return u
        }
        // 2026-05-09 用户 push 阉割版 onboarding 默认 placeholder 防泄漏私网 IP
        // 用户必须在第一次启动 wizard 填自己 server URL UserDefaults 才会有真值
        return placeholderURL
    }

    public static var sharedSecret: String? {
        if let s = UserDefaults(suiteName: appGroup)?.string(forKey: "sharedSecret") {
            return s
        }
        return Bundle.main.infoDictionary?["OPIA_PUSH_SECRET"] as? String
    }

    public static func syncToAppGroup() {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(serverURL.absoluteString, forKey: "serverURL")
        if let sharedSecret {
            defaults.set(sharedSecret, forKey: "sharedSecret")
        }
    }

    /// One-shot migration: 旧版 `serverURL` 单字段 → 新版 endpoints 列表.
    /// 调用安全幂等 — endpoints 已存在则跳过. 用 install 时默认带上 Tailscale fallback.
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
}
