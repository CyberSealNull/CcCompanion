//
//  DirectAPIConfig.swift
//  CcCompanion
//
//  P0 直连: 主 chat 双 backend 模式配置. .ccServer = 现路径(经 apns-server, 逐字节不变);
//  .directAPI = 直连 provider API SSE, 不经 server, 不装 Claude Code 也能用.
//  API key 只进 Keychain(照 CcServerConfig.swift:14-15 现成模式), 不进 UserDefaults/日志/commit.
//

import Foundation
// code review P0-4: 纯逻辑(provider/adapter/SSE解析/baseURL校验)抽成本地 SPM package DirectAPICore,
// swift test 真跑单测(见 DirectAPICore/Tests/), 不再是不可复跑的会话临时脚本. app 侧只留状态存取
// (Keychain/UserDefaults/app-group) 这些天然绑 app 运行环境、不该进纯逻辑包的部分.
import DirectAPICore

extension Notification.Name {
    /// P0 直连: `DirectAPIConfig.mode` 变更时发出. ChatViewModel 监听它取消旧模式在途任务(backfill/SSE/poll)
    /// 再重启, 不能指望调用点"下次读到新值就自动对"(computed 路由不保证跨 await 稳定).
    static let ccDirectAPIModeChanged = Notification.Name("ccDirectAPIModeChanged")
}

enum ChatBackendMode: String {
    case ccServer
    case directAPI
}

nonisolated enum DirectAPIConfig {
    private static let kMode = "directapi.mode"
    private static let kProvider = "directapi.provider"
    private static let kBaseURL = "directapi.baseURL"
    private static let kModel = "directapi.model"
    private static let kPersona = "ai_persona"

    private static let keychainService = "com.starryfield.cccompanion"
    private static let keychainAccount = "ccc-direct-api-key"

    static let defaultOpenAICompatBaseURL = "https://api.openai.com/v1"
    static let defaultPersonaTemplate = """
    你是一个友善、简洁、有帮助的助手。用自然口语化的语言回复(跟随对方使用的语言),不说套话,直接给出有用的回答。
    """

    // MARK: - Mode (app group UserDefaults, 参照 CcServerConfig 键风格)

    static var mode: ChatBackendMode {
        get {
            guard let raw = UserDefaults(suiteName: CcServerConfig.appGroup)?.string(forKey: kMode),
                  let m = ChatBackendMode(rawValue: raw) else { return .ccServer }
            return m
        }
        set {
            let changed = newValue != mode
            UserDefaults(suiteName: CcServerConfig.appGroup)?.set(newValue.rawValue, forKey: kMode)
            // code review 抓到(critical): dbQueue 是运行时 computed 路由, 不保证跨 await 的整项操作(backfill/SSE)
            // 归属稳定. 模式切换必须是显式生命周期事件, 让 ChatViewModel 取消旧模式在途任务再重启, 不能指望
            // "调用点下次读到新值就自动对" —— 详见 learnings/2026-07-13_运行时computed路由跨await会串库.
            if changed {
                NotificationCenter.default.post(name: .ccDirectAPIModeChanged, object: nil)
            }
        }
    }

    /// 单一门控读点: 一切「directAPI 模式下要 gate 掉的 server 功能」都读这个, 不在各调用点零散判断.
    static var isActive: Bool { mode == .directAPI }

    // MARK: - Provider config

    static var provider: DirectAPIProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: kProvider),
                  let p = DirectAPIProvider(rawValue: raw) else { return .anthropic }
            return p
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: kProvider) }
    }

    static var baseURL: String {
        get {
            let saved = UserDefaults.standard.string(forKey: kBaseURL) ?? ""
            return saved.isEmpty ? defaultOpenAICompatBaseURL : saved
        }
        set { UserDefaults.standard.set(newValue, forKey: kBaseURL) }
    }

    static var model: String {
        get {
            let saved = UserDefaults.standard.string(forKey: kModel) ?? ""
            return saved.isEmpty ? provider.defaultModel : saved
        }
        set { UserDefaults.standard.set(newValue, forKey: kModel) }
    }

    // MARK: - Persona (设置页 + onboarding 门 B 共用同一个 key)

    static var persona: String {
        get {
            let saved = UserDefaults.standard.string(forKey: kPersona) ?? ""
            return saved.isEmpty ? defaultPersonaTemplate : saved
        }
        set { UserDefaults.standard.set(newValue, forKey: kPersona) }
    }

    /// directAPI system prompt = persona + 身份拼装. 公开版没有 vault, 不引入任何咱家记忆文件路径.
    static func composeSystemPrompt() -> String {
        let aiName = CcNameResolver.name(for: .ai)
        let userName = CcNameResolver.name(for: .user)
        return "\(persona)\n\n你叫 \(aiName), 对方是 \(userName)。"
    }

    // MARK: - API key (Keychain only)
    //
    // 二审(P0-4): 实际的 SecItem 调用搬进 DirectAPICore 的 SecureAPIKeyStore(纯 Foundation+Security,
    // 不依赖任何 app 专属类型), 用 swift test 真跑验证"key 不落 UserDefaults dump"(见
    // SecureAPIKeyStoreTests), 不再只靠会话临时 grep. service/account 字符串跟改动前逐字节一致,
    // 已经存过的 Keychain item 不受影响.
    private static let keyStore = SecureAPIKeyStore(service: keychainService, account: keychainAccount)

    static var apiKey: String? { keyStore.apiKey }
    static var hasApiKey: Bool { keyStore.hasApiKey }
    static func setApiKey(_ key: String?) { keyStore.setApiKey(key) }
}
