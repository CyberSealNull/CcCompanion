//
//  TerminalView.swift
//  OpiaCompanion
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
    @Published var session: String = "opia"
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
        Task { await self.fetchSessions() }
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
        let url = OpiaServerConfig.serverURL.appendingPathComponent("tmux/sessions")
        do {
            let (data, _) = try await urlSession.data(from: url)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["sessions"] as? [String] {
                self.sessions = arr
            }
        } catch {
            // 静默
        }
    }

    func fetchCapture() async {
        let base = OpiaServerConfig.serverURL.appendingPathComponent("tmux/capture")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "lines", value: "120"),
        ]
        guard let url = components?.url else { return }
        do {
            let (data, _) = try await urlSession.data(from: url)
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

    func send(enter: Bool = true) async {
        let keys = draft
        guard !keys.isEmpty || !enter else { return }
        sending = true
        defer { sending = false }

        let url = OpiaServerConfig.serverURL.appendingPathComponent("tmux/send")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = OpiaServerConfig.sharedSecret, !secret.isEmpty {
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

    func sendCtrlC() async {
        await sendRawKey("C-c")
    }

    func sendEscape() async {
        await sendRawKey("Escape")
    }

    // 2026-05-14 build 197 — 清屏 输 "clear" + Enter (走 shell clear)
    func sendClearScreen() async {
        let url = OpiaServerConfig.serverURL.appendingPathComponent("tmux/send")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = OpiaServerConfig.sharedSecret, !secret.isEmpty {
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
        let url = OpiaServerConfig.serverURL.appendingPathComponent("tmux/send")
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
                            .foregroundStyle(s == vm.session ? Color.white : Color.opiaTextDim)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(s == vm.session ? Color.opiaAssistant : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                Spacer()
                Text(vm.content.isEmpty ? "" : "\(vm.content.split(separator: "\n").count) lines")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.opiaTextDim)
                Button {
                    Task { await vm.fetchSessions(); await vm.fetchCapture() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.opiaSerifAdaptive(size: 12))
                        .foregroundStyle(Color.opiaTextDim)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.opiaCard)

            // 终端输出 — pure black bg + green text 经典 terminal 风
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        Text(vm.content.isEmpty ? "// 等待 tmux 输出..." : vm.content)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.opiaText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .id("end")
                        Spacer(minLength: 0)
                    }
                }
                .background(Color.opiaBg)
                .onChange(of: vm.content) { _, _ in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
            }

            if let err = vm.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.opiaSerifAdaptive(size: 11))
                    Text(err)
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.12))
            }

            // 输入区 — prompt 风
            HStack(spacing: 8) {
                Text("$")
                    .font(.system(size: 14, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color.opiaAssistant)

                TextField("", text: $vm.draft, prompt: Text("命令").foregroundStyle(Color.opiaTextDim), axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.opiaText)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await vm.send() } }
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)

                // 2026-05-14 build 197 — 清屏按钮 输入框左边 用户 push 加
                Button {
                    Task { await vm.sendClearScreen() }
                } label: {
                    Image(systemName: "eraser")
                        .font(.opiaSerifAdaptive(size: 18, weight: .semibold))
                        .foregroundStyle(Color.opiaTextDim)
                }
                // Phase D amendment #19 — ESC + ^C 按钮删 (走 /stop slash 命令中断)
                Button {
                    Task { await vm.send() }
                } label: {
                    Image(systemName: vm.sending ? "ellipsis.circle" : "return")
                        .font(.opiaSerifAdaptive(size: 20, weight: .semibold))
                        .foregroundStyle(vm.draft.isEmpty && !vm.sending ? Color.white.opacity(0.25) : Color.opiaAssistant)
                }
                .disabled(vm.sending)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.opiaCard)
        }
        .background(Color.opiaBg)
        // Phase E 2026-05-11 — 删 nav 顶部 "终端 opia" 标题, tab 顶部不显 session name
        #if os(iOS)
        .navigationBarHidden(true)
        #endif
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }
}

#Preview {
    NavigationStack {
        TerminalView()
    }
}
