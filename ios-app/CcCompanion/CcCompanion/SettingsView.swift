//
//  SettingsView.swift
//  CcCompanion
//
//  Usage section: ccusage active block + OTS 统计 + Anthropic 跳转
//  插入 ConsoleView ScrollView 顶部使用
//

import SwiftUI
import Combine
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Response models

private struct UsageOverviewResponse: Codable {
    let ok: Bool
    let ccusage: CcusageData
    let ots: OTSData
    let anthropicUrl: String

    enum CodingKeys: String, CodingKey {
        case ok, ccusage, ots
        case anthropicUrl = "anthropic_url"
    }
}

private struct CcusageData: Codable {
    let available: Bool
    let error: String?
    let activeBlock: ActiveBlock?

    enum CodingKeys: String, CodingKey {
        case available, error
        case activeBlock = "active_block"
    }
}

private struct ActiveBlock: Codable {
    let costUsd: Double
    let tokens: Int
    let endTime: String
    let minutesUntilReset: Int?
    let models: [String]?

    enum CodingKeys: String, CodingKey {
        case costUsd = "cost_usd"
        case tokens
        case endTime = "end_time"
        case minutesUntilReset = "minutes_until_reset"
        case models
    }
}

private struct OTSData: Codable {
    let chatTotal: Int
    let chatToday: Int
    let activeDeviceCount: Int
    let uptimeHours: Double

    enum CodingKeys: String, CodingKey {
        case chatTotal = "chat_total"
        case chatToday = "chat_today"
        case activeDeviceCount = "active_device_count"
        case uptimeHours = "uptime_hours"
    }
}

// MARK: - ViewModel

@MainActor
final class UsageSectionViewModel: ObservableObject {
    @Published fileprivate var response: UsageOverviewResponse? = nil
    @Published var loading: Bool = false

    private var pollTask: Task<Void, Never>?

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.fetch()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 min
                if Task.isCancelled { break }
                await self?.fetch()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func fetch() async {
        loading = true
        defer { loading = false }
        let url = CcServerConfig.serverURL.appendingPathComponent("usage")
        do {
            let (data, _) = try await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url))
            let decoded = try JSONDecoder().decode(UsageOverviewResponse.self, from: data)
            response = decoded
        } catch {
            // 静默降级 — 用量数据非关键路径
        }
    }
}

// MARK: - View

struct UsageSection: View {
    @StateObject private var vm = UsageSectionViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("用量", systemImage: "chart.bar.fill")
                    .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
                Spacer()
                if vm.loading && vm.response == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await vm.fetch() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.ccSerifAdaptive(size: 12))
                            .foregroundStyle(Color.ccTextDim)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let resp = vm.response {
                // --- 当前 session card ---
                VStack(alignment: .leading, spacing: 6) {
                    Label("当前 5h session", systemImage: "clock.fill")
                        .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ccTextDim)
                    if resp.ccusage.available, let blk = resp.ccusage.activeBlock {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(formatTokens(blk.tokens))
                                .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                                .foregroundStyle(Color.ccText)
                            Text("tok")
                                .font(.ccSerifAdaptive(size: 12))
                                .foregroundStyle(Color.ccTextDim)
                            Text("·")
                                .foregroundStyle(Color.ccTextDim)
                            Text("$\(String(format: "%.2f", blk.costUsd))")
                                .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                                .foregroundStyle(Color.ccAccent)
                        }
                        if let mins = blk.minutesUntilReset {
                            Text("重置倒计时 \(mins) 分钟")
                                .font(.ccSerifAdaptive(size: 11))
                                .foregroundStyle(Color.ccTextDim)
                        }
                        if let models = blk.models, !models.isEmpty {
                            Text(models.joined(separator: " · "))
                                .font(.ccSerifAdaptive(size: 11))
                                .foregroundStyle(Color.ccTextDim)
                                .lineLimit(1)
                        }
                    } else if !resp.ccusage.available {
                        Text(resp.ccusage.error ?? "未安装 ccusage")
                            .font(.ccSerifAdaptive(size: 11))
                            .foregroundStyle(Color.ccTextDim)
                    } else {
                        Text("无 active 5h block")
                            .font(.ccSerifAdaptive(size: 11))
                            .foregroundStyle(Color.ccTextDim)
                    }
                }
                .padding(10)
                .background(Color.ccCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // --- OTS 统计 card ---
                VStack(alignment: .leading, spacing: 6) {
                    Label("OTS 统计", systemImage: "server.rack")
                        .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ccTextDim)
                    let ots = resp.ots
                    HStack(spacing: 16) {
                        statItem(value: formatCount(ots.chatTotal), label: "全部消息")
                        statItem(value: formatCount(ots.chatToday), label: "今日消息")
                        statItem(value: "\(ots.activeDeviceCount)", label: "在线设备")
                        statItem(value: formatUptime(ots.uptimeHours), label: "在线时长")
                    }
                }
                .padding(10)
                .background(Color.ccCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // --- Anthropic 完整用量按钮 ---
                if let anthropicURL = URL(string: resp.anthropicUrl) {
                    Button {
                        #if os(iOS)
                        UIApplication.shared.open(anthropicURL)
                        #endif
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text("Anthropic 完整用量")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.ccSerifAdaptive(size: 11))
                                .foregroundStyle(Color.ccTextDim)
                        }
                        .font(.ccSerifAdaptive(size: 16))
                        .foregroundStyle(Color.ccText)
                        .padding(10)
                        .background(Color.ccCard)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            } else if !vm.loading {
                Text("用量数据加载失败")
                    .font(.ccSerifAdaptive(size: 11))
                    .foregroundStyle(Color.ccTextDim)
            }
        }
        .padding(14)
        .background(Color.ccCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.ccSerifAdaptive(size: 16, weight: .semibold))
                .foregroundStyle(Color.ccText)
            Text(label)
                .font(.ccSerifAdaptive(size: 11))
                .foregroundStyle(Color.ccTextDim)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return String(n)
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return String(n)
    }

    private func formatUptime(_ hours: Double) -> String {
        if hours >= 24 { return String(format: "%.0fd", hours / 24) }
        if hours >= 1 { return String(format: "%.0fh", hours) }
        return String(format: "%.0fm", hours * 60)
    }
}

// MARK: - CcSettingsView v2 (2026-05-07 用户 push: Aelios 风格 9 group)
// 视觉规范: 暖橙 + 自画 header + 圆角卡片 + 等宽数值

// Phase 设置大砍 (2026-05-11) — 砍 SESSION/VAULT/ACTIVITY/STORAGE 数字字段, 只留 connections + debug log.
struct CcSettingsResponse {
    var connections: [String: Bool] = [:]
    var debugLogLines: [String] = []
}

@MainActor
final class CcSettingsViewModel: ObservableObject {
    @Published var data = CcSettingsResponse()
    @Published var loading: Bool = false
    @Published var healthOk: Bool = false
    @Published var lastHealthCheck: String = "—"

    func refreshAll() async {
        loading = true
        defer { loading = false }
        // Phase 设置大砍 (2026-05-11) — 只留 connections + health, 其他统计接口砍掉.
        await fetch("connections/status") { d in
            self.data.connections = (d["connections"] as? [String: Bool]) ?? [:]
        }
        await checkHealth()
    }

    func checkHealth() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("health")
        do {
            let (_, resp) = try await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url))
            healthOk = (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            healthOk = false
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        lastHealthCheck = f.string(from: Date())
    }

    func loadDebugLog() async {
        await fetch("debug/server_log") { d in
            self.data.debugLogLines = (d["lines"] as? [String]) ?? []
        }
    }

    private func fetch(_ path: String, apply: @escaping ([String: Any]) -> Void) async {
        let url = CcServerConfig.serverURL.appendingPathComponent(path)
        do {
            let (data, _) = try await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url))
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                apply(json)
            }
        } catch {
            // 静默
        }
    }

    // Phase 设置大砍 (2026-05-11) — postChain helper 删 (软清/硬重启 UI 已砍, 搬到终端 tab phase E).
}

// MARK: - 订阅用量面板 (ai-usage-monitor 8796, 2026-06-12 款式A — 公开版 only Claude)
// 数据源跟旧 UsageSection(8795 OTS 统计) 不同: 8796 ai-usage-monitor 给 Claude 订阅窗百分比.
// Claude 订阅窗挂 ccusage.rate_limits 下(不在顶层 claude 键).
// 进区块 onAppear 拉一次 + 手动刷新, 不常驻轮询(设置页场景省电省请求).
// 生态: 服务端装 waterside0219/ai-usage-monitor, 本卡渲染它的数据. 配置见 docs/USAGE_PANEL_SETUP.md.

