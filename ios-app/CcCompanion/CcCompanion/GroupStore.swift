//
//  GroupStore.swift
//  CcCompanion
//
//  Polling store for apns-server workgroup chat.
//

import Foundation
import Combine
import DirectAPICore

nonisolated struct GroupPollResponse: Codable, Sendable {
    let ok: Bool
    let records: [GroupMessage]
    let count: Int?
    let lastTs: String?
    let status: GroupStatusSnapshot?

    enum CodingKeys: String, CodingKey {
        case ok, records, count, status
        case lastTs = "last_ts"
    }
}

nonisolated struct GroupRosterResponse: Codable, Sendable {
    let ok: Bool
    let roster: [GroupMember]
    let status: GroupStatusSnapshot?
}

nonisolated struct GroupRosterOnlineResponse: Codable, Sendable {
    let ok: Bool
    let count: Int
    let online: [String]
}

actor GroupNetworkClient {
    static let shared = GroupNetworkClient()

    // 二审(P0-2): 群聊不是 directAPI 模式的功能门控对象, 但网络层兜底闸要覆盖"仓库里所有自建
    // session"这条结构性承诺(不依赖记得每处改), 经 ccGuarded() 工厂显式注入 guard protocol.
    // canInit() 只在 DirectAPIConfig.isActive 时才生效, 不影响群聊在 ccServer 模式下的现有行为.
    private let session: URLSession = {
        let cfg = DirectAPIServerGuardProtocol.ccGuarded()
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg)
    }()

    func fetchRoster() async throws -> GroupRosterResponse {
        let url = CcServerConfig.serverURL.appendingPathComponent("group/roster")
        var request = CcServerConfig.authenticatedRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response)
        return try JSONDecoder().decode(GroupRosterResponse.self, from: data)
    }

    /// Build 214 T1 — 工作群输入框 调 POST /group/send 把 amian 的文字消息塞到工作群.
    /// mentions 数组是已解析的 agent id list. Build 217 Q1: 加 replyTo 支持引用 reply_to.
    @discardableResult
    func sendMessage(senderId: String, text: String, mentions: [String], replyTo: String? = nil) async throws -> Bool {
        let url = CcServerConfig.serverURL.appendingPathComponent("group/send")
        var request = CcServerConfig.authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        var payload: [String: Any] = [
            "sender_id": senderId,
            "text": text,
            "mentions": mentions,
        ]
        if let replyTo, !replyTo.isEmpty {
            payload["reply_to"] = replyTo
            payload["parent_msg_id"] = replyTo
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await session.data(for: request)
        try Self.validate(response: response)
        return true
    }

    /// Build 217-patch-A — upload binary attachment (image / file / video) to /group/upload.
    /// 跟 /chat/upload 同款: raw POST body + query string filename/sender_id/text/mentions/reply_to.
    /// Returns the new GroupMessage record server created.
    @discardableResult
    func uploadAttachment(
        data: Data,
        filename: String,
        senderId: String,
        text: String,
        mentions: [String],
        replyTo: String?
    ) async throws -> GroupMessage? {
        var components = URLComponents(url: CcServerConfig.serverURL.appendingPathComponent("group/upload"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "sender_id", value: senderId),
            URLQueryItem(name: "text", value: text),
        ]
        if !mentions.isEmpty {
            items.append(URLQueryItem(name: "mentions", value: mentions.joined(separator: ",")))
        }
        if let replyTo, !replyTo.isEmpty {
            items.append(URLQueryItem(name: "reply_to", value: replyTo))
        }
        components?.queryItems = items
        guard let finalURL = components?.url else { throw URLError(.badURL) }
        var request = CcServerConfig.authenticatedRequest(url: finalURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 60
        let (respData, response) = try await session.upload(for: request, from: data)
        try Self.validate(response: response)
        struct UploadResponse: Codable { let ok: Bool; let record: GroupMessage? }
        return (try? JSONDecoder().decode(UploadResponse.self, from: respData))?.record
    }

    /// Build 218 Q2 — 删群消息 (多选 batch 删 共用单条删).
    @discardableResult
    func deleteMessage(id: String) async throws -> Bool {
        let url = CcServerConfig.serverURL.appendingPathComponent("group/delete")
        var request = CcServerConfig.authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id])
        let (_, response) = try await session.data(for: request)
        try Self.validate(response: response)
        return true
    }

    /// Build 220 item 13 — 在线人数 endpoint.
    func fetchOnlineRoster() async throws -> GroupRosterOnlineResponse {
        let url = CcServerConfig.serverURL.appendingPathComponent("group/roster/online")
        var request = CcServerConfig.authenticatedRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response)
        return try JSONDecoder().decode(GroupRosterOnlineResponse.self, from: data)
    }

    func touchActiveViewer() async throws {
        let url = CcServerConfig.serverURL.appendingPathComponent("group/poll")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "viewer", value: "amian"),
        ]
        guard let finalURL = components?.url else { throw URLError(.badURL) }
        var request = CcServerConfig.authenticatedRequest(url: finalURL)
        request.timeoutInterval = 10
        let (_, response) = try await session.data(for: request)
        try Self.validate(response: response)
    }

    func fetchPoll(since: String?, limit: Int) async throws -> GroupPollResponse {
        let url = CcServerConfig.serverURL.appendingPathComponent("group/poll")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Build 220 item 13 — heartbeat: sender_id=amian 让 /group/roster/online 把 amian 也算在线
        var items = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sender_id", value: "amian"),
        ]
        if let since, !since.isEmpty {
            items.append(URLQueryItem(name: "since", value: since))
        }
        components?.queryItems = items
        guard let finalURL = components?.url else { throw URLError(.badURL) }
        var request = CcServerConfig.authenticatedRequest(url: finalURL)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response)
        return try JSONDecoder().decode(GroupPollResponse.self, from: data)
    }

    private static func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

