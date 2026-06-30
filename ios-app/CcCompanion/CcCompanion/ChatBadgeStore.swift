//
//  ChatBadgeStore.swift
//  CcCompanion
//
//  Build 215 P4 — app 级 chat tab unread 计数 store.
//  ChatViewModel 的 unreadCount 只在 ChatListView 在屏时活, 切到群聊 / 终端 / 设置 tab 时 vm.stop() 不 polling.
//  这份 store 在 ContentView 层 @StateObject, featureGroupView 开关无关一直跑 light polling, tab 0 badge 能稳显.
//  逻辑跟 GroupStore unread 一致: lastSeenTs 持久化 UserDefaults, 拉新消息按 r.ts > lastSeenTs 算 unread.
//

import Foundation
import Combine

@MainActor
final class ChatBadgeStore: ObservableObject {
    @Published var unreadCount: Int = 0

    /// Build 218 B1 — ContentView set true 当 chat tab 在屏 + 应用在前台.
    /// active 时新消息直接被算"读过", 不增 badge, 同步推 lastSeenTs.
    @Published var isChatTabActive: Bool = false

    private var pollTask: Task<Void, Never>? = nil
    private var latestKnownTs: String = ""
    private var streamFailureCount: Int = 0
    private let lastSeenKey = "chat_last_seen_ts"
    // 2026-06-30 SSE: badge 长连接专用 session, resource timeout 7 天
    private let streamSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: cfg)
    }()

    private var lastSeenTs: String {
        get { UserDefaults.standard.string(forKey: lastSeenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastSeenKey) }
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.fetchOnce(reset: true)
            await self?.runRealtimeLoop()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 视图打开 chat tab 时调. 清 unread 计数并把 lastSeenTs 推到最新已知 ts.
    func markAllRead() {
        unreadCount = 0
        if !latestKnownTs.isEmpty {
            lastSeenTs = latestKnownTs
        }
    }

    private func fetchOnce(reset: Bool) async {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/poll")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "limit", value: "50")]
        // 第一次 reset=true 走 since=lastSeenTs 算 cold-start unread.
        // 后续 reset=false 走 since=latestKnownTs 只拉新.
        let since = reset ? lastSeenTs : latestKnownTs
        if !since.isEmpty {
            items.append(URLQueryItem(name: "since", value: since))
        }
        components?.queryItems = items
        guard let finalURL = components?.url else { return }
        let request = CcServerConfig.authenticatedRequest(url: finalURL)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            // 解码 — 走 chat.new_records (同 /chat/poll + SSE data 形). 处理逻辑抽到 apply, poll/SSE 共用.
            let decoded = try JSONDecoder().decode(BadgePollResponse.self, from: data)
            apply(decoded)
        } catch {
            // 静默 — badge 不是关键路径
        }
    }

    // 2026-06-30 SSE Phase1: badge 也走 SSE 优先, 失败累计 3 次降级 poll 窗口
    private func runRealtimeLoop() async {
        while !Task.isCancelled {
            if streamFailureCount >= 3 {
                await runPollingFallbackWindow()
                streamFailureCount = 0
                continue
            }
            do {
                try await streamOnce()
                if Task.isCancelled { break }
                streamFailureCount += 1
            } catch {
                if Task.isCancelled { break }
                streamFailureCount += 1
            }
            let delay = min(15, 1 << min(streamFailureCount, 4))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    // SSE 不可用 (server 无 /chat/stream) 时降级窗口: 6 tick poll 兜底
    private func runPollingFallbackWindow() async {
        var ticks = 0
        while !Task.isCancelled, ticks < 6 {
            await fetchOnce(reset: false)
            ticks += 1
            try? await Task.sleep(nanoseconds: 5_000_000_000) // fallback only
        }
    }

    private func streamOnce() async throws {
        var components = URLComponents(
            url: CcServerConfig.serverURL.appendingPathComponent("chat/stream"),
            resolvingAgainstBaseURL: false
        )
        var items = [URLQueryItem(name: "limit", value: "50")]
        let since = latestKnownTs.isEmpty ? lastSeenTs : latestKnownTs
        if !since.isEmpty {
            items.append(URLQueryItem(name: "since", value: since))
        }
        components?.queryItems = items
        guard let finalURL = components?.url else { throw URLError(.badURL) }
        var request = CcServerConfig.authenticatedRequest(url: finalURL)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let (bytes, response) = try await streamSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.contains("text/event-stream") else {
            throw URLError(.cannotParseResponse)
        }
        streamFailureCount = 0

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            if line.hasPrefix(":") || line.isEmpty { continue }
            guard line.hasPrefix("data:") else { continue }
            let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = raw.data(using: .utf8) else { continue }
            let decoded = try JSONDecoder().decode(BadgePollResponse.self, from: data)
            apply(decoded)
        }
    }

    // poll / SSE 共用的 unread 计算逻辑 (从 fetchOnce 抽出)
    private func apply(_ decoded: BadgePollResponse) {
        let baseline = lastSeenTs
        let active = isChatTabActive
        var sawNewer = false
        for r in decoded.records where r.role != "user" && r.role != "task" {
            if !baseline.isEmpty && r.ts > baseline {
                if !active {
                    unreadCount += 1
                }
                sawNewer = true
            } else if baseline.isEmpty {
                // cold start 且没 baseline — 不算 unread (避免老用户首次启动看到大数字)
                break
            }
            if r.ts > latestKnownTs {
                latestKnownTs = r.ts
            }
        }
        // 如果 server 给的 last_ts 比本地新, 更新 latestKnownTs (不算 unread, 只追 baseline)
        if let last = decoded.lastTs, last > latestKnownTs {
            latestKnownTs = last
        }
        // Build 218 B1 — chat tab 在屏时, 把新消息 baseline 推进到最新已知, 防止下次轮询又算 unread
        if active && sawNewer {
            lastSeenTs = latestKnownTs
            if unreadCount != 0 { unreadCount = 0 }
        }
    }
}

/// 最小 schema — 只要 ts / role 算 unread, 不解析 text/attachment 节省 cpu.
private struct BadgePollResponse: Codable {
    let chat: BadgePollChat

    var records: [BadgeRecord] { chat.newRecords }
    var lastTs: String? { chat.lastTs }
}

private struct BadgePollChat: Codable {
    let newRecords: [BadgeRecord]
    let lastTs: String?

    enum CodingKeys: String, CodingKey {
        case newRecords = "new_records"
        case lastTs = "last_ts"
    }
}

private struct BadgeRecord: Codable {
    let ts: String
    let role: String?

    enum CodingKeys: String, CodingKey {
        case ts
        case role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""
        self.role = try c.decodeIfPresent(String.self, forKey: .role)
    }
}