private struct SubUsageResponse: Codable {
    let ok: Bool?
    let ccusage: SubCcusage?
}
private struct SubCcusage: Codable {
    let available: Bool?
    let rateLimits: SubRateLimits?
    enum CodingKeys: String, CodingKey {
        case available
        case rateLimits = "rate_limits"
    }
}
private struct SubRateLimits: Codable {
    let available: Bool?
    let stale: Bool?
    let fiveHour: SubWindow?
    let sevenDay: SubWindow?
    enum CodingKeys: String, CodingKey {
        case available, stale
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}
private struct SubWindow: Codable {
    let usedPercent: Double?
    let resetAfterSeconds: Double?
    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAfterSeconds = "reset_after_seconds"
    }
}

@MainActor
final class SubUsageViewModel: ObservableObject {
    @Published fileprivate var response: SubUsageResponse? = nil
    @Published var loading: Bool = false
    @Published var failed: Bool = false

    // host 跟着现有 server 配置走, 仅换端口 8796, 不硬编码 IP.
    private var monitorURL: URL? {
        var comps = URLComponents(url: CcServerConfig.serverURL, resolvingAgainstBaseURL: false)
        comps?.port = 8796
        comps?.path = "/usage"
        return comps?.url
    }

    func fetch() async {
        guard let url = monitorURL else { failed = true; return }
        loading = true
        defer { loading = false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 35   // ccusage 冷跑可达 9s, server 端 timeout 30s, 留余量
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                failed = (response == nil); return
            }
            response = try JSONDecoder().decode(SubUsageResponse.self, from: data)
            failed = false
        } catch {
            failed = (response == nil)   // 已有数据时保留旧数据不闪占位
        }
    }
}

struct SubUsageSection: View {
    @StateObject private var vm = SubUsageViewModel()