@MainActor
final class GroupStore: ObservableObject {
    @Published var messages: [GroupMessage] = []
    @Published var membersById: [String: GroupMember] = GroupMember.defaultMap
    @Published var agentStatus: [String: GroupAgentStatus] = [:]
    @Published var loading: Bool = false
    @Published var lastError: String? = nil
    // Build 215 T1 — 客户端 unread / mention 计数. 视图 onAppear markAllRead() 清零, polling 拉到新消息 → 自增.
    @Published var unreadCount: Int = 0
    @Published var mentionCount: Int = 0
    // r5: ContentView set true 当群聊 tab 在屏 + app 在前台. active 时新消息直接算"读过" 不增 badge, 同步推 lastSeenTs.
    @Published var isGroupTabActive: Bool = false
    // Build 220 item 13 — 在线人数 (每 5s 拉 /group/roster/online).
    @Published var onlineCount: Int = 0
    @Published var onlineIds: [String] = []
    // 持久化 last_seen_ts 让 app 重启后 unread 状态可恢复 (不靠后端 endpoint).
    private let lastSeenKey = "group_last_seen_ts"
    private var lastSeenTs: String {
        get { UserDefaults.standard.string(forKey: lastSeenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastSeenKey) }
    }

    private var pollTask: Task<Void, Never>? = nil
    private var onlinePollTask: Task<Void, Never>? = nil  // Build 220 item 13
    private var lastTs: String? = nil
    private let client = GroupNetworkClient.shared

    var typingMembers: [GroupMember] {
        agentStatus
            .filter { $0.value.isTyping == true && !GroupMemberRemovalsStore.isRemoved($0.key) }
            .compactMap { membersById[$0.key] ?? GroupMember.defaultMap[$0.key] }
            .sorted { $0.title < $1.title }
    }

