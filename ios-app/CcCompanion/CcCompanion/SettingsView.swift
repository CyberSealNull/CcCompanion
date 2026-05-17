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
    @AppStorage("chat_font_size_level") private var chatFontLevel: String = "medium"
    // Phase D 2026-05-11 — "仿 cc 终端文字" default true (旧行为). 关掉显示 "[AI名字] 正在输入..."
    @AppStorage("typing_verbs_enabled") private var typingVerbsEnabled: Bool = true

    @AppStorage("debug_unlocked") private var debugUnlocked: Bool = false

    @ObservedObject private var themeStore = ThemeStore.shared  // Phase E — 主题 picker

    // Phase E (item 7) — 聊天背景 disk path. 空字符串 = 走主题 bg color.
    @AppStorage("chat_background_path") private var chatBackgroundPath: String = ""

    @State private var actionToast: String = ""

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

    // Phase E (item 7) — chat background PHPicker state
    @State private var bgPickerPresented: Bool = false
    @State private var bgPickedImage: UIImage? = nil
    @State private var bgRefreshTick: Int = 0

    private static let aiAvatarFilename = "cccAvatarAI.png"
    private static let userAvatarFilename = "cccAvatarUser.png"
    private static let chatBackgroundFilename = "cccChatBackground.png"

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

                // Group 7 FEATURES (大砍版)
                section("FEATURES") {
                    toggleRow("仿ClaudeCode趣味Thinking文字", binding: $typingVerbsEnabled)
                }

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
        .onChange(of: aiName) { _, _ in CcNameResolver.notifyChanged() }
        .onChange(of: userName) { _, _ in CcNameResolver.notifyChanged() }
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
                        if let path = AvatarDiskStore.save(cropped, filename: filename) {
                            switch slot {
                            case .ai: aiAvatarPath = path
                            case .user: userAvatarPath = path
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
                    if let path = AvatarDiskStore.save(resized, filename: Self.chatBackgroundFilename) {
                        chatBackgroundPath = path
                        bgRefreshTick &+= 1
                        actionToast = "聊天背景已存"
                    } else {
                        actionToast = "背景保存失败"
                    }
                }
            }
        }
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
                    AvatarDiskStore.remove(filename: Self.chatBackgroundFilename)
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
        if !chatBackgroundPath.isEmpty, let img = UIImage(contentsOfFile: chatBackgroundPath) {
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