    // 未配置态指引文档 (服务端怎么装 ai-usage-monitor).
    private static let setupDocURL = URL(string: "https://github.com/CyberSealNull/CcCompanion/blob/main/docs/USAGE_PANEL_SETUP.md")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("用量", systemImage: "gauge")
                    .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
                Spacer()
                if vm.loading && vm.response == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await vm.fetch() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.ccSerifAdaptive(size: 12))
                            .foregroundStyle(Color.ccTextDim)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let resp = vm.response {
                // ===== CLAUDE 订阅区 =====
                let rl = resp.ccusage?.rateLimits
                sectionTitle("CLAUDE 订阅", stale: rl?.stale == true)
                if let rl, rl.available != false {
                    usageRow(label: "5 小时窗", window: rl.fiveHour)
                    usageRow(label: "7 天窗", window: rl.sevenDay)
                } else {
                    unavailableRow("Claude 订阅数据暂不可用")
                }
            } else if vm.failed {
                // ===== 未配置态指引 (公开版新增) =====
                unconfiguredGuide()
            } else if !vm.loading {
                Text("用量数据加载中…")
                    .font(.ccSerifAdaptive(size: 11))
                    .foregroundStyle(Color.ccTextDim)
            }
        }
        .padding(14)
        .background(Color.ccCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { Task { await vm.fetch() } }   // 进区块拉一次, 不常驻轮询
    }

    @ViewBuilder
    private func unconfiguredGuide() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("查看 Claude Code 的订阅用量与重置时间。需在你的服务器上配置用量服务，约 5 分钟。")
                .font(.ccSerifAdaptive(size: 12))
                .foregroundStyle(Color.ccTextDim)
                .fixedSize(horizontal: false, vertical: true)
            if let url = Self.setupDocURL {
                Link("查看配置指引 →", destination: url)
                    .font(.ccSerifAdaptive(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func sectionTitle(_ title: String, stale: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                .foregroundStyle(Color.ccTextDim)
                .tracking(0.5)
            if stale {
                Text("· 数据可能过期")
                    .font(.ccSerifAdaptive(size: 10))
                    .foregroundStyle(Color.ccTextDim.opacity(0.8))
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func usageRow(label: String, window: SubWindow?) -> some View {
        let pct = max(0, min(100, window?.usedPercent ?? 0))
        HStack(spacing: 10) {
            Text(label)
                .font(.ccSerifAdaptive(size: 13))
                .foregroundStyle(Color.ccText)
                .frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.ccTextDim.opacity(0.18))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barColor(pct))
                        .frame(width: max(2, geo.size.width * pct / 100))
                }
            }
            .frame(height: 8)
            Text("\(Int(pct.rounded()))%")
                .font(.ccSerifAdaptive(size: 13, weight: .semibold))
                .foregroundStyle(barColor(pct))
                .frame(width: 42, alignment: .trailing)
            Text(resetText(window?.resetAfterSeconds))
                .font(.ccSerifAdaptive(size: 10))
                .foregroundStyle(Color.ccTextDim)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func unavailableRow(_ text: String) -> some View {
        Text(text)
            .font(.ccSerifAdaptive(size: 11))
            .foregroundStyle(Color.ccTextDim)
            .padding(.vertical, 4)
    }

    // 进度条配色: <60 主题 accent / 60-90 黄(≈#D9A441) / ≥90 红(≈#C25450).
    private func barColor(_ pct: Double) -> Color {
        if pct >= 90 { return Color(red: 0.761, green: 0.329, blue: 0.314) }
        if pct >= 60 { return Color(red: 0.851, green: 0.643, blue: 0.255) }
        return Color.ccAccent
    }

    // reset_after_seconds → 「X天Yh / XhYm / Xm 后刷新」.
    private func resetText(_ secs: Double?) -> String {
        guard let s = secs, s > 0 else { return "已刷新" }
        let total = Int(s)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let mins = (total % 3600) / 60
        if days >= 1 { return "\(days)天\(hours)h 后刷新" }
        if hours >= 1 { return "\(hours)h\(mins)m 后刷新" }
        return "\(mins)m 后刷新"
    }
}

struct CcSettingsView: View {
    @StateObject private var vm = CcSettingsViewModel()

    @AppStorage("ai_name") private var aiName: String = CcDefaultAIName
    @AppStorage("ai_avatar_path") private var aiAvatarPath: String = ""
    // Phase 2.2 — user side (我的名字/头像) for cccompanion brand neutralize.
    // Phase F (item 1) — emoji @AppStorage 删 (fallback 走 AppIcon / SF symbol)
    @AppStorage("user_name") private var userName: String = CcDefaultUserName
    @AppStorage("user_avatar_path") private var userAvatarPath: String = ""

    @AppStorage("tts_enabled") private var ttsEnabled: Bool = false
    @AppStorage("heartbeat_enabled") private var heartbeatEnabled: Bool = true
    @AppStorage("live_activity_enabled") private var liveActivityEnabled: Bool = false
    @AppStorage("notify_on_polling_assistant") private var notifyOnPollingAssistant: Bool = true
    @AppStorage("enable_decision_haptic") private var enableDecisionHaptic: Bool = true
    @AppStorage("feature_group_view") private var featureGroupView: Bool = false
    @AppStorage("group_name") private var groupName: String = "群聊"
    // Build 215 S1 — 群聊背景图 disk path (跟 chat 背景独立)
    @AppStorage("group_chat_background_path") private var groupChatBackgroundPath: String = ""
    // Build 215 S2 — 群聊整体头像 (group-level, 跟 per-member 头像独立)
    @AppStorage("group_avatar_path") private var groupAvatarPath: String = ""
    @AppStorage("chat_font_size_level") private var chatFontLevel: String = "medium"
    // Phase D 2026-05-11 — "仿 cc 终端文字" default true (旧行为). 关掉显示 "[AI名字] 正在输入..."
    @AppStorage("typing_verbs_enabled") private var typingVerbsEnabled: Bool = true

    @AppStorage("debug_unlocked") private var debugUnlocked: Bool = false

    @ObservedObject private var themeStore = ThemeStore.shared  // Phase E — 主题 picker

    // Phase E (item 7) — 聊天背景 disk path. 空字符串 = 走主题 bg color.
    @AppStorage("chat_background_path") private var chatBackgroundPath: String = ""

    @State private var actionToast: String = ""
    @State private var showHapticInfo: Bool = false
    // Build 215 S2 — 群聊编辑 sheet 状态
    @State private var showGroupSettingsEdit: Bool = false
    @State private var showSessionOrder: Bool = false  // build226 终端 session 调序
    // Build 215 S1 — 群聊背景 PHPicker state
    @State private var groupBgPickerPresented: Bool = false
    @State private var groupBgRefreshTick: Int = 0

    // Phase multi-server fallback (2026-05-11) — endpoints UI state
    @ObservedObject private var resolver = EndpointResolver.shared
    @State private var editingEndpoint: EndpointEdit? = nil
    @State private var endpointsTick: Int = 0  // bump to force section re-render after persist

    // Phase E (item 5) — 头像 PHPicker + crop state
    private enum AvatarSlot { case ai, user }
    @State private var avatarPickerSlot: AvatarSlot? = nil
    @State private var avatarPickerPresented: Bool = false
    @State private var avatarPickedImage: UIImage? = nil
    @State private var avatarCropPresented: Bool = false
    @State private var avatarRefreshTick: Int = 0  // bump to force avatar Image re-read after save

    // 工作群头像 PHPicker + crop state
    @State private var groupAvatarMemberId: String? = nil
    @State private var groupAvatarPickerPresented: Bool = false
    @State private var groupAvatarPickedImage: UIImage? = nil
    @State private var groupAvatarCropPresented: Bool = false
    @State private var groupAvatarRefreshTick: Int = 0

    // Build 218 S3/S4 — member 编辑 / 添加 / 删除 sheet 状态
    @State private var memberEditTarget: GroupMember? = nil
    @State private var memberAddSheetPresented: Bool = false
    @State private var memberQuickNamingPresented: Bool = false
    @State private var memberDeleteConfirm: GroupMember? = nil
    @AppStorage(GroupMemberOverrideStore.revisionKey) private var memberOverrideRev: Int = 0
    @AppStorage(GroupMemberColorOverrideStore.revisionKey) private var memberColorOverrideRev: Int = 0
    @AppStorage(GroupMemberAdditionsStore.revisionKey) private var memberAdditionsRev: Int = 0
    @AppStorage(GroupMemberRemovalsStore.revisionKey) private var memberRemovalsRev: Int = 0

    // Phase E (item 7) — chat background PHPicker state
    @State private var bgPickerPresented: Bool = false
    @State private var bgPickedImage: UIImage? = nil
    @State private var bgRefreshTick: Int = 0

    private static let aiAvatarFilename = "cccAvatarAI.png"
    private static let userAvatarFilename = "cccAvatarUser.png"
    private static let chatBackgroundFilename = "cccChatBackground.png"
    // Build 215 S1/S2 — 群聊背景 + 群聊整体头像 filename
    private static let groupChatBackgroundFilename = "cccGroupChatBackground.png"
    private static let groupAvatarFilename = "cccGroupAvatar.png"

    private var groupConfigMembers: [GroupMember] {
        // Build 218 S4 — base = default roster − removals, 然后追加 user additions.
        _ = memberOverrideRev; _ = memberColorOverrideRev; _ = memberAdditionsRev; _ = memberRemovalsRev
        let removals = GroupMemberRemovalsStore.removals()
        let baseIDs = ["amian", "opia", "di", "shu", "sonnet", "opus47_fresh", "fresh"]
        var list: [GroupMember] = baseIDs.compactMap { id in
            guard !removals.contains(id) else { return nil }
            return GroupMember.defaultMap[id]?.withCustomAvatarURL(GroupAvatarStore.avatarPath(for: id))
        }
        for added in GroupMemberAdditionsStore.additions() where !removals.contains(added.id) {
            list.append(added.withCustomAvatarURL(GroupAvatarStore.avatarPath(for: added.id)))
        }
        return list
    }

    private var buildVersion: String {
        let info = Bundle.main.infoDictionary
        let s = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let b = (info?["CFBundleVersion"] as? String) ?? "?"
        return "v\(s) build \(b)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // STATUS HEADER (顶部 health 简版)
                statusHeader

                // Group 1 ABOUT (Phase 设置大砍 — 删 命名日/第一次相遇/模型)
                // Phase G2 2026-05-11 用户 push — ABOUT 合并 AI + user 4 row 不再单开"我" section
                section("ABOUT") {
                    rowToggleableText(label: "AI 名字") {
                        TextField(CcDefaultAIName, text: $aiName)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color.ccAccent)
                            .multilineTextAlignment(.trailing)
                    }
                    .onLongPressGesture {
                        debugUnlocked.toggle()
                        actionToast = debugUnlocked ? "DEBUG 解锁" : "DEBUG 锁定"
                    }
                    avatarPickerRow(label: "AI 头像", slot: .ai)
                    rowToggleableText(label: "我的名字") {
                        TextField(CcDefaultUserName, text: $userName)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color.ccAccent)
                            .multilineTextAlignment(.trailing)
                    }
                    avatarPickerRow(label: "我的头像", slot: .user)
                }

                // Group 2 SESSION — 砍 (软清/硬重启搬到终端 tab phase E)

                // Group 3 SERVER (Phase multi-server fallback 2026-05-11 — 多 endpoint + auto fallback)
                serverEndpointsSection

                // 订阅用量面板 (ai-usage-monitor 8796) — Claude Code 订阅窗百分比, 公开版 only Claude
                SubUsageSection()

                // Group 4 CONNECTIONS (ccc 不要)

                // Group 5 VAULT — 砍

                // Group 6 ACTIVITY — 砍 (build 号搬到 CREDITS)

                // Phase E (2026-05-11) — 主题 picker 搬到 settings
                // T2 2026-05-12 — 加 followSystemColorScheme toggle + 手动 light/dark picker
                section("主题") {
                    Picker("", selection: $themeStore.theme) {
                        ForEach(CcTheme.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)

                    toggleRow("跟随系统切换浅色/深色", binding: $themeStore.followSystemColorScheme)

                    if !themeStore.followSystemColorScheme && themeStore.theme == .warm {
                        Picker("", selection: $themeStore.schemePref) {
                            Text("浅色").tag(CcColorSchemePref.light)
                            Text("深色").tag(CcColorSchemePref.dark)
                        }
                        .pickerStyle(.segmented)
                        .padding(.vertical, 4)
                    }
                }

                // 终端 session 顺序 (build226) — 拖动自定义终端 tab 的 session 排序
                section("终端") {
                    Button {
                        showSessionOrder = true
                    } label: {
                        HStack {
                            Text("session 顺序")
                                .font(.ccSerifAdaptive(size: 15))
                                .foregroundStyle(Color.ccText)
                            Spacer()
                            Text("拖动调序")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(Color.ccTextDim)
                            Image(systemName: "chevron.right")
                                .font(.ccSerifAdaptive(size: 12))
                                .foregroundStyle(Color.ccTextDim)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }

                // Group 7 FEATURES (大砍版)
                section("FEATURES") {
                    toggleRow("仿ClaudeCode趣味Thinking文字", binding: $typingVerbsEnabled)
                    toggleRow("新消息通知", binding: $notifyOnPollingAssistant)
                    toggleRowWithInfo("决策提示触感和声效", binding: $enableDecisionHaptic) {
                        showHapticInfo = true
                    }
                }

                groupConfigSection

                // Group 7.5 聊天字号
                section("聊天字号") {
                    Picker("", selection: $chatFontLevel) {
                        Text("小").tag("small")
                        Text("中").tag("medium")
                        Text("大").tag("large")
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)
                }

                // Phase E (item 7) — 聊天背景 自定义
                section("聊天背景") {
                    chatBackgroundRow
                }

                // Group 8 STORAGE (Phase E amend — 清缓存按钮砍 留 "重新同步全部历史" 一个)
                section("STORAGE") {
                    // 2026-05-09 用户 push 删过本地后从 server 拉全量历史回本地 SwiftData
                    actionRow(label: "重新同步全部历史 (从 server)", color: .blue) {
                        UserDefaults.standard.set(false, forKey: "backfillComplete_v2")
                        NotificationCenter.default.post(name: NSNotification.Name("CcResyncHistory"), object: nil)
                        actionToast = "已触发 后台分批拉 server 全量 13000+ 条 完成约 30-60 秒"
                    }
                }

                // Group 9 DEBUG (长按 ABOUT 标题解锁)
                if debugUnlocked {
                    section("DEBUG") {
                        actionRow(label: "刷新 server.log 50 行", color: .blue) {
                            Task { await vm.loadDebugLog() }
                        }
                        if !vm.data.debugLogLines.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(vm.data.debugLogLines.suffix(20), id: \.self) { line in
                                    Text(line)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(Color.ccTextDim)
                                        .lineLimit(2)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        actionRow(label: "测 abort (shu)", color: .orange) {
                            Task {
                                let url = CcServerConfig.serverURL.appendingPathComponent("chain/abort")
                                var req = URLRequest(url: url); req.httpMethod = "POST"
                                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                                req.httpBody = try? JSONSerialization.data(withJSONObject: ["session": "shu"])
                                _ = try? await URLSession.shared.data(for: req)
                                actionToast = "abort shu 已发"
                            }
                        }
                    }
                }

                // CREDITS
                credits

                if !actionToast.isEmpty {
                    Text(actionToast)
                        .font(.ccSerifAdaptive(size: 11))
                        .foregroundStyle(Color.ccAccent)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
        }
        .background(Color.ccBg)
        .task { await vm.refreshAll() }
        .refreshable { await vm.refreshAll() }
        .onChange(of: aiName) { _, newName in
            CcNameResolver.notifyChanged()
            Task { await PushTokenManager.shared.updateAIName(newName) }
        }
        .onChange(of: userName) { _, _ in CcNameResolver.notifyChanged() }
        .onChange(of: groupName) { _, _ in
            NotificationCenter.default.post(name: .ccGroupAppearanceDidChange, object: nil)
        }
        .alert("决策提示触感和声效", isPresented: $showHapticInfo) {
            Button("好") {}
        } message: {
            Text("当 Claude Code 在终端等你按 y/n 同意时（例如 proceed?、continue?、[y/n]、✏️ 编辑提示等），会触发一次短触感和提示音。帮你切到别的 App 时不漏掉 prompt。\n\n关掉就只看屏幕，不振不响。")
        }
        // build226 — 终端 session 调序 sheet
        .sheet(isPresented: $showSessionOrder) {
            TerminalSessionOrderView()
        }
        // Build 215 S2 — 群聊编辑 sheet (头像 + 名称 同时编辑, 保存才落)
        .sheet(isPresented: $showGroupSettingsEdit) {
            GroupSettingsEditSheet(
                groupName: groupName,
                groupAvatarPath: groupAvatarPath,
                avatarFilename: Self.groupAvatarFilename,
                onSave: { newName, newAvatarPath, clearAvatar in
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    groupName = trimmed.isEmpty ? "群聊" : trimmed
                    if clearAvatar {
                        if !groupAvatarPath.isEmpty {
                            AvatarDiskStore.remove(storedValue: groupAvatarPath)
                        }
                        groupAvatarPath = ""
                    } else if let path = newAvatarPath {
                        groupAvatarPath = path
                    }
                    actionToast = "群聊设置已保存"
                    showGroupSettingsEdit = false
                    NotificationCenter.default.post(name: .ccGroupAppearanceDidChange, object: nil)
                },
                onCancel: { showGroupSettingsEdit = false }
            )
        }
        // Build 215 S1 — 群聊背景 PHPicker
        .sheet(isPresented: $groupBgPickerPresented) {
            AvatarPHPicker { img in
                groupBgPickerPresented = false
                if let img {
                    let resized = downscaleForBackground(img)
                    if let storedFilename = AvatarDiskStore.save(resized, filename: Self.groupChatBackgroundFilename) {
                        groupChatBackgroundPath = storedFilename
                        groupBgRefreshTick &+= 1
                        actionToast = "群聊背景已存"
                    } else {
                        actionToast = "背景保存失败"
                    }
                }
            }
        }
        // Phase multi-server fallback — endpoint editor sheet
        .sheet(item: $editingEndpoint) { edit in
            EndpointEditorSheet(initial: edit) { saved in
                applyEndpointEdit(saved)
                editingEndpoint = nil
            } onCancel: {
                editingEndpoint = nil
            }
        }
        // Phase E (item 5) — 头像 PHPicker + crop sheet (AI / user 共享 state, 用 slot 区分落盘 filename)
        .sheet(isPresented: $avatarPickerPresented) {
            AvatarPHPicker { img in
                avatarPickerPresented = false
                if let img {
                    avatarPickedImage = img
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        avatarCropPresented = true
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $avatarCropPresented) {
            if let img = avatarPickedImage, let slot = avatarPickerSlot {
                AvatarCropView(
                    originalImage: img,
                    onConfirm: { cropped in
                        let filename = (slot == .ai) ? Self.aiAvatarFilename : Self.userAvatarFilename
                        if let storedFilename = AvatarDiskStore.save(cropped, filename: filename) {
                            switch slot {
                            case .ai: aiAvatarPath = storedFilename
                            case .user: userAvatarPath = storedFilename
                            }
                            avatarRefreshTick &+= 1
                            actionToast = "头像已存"
                        } else {
                            actionToast = "头像保存失败"
                        }
                        avatarCropPresented = false
                        avatarPickedImage = nil
                    },
                    onCancel: {
                        avatarCropPresented = false
                        avatarPickedImage = nil
                    }
                )
            }
        }
        // Phase E (item 7) — chat background PHPicker (无 crop, 直接 scaledToFill)
        .sheet(isPresented: $bgPickerPresented) {
            AvatarPHPicker { img in
                bgPickerPresented = false
                if let img {
                    let resized = downscaleForBackground(img)
                    if let storedFilename = AvatarDiskStore.save(resized, filename: Self.chatBackgroundFilename) {
                        chatBackgroundPath = storedFilename
                        bgRefreshTick &+= 1
                        actionToast = "聊天背景已存"
                    } else {
                        actionToast = "背景保存失败"
                    }
                }
            }
        }
        .sheet(isPresented: $groupAvatarPickerPresented) {
            AvatarPHPicker { img in
                groupAvatarPickerPresented = false
                if let img {
                    groupAvatarPickedImage = img
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        groupAvatarCropPresented = true
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $groupAvatarCropPresented) {
            if let img = groupAvatarPickedImage, let memberId = groupAvatarMemberId {
                AvatarCropView(
                    originalImage: img,
                    onConfirm: { cropped in
                        if let storedFilename = AvatarDiskStore.save(cropped, filename: GroupAvatarStore.filename(for: memberId)) {
                            GroupAvatarStore.setAvatarPath(storedFilename, for: memberId)
                            groupAvatarRefreshTick &+= 1
                            actionToast = "群聊头像已存"
                        } else {
                            actionToast = "群聊头像保存失败"
                        }
                        groupAvatarCropPresented = false
                        groupAvatarPickedImage = nil
                    },
                    onCancel: {
                        groupAvatarCropPresented = false
                        groupAvatarPickedImage = nil
                    }
                )
            }
        }
    }

    // MARK: - Workgroup local settings

    @ViewBuilder
    private var groupConfigSection: some View {
        section("群聊") {
            // Build 215 S2 — 简化: 名称 + 头像缩略 + "编辑"按钮 一行 → 弹 sheet 同时编辑头像/名称
            groupHeaderRow

            // Build 215 S1 — 群聊背景行 (复用 chatBackgroundRow pattern 但绑 groupChatBackgroundPath)
            groupBackgroundRow

            Button {
                memberQuickNamingPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.ccAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("一键命名")
                            .font(.ccSerifAdaptive(size: 14, weight: .semibold))
                            .foregroundStyle(Color.ccText)
                        Text("仅本机显示 不上传")
                            .font(.ccSerifAdaptive(size: 11))
                            .foregroundStyle(Color.ccTextDim)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ccTextDim)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)

            ForEach(groupConfigMembers) { member in
                groupAvatarRow(member: member)
                    .contextMenu {
                        Button(role: .destructive) {
                            memberDeleteConfirm = member
                        } label: {
                            Label("删除成员", systemImage: "trash")
                        }
                    }
            }

            // Build 218 S4 — 列表底加 "+" 添加成员入口
            Button {
                memberAddSheetPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.ccAccent)
                    Text("添加成员")
                        .font(.ccSerifAdaptive(size: 14))
                        .foregroundStyle(Color.ccAccent)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)

            toggleRow("群聊视图", binding: $featureGroupView)
        }
        .id("group-config-\(groupAvatarRefreshTick)-\(groupBgRefreshTick)-\(memberOverrideRev)-\(memberColorOverrideRev)-\(memberAdditionsRev)-\(memberRemovalsRev)")
        .sheet(item: $memberEditTarget) { member in
            GroupMemberEditSheet(member: member) { newName, newColor, clearAvatar in
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed == member.displayName {
                    GroupMemberOverrideStore.setDisplayNameOverride(nil, for: member.id)
                } else {
                    GroupMemberOverrideStore.setDisplayNameOverride(trimmed, for: member.id)
                }
                if newColor == (member.color ?? "slate") {
                    GroupMemberColorOverrideStore.setColorOverride(nil, for: member.id)
                } else {
                    GroupMemberColorOverrideStore.setColorOverride(newColor, for: member.id)
                }
                if clearAvatar {
                    GroupAvatarStore.removeAvatar(for: member.id)
                }
                memberEditTarget = nil
                actionToast = "\(trimmed.isEmpty ? member.displayName : trimmed) 已保存"
            } onPickAvatar: {
                groupAvatarMemberId = member.id
                memberEditTarget = nil
                groupAvatarPickerPresented = true
            } onCancel: {
                memberEditTarget = nil
            } onDelete: {
                // Build 220 item 1 — Edit sheet 红删除按钮调这里, 跟 contextMenu 删除路径同款
                GroupMemberRemovalsStore.markRemoved(member.id)
                GroupMemberAdditionsStore.remove(id: member.id)
                let title = member.title
                let mid = member.id
                Task {
                    let r = await GroupMemberSyncClient.delete(id: mid)
                    if !r.ok { await MainActor.run { actionToast = "本地已删 \(title), 但 \(r.detail)" } }
                }
                memberEditTarget = nil
                actionToast = "已从群里删除 \(member.title)"
            }
        }
        .sheet(isPresented: $memberQuickNamingPresented) {
            GroupMemberQuickNamingSheet(members: groupConfigMembers) { drafts in
                for member in groupConfigMembers {
                    let trimmed = (drafts[member.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || trimmed == member.displayName {
                        GroupMemberOverrideStore.setDisplayNameOverride(nil, for: member.id)
                    } else {
                        GroupMemberOverrideStore.setDisplayNameOverride(trimmed, for: member.id)
                    }
                }
                memberQuickNamingPresented = false
                actionToast = "本机成员名已保存"
            } onCancel: {
                memberQuickNamingPresented = false
            }
        }
        .sheet(isPresented: $memberAddSheetPresented) {
            GroupMemberAddSheet { newMember in
                // Build 220 r4 item 2 — 不填 avatar 时之前出现 silent fail: sheet 关 + 成员不出现.
                // 修法 (belt + suspenders): add() 内部 persist 已 bump revision, 这里再显式 bump 一次
                // 防止某些情况 @AppStorage observation 还没 fire 就 sheet dismiss. dismiss 也延后一拍.
                GroupMemberAdditionsStore.add(newMember)
                GroupMemberAdditionsStore.bumpRevisionPublic()
                actionToast = "已添加 \(newMember.displayName)"
                // Build 221 task1 — 后端持久化失败不再 silent: surface toast
                Task {
                    let r = await GroupMemberSyncClient.add(newMember)
                    if !r.ok {
                        await MainActor.run { actionToast = "本地已加 \(newMember.displayName), 但 \(r.detail)" }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    memberAddSheetPresented = false
                }
            } onCancel: {
                memberAddSheetPresented = false
            }
        }
        .alert("删除成员", isPresented: Binding(
            get: { memberDeleteConfirm != nil },
            set: { if !$0 { memberDeleteConfirm = nil } }
        )) {
            Button("取消", role: .cancel) { memberDeleteConfirm = nil }
            Button("删除", role: .destructive) {
                if let m = memberDeleteConfirm {
                    GroupMemberRemovalsStore.markRemoved(m.id)
                    GroupMemberAdditionsStore.remove(id: m.id)
                    let title = m.title
                    let mid = m.id
                    Task {
                        let r = await GroupMemberSyncClient.delete(id: mid)
                        if !r.ok { await MainActor.run { actionToast = "本地已删 \(title), 但 \(r.detail)" } }
                    }
                    actionToast = "已从群里删除 \(m.title)"
                }
                memberDeleteConfirm = nil
            }
        } message: {
            if let m = memberDeleteConfirm {
                Text("确定从群里删除 \(m.title) 吗?")
            }
        }
    }

    // Build 215 S2 — 群聊主 row (头像 + 名称 + 编辑入口)
    @ViewBuilder
    private var groupHeaderRow: some View {
        Button {
            showGroupSettingsEdit = true
        } label: {
            HStack(spacing: 10) {
                groupAvatarThumb
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.ccAccent.opacity(0.25), lineWidth: 1))
                Text(groupName.isEmpty ? "群聊" : groupName)
                    .font(.ccSerifAdaptive(size: 15))
                    .foregroundStyle(Color.ccText)
                Spacer()
                Text("编辑")
                    .font(.ccSerifAdaptive(size: 12))
                    .foregroundStyle(Color.ccAccent)
                Image(systemName: "chevron.right")
                    .font(.ccSerifAdaptive(size: 11))
                    .foregroundStyle(Color.ccTextDim)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var groupAvatarThumb: some View {
        if !groupAvatarPath.isEmpty, let img = AvatarDiskStore.load(storedValue: groupAvatarPath) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                Circle().fill(Color.ccAccent.opacity(0.15))
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
            }
        }
    }

    // Build 215 S1 — 群聊背景 row (复用 chatBackgroundRow pattern)
    @ViewBuilder
    private var groupBackgroundRow: some View {
        VStack(spacing: 0) {
            Button {
                groupBgPickerPresented = true
            } label: {
                HStack {
                    Text("群聊背景")
                        .font(.ccSerifAdaptive(size: 15))
                        .foregroundStyle(Color.ccText)
                    Spacer()
                    groupBgThumbnail
                        .frame(width: 44, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.ccAccent.opacity(0.25), lineWidth: 1))
                    Text(groupChatBackgroundPath.isEmpty ? "选择" : "更换")
                        .font(.ccSerifAdaptive(size: 12))
                        .foregroundStyle(Color.ccAccent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
            if !groupChatBackgroundPath.isEmpty {
                Button {
                    AvatarDiskStore.remove(storedValue: groupChatBackgroundPath)
                    groupChatBackgroundPath = ""
                    groupBgRefreshTick &+= 1
                    actionToast = "群聊背景已恢复默认"
                } label: {
                    HStack {
                        Text("恢复默认 (走主题色)")
                            .font(.ccSerifAdaptive(size: 14))
                            .foregroundStyle(Color.ccTextDim)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var groupBgThumbnail: some View {
        if !groupChatBackgroundPath.isEmpty, let img = AvatarDiskStore.load(storedValue: groupChatBackgroundPath) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                Color.ccCard
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ccTextDim)
            }
        }
    }

    @ViewBuilder
    private func groupAvatarRow(member: GroupMember) -> some View {
        HStack(spacing: 10) {
            Button {
                groupAvatarMemberId = member.id
                groupAvatarPickerPresented = true
            } label: {
                HStack(spacing: 10) {
                    GroupAvatarView(member: member, size: 36)
                        .overlay(Circle().stroke(Color.ccAccent.opacity(0.25), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.title)
                            .font(.ccSerifAdaptive(size: 15))
                            .foregroundStyle(Color.ccText)
                        Text(member.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.ccTextDim)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Build 218 S3 — 替代旧"选择/更换 + trash" 为单一"编辑"按钮 → 弹 GroupMemberEditSheet
            Button {
                memberEditTarget = member
            } label: {
                Text("编辑")
                    .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    // MARK: - Phase E avatar / background helpers

    @ViewBuilder
    private func avatarPickerRow(label: String, slot: AvatarSlot) -> some View {
        Button {
            avatarPickerSlot = slot
            avatarPickerPresented = true
        } label: {
            HStack {
                Text(label)
                    .font(.ccSerifAdaptive(size: 15))
                    .foregroundStyle(Color.ccText)
                Spacer()
                avatarPreview(slot: slot)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.ccAccent.opacity(0.25), lineWidth: 1))
                Text(currentAvatarPath(slot).isEmpty ? "选择" : "更换")
                    .font(.ccSerifAdaptive(size: 12))
                    .foregroundStyle(Color.ccAccent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
        .id("\(slot == .ai ? "ai" : "user")-\(avatarRefreshTick)")
    }

    @ViewBuilder
    private func avatarPreview(slot: AvatarSlot) -> some View {
        CcAvatarView(role: slot == .ai ? .ai : .user, size: 36)
    }

    private func currentAvatarPath(_ slot: AvatarSlot) -> String {
        switch slot {
        case .ai: return aiAvatarPath
        case .user: return userAvatarPath
        }
    }

    @ViewBuilder
    private var chatBackgroundRow: some View {
        VStack(spacing: 0) {
            Button {
                bgPickerPresented = true
            } label: {
                HStack {
                    Text("聊天背景")
                        .font(.ccSerifAdaptive(size: 15))
                        .foregroundStyle(Color.ccText)
                    Spacer()
                    chatBackgroundThumbnail
                        .frame(width: 44, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.ccAccent.opacity(0.25), lineWidth: 1))
                    Text(chatBackgroundPath.isEmpty ? "选择" : "更换")
                        .font(.ccSerifAdaptive(size: 12))
                        .foregroundStyle(Color.ccAccent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
            if !chatBackgroundPath.isEmpty {
                Button {
                    AvatarDiskStore.remove(storedValue: chatBackgroundPath)
                    chatBackgroundPath = ""
                    bgRefreshTick &+= 1
                    actionToast = "已恢复默认背景"
                } label: {
                    HStack {
                        Text("恢复默认 (走主题色)")
                            .font(.ccSerifAdaptive(size: 14))
                            .foregroundStyle(Color.ccTextDim)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .id("bg-\(bgRefreshTick)")
    }

    @ViewBuilder
    private var chatBackgroundThumbnail: some View {
        if !chatBackgroundPath.isEmpty, let img = AvatarDiskStore.load(storedValue: chatBackgroundPath) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                Color.ccCard
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ccTextDim)
            }
        }
    }

    /// 下采样到 1080 长边以内, 防 4K 原图爆内存. 维持 aspect.
    private func downscaleForBackground(_ image: UIImage) -> UIImage {
        let maxSide: CGFloat = 1080
        let w = image.size.width
        let h = image.size.height
        let m = max(w, h)
        guard m > maxSide else { return image }
        let scale = maxSide / m
        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - section helpers

    @ViewBuilder
    private var statusHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.ccSerifAdaptive(size: 28, weight: .bold))
                    .foregroundStyle(Color.ccText)
                Text("STATUS · INFO")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.ccTextDim)
                    .tracking(1.5)
            }
            Spacer()
            Button {
                Task { await vm.refreshAll() }
            } label: {
                Image(systemName: vm.loading ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.clockwise.circle")
                    .font(.ccSerifAdaptive(size: 26))
                    .foregroundStyle(Color.ccAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.ccTextDim)
                .tracking(1.2)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                content()
            }
            .background(Color.ccCard)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private func rowText(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.ccSerifAdaptive(size: 15))
                .foregroundStyle(Color.ccText)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Color.ccAccent)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func rowToggleableText<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.ccSerifAdaptive(size: 15))
                .foregroundStyle(Color.ccText)
            Spacer()
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func toggleRow(_ label: String, binding: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.ccSerifAdaptive(size: 15))
                .foregroundStyle(Color.ccText)
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(Color.ccAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func toggleRowWithInfo(_ label: String, binding: Binding<Bool>, onInfo: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
                .font(.ccSerifAdaptive(size: 15))
                .foregroundStyle(Color.ccText)
            Spacer()
            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.ccSerifAdaptive(size: 15))
                    .foregroundStyle(Color.ccAccent)
            }
            .buttonStyle(.plain)
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(Color.ccAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func actionRow(label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.ccSerifAdaptive(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.ccSerifAdaptive(size: 12))
                    .foregroundStyle(Color.ccTextDim)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func connectionRow(_ label: String, key: String) -> some View {
        let active = vm.data.connections[key] ?? false
        HStack {
            Circle()
                .fill(active ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.ccSerifAdaptive(size: 15))
                .foregroundStyle(Color.ccText)
            Spacer()
            Text(active ? "online" : "offline")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(active ? Color.ccAccent : Color.ccTextDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var credits: some View {
        VStack(spacing: 6) {
            Text("CcCompanion")
                .font(.ccSerifAdaptive(size: 14, weight: .semibold))
                .foregroundStyle(Color.ccTextDim)
            Text("Open source iPhone client for Claude Code")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.ccTextDim)
                .multilineTextAlignment(.center)
            if let url = URL(string: "https://github.com/CyberSealNull/CcCompanion") {
                Link("github.com/CyberSealNull/CcCompanion", destination: url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.ccAccent)
            }
            Text(buildVersion)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.ccTextDim.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 24)
    }

    // Phase 设置大砍 (2026-05-11) — formatBigNum/formatBytes 删 (SESSION/STORAGE 数字 row 砍).

    // MARK: - Phase multi-server fallback (2026-05-11)

    @ViewBuilder
    private var serverEndpointsSection: some View {
        section("SERVER") {
            HStack {
                Text("当前使用")
                    .font(.ccSerifAdaptive(size: 15))
                    .foregroundStyle(Color.ccText)
                Spacer()
                let list = CcServerConfig.endpoints
                let idx = CcServerConfig.activeIndex
                let activeLabel = (idx >= 0 && idx < list.count) ? list[idx].label : "—"
                Text(activeLabel)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Color.ccAccent)
                if resolver.resolving {
                    ProgressView().controlSize(.mini).padding(.leading, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)

            ForEach(Array(CcServerConfig.endpoints.enumerated()), id: \.offset) { idx, ep in
                endpointRow(idx: idx, ep: ep)
            }

            actionRow(label: "+ 添加 endpoint", color: .blue) {
                editingEndpoint = EndpointEdit(index: nil, url: "http://", label: "新")
            }

            actionRow(label: "重新探测全部 (ping /health)", color: .blue) {
                Task { await resolver.resolveOnce(); endpointsTick &+= 1 }
            }
        }
        .id("endpoints-\(endpointsTick)-\(resolver.activeIndex)")
    }

    @ViewBuilder
    private func endpointRow(idx: Int, ep: (url: String, label: String)) -> some View {
        let isActive = (idx == resolver.activeIndex)
        let status: EndpointResolver.Status = idx < resolver.statuses.count ? resolver.statuses[idx] : .unknown
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ep.label)
                        .font(.ccSerifAdaptive(size: 15, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.ccAccent : Color.ccText)
                    if isActive {
                        Text("active")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color.ccAccent)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.ccAccent.opacity(0.4), lineWidth: 0.5))
                    }
                }
                Text(ep.url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.ccTextDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button { moveEndpoint(from: idx, to: idx - 1) } label: {
                Image(systemName: "arrow.up").font(.ccSerifAdaptive(size: 12))
            }
            .buttonStyle(.plain)
            .disabled(idx == 0)
            .opacity(idx == 0 ? 0.3 : 1)

            Button { moveEndpoint(from: idx, to: idx + 1) } label: {
                Image(systemName: "arrow.down").font(.ccSerifAdaptive(size: 12))
            }
            .buttonStyle(.plain)
            .disabled(idx >= CcServerConfig.endpoints.count - 1)
            .opacity(idx >= CcServerConfig.endpoints.count - 1 ? 0.3 : 1)

            Button {
                editingEndpoint = EndpointEdit(index: idx, url: ep.url, label: ep.label)
            } label: {
                Image(systemName: "pencil").font(.ccSerifAdaptive(size: 12))
            }
            .buttonStyle(.plain)

            Button {
                deleteEndpoint(at: idx)
            } label: {
                Image(systemName: "trash").font(.ccSerifAdaptive(size: 12))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            resolver.setActiveIndexManually(idx)
            endpointsTick &+= 1
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.1)).frame(height: 0.5), alignment: .bottom)
    }

    private func statusColor(_ s: EndpointResolver.Status) -> Color {
        switch s {
        case .ok: return .green
        case .down: return .red
        case .unknown: return Color.ccTextDim
        }
    }

    private func applyEndpointEdit(_ edit: EndpointEdit) {
        var list = CcServerConfig.endpoints
        let cleanURL = edit.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = edit.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty, URL(string: cleanURL) != nil else {
            actionToast = "URL 格式错"
            return
        }
        let entry = (url: cleanURL, label: cleanLabel.isEmpty ? "endpoint" : cleanLabel)
        if let idx = edit.index, idx >= 0, idx < list.count {
            list[idx] = entry
        } else {
            list.append(entry)
        }
        CcServerConfig.setEndpoints(list)
        CcServerConfig.syncToAppGroup()
        resolver.endpointsDidChange()
        endpointsTick &+= 1
        actionToast = "已存 — 后台重新探测中"
    }

    private func deleteEndpoint(at idx: Int) {
        var list = CcServerConfig.endpoints
        guard idx >= 0, idx < list.count else { return }
        list.remove(at: idx)
        CcServerConfig.setEndpoints(list)
        let active = CcServerConfig.activeIndex
        if active >= list.count {
            CcServerConfig.setActiveIndex(max(0, list.count - 1))
        }
        CcServerConfig.syncToAppGroup()
        resolver.endpointsDidChange()
        endpointsTick &+= 1
    }

    private func moveEndpoint(from src: Int, to dst: Int) {
        var list = CcServerConfig.endpoints
        guard src >= 0, src < list.count, dst >= 0, dst < list.count, src != dst else { return }
        let item = list.remove(at: src)
        list.insert(item, at: dst)
        let activeURL: String? = {
            let i = CcServerConfig.activeIndex
            return i >= 0 && i < CcServerConfig.endpoints.count ? CcServerConfig.endpoints[i].url : nil
        }()
        CcServerConfig.setEndpoints(list)
        if let activeURL, let newIdx = list.firstIndex(where: { $0.url == activeURL }) {
            CcServerConfig.setActiveIndex(newIdx)
        }
        CcServerConfig.syncToAppGroup()
        resolver.endpointsDidChange()
        endpointsTick &+= 1
    }
}

// MARK: - Endpoint editor (Phase multi-server fallback 2026-05-11)

struct EndpointEdit: Identifiable {
    let id = UUID()
    let index: Int?
    var url: String
    var label: String
}

struct EndpointEditorSheet: View {
    @State var initial: EndpointEdit
    let onSave: (EndpointEdit) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("URL") {
                    TextField("http://10.x.x.x:8795", text: $initial.url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled(true)
                }
                Section("标签") {
                    TextField("标签", text: $initial.label)
                }
                Section {
                    Text("常用提示")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.ccTextDim)
                    Text("Tailscale 在常驻 mac 上运行 tailscale ip, 填 100.x.x.x:8795")
                        .font(.ccSerifAdaptive(size: 12))
                        .foregroundStyle(Color.ccTextDim)
                    Text("局域网在 mac 上运行 ifconfig en0, 填 10. 或 192.168. 段 IP")
                        .font(.ccSerifAdaptive(size: 12))
                        .foregroundStyle(Color.ccTextDim)
                }
            }
            .navigationTitle(initial.index == nil ? "添加 endpoint" : "改 endpoint")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(initial) }
                }
            }
        }
    }
}

// MARK: - Group Settings Edit Sheet (build 215 S2)

/// 群聊整体设置编辑面板 — 头像 + 名称 同时编辑, "保存"才落盘.
/// 编辑期 draft 跟现状分离, 取消不动 AppStorage.
struct GroupSettingsEditSheet: View {
    let groupName: String
    let groupAvatarPath: String
    let avatarFilename: String
    // Build 215 P2 — save callback 现在传 (name, avatarPath?, clearAvatar). clearAvatar=true 时 parent 删磁盘 + AppStorage.
    // 之前 onClearAvatar 是即时 callback, 跳过"保存才落"闸 — 这次走 draft state 跟正常编辑同款.
    let onSave: (String, String?, Bool) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftName: String = ""
    // nil = 没动过 (走 AppStorage 原值) / "" = 用户主动恢复默认 (保存才落) / 非空 = 用户选了新头像 (保存才落)
    @State private var draftAvatarPath: String? = nil
    @State private var pickerPresented: Bool = false
    @State private var pickedImage: UIImage? = nil
    @State private var cropPresented: Bool = false

    private var currentAvatarPath: String {
        draftAvatarPath ?? groupAvatarPath
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("头像") {
                    HStack(spacing: 14) {
                        avatarThumb
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.ccAccent.opacity(0.3), lineWidth: 1))
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                pickerPresented = true
                            } label: {
                                Label(currentAvatarPath.isEmpty ? "选择头像" : "更换头像", systemImage: "photo.on.rectangle")
                            }
                            if !currentAvatarPath.isEmpty {
                                Button(role: .destructive) {
                                    // Build 215 P2 — 只改 draft, 不立刻 onClearAvatar.
                                    // 用户接着按"保存"才删磁盘 + 清 AppStorage; 按"取消"原值保留.
                                    draftAvatarPath = ""
                                } label: {
                                    Label("恢复默认", systemImage: "arrow.uturn.backward")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("名称") {
                    TextField("群聊", text: $draftName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
            .navigationTitle("群聊设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        // Build 215 P2 — draftAvatarPath == "" 表示用户在 sheet 里点了恢复默认.
                        // 这时传 clearAvatar=true 让 parent 删磁盘 + 清 AppStorage (取消按钮拦得住).
                        let clearAvatar = (draftAvatarPath == "")
                        let avatarToSet = clearAvatar ? nil : draftAvatarPath
                        onSave(draftName, avatarToSet, clearAvatar)
                    }
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            draftName = groupName
        }
        .sheet(isPresented: $pickerPresented) {
            AvatarPHPicker { img in
                pickerPresented = false
                if let img {
                    pickedImage = img
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        cropPresented = true
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $cropPresented) {
            if let img = pickedImage {
                AvatarCropView(
                    originalImage: img,
                    onConfirm: { cropped in
                        if let storedFilename = AvatarDiskStore.save(cropped, filename: avatarFilename) {
                            draftAvatarPath = storedFilename
                        }
                        cropPresented = false
                        pickedImage = nil
                    },
                    onCancel: {
                        cropPresented = false
                        pickedImage = nil
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var avatarThumb: some View {
        let path = currentAvatarPath
        if !path.isEmpty, let img = AvatarDiskStore.load(storedValue: path) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                Circle().fill(Color.ccAccent.opacity(0.15))
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
            }
        }
    }
}

// MARK: - Build 218 S3 — GroupMemberEditSheet (单个 member 头像 + displayName 编辑)
struct GroupMemberEditSheet: View {
    let member: GroupMember
    let onSave: (String, String, Bool) -> Void
    let onPickAvatar: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void  // Build 220 item 1 — 显式删除入口, 不靠长按 contextMenu

    @Environment(\.dismiss) private var dismiss
    @State private var draftName: String = ""
    @State private var draftColor: String = "slate"
    @State private var draftClearAvatar: Bool = false
    @State private var showDeleteConfirm: Bool = false

    private let colorOptions: [(tag: String, label: String)] = [
        ("orange",  "暖橙"),
        ("blue",    "雾青"),
        ("green",   "苔绿"),
        ("purple",  "鸢尾紫"),
        ("slate",   "石板"),
        ("neutral", "米白"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("头像") {
                    HStack(spacing: 14) {
                        GroupAvatarView(member: member, size: 64)
                            .overlay(Circle().stroke(Color.ccAccent.opacity(0.3), lineWidth: 1))
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                // 关 sheet, parent 拉起 PHPicker (复用现有 groupAvatarPickerPresented 流).
                                onPickAvatar()
                            } label: {
                                Label(GroupAvatarStore.avatarPath(for: member.id) == nil ? "选择头像" : "更换头像", systemImage: "photo.on.rectangle")
                            }
                            if GroupAvatarStore.avatarPath(for: member.id) != nil {
                                Button(role: .destructive) {
                                    draftClearAvatar = true
                                } label: {
                                    Label(draftClearAvatar ? "保存时清除" : "恢复默认", systemImage: "arrow.uturn.backward")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("名称") {
                    TextField(member.displayName, text: $draftName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    if let override = GroupMemberOverrideStore.displayNameOverride(for: member.id), !override.isEmpty {
                        Button(role: .destructive) {
                            draftName = member.displayName
                        } label: {
                            Label("恢复默认名称 (\(member.displayName))", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
                Section("颜色") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 12)], spacing: 12) {
                        ForEach(colorOptions, id: \.tag) { opt in
                            Button {
                                draftColor = opt.tag
                            } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(GroupMember.swatchColor(for: opt.tag))
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Circle()
                                                .stroke(draftColor == opt.tag ? Color.ccAccent : Color.ccTextDim.opacity(0.2),
                                                        lineWidth: draftColor == opt.tag ? 2.5 : 0.5)
                                        )
                                    Text(opt.label)
                                        .font(.ccSerifAdaptive(size: 11, weight: draftColor == opt.tag ? .semibold : .regular))
                                        .foregroundStyle(draftColor == opt.tag ? Color.ccText : Color.ccTextDim)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("信息") {
                    HStack { Text("ID").foregroundStyle(Color.ccTextDim); Spacer(); Text(member.id).font(.system(.body, design: .monospaced)) }
                    if let model = member.model, !model.isEmpty {
                        HStack { Text("模型").foregroundStyle(Color.ccTextDim); Spacer(); Text(model) }
                    }
                    if let tmux = member.tmux, !tmux.isEmpty {
                        HStack { Text("tmux session").foregroundStyle(Color.ccTextDim); Spacer(); Text(tmux).font(.system(.body, design: .monospaced)) }
                    }
                }
                // Build 220 item 1 — 显式删除按钮 (替代长按 contextMenu 隐藏入口)
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("删除成员")
                                .font(.ccSerifAdaptive(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle("编辑 \(member.title)")
            .alert("删除 \(member.title)?", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { onDelete() }
            } message: {
                Text("从群里删除 \(member.title). 删了就不在群里了 重新加成员才能恢复.")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if draftClearAvatar {
                            GroupAvatarStore.removeAvatar(for: member.id)
                        }
                        onSave(draftName, draftColor, draftClearAvatar)
                    }
                }
            }
        }
        .onAppear {
            draftName = GroupMemberOverrideStore.displayNameOverride(for: member.id) ?? member.displayName
            draftColor = GroupMemberColorOverrideStore.colorOverride(for: member.id) ?? member.color ?? "slate"
        }
    }
}

struct GroupMemberQuickNamingSheet: View {
    let members: [GroupMember]
    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var drafts: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("仅本机显示") {
                    ForEach(members) { member in
                        TextField(member.displayName, text: Binding(
                            get: { drafts[member.id] ?? (GroupMemberOverrideStore.displayNameOverride(for: member.id) ?? member.displayName) },
                            set: { drafts[member.id] = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    }
                }
            }
            .navigationTitle("一键命名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(drafts) }
                }
            }
        }
        .onAppear {
            for member in members {
                drafts[member.id] = GroupMemberOverrideStore.displayNameOverride(for: member.id) ?? member.displayName
            }
        }
    }
}

// MARK: - Build 218 S4 — GroupMemberAddSheet (添加新 agent 成员)
struct GroupMemberAddSheet: View {
    let onSave: (GroupMember) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftId: String = ""
    @State private var draftName: String = ""
    @State private var draftModel: String = ""
    @State private var draftTmux: String = ""
    @State private var draftCanReply: Bool = true
    @State private var draftColor: String = "slate"
    @State private var draftAvatar: String = ""

    private let colorOptions: [(tag: String, label: String)] = [
        ("orange",  "暖橙"),
        ("blue",    "雾青"),
        ("green",   "苔绿"),
        ("purple",  "鸢尾紫"),
        ("slate",   "石板"),
        ("neutral", "米白"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("身份") {
                    TextField("id (英文唯一标识, 如 my-agent)", text: $draftId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("显示名称", text: $draftName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("头像首字 (可选, 1 字)", text: $draftAvatar)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                Section("接入") {
                    TextField("模型 (e.g. Claude Sonnet 4.6)", text: $draftModel)
                    TextField("tmux session 名", text: $draftTmux)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Toggle("允许回复", isOn: $draftCanReply)
                }
                Section("颜色") {
                    // Build 220 item 9 — 圆色块 grid, 每块下面文字标签. 走 designer-grade muted 色板.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 12)], spacing: 12) {
                        ForEach(colorOptions, id: \.tag) { opt in
                            Button {
                                draftColor = opt.tag
                            } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(GroupMember.swatchColor(for: opt.tag))
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Circle()
                                                .stroke(draftColor == opt.tag ? Color.ccAccent : Color.ccTextDim.opacity(0.2),
                                                        lineWidth: draftColor == opt.tag ? 2.5 : 0.5)
                                        )
                                    Text(opt.label)
                                        .font(.ccSerifAdaptive(size: 11, weight: draftColor == opt.tag ? .semibold : .regular))
                                        .foregroundStyle(draftColor == opt.tag ? Color.ccText : Color.ccTextDim)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("添加成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let id = draftId.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let avatar = draftAvatar.trimmingCharacters(in: .whitespacesAndNewlines)
                        let m = GroupMember(
                            id: id,
                            displayName: name.isEmpty ? id : name,
                            kind: "agent",
                            avatar: avatar.isEmpty ? String((name.isEmpty ? id : name).prefix(1)).uppercased() : avatar,
                            color: draftColor,
                            model: draftModel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                            tmux: draftTmux.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                            canReply: draftCanReply,
                            optional: nil,
                            customAvatarURL: nil
                        )
                        onSave(m)
                    }
                    .disabled(draftId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Build 218 S4 / 221 task1 — backend sync client.
// AppStorage 仍是本地 SoT, 但后端持久化结果不再 silent 吞掉:
// 返回 (ok, message), callsite 在后端失败时 surface toast 让用户知道"本地加了但后端没持久化".
// Build 221 root cause: 之前 `_ = try? await ...` 把 404 / 网络错全吞了, 生产服没 add_member
// endpoint 时用户完全无信号 (silent fail). 现在 check HTTP status + 解析 ok 字段.
enum GroupMemberSyncClient {
    struct SyncResult {
        let ok: Bool
        let detail: String
    }

    static func add(_ member: GroupMember) async -> SyncResult {
        let url = CcServerConfig.serverURL.appendingPathComponent("group/members/add")
        var req = CcServerConfig.authenticatedRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "id": member.id,
            "display_name": member.displayName,
            "avatar": member.avatar ?? "",
            "color": member.color ?? "slate",
            "model": member.model ?? "",
            "tmux": member.tmux ?? "",
            "can_reply": member.canReply ?? true,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return await postExpectingOK(req, action: "添加")
    }

    static func delete(id: String) async -> SyncResult {
        let url = CcServerConfig.serverURL.appendingPathComponent("group/members/delete")
        var req = CcServerConfig.authenticatedRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id])
        return await postExpectingOK(req, action: "删除")
    }

    private static func postExpectingOK(_ req: URLRequest, action: String) async -> SyncResult {
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 {
                return SyncResult(ok: false, detail: "后端无 \(action)成员接口 (服务端待升级)")
            }
            guard (200...299).contains(code) else {
                return SyncResult(ok: false, detail: "后端\(action)失败 (HTTP \(code))")
            }
            // 解 {"ok": true/false}
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = obj["ok"] as? Bool {
                return SyncResult(ok: ok, detail: ok ? "" : "后端\(action)返回 ok=false")
            }
            return SyncResult(ok: true, detail: "")
        } catch {
            return SyncResult(ok: false, detail: "后端\(action)网络错: \(error.localizedDescription)")
        }
    }
}

// build226 — 终端 session 顺序调序视图. 拖动重排 → 保存 POST /tmux/sessions/order.
// 服务端 /tmux/sessions 之后按 saved order 返回, 终端 tab 第一个即默认 session.
struct TerminalSessionOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [String] = []
    @State private var loading: Bool = true
    @State private var saving: Bool = false
    @State private var toast: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sessions.isEmpty {
                    Text("没有可调序的 session")
                        .foregroundStyle(Color.ccTextDim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(sessions, id: \.self) { s in
                                HStack {
                                    Image(systemName: "line.3.horizontal")
                                        .foregroundStyle(Color.ccTextDim)
                                    Text(s)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                            .onMove { from, to in
                                sessions.move(fromOffsets: from, toOffset: to)
                            }
                        } header: {
                            Text("拖动右侧把手调整顺序，第一个即终端默认 session")
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("终端 session 顺序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        Task { await save() }
                    }
                    .disabled(saving || sessions.isEmpty)
                }
            }
            .overlay(alignment: .bottom) {
                if let t = toast {
                    Text(t)
                        .font(.ccSerifAdaptive(size: 13))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.ccCard)
                        .foregroundStyle(Color.ccAccent)
                        .clipShape(Capsule())
                        .padding(.bottom, 24)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        // /tmux/sessions 已按 saved order 返回, 直接用它当当前顺序展示。
        let url = CcServerConfig.serverURL.appendingPathComponent("tmux/sessions")
        do {
            let (data, _) = try await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url))
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["sessions"] as? [String] {
                sessions = arr
            }
        } catch {
            // 静默
        }
        loading = false
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let url = CcServerConfig.serverURL.appendingPathComponent("tmux/sessions/order")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["order": sessions])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["ok"] as? Bool == true {
                toast = "已保存"
                try? await Task.sleep(nanoseconds: 600_000_000)
                dismiss()
            } else {
                toast = "保存失败 (\(code))"
            }
        } catch {
            toast = "保存失败: \(error.localizedDescription)"
        }
    }
}
