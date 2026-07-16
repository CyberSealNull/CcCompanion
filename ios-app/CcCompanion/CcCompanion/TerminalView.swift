//
//  TerminalView.swift
//  CcCompanion
//
//  v0.6 终端 tab — 连 mac mini tmux session 看 raw 输出 + send keys
//  走 server /tmux/capture (poll 1.5s) + /tmux/send (POST keys)
//  不真正 SSH 不连本地 shell — 跟 chat 一样走 ZeroTier → mac mini server
//

import SwiftUI
import Foundation
import Combine
import AudioToolbox
import DirectAPICore
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class TerminalViewModel: ObservableObject {
    @Published var content: String = ""
    @Published var session: String = ""
    @Published var sessions: [String] = []
    @Published var sending: Bool = false
    @Published var lastError: String? = nil

    private var pollingTask: Task<Void, Never>? = nil
    private var lastDecisionTriggerAt: Date? = nil
    private var lastDecisionPromptSignature: String? = nil
    // 二审(P0-2): review 点名的"Terminal 等其它路径"漏网自建 session, 经 ccGuarded() 工厂显式注入 guard protocol.
    private let urlSession: URLSession

    init(urlSession: URLSession? = nil) {
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let cfg = DirectAPIServerGuardProtocol.ccGuarded()
            cfg.timeoutIntervalForRequest = 6
            cfg.timeoutIntervalForResource = 10
            self.urlSession = URLSession(configuration: cfg)
        }
    }

    func start() {
        pollingTask?.cancel()
        Task {
            await self.fetchSessions()
            await self.fetchCapture()
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchCapture()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func fetchSessions() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("tmux/sessions")
        do {
            let (data, _) = try await urlSession.data(for: CcServerConfig.authenticatedRequest(url: url))
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["sessions"] as? [String] {
                self.sessions = arr
                await reconcileSelectedSession(with: arr)
            }
        } catch {
            // 静默
            if session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session = await CcServerConfig.fetchDefaultSession(using: urlSession)
            }
        }
    }

    func fetchCapture() async {
        await ensureSessionSelected()
        guard !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let base = CcServerConfig.serverURL.appendingPathComponent("tmux/capture")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "lines", value: "120"),
        ]
        guard let url = components?.url else { return }
        do {
            let (data, _) = try await urlSession.data(for: CcServerConfig.authenticatedRequest(url: url))
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let txt = obj["content"] as? String {
                self.content = txt
                maybeTriggerDecisionFeedback(for: txt)
                self.lastError = nil
            } else if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let err = obj["error"] as? String {
                self.lastError = err
            }
        } catch {
            // 网络抖动静默
        }
    }

    private var decisionFeedbackEnabled: Bool {
        if UserDefaults.standard.object(forKey: "enable_decision_haptic") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "enable_decision_haptic")
    }

    private func maybeTriggerDecisionFeedback(for text: String) {
        guard decisionFeedbackEnabled else {
            lastDecisionPromptSignature = nil
            return
        }
        guard let signature = Self.decisionPromptSignature(in: text) else {
            lastDecisionPromptSignature = nil
            return
        }
        guard signature != lastDecisionPromptSignature else { return }

        let now = Date()
        if let lastDecisionTriggerAt,
           now.timeIntervalSince(lastDecisionTriggerAt) < 0.3 {
            return
        }

        lastDecisionTriggerAt = now
        lastDecisionPromptSignature = signature
        fireDecisionFeedback()
    }

    private func fireDecisionFeedback() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        #endif
        AudioServicesPlaySystemSound(1054)
    }

    static func detectDecisionPrompt(_ text: String) -> Bool {
        decisionPromptSignature(in: text) != nil
    }

    private static func decisionPromptSignature(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines.reversed() {
            if isDecisionPromptLine(line) {
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return isDecisionPromptLine(text) ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    private static func isDecisionPromptLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let containsPromptPhrase = [
            "proceed?",
            "continue?",
            "confirm?",
            "do you want to",
            "press enter to",
            "are you sure",
        ].contains { lower.contains($0) }

        if containsPromptPhrase { return true }
        if line.contains("✏️") || line.contains("✏") { return true }
        if lower.range(of: #"\[[[:space:]]*y[[:space:]]*/[[:space:]]*n[[:space:]]*\]"#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"\([[:space:]]*y[[:space:]]*/[[:space:]]*n[[:space:]]*\)"#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"\by[[:space:]]*/[[:space:]]*n\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private func ensureSessionSelected() async {
        if !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        await fetchSessions()
        if session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session = await CcServerConfig.fetchDefaultSession(using: urlSession)
        }
    }

    private func reconcileSelectedSession(with arr: [String]) async {
        let current = session.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = arr.first, (current.isEmpty || !arr.contains(current)) {
            session = first
            return
        }
        if arr.isEmpty {
            session = await CcServerConfig.fetchDefaultSession(using: urlSession)
        }
    }

    @discardableResult
    func send(keys: String, enter: Bool = true) async -> Bool {
        guard !keys.isEmpty || !enter else { return false }
        sending = true
        defer { sending = false }
        await ensureSessionSelected()
        guard !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let url = CcServerConfig.serverURL.appendingPathComponent("tmux/send")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        let payload: [String: Any] = [
            "keys": keys,
            "session": session,
            "enter": enter,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastError = "发送失败: 无效响应"
                return false
            }
            guard (200..<300).contains(http.statusCode) else {
                let serverError = Self.serverError(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                lastError = "发送失败 (\(http.statusCode)): \(serverError)"
                return false
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["ok"] as? Bool == true else {
                lastError = "发送失败: server 未确认成功"
                return false
            }
            lastError = nil
            // 立刻 fetch 一次更新输出
            await fetchCapture()
            return true
        } catch {
            self.lastError = "发送失败: \(error.localizedDescription)"
            return false
        }
    }

    private static func serverError(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String,
              !error.isEmpty else { return nil }
        return error
    }

    // 2026-05-19 真发特殊键 走 server 新增 `key` 字段 (tmux send-keys 键名)
    // 之前 sendRawKey(keys="Escape") 实际把字符串 Escape 字面粘到 shell — 假功能
    // 见 ~/Opia/work/done/2026-05-19_ccc-终端工具栏-加快捷按钮-implement-result.md
    enum TerminalSpecialKey: String {
        case escape = "Escape"
        case up = "Up"
        case down = "Down"
        case enter = "Enter"
        case tab = "Tab"
        case ctrlC = "C-c"
        case ctrlL = "C-l"  // 2026-05-19 clear 按钮 (跑 Claude Code 时不能 paste "clear" 字面字符串)
    }

    func sendSpecialKey(_ key: TerminalSpecialKey) async {
        await ensureSessionSelected()
        guard !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let url = CcServerConfig.serverURL.appendingPathComponent("tmux/send")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        let payload: [String: Any] = [
            "session": session,
            "key": key.rawValue,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await urlSession.data(for: req)
        // 立即 fetch 一次 让用户看到按键效果
        await fetchCapture()
    }

    func sendRepeatedSpecialKey(_ key: TerminalSpecialKey, count: Int) async {
        for _ in 0..<count {
            await sendSpecialKey(key)
            try? await Task.sleep(nanoseconds: 80_000_000)  // 80ms 间隔
        }
    }

    // 2026-05-19 clear 按钮真实意图 — 清 Claude Code chain 历史 (/clear slash)
    // 不是清终端画面 (Claude Code TUI 拦截 C-l 改 redraw 那条路对用户没意义)
    func sendSlashClear() async {
        await ensureSessionSelected()
        guard !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let url = CcServerConfig.serverURL.appendingPathComponent("tmux/send")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        let payload: [String: Any] = [
            "keys": "/clear",
            "session": session,
            "enter": true,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await urlSession.data(for: req)
        await fetchCapture()
    }

    func sendCtrlC() async {
        await sendSpecialKey(.ctrlC)
    }

    func sendEscape() async {
        await sendSpecialKey(.escape)
    }

    // 2026-05-14 build 197 — 清屏 输 "clear" + Enter (走 shell clear)
    func sendClearScreen() async {
        await ensureSessionSelected()
        guard !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let url = CcServerConfig.serverURL.appendingPathComponent("tmux/send")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        let payload: [String: Any] = [
            "keys": "clear",
            "session": session,
            "enter": true,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await urlSession.data(for: req)
        // 清完立刻 fetch 一次更新输出
        await fetchCapture()
    }

    private func sendRawKey(_ keys: String) async {
        await ensureSessionSelected()
        guard !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let url = CcServerConfig.serverURL.appendingPathComponent("tmux/send")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "keys": keys,
            "session": session,
            "enter": false,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await urlSession.data(for: req)
    }
}

struct TerminalView: View {
    @StateObject private var vm = TerminalViewModel()
    // 打字解耦: 输入态留在 View，不再每字符发布整个 TerminalViewModel。
    @State private var draftLocal: String = ""
    @FocusState private var inputFocused: Bool
    // v2.8 R3b: 观察 ThemeStore 让运行时切微信主题立即重渲终端页皮 (cc 共享单例 state 必须 observe, 否则切主题 body 不重算).
    @ObservedObject private var themeStore = ThemeStore.shared
    // v2.8 R3b: ContentView (case 1) 注入 { selectedTab = 0 }; 微信风返回栏点返回箭头回聊天 tab. 其它主题不渲染这栏, onBack 不调.
    var onBack: () -> Void = {}

    // v2.8 R3b: 微信主题下终端页套绿白皮 — 只 .wechat gate, 其它主题恒走 cc token 零回归.
    private var isWechat: Bool { themeStore.theme == .wechat }
    private var skinBg: Color { isWechat ? WechatTermSkin.bg : Color.ccBg }
    private var skinCard: Color { isWechat ? WechatTermSkin.card : Color.ccCard }
    private var skinText: Color { isWechat ? WechatTermSkin.ink : Color.ccText }
    private var skinDim: Color { isWechat ? WechatTermSkin.ink.opacity(0.45) : Color.ccTextDim }
    private var skinAccent: Color { isWechat ? WechatTermSkin.green : Color.ccAccent }

    var body: some View {
        VStack(spacing: 0) {
            // v2.8 R3b: 微信主题不渲染 tab bar (ContentView .wechat → EmptyView), 进了终端 tab 没返回栏回不去聊天.
            // 这条微信风返回栏只 .wechat gate, 左上返回箭头 → onBack() (ContentView 注入 selectedTab=0). 视觉对齐 WeChatHeaderBar (ink 箭头/居中标题/浅底).
            if isWechat {
                ZStack {
                    HStack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(WechatTermSkin.ink)
                        }
                        .accessibilityLabel("返回")
                        Spacer()
                    }
                    Text("终端")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(WechatTermSkin.ink)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(WechatTermSkin.card)
            }
            // 顶部 session picker — terminal 风顶部栏
            HStack(spacing: 6) {
                // 仿 macOS 红黄绿三圆点装饰 — v2.8 R3b: 微信皮下藏掉 (微信功能页不是黑底终端).
                if !isWechat {
                    Circle().fill(Color(red: 1.0, green: 0.36, blue: 0.32)).frame(width: 10, height: 10)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 10, height: 10)
                    Circle().fill(Color(red: 0.27, green: 0.85, blue: 0.39)).frame(width: 10, height: 10)
                    Spacer().frame(width: 4)
                }
                // session 标签横向滚动 防 session 多时 SwiftUI 把 Text 压成竖排
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(vm.sessions.isEmpty ? [vm.session] : vm.sessions, id: \.self) { s in
                            Button {
                                vm.session = s
                                Task { await vm.fetchCapture() }
                            } label: {
                                Text(s)
                                    .font(.system(size: 11, design: .monospaced).weight(s == vm.session ? .semibold : .regular))
                                    .foregroundStyle(s == vm.session ? Color.white : skinDim)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .background(s == vm.session ? skinAccent : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                        }
                    }
                }
                Text(vm.content.isEmpty ? "" : "\(vm.content.split(separator: "\n").count) lines")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(skinDim)
                Button {
                    Task { await vm.fetchSessions(); await vm.fetchCapture() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.ccSerifAdaptive(size: 12))
                        .foregroundStyle(skinDim)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(skinCard)

            // 终端输出 — pure black bg + green text 经典 terminal 风
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        Text(vm.content.isEmpty ? "// 等待 tmux 输出..." : vm.content)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(skinText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .id("end")
                        Spacer(minLength: 0)
                    }
                }
                .background(skinBg)
                .onChange(of: vm.content) { _, _ in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
            }

            if let err = vm.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.ccSerifAdaptive(size: 11))
                    Text(err)
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.12))
            }

            // 2026-05-19 快捷按钮工具栏 (Esc / ↑ / ↑↑ / ↓ / Enter / clear)
            // 只在 Terminal tab 显示 chat tab 不显 (此处 view 本身就是 Terminal tab)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    TerminalShortcutButton(label: "Esc", isWechat: isWechat) { Task { await vm.sendSpecialKey(.escape) } }
                    TerminalShortcutButton(label: "↑", isWechat: isWechat) { Task { await vm.sendSpecialKey(.up) } }
                    TerminalShortcutButton(label: "↑↑", isWechat: isWechat) { Task { await vm.sendRepeatedSpecialKey(.up, count: 2) } }
                    TerminalShortcutButton(label: "↓", isWechat: isWechat) { Task { await vm.sendSpecialKey(.down) } }
                    TerminalShortcutButton(label: "Enter", isWechat: isWechat) { Task { await vm.sendSpecialKey(.enter) } }
                    TerminalShortcutButton(label: "clear", isWechat: isWechat) { Task { await vm.sendSlashClear() } }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(height: 40)
            .background(skinCard)
            .overlay(Rectangle().fill((isWechat ? WechatTermSkin.ink : Color.ccTextDim).opacity(0.12)).frame(height: 1), alignment: .top)

            // 输入区 — prompt 风
            HStack(spacing: 8) {
                Text("$")
                    .font(.system(size: 14, design: .monospaced).weight(.bold))
                    .foregroundStyle(skinAccent)

                TextField("", text: $draftLocal, prompt: Text("命令").foregroundStyle(skinDim), axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(skinText)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { sendDraft() }
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)

                // 2026-05-19 删旧橡皮擦清屏按钮 — 工具栏已有 clear 按钮 (走 /clear slash) 双入口混淆
                // 原 vm.sendClearScreen() paste "clear"+Enter 行为跟工具栏 /clear 不一致 (一个 user msg 一个 slash)
                // 工具栏 clear 是 user-facing 单一入口. sendClearScreen() function 保留 dead 不删
                // Phase D amendment #19 — ESC + ^C 按钮删 (走 /stop slash 命令中断)
                Button {
                    sendDraft()
                } label: {
                    Image(systemName: vm.sending ? "ellipsis.circle" : "return")
                        .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                        .foregroundStyle(draftLocal.isEmpty && !vm.sending ? (isWechat ? WechatTermSkin.ink.opacity(0.25) : Color.white.opacity(0.25)) : skinAccent)
                }
                .disabled(vm.sending)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(skinCard)
        }
        .background(skinBg)
        // Phase E 2026-05-11 — 删 nav 顶部 "终端 cc" 标题, tab 顶部不显 session name
        #if os(iOS)
        .navigationBarHidden(true)
        #endif
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    private func sendDraft() {
        let keys = draftLocal
        guard !keys.isEmpty else { return }
        Task {
            let succeeded = await vm.send(keys: keys)
            draftLocal = TerminalDraftOwnership.resolvedDraft(
                current: draftLocal,
                sent: keys,
                succeeded: succeeded
            )
        }
    }
}

enum TerminalDraftOwnership {
    static func resolvedDraft(current: String, sent: String, succeeded: Bool) -> String {
        guard succeeded, current == sent else { return current }
        return ""
    }
}

// v2.8 R3b: 微信主题终端页配色常量 (绿白皮). 仅 .wechat gate 引用, 其它主题不碰. #07C160 微信绿同 FloatingTabBar/ChatView wechatAccent, ink 同 WeChatHeaderBar inkColor.
private enum WechatTermSkin {
    static let green = Color(red: 0.027, green: 0.756, blue: 0.376)  // #07C160 微信绿
    static let ink = Color(red: 0.094, green: 0.094, blue: 0.094)    // 微信深墨字
    static let bg = Color(red: 0.929, green: 0.929, blue: 0.929)     // #EDEDED 微信浅灰底
    static let card = Color.white                                    // 卡片/栏白底
}

// 2026-05-19 终端快捷按钮 — 输入框上方横排 monospace 胶囊
private struct TerminalShortcutButton: View {
    let label: String
    // v2.8 R3b: 微信皮下快捷键胶囊走绿白 (ink 字 / 浅底 / ink 描边), 其它主题恒走 cc token 零回归.
    var isWechat: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, design: .monospaced).weight(.medium))
                .foregroundStyle(isWechat ? WechatTermSkin.ink : Color.ccText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isWechat ? WechatTermSkin.bg : Color.ccBg)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke((isWechat ? WechatTermSkin.ink : Color.ccTextDim).opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        TerminalView()
    }
}
