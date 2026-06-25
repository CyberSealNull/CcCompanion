import SwiftUI
import Combine

// 微信主题 v2.8 修: 微信顶栏昵称改成跟设置里的「AI 名字」(ai_name) 走, 不再读 server /status/wechat_nick.
// 根因: 旧 v2.7 C 版只拉 server wechat_nick, 跟本地 ai_name 完全脱节, 用户在设置改了 AI 名字微信顶栏不变。
// 设置/Onboarding 改名 → CcNameResolver.notifyChanged() 发 .ccIdentityDidChange → 这里实时刷新, 顶栏 + 反向拍一拍灰字 + 引用块全跟着变。

@MainActor
final class WechatNickStore: ObservableObject {
    static let shared = WechatNickStore()

    @Published private(set) var nick: String = CcNameResolver.name(for: .ai)

    private var cancellable: AnyCancellable?

    private init() {
        // 订阅改名通知, ai_name 一变微信昵称立刻跟着变 (跟其它主题统一).
        cancellable = NotificationCenter.default.publisher(for: .ccIdentityDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    /// 进微信主题 / app 启动 / 改名后调, 同步当前 ai_name (兼容旧调用点 onAppear { refresh() }).
    func refresh(force: Bool = false) {
        nick = CcNameResolver.name(for: .ai)
    }
}
