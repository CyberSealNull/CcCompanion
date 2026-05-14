//
//  ContentView.swift
//  OpiaCompanion
//
//  主 app 控制台 — 启动 Live Activity + 本地 update + 结束.
//  v0.1 没接 APNs 全部本地 (路径 A by 枢 review).
//

import SwiftUI

struct ThemeSettingsCard: View {
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("外观", systemImage: "paintbrush.fill")
                .font(.opiaSerifAdaptive(size: 17, weight: .semibold))
                .foregroundStyle(Color.opiaAccent)

            VStack(alignment: .leading, spacing: 6) {
                Text("主题")
                    .font(.opiaSerifAdaptive(size: 12, weight: .semibold))
                    .foregroundStyle(Color.opiaTextDim)
                Picker("主题", selection: $theme.theme) {
                    ForEach(OpiaTheme.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("夜间 / 白天")
                    .font(.opiaSerifAdaptive(size: 12, weight: .semibold))
                    .foregroundStyle(Color.opiaTextDim)
                Picker("外观", selection: $theme.schemePref) {
                    ForEach(OpiaColorSchemePref.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(14)
        .background(Color.opiaCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ContentView: View {
    @State private var showFavorites = false
    @State private var selectedTab: Int = 0
    @State private var chatScrollToken: Int = 0
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var theme = ThemeStore.shared
    @AppStorage("opia_onboarding_completed") private var onboardingCompleted: Bool = false

    private var needsOnboarding: Bool {
        if !onboardingCompleted { return true }
        let host = OpiaServerConfig.serverURL.host ?? ""
        return host == "example.com" || host.isEmpty
    }

    private var tabs: [FloatingTabBarItem] {
        return [
            .init(id: 0, title: "聊天", systemImage: "bubble.left.and.bubble.right"),
            .init(id: 1, title: "终端", systemImage: "terminal"),
            .init(id: 2, title: "设置", systemImage: "gearshape.fill"),
        ]
    }

    var body: some View {
        // 内容 + tab bar 用 VStack 占独立 row 避免 safeAreaInset 在 NavigationStack 内不生效的问题
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case 0: NavigationStack { ChatView(onShowFavorites: { showFavorites = true }, scrollToken: chatScrollToken) }
                case 1: NavigationStack { TerminalView() }
                case 2: NavigationStack { OpiaSettingsView() }
                default: NavigationStack { ChatView(onShowFavorites: { showFavorites = true }, scrollToken: chatScrollToken) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FloatingTabBar(items: tabs, selection: $selectedTab)
                .ignoresSafeArea(.keyboard, edges: .bottom)  // tab bar 不被 keyboard 推上去 始终保持在底部
        }
        .background(Color.opiaBg)
        .overlay(OpiaToastOverlay())  // Phase D — global toast (复制/收藏 反馈)
        .font(theme.theme == .terminal ? .system(.body, design: .monospaced) : nil)
        // T2 2026-05-12 — single source of truth in ThemeStore.preferredColorScheme.
        // terminal/night force dark; warm honors followSystemColorScheme + schemePref.
        .preferredColorScheme(theme.preferredColorScheme)
        // Phase E 2026-05-11 — cccompanion build 也要能弹 FavoritesView
        .sheet(isPresented: $showFavorites) {
            NavigationStack { FavoritesView() }
        }
        .fullScreenCover(isPresented: Binding(get: { needsOnboarding }, set: { _ in })) {
            OnboardingWizard()
        }
        .task {
            // Phase multi-server fallback — kick off endpoint resolver (background ping every 60s).
            EndpointResolver.shared.start()
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == 0 { chatScrollToken &+= 1 }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && selectedTab == 0 {
                chatScrollToken &+= 1
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
                    .font(.opiaSerifAdaptive(size: 17, weight: .semibold))
                    .foregroundStyle(Color.opiaAccent)
                Text("用量 (5h window)")
                    .font(.opiaSerifAdaptive(size: 17, weight: .semibold))
                Spacer()
                if let act = active, !act.models.isEmpty {
                    Text(act.models.first ?? "")
                        .font(.opiaSerifAdaptive(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.opiaCard)
                        .clipShape(Capsule())
                }
            }

            if loading && active == nil {
                HStack { ProgressView(); Text("加载中...").font(.opiaSerifAdaptive(size: 16)).foregroundStyle(.secondary) }
            } else if let act = active {
                // reset 时间 + 剩余分钟
                HStack {
                    Label("Reset \(formatLocalTime(act.endTime))", systemImage: "clock.arrow.circlepath")
                        .font(.opiaSerifAdaptive(size: 16))
                    Spacer()
                    Text("剩 \(act.projectionRemainingMin) 分")
                        .font(.opiaSerifAdaptive(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                // tokens used vs projection 进度条
                let used = Double(act.totalTokens)
                let proj = max(Double(act.projectionTotalTokens), used + 1)
                ProgressView(value: used, total: proj)
                    .tint(Color.opiaAccent)
                HStack {
                    Text("已用 \(formatTokens(act.totalTokens)) (\(percentUsed(act))%)")
                        .font(.opiaSerifAdaptive(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("估总 \(formatTokens(act.projectionTotalTokens))")
                        .font(.opiaSerifAdaptive(size: 12))
                        .foregroundStyle(.secondary)
                }
                // burn rate + 参考价
                HStack {
                    Label("\(formatBurn(act.burnTokensPerMin))/min", systemImage: "flame.fill")
                        .font(.opiaSerifAdaptive(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("≈ $\(String(format: "%.2f", act.costUsd)) (Max 订阅 仅参考)")
                        .font(.opiaSerifAdaptive(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("无 active block — 5h 窗口空闲中")
                    .font(.opiaSerifAdaptive(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.opiaCard)
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
        let url = OpiaServerConfig.serverURL.appendingPathComponent("usage/active")
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
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
