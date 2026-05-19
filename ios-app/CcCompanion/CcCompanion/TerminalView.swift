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

@MainActor
final class TerminalViewModel: ObservableObject {
    @Published var content: String = ""
    @Published var draft: String = ""
    @Published var session: String = ""
    @Published var sessions: [String] = []
    @Published var sending: Bool = false
    @Published var lastError: String? = nil

    private var pollingTask: Task<Void, Never>? = nil
    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

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
                self.lastError = nil
            } else if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let err = obj["error"] as? String {
                self.lastError = err
            }
        } catch {
            // 网络抖动静默
        }
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

    func send(enter: Bool = true) async {
        let keys = draft
        guard !keys.isEmpty || !enter else { return }
        sending = true
        defer { sending = false }
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
            "keys": keys,
            "session": session,
            "enter": enter,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            _ = try await urlSession.data(for: req)
            self.draft = ""
            // 立刻 fetch 一次更新输出
            await fetchCapture()
        } catch {
            self.lastError = "发送失败: \(error.localizedDescription)"
        }
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
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 session picker — terminal 风顶部栏
            HStack(spacing: 6) {
                // 仿 macOS 红黄绿三圆点装饰
                Circle().fill(Color(red: 1.0, green: 0.36, blue: 0.32)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 0.27, green: 0.85, blue: 0.39)).frame(width: 10, height: 10)
                Spacer().frame(width: 4)
                ForEach(vm.sessions.isEmpty ? [vm.session] : vm.sessions, id: \.self) { s in
                    Button {
                        vm.session = s
                        Task { await vm.fetchCapture() }
                    } label: {
                        Text(s)
                            .font(.system(size: 11, design: .monospaced).weight(s == vm.session ? .semibold : .regular))
                            .foregroundStyle(s == vm.session ? Color.white : Color.ccTextDim)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(s == vm.session ? Color.ccAccent : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                Spacer()
                Text(vm.content.isEmpty ? "" : "\(vm.content.split(separator: "\n").count) lines")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.ccTextDim)
                Button {
                    Task { await vm.fetchSessions(); await vm.fetchCapture() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.ccSerifAdaptive(size: 12))
                        .foregroundStyle(Color.ccTextDim)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.ccCard)

            // 终端输出 — pure black bg + green text 经典 terminal 风
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        Text(vm.content.isEmpty ? "// 等待 tmux 输出..." : vm.content)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.ccText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .id("end")
                        Spacer(minLength: 0)
                    }
                }
                .background(Color.ccBg)
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
                    TerminalShortcutButton(label: "Esc") { Task { await vm.sendSpecialKey(.escape) } }
                    TerminalShortcutButton(label: "↑") { Task { await vm.sendSpecialKey(.up) } }
                    TerminalShortcutButton(label: "↑↑") { Task { await vm.sendRepeatedSpecialKey(.up, count: 2) } }
                    TerminalShortcutButton(label: "↓") { Task { await vm.sendSpecialKey(.down) } }
                    TerminalShortcutButton(label: "Enter") { Task { await vm.sendSpecialKey(.enter) } }
                    TerminalShortcutButton(label: "clear") { Task { await vm.sendSlashClear() } }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(height: 40)
            .background(Color.ccCard)
            .overlay(Rectangle().fill(Color.ccTextDim.opacity(0.12)).frame(height: 1), alignment: .top)

            // 输入区 — prompt 风
            HStack(spacing: 8) {
                Text("$")
                    .font(.system(size: 14, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color.ccAccent)

                TextField("", text: $vm.draft, prompt: Text("命令").foregroundStyle(Color.ccTextDim), axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.ccText)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await vm.send() } }
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)

                // 2026-05-19 删旧橡皮擦清屏按钮 — 工具栏已有 clear 按钮 (走 /clear slash) 双入口混淆
                // 原 vm.sendClearScreen() paste "clear"+Enter 行为跟工具栏 /clear 不一致 (一个 user msg 一个 slash)
                // 工具栏 clear 是 user-facing 单一入口. sendClearScreen() function 保留 dead 不删
                // Phase D amendment #19 — ESC + ^C 按钮删 (走 /stop slash 命令中断)
                Button {
                    Task { await vm.send() }
                } label: {
                    Image(systemName: vm.sending ? "ellipsis.circle" : "return")
                        .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                        .foregroundStyle(vm.draft.isEmpty && !vm.sending ? Color.white.opacity(0.25) : Color.ccAccent)
                }
                .disabled(vm.sending)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.ccCard)
        }
        .background(Color.ccBg)
        // Phase E 2026-05-11 — 删 nav 顶部 "终端 cc" 标题, tab 顶部不显 session name
        #if os(iOS)
        .navigationBarHidden(true)
        #endif
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }
}

// 2026-05-19 终端快捷按钮 — 输入框上方横排 monospace 胶囊
private struct TerminalShortcutButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, design: .monospaced).weight(.medium))
                .foregroundStyle(Color.ccText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.ccBg)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.ccTextDim.opacity(0.25), lineWidth: 0.5)
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
