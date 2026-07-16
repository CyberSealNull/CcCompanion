//
//  ContentView.swift
//  CcCompanion
//
//  主 app 控制台 — 启动 Live Activity + 本地 update + 结束.
//  v0.1 没接 APNs 全部本地 (path A per code review).
//

import SwiftUI

struct ThemeSettingsCard: View {
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("外观", systemImage: "paintbrush.fill")
                .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                .foregroundStyle(Color.ccAccent)

            VStack(alignment: .leading, spacing: 6) {
                Text("主题")
                    .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ccTextDim)
                Picker("主题", selection: $theme.theme) {
                    ForEach(CcTheme.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("夜间 / 白天")
                    .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ccTextDim)
                Picker("外观", selection: $theme.schemePref) {
                    ForEach(CcColorSchemePref.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(14)
        .background(Color.ccCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ContentView: View {
    @State private var showFavorites = false
    @State private var selectedTab: Int = 0
    @State private var chatScrollToken: Int = 0
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var theme = ThemeStore.shared
    // Build 215 T1 — GroupStore 提到 ContentView 层 让 tab badge 能读 unread / mention 计数.
    // GroupChatView 接受 @ObservedObject 共用同一个实例 (避免双 store 双 polling).
    @StateObject private var groupStore = GroupStore()
    // Build 215 P4 — chat tab unread badge store (跑独立 light polling 不依赖 ChatViewModel)
    @StateObject private var chatBadgeStore = ChatBadgeStore()
    @AppStorage("cc_onboarding_completed") private var onboardingCompleted: Bool = false
    @AppStorage("feature_group_view") private var featureGroupView: Bool = false

    private var needsOnboarding: Bool {
        if !onboardingCompleted { return true }
        // P0 直连: 门 B 用户没有(也不需要) server host, 不能拿 ccServer 的 placeholder 判定卡死在 onboarding 循环里.
        if DirectAPIConfig.isActive { return false }
        let host = CcServerConfig.serverURL.host ?? ""
        return host == "example.com" || host.isEmpty
    }

    private var groupTabBadge: BadgeStyle {
        // Build 215 T1 — mention > 0 红 @ 升级版 / 无 mention 但有 unread 红圆点 / 都没 none
        if groupStore.mentionCount > 0 { return .mentionAt }
        if groupStore.unreadCount > 0 { return .unreadDot }
        return .none
    }

    private var chatTabBadge: BadgeStyle {
        chatBadgeStore.unreadCount > 0 ? .unreadDot : .none
    }

    private var tabs: [FloatingTabBarItem] {
        var items: [FloatingTabBarItem] = [
            .init(id: 0, title: "聊天", systemImage: "bubble.left.and.bubble.right", badge: chatTabBadge),
        ]
        // P0 直连: 终端/群聊都是打 server 端点的功能, directAPI 模式下 gate 掉(单一门控读点 DirectAPIConfig.isActive).
        if featureGroupView && !DirectAPIConfig.isActive {
            items.append(.init(id: 3, title: "群聊", systemImage: "person.3.sequence.fill", badge: groupTabBadge))
        }
        if !DirectAPIConfig.isActive {
            items.append(.init(id: 1, title: "终端", systemImage: "terminal"))
        }
        items.append(.init(id: 2, title: "设置", systemImage: "gearshape.fill"))
        return items
    }

    private var onEnterTerminal: () -> Void {
        // P0 直连: 终端(TerminalView)整个是 tmux/sessions 打 server, directAPI 没有这条路; 双入口(tab bar +
        // 微信主题昵称长按)都经这一个闭包, gate 收在这一处, WeChatHeaderBar 长按变成 no-op 不用另外改.
        DirectAPIConfig.isActive ? {} : { selectedTab = 1 }
    }

    var body: some View {
        // 内容 + tab bar 用 VStack 占独立 row 避免 safeAreaInset 在 NavigationStack 内不生效的问题
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case 0: NavigationStack { ChatView(onShowFavorites: { showFavorites = true }, scrollToken: chatScrollToken, onEnterTerminal: onEnterTerminal, onShowSettings: { selectedTab = 2 }) }
                // v2.8 R3b 真机修: 从终端返回聊天页时 bump chatScrollToken, 触发 ChatView .onChange(of:scrollToken)→scrollBottom,
                // 否则视图复用不走 onAppear、token 不变不触发 onChange, 返回后卡在旧滚动位置要手动下拉。
                case 1 where !DirectAPIConfig.isActive: NavigationStack { TerminalView(onBack: { selectedTab = 0; chatScrollToken &+= 1 }) }
                case 2: NavigationStack { CcSettingsView() }
                case 3 where featureGroupView && !DirectAPIConfig.isActive: NavigationStack { GroupChatView(store: groupStore) }
                default: NavigationStack { ChatView(onShowFavorites: { showFavorites = true }, scrollToken: chatScrollToken, onEnterTerminal: onEnterTerminal, onShowSettings: { selectedTab = 2 }) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if theme.theme == .wechat {
                // v2.3 任务3: 微信主题完全不渲染任何 tab (连 WeChatTabBar 也撤掉), 纯聊天页伪装. 出戏靠左上角返回箭头(v2.2 onExit→.warm), 切回正常主题后 FloatingTabBar 自然恢复.
                EmptyView()
            } else {
                FloatingTabBar(items: tabs, selection: $selectedTab)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        .background(Color.ccBg)
        .overlay(CcToastOverlay())  // Phase D — global toast (复制/收藏 反馈)
        .font(theme.theme == .terminal ? .system(.body, design: .monospaced) : nil)
        // T2 2026-05-12 — single source of truth in ThemeStore.preferredColorScheme.
        // terminal/night force dark; warm honors followSystemColorScheme + schemePref.
        .preferredColorScheme(theme.preferredColorScheme)
        // v2.4 P1 修: 从设置页(case2)等非聊天 tab 切到微信主题, v2.3 把 tab 栏换成 EmptyView 后用户卡在当前页无出口(返回箭头只在 ChatView 的 WeChatHeaderBar, 当前路径不渲染它). 进 .wechat 时同步回聊天 tab, 落在带返回箭头的聊天页; 切回其它主题 FloatingTabBar 自然恢复 selectedTab 不动.
        .onChange(of: theme.theme) { _, newTheme in
            if newTheme == .wechat {
                selectedTab = 0
                // v2.8: 原首次切微信主题弹屏中 toast 提示长按昵称进终端, 改成 WeChatHeaderBar 昵称正下方的引导气泡
                // (更直观且覆盖冷启动就在微信主题不触发 onChange 的情况). toast 移除, 见 WeChatHeaderBar.terminalHintBubble.
            }
        }
        // Phase E 2026-05-11 — cccompanion build 也要能弹 FavoritesView
        .sheet(isPresented: $showFavorites) {
            NavigationStack { FavoritesView() }
        }
        .fullScreenCover(isPresented: Binding(get: { needsOnboarding }, set: { _ in })) {
            OnboardingWizard()
        }
        .task {
            // Phase multi-server fallback — kick off endpoint resolver (background ping every 60s).
            // (directAPI 用户通常 endpoints 为空, resolveOnce 空列表早退, 无害不用额外 gate.)
            EndpointResolver.shared.start()
            // Build 215 T1 — featureGroupView 开关下后台跑 group polling, tab badge 才能在用户不进群聊 tab 时增长
            // P0 直连: group/chat badge 轮询都打 server 端点, directAPI 模式下 gate 掉.
            if featureGroupView && !DirectAPIConfig.isActive {
                groupStore.start()
            }
            // Build 215 P4 — chat badge polling 一直跑 (不绑 feature flag, 聊天 tab 永远存在)
            if !DirectAPIConfig.isActive {
                chatBadgeStore.start()
            }
            // Build 218 B1 — 启动时根据当前 tab 同步 isChatTabActive (cold start tab 0 默认)
            chatBadgeStore.isChatTabActive = (selectedTab == 0)
            // r5: 同款 cold start 群聊 tab active flag
            groupStore.isGroupTabActive = (selectedTab == 3)
        }
        .onChange(of: featureGroupView) { _, enabled in
            if enabled && !DirectAPIConfig.isActive {
                groupStore.start()
            } else {
                groupStore.stop()
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            // Build 218 B1 — 在屏状态推给 ChatBadgeStore, 让其在屏期间不增 badge
            chatBadgeStore.isChatTabActive = (newTab == 0)
            if newTab == 0 {
                chatScrollToken &+= 1
                // Build 215 P4 — 进 chat tab 视为已读, 清 badge
                chatBadgeStore.markAllRead()
            }
            // Build 217 T4 — 进群聊 tab 同样清 unread + mention 红 @
            // r5: 同 ChatBadgeStore pattern push isGroupTabActive 让 fetch 在屏时不增 badge
            groupStore.isGroupTabActive = (newTab == 3)
            if newTab == 3 {
                groupStore.markAllRead()
            }
        }
        .onChange(of: featureGroupView) { _, enabled in
            if !enabled && selectedTab == 3 {
                selectedTab = 0
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Build 218 B1 — 后台时 isChatTabActive = false (即使 selectedTab==0), 防止后台 polling 误清 unread
            chatBadgeStore.isChatTabActive = (newPhase == .active && selectedTab == 0)
            // r5: 同款给群聊 tab
            groupStore.isGroupTabActive = (newPhase == .active && selectedTab == 3)
            if newPhase == .active && selectedTab == 0 {
                chatScrollToken &+= 1
                chatBadgeStore.markAllRead()
            }
        }
    }

}

#Preview {
    ContentView()
}

// MARK: - Usage Banner (Claude Code Max 5h block)

struct UsageActiveResponse: Codable {
    let ok: Bool
    let active: UsageActive?
}

struct UsageActive: Codable {
    let startTime: String
    let endTime: String
    let models: [String]
    let entries: Int
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreateTokens: Int
    let cacheReadTokens: Int
    let costUsd: Double
    let burnTokensPerMin: Double
    let burnIndicator: Double
    let burnCostPerHour: Double
    let projectionTotalTokens: Int
    let projectionTotalCost: Double
    let projectionRemainingMin: Int

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case models
        case entries
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreateTokens = "cache_create_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case costUsd = "cost_usd"
        case burnTokensPerMin = "burn_tokens_per_min"
        case burnIndicator = "burn_indicator"
        case burnCostPerHour = "burn_cost_per_hour"
        case projectionTotalTokens = "projection_total_tokens"
        case projectionTotalCost = "projection_total_cost"
        case projectionRemainingMin = "projection_remaining_min"
    }
}

struct UsageBanner: View {
    @State private var active: UsageActive?
    @State private var loading: Bool = true
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
                Text("用量 (5h window)")
                    .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                Spacer()
                if let act = active, !act.models.isEmpty {
                    Text(act.models.first ?? "")
                        .font(.ccSerifAdaptive(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.ccCard)
                        .clipShape(Capsule())
                }
            }

            if loading && active == nil {
                HStack { ProgressView(); Text("加载中...").font(.ccSerifAdaptive(size: 16)).foregroundStyle(.secondary) }
            } else if let act = active {
                // reset 时间 + 剩余分钟
                HStack {
                    Label("Reset \(formatLocalTime(act.endTime))", systemImage: "clock.arrow.circlepath")
                        .font(.ccSerifAdaptive(size: 16))
                    Spacer()
                    Text("剩 \(act.projectionRemainingMin) 分")
                        .font(.ccSerifAdaptive(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                // tokens used vs projection 进度条
                let used = Double(act.totalTokens)
                let proj = max(Double(act.projectionTotalTokens), used + 1)
                ProgressView(value: used, total: proj)
                    .tint(Color.ccAccent)
                HStack {
                    Text("已用 \(formatTokens(act.totalTokens)) (\(percentUsed(act))%)")
                        .font(.ccSerifAdaptive(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("估总 \(formatTokens(act.projectionTotalTokens))")
                        .font(.ccSerifAdaptive(size: 12))
                        .foregroundStyle(.secondary)
                }
                // burn rate + 参考价
                HStack {
                    Label("\(formatBurn(act.burnTokensPerMin))/min", systemImage: "flame.fill")
                        .font(.ccSerifAdaptive(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("≈ $\(String(format: "%.2f", act.costUsd)) (Max 订阅 仅参考)")
                        .font(.ccSerifAdaptive(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("无 active block — 5h 窗口空闲中")
                    .font(.ccSerifAdaptive(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.ccCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel(); pollTask = nil }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await fetchOnce()
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            }
        }
    }

    private func fetchOnce() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("usage/active")
        do {
            let (data, _) = try await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url))
            let decoded = try JSONDecoder().decode(UsageActiveResponse.self, from: data)
            await MainActor.run {
                self.active = decoded.active
                self.loading = false
            }
        } catch {
            await MainActor.run { self.loading = false }
        }
    }

    private func formatLocalTime(_ iso: String) -> String {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = isoFmt.date(from: iso)
        if date == nil {
            isoFmt.formatOptions = [.withInternetDateTime]
            date = isoFmt.date(from: iso)
        }
        guard let d = date else { return iso.prefix(16).description }
        let local = DateFormatter()
        local.dateFormat = "HH:mm"
        local.timeZone = TimeZone.current
        return local.string(from: d)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return String(n)
    }

    private func formatBurn(_ n: Double) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", n / 1_000) }
        return String(format: "%.0f", n)
    }

    private func percentUsed(_ act: UsageActive) -> Int {
        let proj = max(act.projectionTotalTokens, act.totalTokens + 1)
        return Int((Double(act.totalTokens) / Double(proj)) * 100.0)
    }
}