    func member(for id: String) -> GroupMember {
        if GroupMemberRemovalsStore.isRemoved(id) {
            return GroupMember(id: id, displayName: id, kind: nil, avatar: nil, color: "neutral", model: nil, tmux: nil, canReply: nil, optional: nil)
                .withCustomAvatarURL(GroupAvatarStore.avatarPath(for: id))
        }
        // Build 220 item 5: use activeRosterMap for default fallback so removed members
        // do not come back as inactive entries. Historical sender ids fall back to
        // a minimal placeholder instead of the default roster.
        let member = membersById[id]
            ?? GroupMember.activeRosterMap[id]
            ?? GroupMember(id: id, displayName: id, kind: nil, avatar: nil, color: "neutral", model: nil, tmux: nil, canReply: nil, optional: nil)
        return member.withCustomAvatarURL(GroupAvatarStore.avatarPath(for: id))
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.reload()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.pollNext()
            }
        }
        // Build 220 item 13: online count refreshes every 5 seconds.
        onlinePollTask?.cancel()
        onlinePollTask = Task { [weak self] in
            await self?.ensureViewerOnline()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refreshOnlineCount()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        onlinePollTask?.cancel()
        onlinePollTask = nil
    }

    /// Build 220 item 13 — pull /group/roster/online; populate onlineCount + onlineIds.
    private func refreshOnlineCount() async {
        do {
            let resp = try await client.fetchOnlineRoster()
            onlineCount = resp.count
            onlineIds = resp.online
        } catch {
            // silent — header dot 不显示 ok
        }
    }

    func ensureViewerOnline() async {
        do {
            try await client.touchActiveViewer()
        } catch {
            // header online count still refreshes below
        }
        await refreshOnlineCount()
    }

    func reload() async {
        loading = true
        lastError = nil
        lastTs = nil
        await fetchRoster()
        await fetchMessages(reset: true)
    }

    func refreshNow() async {
        await fetchRoster()
        await fetchMessages(reset: false)
    }

    /// Build 220 item 6 — 删消息: 立刻本地 remove (UI 即时反馈) + 异步 server delete + poll 兜底.
    /// 解决之前 "删完 UI 不消失" 的 bug — 之前等 server poll 才更新 1-5s 延迟.
    func deleteMessage(id: String) async {
        // 1. 本地 array 立刻 remove (UI 在下次 main run loop 闪掉)
        let beforeCount = messages.count
        messages.removeAll { $0.id == id }
        guard messages.count < beforeCount else { return }  // 没找到 不发 server (避免冗余 call)
        // 2. server delete (fire-and-forget — server poll 会兜底真删)
        do {
            _ = try await GroupNetworkClient.shared.deleteMessage(id: id)
        } catch {
            // server 端失败 — refresh 拉回真实状态 (会把刚删的消息加回来)
            lastError = "删除消息失败 (server 不可达?): \(error.localizedDescription)"
            await fetchMessages(reset: false)
        }
    }

    /// Build 220 item 6 — 多选批量删 同 deleteMessage 模式.
    func deleteMessages(ids: [String]) async {
        let idSet = Set(ids)
        messages.removeAll { idSet.contains($0.id) }
        for id in ids {
            _ = try? await GroupNetworkClient.shared.deleteMessage(id: id)
        }
    }

    private func pollNext() async {
        await fetchMessages(reset: false)
    }

    /// Build 214 T1 — 发完立刻触发一次 pollNext 把自己消息拉回来 (无 optimistic, 简单可靠).
    /// Build 217 Q1 — 加 replyTo 支持引用回复.
    func sendUserMessage(text: String, mentions: [String], replyTo: String? = nil) async -> Bool {
        do {
            _ = try await client.sendMessage(senderId: "amian", text: text, mentions: mentions, replyTo: replyTo)
            await fetchMessages(reset: false)
            return true
        } catch {
            lastError = "发送失败: \(error.localizedDescription)"
            return false
        }
    }

    /// Build 217-patch-A — 上传 attachment (图片 / 文件 / 视频 / 拍照) 到 /group/upload.
    /// 走 amian sender + caption (空 OK). 上传完触发一次 fetchMessages 拉回来.
    func uploadUserAttachment(
        data: Data,
        filename: String,
        caption: String,
        mentions: [String],
        replyTo: String?
    ) async -> Bool {
        do {
            _ = try await client.uploadAttachment(
                data: data,
                filename: filename,
                senderId: "amian",
                text: caption,
                mentions: mentions,
                replyTo: replyTo
            )
            await fetchMessages(reset: false)
            return true
        } catch {
            lastError = "上传失败: \(error.localizedDescription)"
            return false
        }
    }

    /// Agent (kind == "agent") roster — 给 @ picker / mention 解析用.
    var agentMembers: [GroupMember] {
        GroupMember.activeRoster
            .filter { ($0.kind ?? "") == "agent" && !GroupMemberRemovalsStore.isRemoved($0.id) }
            .map { member(for: $0.id) }
            .sorted { $0.id < $1.id }
    }

    func mentionMember(for token: String) -> GroupMember? {
        // r4-3: 找全 roster (includes user/human members so they can be mentioned), 不只 agent
        let normalized = token.lowercased()
        let all = GroupMember.activeRoster
            .filter { !GroupMemberRemovalsStore.isRemoved($0.id) }
            .map { member(for: $0.id) }
        return all.first { member in
            member.id == token
                || member.id.lowercased() == normalized
                || member.displayName == token
                || member.title == token
        }
    }

    private func fetchRoster() async {
        do {
            let response = try await client.fetchRoster()
            let removals = GroupMemberRemovalsStore.removals()
            var map = GroupMember.activeRosterMap
            for member in response.roster where !removals.contains(member.id) {
                map[member.id] = member
            }
            membersById = map
            if let status = response.status {
                agentStatus = status.agents
            }
            lastError = nil
        } catch {
            lastError = "群聊成员加载失败: \(error.localizedDescription)"
        }
    }

    private func fetchMessages(reset: Bool) async {
        do {
            let response = try await client.fetchPoll(since: reset ? nil : lastTs, limit: reset ? 120 : 80)
            if reset {
                messages = response.records
                // Build 215 P1 — reset 路径也按 lastSeenTs 重算 unread/mention.
                // 修上一单 cold start 漏: app 重开走 reload → reset=true → 之前只赋 messages, unreadCount 不动 → 后台期间到的新消息漏算.
                recomputeUnreadFromMessages()
            } else {
                merge(records: response.records)
            }
            if let status = response.status {
                agentStatus = status.agents
            }
            if let last = response.lastTs, !last.isEmpty {
                lastTs = last
            } else if let last = response.records.last?.ts, !last.isEmpty {
                lastTs = last
            }
            loading = false
            lastError = nil
        } catch {
            loading = false
            lastError = "群聊消息加载失败: \(error.localizedDescription)"
        }
    }

    private func merge(records: [GroupMessage]) {
        guard !records.isEmpty else { return }
        var byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for record in records {
            byId[record.id] = record
        }
        messages = byId.values.sorted { lhs, rhs in
            if lhs.ts == rhs.ts { return lhs.id < rhs.id }
            return lhs.ts < rhs.ts
        }
        // Build 215 T1 — 新进来的消息按 lastSeenTs 算 unread + mention.
        // 自己发的不算 / amian 的不算 (isHumanSender).
        // r5: tab 在屏 + 前台时 active=true 新消息直接算读过 不增 badge 同步 push lastSeenTs.
        let seen = lastSeenTs
        for r in records where !r.isHumanSender {
            if seen.isEmpty || r.ts > seen {
                if isGroupTabActive {
                    // 在屏 直接算读 同步推 lastSeenTs (但不在循环里写 UserDefaults — 循环外一次)
                    continue
                }
                unreadCount += 1
                if isMentioningHuman(r) {
                    mentionCount += 1
                }
            }
        }
        if isGroupTabActive, let latest = records.last?.ts, !latest.isEmpty {
            lastSeenTs = latest
        }
    }

    /// Build 215 P1 — cold start / reset 路径用. 全量扫 messages 跟 lastSeenTs 比, 重算 unread/mention 计数.
    /// 调用前提: messages 已经赋值. 不依赖之前 stored unreadCount (会被覆盖).
    private func recomputeUnreadFromMessages() {
        // r5: tab 在屏 + 前台时 active=true 直接 0 + push lastSeenTs.
        if isGroupTabActive {
            unreadCount = 0
            mentionCount = 0
            if let latest = messages.last?.ts, !latest.isEmpty {
                lastSeenTs = latest
            }
            return
        }
        let seen = lastSeenTs
        var unread = 0
        var mention = 0
        for r in messages where !r.isHumanSender {
            if seen.isEmpty || r.ts > seen {
                unread += 1
                if isMentioningHuman(r) {
                    mention += 1
                }
            }
        }
        unreadCount = unread
        mentionCount = mention
    }

    private func isMentioningHuman(_ message: GroupMessage) -> Bool {
        // Human-tagging tokens. "amian" kept as the protocol-level id (see
        // GroupMember.defaults note); "user" / "User" are the user-facing names.
        let humanTags = ["amian", "user", "User"]
        if message.mentions.contains(where: { humanTags.contains($0) }) { return true }
        let text = message.text
        return humanTags.contains { text.contains("@\($0)") }
    }

    /// Build 215 T1 — 视图打开 / 重新进入群聊 tab 时调. 清 unread + mention 计数并记最新 lastSeenTs.
    func markAllRead() {
        unreadCount = 0
        mentionCount = 0
        if let latest = messages.last?.ts, !latest.isEmpty {
            lastSeenTs = latest
        }
    }

    /// 视图消失时存当前最新 ts 当 seen baseline. 下次新消息进来才算 unread.
    func snapshotLastSeen() {
        if let latest = messages.last?.ts, !latest.isEmpty {
            lastSeenTs = latest
        }
    }
}
