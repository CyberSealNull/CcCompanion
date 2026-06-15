import SwiftUI
import Combine

// 微信主题 v2.7 C: 微信昵称.
// 只微信主题读 GET /status/wechat_nick (顶栏 + 反向拍一拍灰字用), 其它主题仍走原 aiName.
// 拉取前 / 失败回退 FlavorConfig.defaultWechatNick (私版默认 AI 名 / 公开版中性).

private struct WechatNickResponse: Codable {
    let ok: Bool?
    let nick: String?
}

@MainActor
final class WechatNickStore: ObservableObject {
    static let shared = WechatNickStore()

    @Published private(set) var nick: String = FlavorConfig.defaultWechatNick

    private var lastLoaded: Date?

    /// 进微信主题 / app 启动调. 60s 内有缓存且非强制不重复拉.
    func refresh(force: Bool = false) {
        if !force, let last = lastLoaded, Date().timeIntervalSince(last) < 60 { return }
        Task { await load() }
    }

    func load() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("status/wechat_nick")
        if let (data, _) = try? await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url)),
           let resp = try? JSONDecoder().decode(WechatNickResponse.self, from: data),
           let n = resp.nick, !n.isEmpty {
            self.nick = n
            self.lastLoaded = Date()
        }
        // 失败保留旧值, 不崩.
    }
}
