//
//  ChatView.swift
//  CcCompanion
//
//  v0.5 出门也能直接跟 Cc 聊 不切微信 不 ssh.
//  iPhone 输入 → POST /chat/send → server bus_send → tmux 主 session
//  主 session reply → bus_stop_hook → POST /chat/append → server 历史 + push spoke
//  iPhone 1s polling /chat/history?since=<lastTs>
//

import SwiftUI
import Foundation
import Combine
import AudioToolbox
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(LinkPresentation)
import LinkPresentation
#endif
#if canImport(QuickLook)
import QuickLook
#endif

// Phase F (item 7) 2026-05-11 — 复制/收藏按钮挂 bubble 右下边缘 (跟 bubble 同宽 right-align)
// 用 custom HorizontalAlignment, bubble 跟 meta HStack 都 anchor 自己的 trailing 到 bubbleEnd 这条 guide
extension HorizontalAlignment {
    private struct CcBubbleEnd: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.trailing] }
    }
    static let ccBubbleEnd = HorizontalAlignment(CcBubbleEnd.self)
}

// MARK: - Brand defaults

let CcDefaultAIName = "Claude"
// Phase F 2026-05-11 — cccompanion default user name 改 "User" (4 letters 开源用户友好)
let CcDefaultUserName = "User"

// MARK: - Cc brand colors (dynamic light + dark) — internal 让其它 view 也能用

enum CcTheme: String, CaseIterable, Identifiable {
    case warm
    case terminal
    // Phase E 2026-05-11 — wechatLight/wechatDark 删 (终端字 wechat 主题下看不清). 加 night 纯深主题.
    case night
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .warm: return "暖橙"
        case .terminal: return "终端"
        case .night: return "夜间"
        }
    }
}

enum CcColorSchemePref: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var swiftUIScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published var theme: CcTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "cc.theme") }
    }
    @Published var schemePref: CcColorSchemePref {
        didSet { UserDefaults.standard.set(schemePref.rawValue, forKey: "cc.colorScheme") }
    }
    // 2026-05-12 T2 — explicit "follow system" toggle (default true). When off,
    // schemePref locks the appearance; terminal/night still force dark.
    @Published var followSystemColorScheme: Bool {
        didSet { UserDefaults.standard.set(followSystemColorScheme, forKey: "cc.followSystemColorScheme") }
    }
    private init() {
        let raw = UserDefaults.standard.string(forKey: "cc.theme") ?? CcTheme.warm.rawValue
        self.theme = CcTheme(rawValue: raw) ?? .warm
        let sRaw = UserDefaults.standard.string(forKey: "cc.colorScheme") ?? CcColorSchemePref.system.rawValue
        self.schemePref = CcColorSchemePref(rawValue: sRaw) ?? .system
        self.followSystemColorScheme =
            UserDefaults.standard.object(forKey: "cc.followSystemColorScheme") as? Bool ?? true
    }

    /// Single source of truth for `.preferredColorScheme`.
    /// terminal / night always force `.dark`; otherwise honor the follow-system toggle
    /// (nil = follow system, else locked to schemePref with `.system` falling back to `.light`).
    var preferredColorScheme: ColorScheme? {
        if theme == .terminal || theme == .night { return .dark }
        if followSystemColorScheme { return nil }
        return schemePref.swiftUIScheme ?? .light
    }
}

extension Color {
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self = dark
        #endif
    }

    // ==== 暖橙 (default) 色卡 ====
    private static let warmBg = Color(
        light: Color(red: 0.985, green: 0.965, blue: 0.925),
        dark:  Color(red: 0.080, green: 0.060, blue: 0.050)
    )
    private static let warmCard = Color(
        light: Color(red: 0.945, green: 0.910, blue: 0.850),
        dark:  Color(red: 0.140, green: 0.110, blue: 0.090)
    )
    // 2026-05-07 用户 push 中档 (light=#E38754 比 91 桃橙深 比 89 D96B36 浅) dark 保留 89 原色
    private static let warmAssistant = Color(
        light: Color(red: 0.89, green: 0.53, blue: 0.33),
        dark:  Color(red: 0.85, green: 0.42, blue: 0.21)
    )
    private static let warmUser = Color(
        light: Color(red: 0.910, green: 0.880, blue: 0.840),
        dark:  Color(red: 0.220, green: 0.200, blue: 0.190)
    )
    private static let warmText = Color(
        light: Color(red: 0.150, green: 0.100, blue: 0.080),
        dark:  Color.white
    )
    private static let warmTextDim = Color(
        light: Color(red: 0.45, green: 0.40, blue: 0.36),
        dark:  Color.white.opacity(0.55)
    )
    private static let warmAccent = Color(
        light: Color(red: 0.80, green: 0.50, blue: 0.10),
        dark:  Color(red: 0.95, green: 0.75, blue: 0.30)
    )
    private static let warmUserText = Color(
        light: Color(red: 0.150, green: 0.100, blue: 0.080),
        dark:  Color.white
    )

    // ==== 终端 (经典 macOS Terminal 黑底白字) 色卡 ====
    // 不分浅深 永远黑底白字 气泡透明 直接文字渲染
    private static let termBg = Color(red: 0.117, green: 0.117, blue: 0.117)  // #1E1E1E 经典终端黑
    private static let termCard = Color(red: 0.16, green: 0.16, blue: 0.16)
    private static let termAssistant = Color.clear  // 气泡背景透明
    private static let termUser = Color.clear
    private static let termText = Color.white  // assistant 文字
    private static let termTextDim = Color(white: 0.55)
    private static let termAccent = Color(red: 0.40, green: 0.85, blue: 1.0)
    private static let termUserText = Color(red: 0.55, green: 0.95, blue: 0.75)  // 浅青绿 区分 user

    // ==== 夜间 = warm.dark 固定版本 (即使系统 light mode 也强制这套色) ====
    private static let nightBg = Color(red: 0.080, green: 0.060, blue: 0.050)         // = warmBg.dark
    private static let nightCard = Color(red: 0.140, green: 0.110, blue: 0.090)       // = warmCard.dark
    private static let nightAssistant = Color(red: 0.85, green: 0.42, blue: 0.21)     // = warmAssistant.dark 暖橙 AI 泡
    private static let nightUser = Color(red: 0.220, green: 0.200, blue: 0.190)       // = warmUser.dark 深灰 user 泡
    private static let nightText = Color.white                                         // = warmText.dark
    private static let nightTextDim = Color.white.opacity(0.55)                        // = warmTextDim.dark
    private static let nightAccent = Color(red: 0.95, green: 0.75, blue: 0.30)         // = warmAccent.dark 亮暖橙
    private static let nightUserText = Color.white                                     // = warmUserText.dark

    // ==== 主题路由 ====
    static var ccBg: Color {
        switch ThemeStore.shared.theme {
        case .terminal: return termBg
        case .night: return nightBg
        case .warm: return warmBg
        }
    }
    static var ccCard: Color {
        switch ThemeStore.shared.theme {
        case .terminal: return termCard
        case .night: return nightCard
        case .warm: return warmCard
        }
    }
    // 2026-05-12 T1 + 23:44 follow-system fix — FloatingTabBar must NOT collapse
    // to system pure-black under warm (T1 motivation), AND must darken to the
    // warm dark variant when system dark mode propagates (23:44 用户 catch).
    // Routing warm through the dynamic `warmCard` (which is `Color(light:, dark:)`)
    // achieves both: env=light → cream `warmCard.light`; env=dark → warm dark
    // `warmCard.dark` = (0.14, 0.11, 0.09). preferredColorScheme(nil) lets the
    // system propagate; locked light/dark also resolves correctly via the same
    // environment binding.
    static var ccFloatingBarBg: Color {
        switch ThemeStore.shared.theme {
        case .terminal: return termCard
        case .night: return nightCard
        case .warm: return warmCard
        }
    }
    static var ccFloatingBarText: Color {
        switch ThemeStore.shared.theme {
        case .terminal, .night: return ccText
        case .warm: return warmText
        }
    }
    static var ccAssistant: Color {
        switch ThemeStore.shared.theme {
        case .terminal: return termAssistant
        case .night: return nightAssistant
        case .warm: return warmAssistant
        }
    }
    static var ccUser: Color {
        switch ThemeStore.shared.theme {
        case .terminal: return termUser
        case .night: return nightUser
        case .warm: return warmUser
        }
    }
    static var ccText: Color {
        switch ThemeStore.shared.theme {
        case .terminal: return termText
        case .night: return nightText
        case .warm: return warmText
        }
    }
    static var ccTextDim: Color {
        #if targetEnvironment(macCatalyst)
        switch ThemeStore.shared.theme {
        case .terminal: return Color(white: 0.73)
        case .night: return nightTextDim
        case .warm: return Color(light: Color(red: 0.45, green: 0.40, blue: 0.36),
                                  dark: Color.white.opacity(0.85))
        }
        #else
        switch ThemeStore.shared.theme {
        case .terminal: return termTextDim
        case .night: return nightTextDim
        case .warm: return warmTextDim
        }
        #endif
    }
    static var ccAccent: Color {
        switch ThemeStore.shared.theme {
        case .terminal: return termAccent
        case .night: return nightAccent
        case .warm: return warmAccent
        }
    }
    static var ccUserText: Color {
        switch ThemeStore.shared.theme {
        case .terminal: return termUserText
        case .night: return nightUserText
        case .warm: return warmUserText
        }
    }
    static var ccAssistantText: Color {
        switch ThemeStore.shared.theme {
        case .terminal: return Color.white
        case .night: return nightText
        case .warm: return Color.white
        }
    }
}

// 终端风字体 helper — view 自己根据 theme 选
extension Font {
    static func ccBody(theme: CcTheme) -> Font {
        theme == .terminal ? .system(.body, design: .monospaced) : .body
    }
}

nonisolated struct ChatLocation: Codable, Hashable, Sendable {
    let lat: Double
    let lon: Double
    let accuracy: Double?
    let label: String?
}

nonisolated struct ChoiceOption: Codable, Hashable, Sendable {
    let label: String
    let value: String
}

nonisolated struct ChatMetadata: Codable, Hashable, Sendable {
    let kind: String?
    let options: [ChoiceOption]?
}

struct ImagePreview: Identifiable, Sendable {
    let id = UUID()
    let data: Data
}

nonisolated struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    let ts: String
    let role: String
    let text: String
    let source: String?
    let quotedTs: String?
    let quotedText: String?
    let attachmentUrl: String?
    let attachmentType: String?  // "image" | "file"
    let attachmentFilename: String?
    let reactions: [String]?
    let audioZh: String?
    let audioEn: String?
    let audioJa: String?
    let location: ChatLocation?
    let metadata: ChatMetadata?
    // 2026-05-12 optimistic-send sort-fix: `ts` now holds the real ISO send
    // timestamp (so failed bubbles sort chronologically alongside server records
    // instead of permanently gluing to the bottom via `local-` lex tail).
    // `localId` is the stable tracking key for sendingIds / failedIds /
    // pendingFailedMessages. nil for any record that originated server-side.
    var localId: String? = nil

    enum CodingKeys: String, CodingKey {
        case ts, role, text, source, reactions
        case quotedTs = "quoted_ts"
        case quotedText = "quoted_text"
        case attachmentUrl = "attachment_url"
        case attachmentType = "attachment_type"
        case attachmentFilename = "attachment_filename"
        case audioZh = "audio_zh"
        case audioEn = "audio_en"
        case audioJa = "audio_ja"
        case location
        case metadata
        case localId = "local_id"
    }

    var id: String { localId ?? (ts + role) }
    var isUser: Bool { role == "user" }

    func attachmentFullURL() -> URL? {
        guard let path = attachmentUrl else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: CcServerConfig.serverURL.absoluteString + path)
    }

    private func absoluteAudioURL(_ path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: CcServerConfig.serverURL.absoluteString + path)
    }

    func multiLangAudios() -> [String: URL] {
        var result: [String: URL] = [:]
        if let zh = audioZh, let url = absoluteAudioURL(zh) { result["zh"] = url }
        if let en = audioEn, let url = absoluteAudioURL(en) { result["en"] = url }
        if let ja = audioJa, let url = absoluteAudioURL(ja) { result["ja"] = url }
        return result
    }

    var hasMultiLangAudio: Bool {
        audioZh != nil || audioEn != nil || audioJa != nil
    }
}

// MARK: - Send-status (optimistic UI + retry, 2026-05-12 spec ots-send-optimistic-retry)
//
// SendStatus is *transient UI metadata* — not part of the server JSON
// envelope and not stored in GRDB. ChatViewModel maintains two ID sets
// (`sendingIds`, `failedIds`) + a UserDefaults-backed list of optimistic
// records so the bubble survives an app kill.
nonisolated public enum SendStatus: String, Codable, Hashable, Sendable {
    case sending
    case sent
    case failed
}

nonisolated public enum ChatConnectionStatus: String, Hashable, Sendable {
    case connected
    case thinking
    case offline
}

nonisolated struct ChatPollResponse: Codable, Sendable {
    let ok: Bool
    let now: String
    let chat: ChatPollChat
    let status: ChatPollStatus
    let settings: ChatPollSettings
}

nonisolated struct ChatPollChat: Codable, Sendable {
    let newRecords: [ChatMessage]
    let lastTs: String?
    let count: Int?

    enum CodingKeys: String, CodingKey {
        case newRecords = "new_records"
        case lastTs = "last_ts"
        case count
    }
}

nonisolated struct ChatPollStatus: Codable, Sendable {
    let status: String
    let isTyping: Bool?
    let since: String?

    enum CodingKeys: String, CodingKey {
        case status, since
        case isTyping = "is_typing"
    }
}

nonisolated struct ChatPollSettings: Codable, Sendable {
    let unchanged: Bool?
    let etag: String?
    let values: [String: Bool]?
}

struct PendingUpload: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case uploading
        case failed(String)
    }

    let id: UUID
    let data: Data
    let filename: String
    let caption: String
    let quotedTs: String?
    var progress: Double
    var state: State

    var displayName: String { filename.isEmpty ? "upload.bin" : filename }
}

enum ChatNetworkError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "网络响应无效"
        case .httpStatus(let code): return "HTTP \(code)"
        }
    }
}

actor ChatNetworkClient {
    static let shared = ChatNetworkClient()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    func fetchPoll(since: String?, etag: String?) async throws -> ChatPollResponse {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/poll")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "limit", value: "50")]
        if let since { items.append(URLQueryItem(name: "since", value: since)) }
        if let etag { items.append(URLQueryItem(name: "etag", value: etag)) }
        components?.queryItems = items
        guard let finalURL = components?.url else { throw URLError(.badURL) }
        var request = CcServerConfig.authenticatedRequest(url: finalURL)
        request.timeoutInterval = 30
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(ChatPollResponse.self, from: data)
    }

    func fetchHistory(url: URL) async throws -> [ChatMessage] {
        var request = CcServerConfig.authenticatedRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatNetworkError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ChatNetworkError.httpStatus(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(ChatViewModel.ChatHistoryResponse.self, from: data)
        return decoded.records
    }


    func fetchSendResponse(for request: URLRequest) async throws -> ChatMessage? {
        let (data, _) = try await session.data(for: request)
        let decoded = try? JSONDecoder().decode(ChatViewModel.ChatSendResponse.self, from: data)
        return decoded?.record
    }
}

struct ToolStack: Identifiable, Hashable {
    let id: String  // 第一条 task message id
    let agent: String  // sender_id / source
    let tools: [ChatMessage]  // role=task 的连续消息
    let isRunning: Bool
    let summary: String
}

enum ChatRowItem: Identifiable, Hashable {
    case message(ChatMessage, showTime: Bool)
    case separator(label: String, id: String)
    case toolStack(ToolStack)

    var id: String {
        switch self {
        case .message(let m, _): return m.id
        case .separator(_, let id): return id
        case .toolStack(let s): return "stack_\(s.id)"
        }
    }

    static func formatSeparator(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(date) {
            return "今天 " + timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 " + timeFormatter.string(from: date)
        }
        if calendar.dateComponents([.year], from: date) == calendar.dateComponents([.year], from: now) {
            return shortDateFormatter.string(from: date)
        }
        return fullDateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f
    }()
    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = [] {
        didSet {
            // 仅末尾 append 1 条 + 同 day + < 30min gap → incremental append
            // 其他情况 (中间 mutate / 整体替换 / 跨 day / 大 gap / 搜索态) → 全量 rebuild
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let inSearchMode = !q.isEmpty || searchFilter != .all
            if !inSearchMode,
               messages.count == oldValue.count + 1,
               messages.count <= visibleLimit,
               Array(messages.dropLast()) == oldValue,
               let last = messages.last,
               last.role != "move",
               last.role != "task",  // task 进 toolStack 全量 rebuild
               !needsNewSeparator(prev: oldValue.last, cur: last) {
                appendIncrementalRow(last, prev: oldValue.last)
            } else {
                rebuildDisplayedRowsCache()
            }
        }
    }
    @Published var draft: String = ""
    @Published var sending: Bool = false
    @Published var lastError: String? = nil
    // 2026-05-12 optimistic-send: id sets are *ephemeral* (recomputed on launch
    // from persisted pendingFailedMessages). sendingIds are never persisted.
    @Published var sendingIds: Set<String> = []
    @Published var failedIds: Set<String> = []
    @Published private var localSendStartedAt: [String: Date] = [:]
    @Published var lastNetworkSuccessAt: Date? = nil
    // 2026-05-14 build 194 — 同步历史进度. 用户之前看不出"同步全部历史"按钮干了什么 加 toast 浮窗
    enum BackfillState: Equatable { case running(synced: Int); case done(synced: Int); case error }
    @Published var backfillProgress: BackfillState? = nil
    // Optimistic local-only messages awaiting server echo. Persisted to UserDefaults
    // (key `pendingFailedSends_v1`) so failed bubbles survive app kill / re-launch.
    @Published private(set) var pendingFailedMessages: [ChatMessage] = []
    private static let kPendingFailedKey = "pendingFailedSends_v1"
    @Published var quoting: ChatMessage? = nil
    @Published var searchText: String = "" { didSet { rebuildDisplayedRowsCache() } }
    @Published var serverSearchResults: [ChatMessage] = [] { didSet { rebuildDisplayedRowsCache() } }
    @Published var isServerSearching: Bool = false
    @Published var isCcTyping: Bool = false
    @Published var ccStatus: String = "online"  // online | typing | sleeping
    @Published var searchFilter: SearchFilter = .all { didSet { rebuildDisplayedRowsCache() } }
    @Published var chatSoundEnabled: Bool = true
    @Published var taskSoundEnabled: Bool = true
    @Published var multiSelectMode: Bool = false
    @Published var selectedTs: Set<String> = []
    @Published var loadingEarlier: Bool = false
    @Published var hasMoreEarlier: Bool = true
    @Published var uploadQueue: [PendingUpload] = []
    @Published private(set) var displayedRowsCache: [ChatRowItem] = []
    @Published private(set) var visibleLimit: Int = 300 { didSet { rebuildDisplayedRowsCache() } }

    var connectionStatus: ChatConnectionStatus {
        if ccStatus == "typing" || isCcTyping { return .thinking }
        if let lastNetworkSuccessAt, Date().timeIntervalSince(lastNetworkSuccessAt) <= 30 {
            return .connected
        }
        return .offline
    }

    private func recordNetworkSuccess() {
        lastNetworkSuccessAt = Date()
    }

    // MARK: - Last assistant turn helpers (task 2+3)
    private var lastAssistantTurn: [ChatMessage] {
        var result: [ChatMessage] = []
        for msg in messages.reversed() {
            guard msg.role != "task", msg.role != "move" else { continue }
            if msg.isUser { break }
            result.insert(msg, at: 0)
        }
        return result
    }
    var lastAssistantTurnLastTs: String? { lastAssistantTurn.last?.ts }
    var lastAssistantTurnFirstTs: String? { lastAssistantTurn.first?.ts }
    var lastAssistantTurnTexts: [String] { lastAssistantTurn.map { $0.text } }
    // All ts in the last turn except the first — passed as extra_replace_ids to server
    var lastAssistantTurnExtraTs: [String] { Array(lastAssistantTurn.dropFirst().map { $0.ts }) }

    // Phase D amendment #18 — every assistant turn-end ts (not just the latest).
    // A message qualifies if it's a non-user assistant message AND the next non-task/move message is a user message (or end of list).
    var assistantTurnEndsTs: Set<String> {
        var result: Set<String> = []
        let filtered = messages.filter { $0.role != "task" && $0.role != "move" }
        for (i, msg) in filtered.enumerated() {
            if msg.isUser { continue }
            let nextIsUser = (i + 1 < filtered.count) ? filtered[i+1].isUser : true
            if nextIsUser { result.insert(msg.ts) }
        }
        return result
    }

    /// All assistant messages in the turn ENDING at the given ts (turn-end message).
    /// Walks back from end until previous user message (exclusive).
    func turnMessages(endingAt ts: String) -> [ChatMessage] {
        let filtered = messages.filter { $0.role != "task" && $0.role != "move" }
        guard let endIdx = filtered.firstIndex(where: { $0.ts == ts }) else { return [] }
        var startIdx = endIdx
        while startIdx > 0, !filtered[startIdx - 1].isUser {
            startIdx -= 1
        }
        return Array(filtered[startIdx...endIdx])
    }

    func turnTexts(endingAt ts: String) -> [String] {
        turnMessages(endingAt: ts).map { $0.text }
    }

    enum SearchFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case image = "图片视频"
        case file = "文件"
        case link = "链接"
        case audio = "音乐音频"
        var id: String { rawValue }
    }

    /// 2026-05-08 用户 push search 状态机 — idle/searching/results/empty/error 四态共享一个 source-of-truth.
    enum SearchState: Equatable {
        case idle
        case searching
        case results(count: Int)
        case empty
        case error(String)
    }

    var searchState: SearchState {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty && searchFilter == .all { return .idle }
        if isServerSearching { return .searching }
        if let err = lastError, err.contains("搜索") { return .error(err) }
        let count = displayedMessages.count
        if count == 0 { return .empty }
        return .results(count: count)
    }

    var displayedMessages: [ChatMessage] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // serverSearchResults 在两种情况下被填: 1) keyword 搜索结果 2) attachment tab 预拉
        let baseSet: [ChatMessage] = !serverSearchResults.isEmpty
            ? serverSearchResults
            : messages

        // 不在搜索状态只渲染可见窗口；messages 本体仍保留完整顺序供 scroll anchor 使用。
        if q.isEmpty && searchFilter == .all { return Array(messages.suffix(visibleLimit)) }


        let needle = q.lowercased()
        return baseSet.filter { msg in
            // 关键字过滤
            let matchKeyword = q.isEmpty
                || msg.text.lowercased().contains(needle)
                || (msg.attachmentFilename ?? "").lowercased().contains(needle)
            guard matchKeyword else { return false }
            // 类型过滤
            switch searchFilter {
            case .all:
                return true
            case .image:
                return msg.attachmentType == "image"
            case .file:
                return msg.attachmentType == "file"
            case .audio:
                return msg.attachmentType == "audio"
            case .link:
                return msg.text.range(of: #"https?://[^\s]+"#, options: .regularExpression) != nil
            }
        }
        // messages 本体已 sort，search 结果直接用 baseSet 顺序 (baseSet 已排序)
    }

    var selectableDisplayedMessages: [ChatMessage] {
        displayedMessages.filter { $0.role != "task" }
    }

    func expandVisibleWindow(by count: Int) {
        visibleLimit += count
    }

    func resetVisibleWindowToRecent() {
        if visibleLimit > 300 {
            visibleLimit = 300
        }
    }

    private func rebuildDisplayedRowsCache() {
        let start = CFAbsoluteTimeGetCurrent()
        let msgs = displayedMessages.filter { $0.role != "move" }
        var out: [ChatRowItem] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lastDate: Date? = nil
        let showTimeById = makeShowTimeById(formatter: formatter)
        var taskBuffer: [ChatMessage] = []

        func flushTaskBuffer() {
            guard !taskBuffer.isEmpty else { return }
            let agent = taskBuffer.first?.source ?? "枢"
            let stack = ToolStack(
                id: taskBuffer.first!.id,
                agent: agent,
                tools: taskBuffer,
                isRunning: false,
                summary: Self.makeToolSummary(taskBuffer)
            )
            out.append(.toolStack(stack))
            taskBuffer.removeAll()
        }

        for msg in msgs {
            if msg.role == "task" {
                // separator 仍然按 task 时间插 (对第一条 task)
                if taskBuffer.isEmpty {
                    let cur = Self.parseChatDate(msg.ts, formatter: formatter)
                    let needSep: Bool = {
                        guard let cur = cur else { return false }
                        guard let prev = lastDate else { return true }
                        let calendar = Calendar.current
                        let crossDay = !calendar.isDate(cur, inSameDayAs: prev)
                        let bigGap = cur.timeIntervalSince(prev) > 1800
                        return crossDay || bigGap
                    }()
                    if needSep, let cur = cur {
                        out.append(.separator(label: ChatRowItem.formatSeparator(cur), id: "sep_\(msg.ts)"))
                    }
                    if let cur = cur { lastDate = cur }
                }
                taskBuffer.append(msg)
                continue
            }
            // 非 task: 先 flush
            flushTaskBuffer()
            let cur = Self.parseChatDate(msg.ts, formatter: formatter)
            let needSep: Bool = {
                guard let cur = cur else { return false }
                guard let prev = lastDate else { return true }
                let calendar = Calendar.current
                let crossDay = !calendar.isDate(cur, inSameDayAs: prev)
                let bigGap = cur.timeIntervalSince(prev) > 1800
                return crossDay || bigGap
            }()
            if needSep, let cur = cur {
                out.append(.separator(label: ChatRowItem.formatSeparator(cur), id: "sep_\(msg.ts)"))
            }
            out.append(.message(msg, showTime: showTimeById[msg.id] ?? true))
            if let cur = cur { lastDate = cur }
        }
        flushTaskBuffer()

        // 最后一组如果是 toolStack 且最近 30s 内仍在跑 标记 isRunning=true
        if let lastIdx = out.indices.last, case .toolStack(let stack) = out[lastIdx] {
            if let lastTs = stack.tools.last?.ts,
               let lastDate = Self.parseChatDate(lastTs, formatter: formatter),
               Date().timeIntervalSince(lastDate) < 30 {
                let running = ToolStack(
                    id: stack.id,
                    agent: stack.agent,
                    tools: stack.tools,
                    isRunning: true,
                    summary: stack.summary
                )
                out[lastIdx] = .toolStack(running)
            }
        }

        displayedRowsCache = out
    }

    private static func makeToolSummary(_ tasks: [ChatMessage]) -> String {
        let toolCount = tasks.count
        let combined = tasks.map { $0.text }.joined(separator: " ").lowercased()
        var parts: [String] = ["使用 \(toolCount) 个工具"]
        // 简化文件计数: 抓 Edited/Wrote/Read/Created 后面的文件名出现次数
        let fileMatches = tasks.filter { msg in
            let t = msg.text.lowercased()
            return t.contains("edited") || t.contains("wrote") || t.contains("created") || t.contains("修改") || t.contains("新建")
        }.count
        if fileMatches > 0 {
            parts.append("\(fileMatches) 文件变更")
        }
        if combined.contains("build succeeded") || combined.contains("build ok") {
            parts.append("build ok")
        } else if combined.contains("build failed") || combined.contains("build error") {
            parts.append("build 失败")
        }
        return parts.joined(separator: " · ")
    }

    /// 检测末尾 append 一条新消息是否需要插 day/30min separator。
    /// nil prev → 当前是第一条 必须插 separator (return true)
    private func needsNewSeparator(prev: ChatMessage?, cur: ChatMessage) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let prev = prev else { return true }
        guard let curDate = Self.parseChatDate(cur.ts, formatter: formatter),
              let prevDate = Self.parseChatDate(prev.ts, formatter: formatter) else {
            return false
        }
        let calendar = Calendar.current
        let crossDay = !calendar.isDate(curDate, inSameDayAs: prevDate)
        let bigGap = curDate.timeIntervalSince(prevDate) > 1800
        return crossDay || bigGap
    }

    /// 末尾追加单条 row 到 cache 不全量重算。
    /// 同时回填上一条的 showTime (如果上一条与当前同 role 且时间差 <= 120s 则上一条 showTime=false)。
    private func appendIncrementalRow(_ msg: ChatMessage, prev: ChatMessage?) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // 回填上一条 row 的 showTime: 仅在上一条 cache 末尾是 .message 且与当前 msg 同 role 且 gap <= 120s 时改为 false
        if let prev = prev,
           prev.role == msg.role,
           let prevDate = Self.parseChatDate(prev.ts, formatter: formatter),
           let curDate = Self.parseChatDate(msg.ts, formatter: formatter),
           curDate.timeIntervalSince(prevDate) <= 120,
           let lastIdx = displayedRowsCache.indices.last,
           case .message(let lastMsg, _) = displayedRowsCache[lastIdx],
           lastMsg.id == prev.id {
            displayedRowsCache[lastIdx] = .message(lastMsg, showTime: false)
        }
        // 当前 row 默认 showTime=true (末尾本来就显示时间 后续来更新的 msg 再回填)
        // 不带任何动画 直接 append 防止跟 scroll bottom 撞抖
        displayedRowsCache.append(.message(msg, showTime: true))
    }

    private func makeShowTimeById(formatter: ISO8601DateFormatter) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for idx in messages.indices {
            let msg = messages[idx]
            let nextIndex = messages.index(after: idx)
            guard nextIndex < messages.endIndex else {
                out[msg.id] = true
                continue
            }
            let next = messages[nextIndex]
            guard next.role == msg.role,
                  let cur = Self.parseChatDate(msg.ts, formatter: formatter),
                  let nxt = Self.parseChatDate(next.ts, formatter: formatter) else {
                out[msg.id] = true
                continue
            }
            out[msg.id] = nxt.timeIntervalSince(cur) > 120
        }
        return out
    }

    private static func parseChatDate(_ ts: String, formatter: ISO8601DateFormatter) -> Date? {
        formatter.date(from: ts) ?? formatter.date(from: ts.replacingOccurrences(of: "+08:00", with: "Z"))
    }

    private var pollingTask: Task<Void, Never>? = nil
    private var lastTs: String? = nil
    private var settingsEtag: String? = nil
    private var pollingFailureCount: Int = 0
    private var appIsActive: Bool = true
    let chatStore = ChatStore.shared
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        return URLSession(configuration: cfg)
    }()

    func start() {
        print("[chat-hydrate] start called")
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            // 2026-05-07 hotfix removed: enforceCacheCap 是 SwiftData 卡 search 时代的兜底 GRDB+FTS5 全量搜不需要 cap
            await self?.loadCachedHistory()
            await self?.bootstrapHistory()
            await self?.pollOnce()
            // Phase 设置大砍 (item B) — populate favorite cache so bookmark icons render correctly
            await FavoritedTurnsCache.shared.refreshFromServer()
            // 2026-05-07 Phase 2: 后台 backfill 限 5000 条 (不再全量 13322 卡 search)
            Task.detached(priority: .background) { [weak self] in
                await self?.backfillHistory()
            }
            // 2026-05-09 用户 push 设置里手动触发 "重新同步全部历史" 监听 notification 重跑 backfill
            let notifTask = Task { [weak self] in
                let stream = NotificationCenter.default.notifications(named: NSNotification.Name("CcResyncHistory"))
                for await _ in stream {
                    guard let self else { return }
                    UserDefaults.standard.set(false, forKey: "backfillComplete_v2")
                    Task.detached(priority: .background) { [weak self] in
                        await self?.backfillHistory()
                    }
                }
            }
            _ = notifTask
            while !Task.isCancelled {
                let delay = self?.pollDelaySeconds() ?? 5
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.pollOnce()
            }
        }
    }

    func setPollingActive(_ active: Bool) {
        appIsActive = active
    }

    private func pollDelaySeconds() -> Int {
        if !appIsActive { return 5 }
        if pollingFailureCount <= 0 { return 1 }
        return min(16, 1 << min(pollingFailureCount, 4))
    }

    private func pollOnce() async {
        do {
            let response = try await ChatNetworkClient.shared.fetchPoll(since: lastTs, etag: settingsEtag)
            recordNetworkSuccess()
            pollingFailureCount = 0
            isCcTyping = response.status.isTyping ?? (response.status.status == "typing")
            ccStatus = response.status.status
            if let etag = response.settings.etag { settingsEtag = etag }
            if response.settings.unchanged != true, let values = response.settings.values {
                chatSoundEnabled = values["chat_sound_enabled"] ?? chatSoundEnabled
                taskSoundEnabled = values["task_sound_enabled"] ?? taskSoundEnabled
            }
            if !response.chat.newRecords.isEmpty {
                chatStore.upsert(response.chat.newRecords)
                mergeUnique(response.chat.newRecords)
                reconcileLocalSendState()
                await refreshRecent()
                lastError = nil
            } else if let last = response.chat.lastTs, (lastTs ?? "") < last {
                lastTs = last
                reconcileLocalSendState()
            }
        } catch {
            pollingFailureCount += 1
            objectWillChange.send()
        }
    }

    private func fetchSoundSettings() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("settings")
        do {
            let (data, _) = try await session.data(for: CcServerConfig.authenticatedRequest(url: url))
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let s = obj["settings"] as? [String: Any] {
                let chat = s["chat_sound_enabled"] as? Bool ?? true
                let task = s["task_sound_enabled"] as? Bool ?? true
                await MainActor.run {
                    self.chatSoundEnabled = chat
                    self.taskSoundEnabled = task
                }
            }
        } catch {}
    }

    private func refreshRecent() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/history")
        guard let withQuery = URL(string: url.absoluteString + "?limit=50") else { return }
        do {
            let records = try await ChatNetworkClient.shared.fetchHistory(url: withQuery)
            recordNetworkSuccess()
            // 用 id-keyed map 合并 — 若 ts 已存在替换 (reaction / edit) / 不存在 append
            var byId: [String: Int] = [:]
            for (i, m) in self.messages.enumerated() { byId[m.id] = i }
            var appended = false
            for rec in records {
                if let idx = byId[rec.id] {
                    if self.messages[idx] != rec {
                        self.messages[idx] = rec
                    }
                } else {
                    self.messages.append(rec)
                    appended = true
                    if (self.lastTs ?? "") < rec.ts {
                        self.lastTs = rec.ts
                    }
                }
            }
            if appended { _sortMessages() }
            self.chatStore.upsert(records)
            reconcileLocalSendState()
        } catch {
            // 静默
        }
    }

    private func fetchTyping() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/typing")
        do {
            let (data, _) = try await session.data(for: CcServerConfig.authenticatedRequest(url: url))
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let isTyping = obj["is_typing"] as? Bool {
                self.isCcTyping = isTyping
            }
        } catch {
            // 网络抖动静默
        }
    }

    private func fetchStatus() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/status")
        do {
            let (data, _) = try await session.data(for: CcServerConfig.authenticatedRequest(url: url))
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = obj["status"] as? String {
                self.ccStatus = status
            }
        } catch {
            // 静默
        }
    }

    func react(_ msg: ChatMessage, emoji: String) async {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/react")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let s = CcServerConfig.sharedSecret, !s.isEmpty { req.setValue(s, forHTTPHeaderField: "X-Auth-Token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["ts": msg.ts, "emoji": emoji])
        do {
            _ = try await session.data(for: req)
            // 立即本地 toggle
            if let idx = self.messages.firstIndex(where: { $0.id == msg.id }) {
                var updated = self.messages[idx].reactions ?? []
                if let pos = updated.firstIndex(of: emoji) {
                    updated.remove(at: pos)
                } else {
                    updated.append(emoji)
                }
                let m = self.messages[idx]
                self.messages[idx] = ChatMessage(
                    ts: m.ts, role: m.role, text: m.text, source: m.source,
                    quotedTs: m.quotedTs, quotedText: m.quotedText,
                    attachmentUrl: m.attachmentUrl, attachmentType: m.attachmentType,
                    attachmentFilename: m.attachmentFilename,
                    reactions: updated.isEmpty ? nil : updated,
                    audioZh: m.audioZh, audioEn: m.audioEn, audioJa: m.audioJa,
                    location: m.location,
                    metadata: m.metadata
                )
            }
        } catch {
            self.lastError = "reaction 失败: \(error.localizedDescription)"
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func loadEarlier() async {
        guard !loadingEarlier, hasMoreEarlier else { return }
        guard let oldest = messages.first?.ts else { return }
        await MainActor.run { self.loadingEarlier = true }
        defer { Task { @MainActor in self.loadingEarlier = false } }
        let cached = chatStore.before(ts: oldest, limit: 200)
        if !cached.isEmpty {
            let existingIds = Set(self.messages.map { $0.id })
            let newOnes = cached.filter { !existingIds.contains($0.id) }
            if !newOnes.isEmpty {
                self.messages = newOnes + self.messages
                self.expandVisibleWindow(by: 200)
                self.hasMoreEarlier = chatStore.before(ts: newOnes.first?.ts ?? oldest, limit: 1).isEmpty == false
                return
            }
        }
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/history")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "before", value: oldest),
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let finalURL = components?.url else { return }
        do {
            let records = try await ChatNetworkClient.shared.fetchHistory(url: finalURL)
            recordNetworkSuccess()
            if records.isEmpty {
                await MainActor.run { self.hasMoreEarlier = false }
                return
            }
            // prepend 旧消息到 messages 头 + 去重
            await MainActor.run {
                let existingIds = Set(self.messages.map { $0.id })
                let newOnes = records.filter { !existingIds.contains($0.id) }
                if newOnes.isEmpty {
                    self.hasMoreEarlier = false
                } else {
                    self.messages = newOnes + self.messages
                    self.expandVisibleWindow(by: 200)
                    self.chatStore.upsert(newOnes)
                }
            }
        } catch {
            // 静默
        }
    }

    private func bootstrapHistory() async {
        // 后台同步全量进 SwiftData，UI 仍只渲染最近 200 条，避免 List 一次性吃上万行。
        // 5-2 23:02 用户 catch 卡死: chatStore.upsert(3963 条) 在主线程阻塞 UI
        // 修: messages = latest 200 条立刻显示 + upsertAsync 分批 yield 后台慢慢写
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/history")
        guard let withQuery = URL(string: url.absoluteString + "?limit=500") else {
            return
        }
        do {
            let records = try await ChatNetworkClient.shared.fetchHistory(url: withQuery)
            recordNetworkSuccess()
            // 先把最近 200 条给 UI 显示 (立刻 不等 SwiftData 写完)
            var latest = Array(records.suffix(200))
            latest.sort(by: Self.chatMessageAscending)
            latest = mergeLocalCommandMessages(into: latest)
            self.messages = latest
            reconcileLocalSendState()
            self.lastTs = records.last?.ts
            self.hasMoreEarlier = records.count >= 200
            // SwiftData 全量 upsert 异步分批 不阻塞 UI
            await self.chatStore.upsertAsync(records)
            self.hasMoreEarlier = records.count >= 200 || self.chatStore.before(ts: latest.first?.ts ?? "", limit: 1).isEmpty == false
        } catch {
            self.lastError = "拉历史失败: \(error.localizedDescription)"
        }
    }

    private func loadCachedHistory() async {
        var cached = chatStore.latest(limit: 200)
        guard !cached.isEmpty else { return }
        cached.sort(by: Self.chatMessageAscending)
        cached = mergeLocalCommandMessages(into: cached)
        self.messages = cached
        self.lastTs = cached.last?.ts
        self.hasMoreEarlier = chatStore.before(ts: cached.first?.ts ?? "", limit: 1).isEmpty == false
        // 2026-05-12 — re-merge any persisted optimistic-failed records on top of
        // the freshly-loaded server cache (kept as ephemeral, no GRDB write).
        self.restorePendingFailedMessages()
    }

    // P0 scroll-jump fix: keep messages array in ts order so messages.last == newest
    private func _sortMessages() {
        messages.sort(by: Self.chatMessageAscending)
    }

    private static func chatMessageAscending(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lhsDate = parseChatDate(lhs.ts, formatter: formatter)
        let rhsDate = parseChatDate(rhs.ts, formatter: formatter)
        switch (lhsDate, rhsDate) {
        case let (l?, r?) where l != r:
            return l < r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
            return lhs.id < rhs.id
        }
    }

    private static func chatMessageDescending(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        chatMessageAscending(rhs, lhs)
    }

    private func mergeLocalCommandMessages(into base: [ChatMessage]) -> [ChatMessage] {
        let localCommands = messages.filter { $0.localId?.hasPrefix("cmd-") == true }
        guard !localCommands.isEmpty else { return base }
        var seen = Set(base.map(\.id))
        var merged = base
        for msg in localCommands where !seen.contains(msg.id) {
            merged.append(msg)
            seen.insert(msg.id)
        }
        return merged.sorted(by: Self.chatMessageAscending)
    }

    private func appendUnique(_ rec: ChatMessage) {
        // 2026-05-12: don't persist optimistic records into GRDB — they're
        // UI-only until the server echoes back a canonical record. Identify
        // optimistic by the `localId` field (the `ts` is now real ISO and
        // indistinguishable from server ts).
        if rec.localId == nil {
            chatStore.upsert([rec])
        }
        if !self.messages.contains(where: { $0.id == rec.id }) {
            self.messages.append(rec)
            _sortMessages()
        }
        if (self.lastTs ?? "") < rec.ts {
            self.lastTs = rec.ts
        }
    }

    private func mergeUnique(_ records: [ChatMessage]) {
        chatStore.upsert(records)
        let existing = Set(self.messages.map { $0.id })
        var added = false
        for r in records where !existing.contains(r.id) {
            self.messages.append(r)
            added = true
        }
        if added { _sortMessages() }
        if let last = records.last, (self.lastTs ?? "") < last.ts {
            self.lastTs = last.ts
        }
    }

    private func fetchNew() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/history")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: "50")]
        if let last = lastTs {
            items.append(URLQueryItem(name: "since", value: last))
        }
        components?.queryItems = items
        guard let finalURL = components?.url else { return }
        do {
            let (data, _) = try await session.data(for: CcServerConfig.authenticatedRequest(url: finalURL))
            let decoded = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
            if !decoded.records.isEmpty {
                self.mergeUnique(decoded.records)
                self.lastError = nil
            }
        } catch {
            // 网络抖动静默 不刷红
        }
    }

    func upload(data: Data, filename: String, caption: String = "", quotedTs: String? = nil) async {
        let id = UUID()
        let isImage = filename.lowercased().hasSuffix(".jpg")
            || filename.lowercased().hasSuffix(".jpeg")
            || filename.lowercased().hasSuffix(".png")
            || filename.lowercased().hasSuffix(".heic")
        let payload = isImage ? ImageCompressor.compress(data: data) : data
        let queued = PendingUpload(
            id: id,
            data: payload,
            filename: filename,
            caption: caption,
            quotedTs: quotedTs,
            progress: 0,
            state: .queued
        )
        uploadQueue.append(queued)
        await runUpload(id: id)
    }

    func retryUpload(_ upload: PendingUpload) async {
        if let idx = uploadQueue.firstIndex(where: { $0.id == upload.id }) {
            uploadQueue[idx].progress = 0
            uploadQueue[idx].state = .queued
        }
        await runUpload(id: upload.id)
    }

    private func runUpload(id: UUID) async {
        guard let upload = uploadQueue.first(where: { $0.id == id }) else { return }
        // caption / filename 走 query string 不走 header (HTTP header 不支持非 ASCII)
        var components = URLComponents(
            url: CcServerConfig.serverURL.appendingPathComponent("chat/upload"),
            resolvingAgainstBaseURL: false
        )
        var items: [URLQueryItem] = [
            URLQueryItem(name: "filename", value: upload.filename),
            URLQueryItem(name: "role", value: "user"),
        ]
        if !upload.caption.isEmpty {
            items.append(URLQueryItem(name: "text", value: upload.caption))
        }
        if let q = upload.quotedTs {
            items.append(URLQueryItem(name: "quoted_ts", value: q))
        }
        components?.queryItems = items
        guard let url = components?.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("\(upload.data.count)", forHTTPHeaderField: "Content-Length")
        if let s = CcServerConfig.sharedSecret, !s.isEmpty { req.setValue(s, forHTTPHeaderField: "X-Auth-Token") }
        self.sending = true
        defer { self.sending = false }
        do {
            updateUpload(id: id, progress: 0, state: .uploading)
            let (respData, _) = try await UploadClient.upload(request: req, data: upload.data) { progress in
                Task { @MainActor [weak self] in
                    self?.updateUpload(id: id, progress: progress, state: .uploading)
                }
            }
            let decoded = try? JSONDecoder().decode(ChatSendResponse.self, from: respData)
            if let rec = decoded?.record {
                self.appendUnique(rec)
            }
            uploadQueue.removeAll { $0.id == id }
            self.quoting = nil
        } catch {
            updateUpload(id: id, progress: 0, state: .failed(error.localizedDescription))
            self.lastError = "上传失败: \(error.localizedDescription)"
        }
    }

    private func updateUpload(id: UUID, progress: Double, state: PendingUpload.State) {
        guard let idx = uploadQueue.firstIndex(where: { $0.id == id }) else { return }
        uploadQueue[idx].progress = progress
        uploadQueue[idx].state = state
    }

    /// 2026-05-08 attachment tab 全量预拉 — 没 keyword 时按附件类型从 GRDB 拉全部 给 file/link/audio tab 用.
    func loadAttachmentTab() async {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.isEmpty else { return }
        switch searchFilter {
        case .all:
            serverSearchResults = []
        case .file:
            let groups = chatStore.filesGrouped(limit: 1000)
            self.serverSearchResults = groups.flatMap { $0.files }.sorted(by: Self.chatMessageDescending)
        case .audio:
            let rows = await chatStore.search(keyword: " ", attachmentTypeFilter: "audio", linkOnly: false, limit: 1000)
            // 上面 keyword=" " 会触发 fallback LIKE 然后被过滤为空 — 改用直接 fetch
            if rows.isEmpty {
                let direct = chatStore.latest(limit: 5000).filter { $0.attachmentType == "audio" }
                self.serverSearchResults = direct.sorted(by: Self.chatMessageDescending)
            } else {
                self.serverSearchResults = rows.sorted(by: Self.chatMessageDescending)
            }
        case .image:
            let direct = chatStore.latest(limit: 5000).filter { $0.attachmentType == "image" }
            self.serverSearchResults = direct.sorted(by: Self.chatMessageDescending)
        case .link:
            let direct = chatStore.latest(limit: 5000).filter {
                $0.text.range(of: #"https?://[^\s]+"#, options: .regularExpression) != nil
            }
            self.serverSearchResults = direct.sorted(by: Self.chatMessageDescending)
        }
    }

    func searchServer() async {
        // 2026-05-07 Phase 2: local-first search 走 ChatStore SwiftData / 本地空 + backfill 未完成 fallback server
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            serverSearchResults = []
            return
        }
        isServerSearching = true
        defer { isServerSearching = false }

        // filter type 转 ChatStore 参数
        let typeFilter: String?
        let linkOnly: Bool
        switch searchFilter {
        case .all: typeFilter = nil; linkOnly = false
        case .image: typeFilter = "image"; linkOnly = false
        case .file: typeFilter = "file"; linkOnly = false
        case .audio: typeFilter = "audio"; linkOnly = false
        case .link: typeFilter = nil; linkOnly = true
        }

        let local = await chatStore.search(keyword: q, attachmentTypeFilter: typeFilter, linkOnly: linkOnly, limit: 500)
        if !local.isEmpty {
            self.serverSearchResults = local.sorted(by: Self.chatMessageDescending)
            return
        }
        // 本地空永远 fallback server (backfillComplete 标记不可靠 历史 hotfix 加 cap 把数据删过)
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/search")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "limit", value: "5000"),
        ]
        guard let finalURL = components?.url else { return }
        do {
            let (data, _) = try await session.data(for: CcServerConfig.authenticatedRequest(url: finalURL))
            let decoded = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
            self.serverSearchResults = decoded.records
            // 顺手缓存到本地
            await chatStore.upsertAsync(decoded.records)
        } catch {
            self.lastError = "搜索失败: \(error.localizedDescription)"
        }
    }

    /// 2026-05-07 Phase 2: 后台分页 backfill 历史进 SwiftData. 不阻塞首屏.
    /// hotfix 限 5000 条最近 (不再全量 13322 防 SwiftData 表过大卡 search)
    func backfillHistory() async {
        // 2026-05-09 用户 push 本地 < 100 条强制重跑 (用户删本地后 flag 还残留 backfill 不会自启)
        let localCount = chatStore.count()
        if localCount < 100 {
            UserDefaults.standard.set(false, forKey: "backfillComplete_v2")
        }
        if UserDefaults.standard.bool(forKey: "backfillComplete_v2") {
            return  // 已完成跳过
        }
        var totalFetched = chatStore.count()
        var oldestTs: String? = chatStore.oldestTs()
        var emptyHits = 0
        // build 194 — 进度浮窗
        self.backfillProgress = .running(synced: totalFetched)
        for _ in 0..<50 {  // 50 页 x 1000/页 = 50000 条上限 覆盖全量 13322
            guard let oldest = oldestTs else { break }
            let url = CcServerConfig.serverURL.appendingPathComponent("chat/history")
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "before", value: oldest),
                URLQueryItem(name: "limit", value: "1000"),
            ]
            guard let finalURL = components?.url else { break }
            do {
                let (data, _) = try await session.data(for: CcServerConfig.authenticatedRequest(url: finalURL))
                let resp = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
                if resp.records.isEmpty {
                    emptyHits += 1
                    if emptyHits >= 2 { break }
                    continue
                }
                emptyHits = 0
                await chatStore.upsertAsync(resp.records)
                totalFetched += resp.records.count
                oldestTs = resp.records.first?.ts  // server 返按 ts asc
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastBackfillAt")
                // build 194 — 每页更新进度
                self.backfillProgress = .running(synced: totalFetched)
            } catch {
                self.backfillProgress = .error
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if case .error = self.backfillProgress { self.backfillProgress = nil }
                }
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // backfill 完毕 GRDB+FTS5 不再 cap 全量保留
        UserDefaults.standard.set(true, forKey: "backfillComplete_v2")
        // build 194 — 完成 toast 显示 3 秒后自动消失
        self.backfillProgress = .done(synced: totalFetched)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .done = self.backfillProgress { self.backfillProgress = nil }
        }
    }

    /// 2026-05-07 Phase 3: 按日期跳到那天第一条消息
    func jumpToDate(_ day: String) async {
        let dayMsgs = chatStore.dateRange(day: day)
        if let first = dayMsgs.first {
            await jumpToMessage(first)
            return
        }
        // 本地没那天 拉 server
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/history")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "date", value: day),
            URLQueryItem(name: "limit", value: "1"),
        ]
        if let finalURL = components?.url,
           let (data, _) = try? await session.data(for: CcServerConfig.authenticatedRequest(url: finalURL)),
           let decoded = try? JSONDecoder().decode(ChatHistoryResponse.self, from: data),
           let first = decoded.records.first {
            await jumpToMessage(first)
        }
    }

    func clearSearch() {
        searchText = ""
        serverSearchResults = []
        searchFilter = .all  // 关搜索框时把筛选 reset 回全部 不停在子分类页
    }

    /// 2026-05-08 patch1: 搜索取消后回到 chat 最底, bump 让 ChatListView 触发 scrollBottom()
    @Published var returnToBottomBump: Int = 0
    func returnToBottom() {
        returnToBottomBump &+= 1
    }

    /// 2026-05-07 用户 push 跳原文 Phase 1: ChatStore.around 优先 本地 miss fallback server /chat/history?around_ts=
    @Published var jumpScrollTarget: String? = nil
    func jumpToMessage(_ targetMsg: ChatMessage) async {
        let ts = targetMsg.ts
        // 先查本地 cache
        var aroundMsgs: [ChatMessage] = chatStore.around(ts: ts, before: 25, after: 25)
        // 本地不足 拉 server
        if aroundMsgs.count < 10 {
            let url = CcServerConfig.serverURL.appendingPathComponent("chat/history")
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "around_ts", value: ts),
                URLQueryItem(name: "n", value: "50"),
            ]
            if let finalURL = components?.url {
                do {
                    let (data, _) = try await session.data(for: CcServerConfig.authenticatedRequest(url: finalURL))
                    let decoded = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
                    aroundMsgs = decoded.records
                    chatStore.upsert(decoded.records)
                } catch {
                    // ignore 用本地有什么算什么
                }
            }
        }
        // merge 到 messages 用 id 去重
        var byId: [String: ChatMessage] = [:]
        for m in messages { byId[m.id] = m }
        for m in aroundMsgs { byId[m.id] = m }
        let merged = mergeLocalCommandMessages(into: byId.values.sorted(by: Self.chatMessageAscending))
        self.messages = merged
        // 临时扩 visibleLimit 让 target 进 visible window
        // build 199 fix: 给 jump 后 visibleLimit 加 hard cap 1500
        // 防止跳到几千行老消息时 visibleLimit 长期膨胀 → 内存/diff 压力
        // 用户回底部触发 resetVisibleWindowToRecent 收回默认 300
        if let targetIdx = merged.firstIndex(where: { $0.id == targetMsg.id || $0.ts == ts }) {
            let kJumpVisibleHardCap = 1500
            let needWindow = min(merged.count - targetIdx + 50, kJumpVisibleHardCap)
            if needWindow > visibleLimit {
                visibleLimit = needWindow
            }
        }
        // 清搜索 + 设 scroll target 让 ChatListView 监听后滚到位
        clearSearch()
        jumpScrollTarget = targetMsg.id
    }

    /// 2026-05-07 用户 push: 紧急停止 chain. POST /chain/abort
    var isCcWorking: Bool {
        if sending { return true }
        if ccStatus == "working" || ccStatus == "typing" { return true }
        // toolStack 在 displayedRowsCache 里查 isRunning
        for row in displayedRowsCache {
            if case let .toolStack(stack) = row, stack.isRunning {
                return true
            }
        }
        return false
    }
    func abortChain(session sessionName: String? = nil) async {
        let resolvedSession: String
        if let sessionName, !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedSession = sessionName
        } else {
            resolvedSession = await fetchActiveSid()
        }
        print("[Cc abort] sending /chain/abort POST session=\(resolvedSession)")
        let url = CcServerConfig.serverURL.appendingPathComponent("chain/abort")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["session": resolvedSession])
        do {
            let (data, response) = try await self.session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            print("[Cc abort] response status=\(status) body=\(body)")
            if status != 200 {
                self.lastError = "中断失败: status \(status) \(body)"
            }
        } catch {
            print("[Cc abort] error: \(error)")
            self.lastError = "中断失败: \(error.localizedDescription)"
        }
    }

    func enterMultiSelect(with msg: ChatMessage? = nil) {
        guard msg?.role != "task" else { return }
        multiSelectMode = true
        quoting = nil
        if let msg {
            selectedTs.insert(msg.ts)
        }
    }

    func exitMultiSelect() {
        multiSelectMode = false
        selectedTs.removeAll()
    }

    func toggleSelection(_ msg: ChatMessage) {
        guard msg.role != "task" else { return }
        if selectedTs.contains(msg.ts) {
            selectedTs.remove(msg.ts)
        } else {
            selectedTs.insert(msg.ts)
        }
    }

    func selectAllDisplayed() {
        selectedTs = Set(selectableDisplayedMessages.map(\.ts))
    }

    var selectedMessages: [ChatMessage] {
        messages
            .filter { selectedTs.contains($0.ts) && $0.role != "task" }
            .sorted(by: Self.chatMessageAscending)
    }

    /// 2026-05-07 用户 push: 多选复制成文字 不加 sender 不加 timestamp 纯文本拼接
    var selectedShareText: String {
        selectedMessages.map { $0.text }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 分享面板用 (UIActivityViewController) 仍带 sender + timestamp 方便外发
    var selectedShareTextWithMeta: String {
        selectedMessages.map { msg in
            "[\(Self.shortTime(msg.ts))] \(Self.displayName(for: msg.role)): \(msg.text)"
        }.joined(separator: "\n")
    }

    func copySelectedToPasteboard() {
        #if canImport(UIKit)
        UIPasteboard.general.string = selectedShareText
        #endif
        exitMultiSelect()
    }

    /// 2026-05-07 用户 push: 多选保存为图片 用 ImageRenderer 把选中 ChatBubble 渲成长图写相册
    @MainActor
    func saveSelectedAsImage() async {
        let msgs = selectedMessages
        guard !msgs.isEmpty else { return }
        #if canImport(UIKit)
        let aiName = CcNameResolver.name(for: .ai)
        let view = SelectedChatRenderer(messages: msgs, aiName: aiName)
            .frame(width: 360)
            .background(Color.ccBg)
        let renderer = ImageRenderer(content: view)
        renderer.scale = UIScreen.main.scale
        if let img = renderer.uiImage {
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        }
        #endif
        exitMultiSelect()
    }

    func addSelectedToFavorites() async {
        let selected = selectedMessages
        guard !selected.isEmpty else {
            exitMultiSelect()
            return
        }
        // 多选合并成一个 favorite entry refs 是 array — 不再每条单独 POST
        await addManyToFavorites(selected)
        exitMultiSelect()
    }

    // build 129 — 整段收藏 (turn 级 仅最后 assistant turn)
    /// Phase 设置大砍 (item B) — delete all favorite items whose last ref ts equals the given turn-end ts.
    /// Server endpoint: POST /favorites/delete_by_turn body {ts: "<ts>"}. Best-effort, no UI on fail.
    func unfavoriteTurn(endingAt ts: String) async {
        let url = CcServerConfig.serverURL.appendingPathComponent("favorites/delete_by_turn")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let s = CcServerConfig.sharedSecret, !s.isEmpty {
            req.setValue(s, forHTTPHeaderField: "X-Auth-Token")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["ts": ts])
        _ = try? await session.data(for: req)
    }

    func addLastAssistantTurnToFavorites() async {
        let turn = lastAssistantTurn
        guard !turn.isEmpty else { return }
        await addManyToFavorites(turn)
    }

    func addManyToFavorites(_ msgs: [ChatMessage]) async {
        // 过滤 task role
        let candidates = msgs.filter { $0.role != "task" }
        guard !candidates.isEmpty else { return }
        let url = CcServerConfig.serverURL.appendingPathComponent("favorites/add")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        // refs array — 一条 favorite entry 多条 ref 按时间序
        let sorted = candidates.sorted(by: Self.chatMessageAscending)
        var refs: [[String: Any]] = []
        var hasImage = false
        for msg in sorted {
            var ref: [String: Any] = ["ts": msg.ts, "role": Self.displayName(for: msg.role), "text": msg.text]
            if msg.attachmentType == "image", let attUrl = msg.attachmentUrl {
                ref["attachment_url"] = attUrl
                hasImage = true
            }
            refs.append(ref)
        }
        // type 判断: 全部 image -> image / 含 text -> text (mixed default text)
        let allImage = refs.count == sorted.filter { $0.attachmentType == "image" }.count
        let type = (allImage && hasImage) ? "image" : "text"
        let payload: [String: Any] = [
            "type": type,
            "source": "chat",
            "refs": refs
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            _ = try await session.data(for: req)
        } catch {
            self.lastError = "收藏失败: \(error.localizedDescription)"
        }
    }

    func deleteSelected() async {
        // 2026-05-06 用户 catch 多选删除崩溃 fix
        // 原版每次 delete() 都 mutate messages array + 调 server 一次 + chatStore.delete 一次
        // 多次 mutation 在 for 循环里 SwiftUI List 正在 render 时被删 cell → crash
        // 修法: 先全部串行 server delete (期间不 mutate messages) 然后一次性 batch mutate UI + cache
        let selected = selectedMessages
        let idsToDelete = Set(selected.map { $0.id })
        let tsToDelete = selected.map { $0.ts }

        for ts in tsToDelete {
            await deleteOnServer(ts: ts)
        }
        // 一次性 mutate messages + cache 避免 List 中间态
        self.messages.removeAll { idsToDelete.contains($0.id) }
        self.chatStore.delete(ids: idsToDelete)

        exitMultiSelect()
    }

    /// 仅 server 删除 不 mutate messages array. 给 deleteSelected 用 (避免 batch 中 array race).
    private func deleteOnServer(ts: String) async {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let s = CcServerConfig.sharedSecret, !s.isEmpty { req.setValue(s, forHTTPHeaderField: "X-Auth-Token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["ts": ts])
        _ = try? await session.data(for: req)
    }

    private static func shortTime(_ ts: String) -> String {
        let parts = ts.split(separator: "T")
        if parts.count >= 2 {
            return String(parts[1].prefix(5))
        }
        return String(ts.prefix(5))
    }

    private static func displayName(for role: String) -> String {
        return CcNameResolver.name(forMessageRole: role)
    }

    func delete(_ msg: ChatMessage) async {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let s = CcServerConfig.sharedSecret, !s.isEmpty { req.setValue(s, forHTTPHeaderField: "X-Auth-Token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["ts": msg.ts])
        do {
            _ = try await session.data(for: req)
            self.messages.removeAll { $0.id == msg.id }
            self.chatStore.delete(ids: [msg.id])
        } catch {
            self.lastError = "删除失败: \(error.localizedDescription)"
        }
    }

    func regenerate(messageTs: String, extraReplaceIds: [String] = []) async {
        guard let assistantIdx = messages.firstIndex(where: { $0.ts == messageTs }),
              assistantIdx > 0 else { return }
        // walk back past consecutive assistant bubbles to find nearest user msg
        var userIdx = assistantIdx - 1
        while userIdx >= 0 && messages[userIdx].role != "user" {
            userIdx -= 1
        }
        guard userIdx >= 0 else { return }
        let userMsg = messages[userIdx]

        let url = CcServerConfig.serverURL.appendingPathComponent("chat/regenerate")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let s = CcServerConfig.sharedSecret, !s.isEmpty { req.setValue(s, forHTTPHeaderField: "X-Auth-Token") }
        let payload: [String: Any] = [
            "replace_msg_id": messageTs,
            "extra_replace_ids": extraReplaceIds,
            "user_text": userMsg.text,
            "client_msg_id": UUID().uuidString,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 200 {
                // Remove all turn bubbles (first + extras) from local state in one pass
                let allTsToRemove = Set([messageTs] + extraReplaceIds)
                let toRemove = messages.filter { allTsToRemove.contains($0.ts) }
                messages.removeAll { allTsToRemove.contains($0.ts) }
                chatStore.delete(ids: Set(toRemove.map { $0.id }))
            }
        } catch {
            self.lastError = "重新生成失败: \(error.localizedDescription)"
        }
    }

    func addToFavorites(_ msg: ChatMessage) async {
        guard msg.role != "task" else { return }
        let url = CcServerConfig.serverURL.appendingPathComponent("favorites/add")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        let isImage = msg.attachmentType == "image" && msg.attachmentUrl != nil
        let type = isImage ? "image" : "text"
        var ref: [String: Any] = ["ts": msg.ts, "role": Self.displayName(for: msg.role), "text": msg.text]
        if isImage, let attUrl = msg.attachmentUrl {
            ref["attachment_url"] = attUrl
        }
        let payload: [String: Any] = [
            "type": type,
            "source": "chat",
            "refs": [ref]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            _ = try await session.data(for: req)
        } catch {
            self.lastError = "收藏失败: \(error.localizedDescription)"
        }
    }

    func clearAllLocalMessages() {
        chatStore.deleteAll()
        messages.removeAll()
        displayedRowsCache.removeAll()
    }

    /// 2026-05-12 send snapshot fix — accept an optional explicit text snapshot
    /// so commit / choice paths can hand off a frozen value across the async
    /// boundary instead of racing through `vm.draft` (which the input box's
    /// onChange can blank between commit and send execution).
    func send(text rawText: String? = nil) async {
        let sourceText = rawText ?? draft
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 2026-05-14 slash routing re-enabled (build 188).
        // 之前怀疑 Phase B routing 触发了 SwiftUI List scroll race, build 183 临时撤掉.
        // build 184 通过把 List 换成 LazyVStack 彻底拔了 race 的根, 不再受 routing 影响.
        // 这里恢复 hasPrefix("/") 入口, 未知 slash 仍 fall through 到 /chat/send 当文字发.
        if text.hasPrefix("/") {
            let handled = await handleSlashCommand(text)
            if handled {
                if rawText == nil { draft = "" }
                return
            }
        }

        // 2026-05-12 optimistic-send refactor (spec ots-send-optimistic-retry):
        // 1. Build a local-id ChatMessage and append it to `messages` IMMEDIATELY
        //    so the bubble shows up — text never disappears between input box
        //    and chat list.
        // 2. Clear vm.draft + quoting at insert time (input box stays empty
        //    even if the network call later fails).
        // 3. Issue the network call with an 8s timeout. On success: drop the
        //    optimistic record (server returns the real one which appendUnique
        //    inserts). On failure: keep the optimistic record, flip its id to
        //    `.failed`, persist for restart recovery.
        let quotedTsForSend = quoting?.ts
        let optimistic = makeOptimisticUserMessage(text: text, quotedTs: quotedTsForSend, quotedText: quoting?.text)
        self.appendUnique(optimistic)
        self.sendingIds.insert(optimistic.id)
        self.localSendStartedAt[optimistic.id] = Date()
        self.draft = ""
        self.quoting = nil
        self.sending = true
        defer { self.sending = false }

        let ok = await postChatSendOptimistic(text: text, quotedTs: quotedTsForSend, replacing: optimistic.id)
        if !ok {
            self.sendingIds.remove(optimistic.id)
            self.localSendStartedAt.removeValue(forKey: optimistic.id)
            self.failedIds.insert(optimistic.id)
            self.appendToPendingFailed(optimistic)
        } else {
            self.sendingIds.remove(optimistic.id)
            self.localSendStartedAt.removeValue(forKey: optimistic.id)
            self.failedIds.remove(optimistic.id)
            self.removeFromPendingFailed(id: optimistic.id)
        }
    }

    // MARK: - Optimistic send helpers (2026-05-12)

    /// Construct a local-only `ChatMessage` for the optimistic UI insert.
    /// 2026-05-12 sort-fix: `ts` now holds the REAL ISO send time (same shape
    /// as server records) so `_sortMessages` chronologically interleaves the
    /// optimistic bubble with the existing chat. The `localId` field carries
    /// the stable `local-<uuid>` tracking key — used by sendingIds / failedIds
    /// / pendingFailedMessages and by the `appendUnique` GRDB-skip guard.
    private func makeOptimisticUserMessage(text: String, quotedTs: String?, quotedText: String?) -> ChatMessage {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = formatter.string(from: now)
        let localId = "local-\(UUID().uuidString)"
        return ChatMessage(
            ts: ts,
            role: "user",
            text: text,
            source: "ios-app",
            quotedTs: quotedTs,
            quotedText: quotedText,
            attachmentUrl: nil,
            attachmentType: nil,
            attachmentFilename: nil,
            reactions: nil,
            audioZh: nil,
            audioEn: nil,
            audioJa: nil,
            location: nil,
            metadata: nil,
            localId: localId
        )
    }

    /// POST /chat/send with an 8s budget. Returns true iff the server confirmed
    /// the record. On success: removes the optimistic local-id message and
    /// inserts the server-canonical record so future polls dedupe cleanly.
    private func postChatSendOptimistic(text: String, quotedTs: String?, replacing optimisticId: String) async -> Bool {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/send")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        req.timeoutInterval = 8
        var payload: [String: Any] = ["text": text]
        if let q = quotedTs { payload["quoted_ts"] = q }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, _) = try await session.data(for: req)
            recordNetworkSuccess()
            let decoded = try? JSONDecoder().decode(ChatSendResponse.self, from: data)
            if let rec = decoded?.record {
                // Replace optimistic with server-canonical record.
                if let idx = self.messages.firstIndex(where: { $0.id == optimisticId }) {
                    self.messages.remove(at: idx)
                }
                self.appendUnique(rec)
                reconcileLocalSendState()
                return true
            }
            // Server returned 200 but no record — treat as failure so the user
            // can retry rather than silently lose the text.
            return false
        } catch {
            self.lastError = "发送失败: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Slash command routing (2026-05-14 Phase B)
    //
    // Each known slash command intercepts the send pipeline and posts to its
    // dedicated apns-server endpoint instead of /chat/send. The response is
    // surfaced to the user as a synthetic local-only assistant bubble (localId
    // prefixed `cmd-` so `appendUnique` skips GRDB persistence — these are
    // ephemeral session output, not chat history).
    //
    // Returns true if `text` was recognized as a slash command (handled or
    // attempted). Returns false if the prefix doesn't match any known command,
    // letting the caller fall through to the normal /chat/send path.
    func handleSlashCommand(_ text: String) async -> Bool {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map { String($0) }
        guard let cmd = parts.first else { return false }
        switch cmd {
        case "/clear":
            await handleSlashClear()
            return true
        case "/help":
            appendCommandReply(slashHelpText())
            return true
        case "/list":
            await handleSlashList()
            return true
        case "/new":
            await handleSlashNew()
            return true
        case "/compact":
            await handleSlashCompact()
            return true
        case "/stop":
            // /stop 跟随 active session — fetchActiveSid 先拿当前 sid 再 abort
            // (build 199 fix: /switch 之后 /stop 不再固定 abort cc)
            await handleSlashStop()
            return true
        case "/switch":
            // 2026-05-14 build 196 — /switch <sid> 切 active tmux session
            let sid = parts.count >= 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if sid.isEmpty {
                appendCommandReply("/switch 需要 sid\n用法 /switch <sid>\n常见 sid: cc / bao / shu / opus47-fresh / xtoken / awen / cc-female")
            } else {
                await handleSlashSwitch(sid: sid)
            }
            return true
        default:
            return false
        }
    }

    private func slashHelpText() -> String {
        return """
        可用命令

        /new 新建一个 cc session
        /list 列出当前活跃 session
        /switch <sid> 切到指定 session (例 /switch bao)
        /stop 中断当前回复
        /clear 清空当前 session chain 上下文 (cc 内部 /clear)
        /help 显示这份说明
        /compact 压缩当前 chain 上下文 (cc 内部 /compact)
        """
    }

    /// Append a synthetic command-response bubble to the local message list.
    /// `localId` prefix `cmd-` keeps the row out of GRDB so it disappears on
    /// next cold start (matches the "command output is transient" semantics).
    private func appendCommandReply(_ text: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = formatter.string(from: Date())
        let localId = "cmd-\(UUID().uuidString)"
        let msg = ChatMessage(
            ts: ts,
            role: "assistant",
            text: text,
            source: "command",
            quotedTs: nil,
            quotedText: nil,
            attachmentUrl: nil,
            attachmentType: nil,
            attachmentFilename: nil,
            reactions: nil,
            audioZh: nil,
            audioEn: nil,
            audioJa: nil,
            location: nil,
            metadata: nil,
            localId: localId
        )
        appendUnique(msg)
    }

    private func slashAuthedRequest(path: String, method: String = "POST", jsonBody: [String: Any]? = nil) -> URLRequest? {
        let url = CcServerConfig.serverURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 8
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        if method != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = jsonBody ?? [:]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func handleSlashList() async {
        guard let req = slashAuthedRequest(path: "chain/sessions", method: "GET") else {
            appendCommandReply("/list 失败 server URL 没配")
            return
        }
        do {
            let (data, _) = try await session.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                appendCommandReply("/list 失败 server 返回不是 JSON")
                return
            }
            let sessions = obj["sessions"] as? [[String: Any]] ?? []
            if sessions.isEmpty {
                appendCommandReply("/list 当前没有活跃 session")
                return
            }
            var lines: [String] = ["当前 session 列表"]
            for s in sessions {
                let sid = s["sid"] as? String ?? "?"
                let active = (s["active"] as? Bool) ?? false
                let marker = active ? "● " : "  "
                lines.append("\(marker)\(sid)")
            }
            appendCommandReply(lines.joined(separator: "\n"))
        } catch {
            appendCommandReply("/list 失败 \(error.localizedDescription)")
        }
    }

    private func handleSlashNew() async {
        guard let req = slashAuthedRequest(path: "chain/new_session", jsonBody: [:]) else {
            appendCommandReply("/new 失败 server URL 没配")
            return
        }
        var mutableReq = req
        mutableReq.timeoutInterval = 15  // tmux new-session 加 claude 启动慢
        do {
            let (data, _) = try await session.data(for: mutableReq)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                appendCommandReply("/new 失败 server 返回不是 JSON")
                return
            }
            if let sid = obj["sid"] as? String {
                let note = obj["note"] as? String ?? "cc 启动中"
                appendCommandReply("/new 已新建 session\nsid \(sid)\n\(note)")
            } else if let err = obj["error"] as? String {
                appendCommandReply("/new 失败 \(err)")
            } else {
                appendCommandReply("/new 完成 但 server 没返 sid")
            }
        } catch {
            appendCommandReply("/new 失败 \(error.localizedDescription)")
        }
    }

    private func handleSlashCompact() async {
        // build 199 fix: /compact 跟随 active session (此前 server 端默认压 cc)
        let activeSid = await fetchActiveSid()
        guard let req = slashAuthedRequest(path: "tmux/send", jsonBody: ["keys": "/compact", "enter": true, "session": activeSid]) else {
            appendCommandReply("/compact 失败 server URL 没配")
            return
        }
        do {
            _ = try await session.data(for: req)
            appendCommandReply("/compact 已发送 \(activeSid) 开始压缩上下文")
        } catch {
            appendCommandReply("/compact 失败 \(error.localizedDescription)")
        }
    }

    private func handleSlashClear() async {
        let activeSid = await fetchActiveSid()
        guard let req = slashAuthedRequest(path: "chain/clear", jsonBody: ["session": activeSid]) else {
            appendCommandReply("/clear 失败 server URL 没配")
            return
        }
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 200 {
                appendCommandReply("已清空 \(activeSid) chain 上下文")
                return
            }
            let message = serverErrorMessage(from: data) ?? "HTTP \(status)"
            appendCommandReply("/clear 失败 \(message)")
        } catch {
            appendCommandReply("/clear 失败 \(error.localizedDescription)")
        }
    }

    private func handleSlashStop() async {
        let activeSid = await fetchActiveSid()
        await abortChain(session: activeSid)
        appendCommandReply("/stop 已发送 中断 \(activeSid) 当前回复")
    }

    private func fetchActiveSid() async -> String {
        guard let req = slashAuthedRequest(path: "chain/sessions", method: "GET") else {
            return await CcServerConfig.fetchDefaultSession(using: session)
        }
        do {
            let (data, _) = try await session.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sessions = obj["sessions"] as? [[String: Any]] {
                for s in sessions {
                    if (s["active"] as? Bool) ?? false, let sid = s["sid"] as? String {
                        return sid
                    }
                }
            }
        } catch {
            // 拿不到 active sid 兜底 server default.
        }
        return await CcServerConfig.fetchDefaultSession(using: session)
    }

    private func serverErrorMessage(from data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? String, !err.isEmpty {
            return err
        }
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return body?.isEmpty == false ? body : nil
    }

    // 2026-05-14 build 196 — /switch <sid> 切 active tmux session
    private func handleSlashSwitch(sid: String) async {
        guard let req = slashAuthedRequest(path: "chain/switch", jsonBody: ["sid": sid]) else {
            appendCommandReply("/switch 失败 server URL 没配")
            return
        }
        do {
            let (data, _) = try await session.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                appendCommandReply("/switch 失败 server 返回不是 JSON")
                return
            }
            if let ok = obj["ok"] as? Bool, ok {
                appendCommandReply("/switch 已切到 \(sid)\n你新发的消息会路由到这个 session")
            } else if let err = obj["error"] as? String {
                appendCommandReply("/switch 失败 \(err)")
            } else {
                appendCommandReply("/switch 未确认 server 没返 ok")
            }
        } catch {
            appendCommandReply("/switch 失败 \(error.localizedDescription)")
        }
    }

    /// Tap-to-retry on a failed bubble. Re-issues the same payload; on success
    /// the failed local-id record is replaced by the server's canonical one.
    func retryFailedSend(id: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              messages[idx].isUser else { return }
        let msg = messages[idx]
        self.failedIds.remove(id)
        self.sendingIds.insert(id)
        self.localSendStartedAt[id] = Date()
        Task { @MainActor in
            self.sending = true
            defer { self.sending = false }
            let ok = await postChatSendOptimistic(text: msg.text, quotedTs: msg.quotedTs, replacing: id)
            if ok {
                self.sendingIds.remove(id)
                self.localSendStartedAt.removeValue(forKey: id)
                self.failedIds.remove(id)
                self.removeFromPendingFailed(id: id)
            } else {
                self.sendingIds.remove(id)
                self.localSendStartedAt.removeValue(forKey: id)
                self.failedIds.insert(id)
                self.appendToPendingFailed(msg)
            }
        }
    }

    /// Drop a failed optimistic bubble (long-press → 删除 from the retry menu).
    func discardFailedSend(id: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages.remove(at: idx)
        }
        sendingIds.remove(id)
        localSendStartedAt.removeValue(forKey: id)
        failedIds.remove(id)
        removeFromPendingFailed(id: id)
    }

    func sendStatus(forId id: String) -> SendStatus {
        if failedIds.contains(id) { return .failed }
        if sendingIds.contains(id) { return .sending }
        return .sent
    }

    func reconcileLocalSendState() {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for id in failedIds {
            if sendingIds.contains(id) { sendingIds.remove(id) }
        }

        for id in Array(sendingIds) {
            if let started = localSendStartedAt[id], now.timeIntervalSince(started) > 30 {
                sendingIds.remove(id)
                localSendStartedAt.removeValue(forKey: id)
                failedIds.insert(id)
                if let msg = messages.first(where: { $0.id == id }) {
                    appendToPendingFailed(msg)
                }
            }
        }

        let locals = messages.filter { $0.localId?.hasPrefix("local-") == true }
        for local in locals {
            guard let localDate = formatter.date(from: local.ts) else { continue }
            let matchedCanonical = messages.contains { candidate in
                guard candidate.localId == nil,
                      candidate.role == local.role,
                      candidate.text == local.text,
                      candidate.quotedTs == local.quotedTs,
                      let candidateDate = formatter.date(from: candidate.ts) else {
                    return false
                }
                return abs(candidateDate.timeIntervalSince(localDate)) <= 120
            }
            if matchedCanonical {
                messages.removeAll { $0.id == local.id }
                sendingIds.remove(local.id)
                failedIds.remove(local.id)
                localSendStartedAt.removeValue(forKey: local.id)
                removeFromPendingFailed(id: local.id)
            }
        }
    }

    // MARK: - Pending-failed persistence (UserDefaults)

    /// Load any optimistic records that were `.failed` at last app exit and
    /// re-hydrate them into `messages` so用户 can still tap retry. Also
    /// downgrades any leftover `.sending` records to `.failed` (we never trust
    /// "still sending" across process death).
    func restorePendingFailedMessages() {
        guard let data = UserDefaults.standard.data(forKey: Self.kPendingFailedKey),
              let list = try? JSONDecoder().decode([ChatMessage].self, from: data),
              !list.isEmpty else { return }
        self.pendingFailedMessages = list
        for m in list {
            if !messages.contains(where: { $0.id == m.id }) {
                messages.append(m)
            }
            failedIds.insert(m.id)
        }
    }

    private func appendToPendingFailed(_ msg: ChatMessage) {
        if !pendingFailedMessages.contains(where: { $0.id == msg.id }) {
            pendingFailedMessages.append(msg)
        }
        persistPendingFailed()
    }

    private func removeFromPendingFailed(id: String) {
        pendingFailedMessages.removeAll(where: { $0.id == id })
        persistPendingFailed()
    }

    private func persistPendingFailed() {
        if let data = try? JSONEncoder().encode(pendingFailedMessages) {
            UserDefaults.standard.set(data, forKey: Self.kPendingFailedKey)
        }
    }

    func clearUnread() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("push/clear-unread")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let s = CcServerConfig.sharedSecret, !s.isEmpty { req.setValue(s, forHTTPHeaderField: "X-Auth-Token") }
        req.httpBody = "{}".data(using: .utf8)
        _ = try? await session.data(for: req)
    }

    func addTodo(_ text: String) async {
        // 不直接 POST /todos/add 改为让 Cc chain 接管 (2026-05-03 用户 push)
        // 流程：把消息原文塞 draft + 提示语 → chain 收到后组织语言 + 分类 + 调 todos.add 工具
        // chain 知道 路径 / heading / actor 该选哪个 比客户端硬编码 inbox 准
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.draft = "把这条加到待办里 你帮我组织一下语言 + 分类到对应位置：\n\n\(trimmed)"
        await send()
    }

    nonisolated struct ChatHistoryResponse: Codable, Sendable {
        let ok: Bool
        let records: [ChatMessage]
    }

    nonisolated struct ChatSendResponse: Codable, Sendable {
        let ok: Bool
        let record: ChatMessage?
    }
}

struct ChatView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = ChatViewModel()
    @StateObject private var speech = SpeechRecognizer()
    @FocusState private var inputFocused: Bool
    @AppStorage("ai_avatar_emoji") private var aiAvatarEmoji: String = "🦀"
    @AppStorage("ai_name") private var aiName: String = CcDefaultAIName
    @AppStorage("ai_avatar_path") private var aiAvatarPath: String = ""
    @AppStorage("chat_font_size_level") private var chatFontLevel: String = "medium"
    // Phase E (item 7) — 聊天背景 disk path
    @AppStorage("chat_background_path") private var chatBackgroundPath: String = ""
    private var chatBodySize: CGFloat { chatFontLevel == "small" ? 15 : chatFontLevel == "large" ? 18 : 17 }
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter: Bool = false
    @State private var showImagePicker: Bool = false
    @State private var showCameraPicker: Bool = false
    @State private var editingImageData: Data? = nil
    // 2026-05-06 用户 push P1: 长按 ImagePreviewStrip 缩略图编辑 (preview-mode) 编辑完更新 preview 不直接发
    @State private var editingPreviewID: UUID? = nil
    @State private var showSearch: Bool = false
    @State private var searchDebounceTask: Task<Void, Never>? = nil
    @State private var hasScrolledInitially: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var shareText: String = ""
    @State private var showDeleteSelectedConfirm: Bool = false
    // 2026-05-12 用户 catch: chat clear 按钮在 multi-server / Bridge / Diary 几轮改动里
    // 不小心从 toolbar trailing menu 砍掉了. 加回去 — confirm dialog + 调 clearAllLocalMessages().
    @State private var showClearChatConfirm: Bool = false
    @State private var selectedImagePreviews: [ImagePreview] = []
    @State private var showTodoInput: Bool = false
    // Bug 2 fix: unique ID per image selection forces PhotoEditView to reinitialise
    @State private var currentImageGenerationID = UUID()
    // 2026-05-07 用户 push 图片点击全屏 zoom 预览
    @State private var previewingImageURL: ImagePreviewURL? = nil
    // 2026-05-08 search 日期入口 — DatePicker sheet
    @State private var showDatePicker: Bool = false
    @State private var datePickerSelection: Date = Date()

    var onShowFavorites: (() -> Void)? = nil
    var scrollToken: Int = 0

    private func statusColor(for status: ChatConnectionStatus) -> Color {
        switch status {
        case .connected: return Color(red: 0.30, green: 0.78, blue: 0.45)
        case .thinking: return Color(red: 0.95, green: 0.75, blue: 0.20)
        case .offline: return Color(red: 0.55, green: 0.55, blue: 0.65)
        }
    }

    private func statusLabel(for status: ChatConnectionStatus) -> String {
        switch status {
        case .connected: return "在线"
        case .thinking: return "思考中"
        case .offline: return "离线"
        }
    }

    private func handleMessageCountChange(oldCount: Int, count: Int, proxy: ScrollViewProxy) {
        guard count > 0, let last = vm.displayedMessages.last else { return }
        // 2026-05-08 用户 push: 切 tab 时 view 重建 onChange of count 会以 0 → N 跳一次 false-positive 触发 sound/haptic
        // 只在 single new append (count == oldCount + 1) 时触发 sound/haptic 跳过 batch jump
        let isSingleAppend = count == oldCount + 1
        if hasScrolledInitially && isSingleAppend && last.role != "user" {
            if last.role == "task" {
                #if os(iOS)
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.prepare()
                gen.impactOccurred(intensity: 0.35)
                #endif
                if vm.taskSoundEnabled {
                    AudioServicesPlaySystemSound(1075)
                }
            } else {
                #if os(iOS)
                let gen = UIImpactFeedbackGenerator(style: .soft)
                gen.prepare()
                gen.impactOccurred(intensity: 0.6)
                #endif
                if vm.chatSoundEnabled {
                    AudioServicesPlaySystemSound(1003)
                }
            }
        }
        let wasInitialMount = !hasScrolledInitially
        let firstDelay = wasInitialMount ? 0.05 : 0.05
        let secondDelay = wasInitialMount ? 0.4 : 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay) {
            if wasInitialMount {
                proxy.scrollTo(last.id, anchor: .bottom)
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            hasScrolledInitially = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + secondDelay) {
            if wasInitialMount {
                proxy.scrollTo(last.id, anchor: .bottom)
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func handleInputFocusChange(focused: Bool, proxy: ScrollViewProxy) {
        if focused, let last = vm.displayedMessages.last {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func handleSpeechTranscriptChange(_ newValue: String) {
        if speech.isRecording {
            vm.draft = newValue
        }
    }

    private func toggleAllDisplayedSelection() {
        if vm.selectedTs.count == vm.selectableDisplayedMessages.count {
            vm.selectedTs.removeAll()
        } else {
            vm.selectAllDisplayed()
        }
    }

    @ViewBuilder
    private func chatRowView(_ row: ChatRowItem) -> some View {
        switch row {
        case .separator(let label, _):
            ChatSeparatorRow(label: label)
        case .toolStack(let stack):
            ToolActivityStackView(stack: stack)
                .id("stack_\(stack.id)")
        case .message(let msg, let showTime):
            ChatMessageListRow(
                message: msg,
                showTime: showTime,
                multiSelectMode: vm.multiSelectMode,
                selected: vm.selectedTs.contains(msg.ts),
                onToggleSelection: { vm.toggleSelection(msg) },
                onEnterMultiSelect: { vm.enterMultiSelect(with: msg) },
                onReact: { emoji in Task { await vm.react(msg, emoji: emoji) } },
                onQuote: { vm.quoting = msg },
                onCopyText: vm.assistantTurnEndsTs.contains(msg.ts)
                    ? { UIPasteboard.general.string = vm.turnTexts(endingAt: msg.ts).joined(separator: "\n\n"); CcToastBus.shared.show("已复制") }
                    : nil,
                onFavorite: { Task { await vm.addToFavorites(msg) } },
                onAddTodo: { Task { await vm.addTodo(msg.text) } },
                onDelete: { Task { await vm.delete(msg) } },
                onRegenerate: msg.ts == vm.lastAssistantTurnLastTs
                    ? { Task { await vm.regenerate(messageTs: vm.lastAssistantTurnFirstTs ?? msg.ts, extraReplaceIds: vm.lastAssistantTurnExtraTs) } }
                    : nil,
                onFavoriteTurn: vm.assistantTurnEndsTs.contains(msg.ts)
                    ? {
                        if FavoritedTurnsCache.shared.contains(msg.ts) {
                            // Already favorited → toggle off
                            FavoritedTurnsCache.shared.remove(msg.ts)
                            Task { await vm.unfavoriteTurn(endingAt: msg.ts); CcToastBus.shared.show("已取消收藏") }
                        } else {
                            FavoritedTurnsCache.shared.insert(msg.ts)
                            Task { await vm.addManyToFavorites(vm.turnMessages(endingAt: msg.ts)); CcToastBus.shared.show("已收藏") }
                        }
                    }
                    : nil,
                onChoiceSelect: { value in Task { await vm.send(text: value) } },
                onPreviewActiveChanged: nil,
                onEnterRP: nil,
                onImageTap: { url in previewingImageURL = ImagePreviewURL(url: url) }
            )
            .id(msg.id)
            .padding(.vertical, 4)
            .padding(.trailing, 12)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 2026-05-07 完整自画 header bar — iOS 26 toolbar 系统 wrap glass capsule 头像被截
            // 顺手把右侧搜索/⊕也一起搬过来 头像跟搜索同一水平线 (用户 catch "和右边的搜索那些平行")
            HStack(spacing: 12) {
                ChatToolbarLeading(
                    multiSelectMode: vm.multiSelectMode,
                    status: statusLabel(for: vm.connectionStatus),
                    statusColor: statusColor(for: vm.connectionStatus),
                    isBreathing: vm.connectionStatus != .offline,
                    aiName: aiName,
                    aiAvatarEmoji: aiAvatarEmoji,
                    aiAvatarPath: aiAvatarPath,
                    onCancel: { vm.exitMultiSelect() }
                )
                Spacer()
                if vm.multiSelectMode {
                    Text("已选 \(vm.selectedTs.count) 条")
                        .font(.ccSerifAdaptive(size: chatBodySize))
                        .foregroundStyle(Color.ccText)
                }
                ChatToolbarTrailing(
                    multiSelectMode: vm.multiSelectMode,
                    selectedCount: vm.selectedTs.count,
                    displayedCount: vm.selectableDisplayedMessages.count,
                    showSearch: showSearch,
                    onToggleAll: toggleAllDisplayedSelection,
                    onToggleSearch: { showSearch.toggle() },
                    onEnterRP: {
                    },
                    onShowFavorites: onShowFavorites,
                    onClearChat: { showClearChatConfirm = true }
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.ccBg)

            // 搜索 search bar + filter tab — 仅 search 模式可见 自定义实现 (replace .searchable iOS 17+ bug)
            if showSearch {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.ccTextDim)
                        TextField("搜对话 / 文件名", text: $vm.searchText)
                            .textFieldStyle(.plain)
                            .submitLabel(.search)
                        if !vm.searchText.isEmpty {
                            Button {
                                vm.searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.ccTextDim)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.ccCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button("取消") {
                        showSearch = false
                        vm.clearSearch()
                        // 2026-05-08 patch1: 取消后回 chat 最底
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            vm.returnToBottom()
                        }
                    }
                    .foregroundStyle(Color.ccAccent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                SearchFilterBar(
                    selected: vm.searchFilter,
                    onSelect: { filter in vm.searchFilter = filter },
                    onDate: { showDatePicker = true }
                )
            }
            // 2026-05-14 build 194 — 同步历史进度浮条 (running / done 状态短暂显示)
            if let progress = vm.backfillProgress {
                BackfillProgressBar(state: progress)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ChatListView(
                vm: vm,
                inputFocused: inputFocused,
                hasScrolledInitially: $hasScrolledInitially,
                scrollToken: scrollToken,
                onEnterRP: nil,
                onImageTap: { url in previewingImageURL = ImagePreviewURL(url: url) }
            )

            Divider()

            if !vm.uploadQueue.isEmpty {
                UploadQueueBar(queue: vm.uploadQueue) { item in
                    Task { await vm.retryUpload(item) }
                }
            }

            if vm.multiSelectMode {
                MultiSelectActionBar(
                    selectedCount: vm.selectedTs.count,
                    onCopy: { vm.copySelectedToPasteboard() },
                    onSaveImage: { Task { await vm.saveSelectedAsImage() } },
                    onShare: {
                        shareText = vm.selectedShareTextWithMeta
                        showShareSheet = true
                        vm.exitMultiSelect()
                    },
                    onFavorite: { Task { await vm.addSelectedToFavorites() } },
                    onDelete: { showDeleteSelectedConfirm = true },
                    onCancel: { vm.exitMultiSelect() }
                )
                .padding(10)
                .background(Color.ccBg)
            } else {
                if let q = vm.quoting {
                    QuotePreviewBar(message: q) {
                        vm.quoting = nil
                    }
                }

                if !selectedImagePreviews.isEmpty {
                    ImagePreviewStrip(previews: $selectedImagePreviews, onEdit: { preview in
                        // 长按编辑 → 弹 PhotoEditView (preview mode 编辑完更新 preview 不直接发)
                        editingPreviewID = preview.id
                        editingImageData = Data(preview.data)
                    })
                }
                if vm.isCcTyping {
                    TypingStatusBar()
                }
                ChatInputBar(
                    vm: vm,
                    speech: speech,
                    inputFocused: $inputFocused,
                    imagePreviews: $selectedImagePreviews,
                    onImage: { showImagePicker = true },
                    onFile: { showFileImporter = true },
                    onCamera: { showCameraPicker = true },
                    onTodo: { showTodoInput = true },
                    onLocation: {}
                )
            }
        }
        // Phase E (item 7) + Phase F (item 2) — 聊天背景 优先 disk image, fallback theme bg.
        // .id(chatBackgroundPath) 强制 path 变时整 ZStack 重建, 绕开 UIImage(contentsOfFile:) 可能的 cache.
        .background(
            ZStack {
                Color.ccBg
                #if canImport(UIKit)
                if !chatBackgroundPath.isEmpty,
                   let img = UIImage(contentsOfFile: chatBackgroundPath) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                #endif
            }
            .id(chatBackgroundPath)
        )
        // speech transcript 处理移到 ChatInputBar 内 (写 draftLocal 而不是 vm.draft) — 旧 onChange 删
        .photosPicker(
            isPresented: $showImagePicker,
            selection: $photoItems,
            maxSelectionCount: 9,
            matching: .images
        )
        .onChange(of: photoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let items = newItems
            photoItems = []
            Task {
                // 单选/多选统一进缩略图预览条，用户可写 caption 后一起发
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run { selectedImagePreviews.append(ImagePreview(data: data)) }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                // 2026-05-06 用户拍: 上传附件不带 draft 当 caption 防 voice transcript 静默 append 残留误发
                let quotedShared = vm.quoting?.ts
                Task {
                    for (idx, url) in urls.enumerated() {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        guard let data = try? Data(contentsOf: url) else { continue }
                        let filename = url.lastPathComponent
                        let cap = ""
                        let q = idx == 0 ? quotedShared : nil
                        await vm.upload(
                            data: data,
                            filename: filename,
                            caption: cap,
                            quotedTs: q
                        )
                    }
                }
            case .failure(let err):
                vm.lastError = "选择文件失败: \(err.localizedDescription)"
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityShareView(activityItems: [shareText])
        }
        .sheet(isPresented: $showTodoInput) {
            TodoInputSheet { text in
                Task { await vm.addTodo(text) }
            }
        }
        .sheet(isPresented: $showDatePicker) {
            DateJumpSheet(selection: $datePickerSelection) { picked in
                showDatePicker = false
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.timeZone = TimeZone(identifier: "UTC")
                let day = f.string(from: picked)
                Task { await vm.jumpToDate(day) }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPicker { data in
                editingImageData = Data(data); currentImageGenerationID = UUID()
            }
            .ignoresSafeArea()
        }
        #endif
        #if os(iOS)
        .fullScreenCover(item: $previewingImageURL) { item in
            ImagePreviewView(url: item.url) { previewingImageURL = nil }
        }
        .fullScreenCover(isPresented: Binding(
            get: { editingImageData != nil },
            set: { if !$0 { editingImageData = nil } }
        )) {
            if let d = editingImageData {
                PhotoEditView(imageData: d) { editedData in
                    // 2026-05-06 preview-mode: 如果 editingPreviewID 不为 nil 替换 preview 不发 upload
                    if let pid = editingPreviewID {
                        if let idx = selectedImagePreviews.firstIndex(where: { $0.id == pid }) {
                            selectedImagePreviews[idx] = ImagePreview(data: editedData)
                        }
                        editingPreviewID = nil
                        editingImageData = nil
                        return
                    }
                    // 2026-05-06 用户拍: 上传附件不带 draft 当 caption
                    let quotedShared = vm.quoting?.ts
                    Task {
                        // Bug 2 fix: generation ID suffix guarantees unique filename per send
                        let genSuffix = currentImageGenerationID.uuidString.prefix(8)
                        let filename = "edited_\(Int(Date().timeIntervalSince1970))_\(genSuffix).jpg"
                        await vm.upload(
                            data: editedData,
                            filename: filename,
                            caption: "",
                            quotedTs: quotedShared
                        )
                    }
                    editingImageData = nil
                }
            }
        }
        #endif
        .alert("删除已选消息？", isPresented: $showDeleteSelectedConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await vm.deleteSelected() }
            }
        }
        .alert("清空本地聊天？", isPresented: $showClearChatConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                vm.clearAllLocalMessages()
            }
        } message: {
            Text("只清本地 GRDB 缓存。服务端 chat_history.jsonl 不动，下次拉历史还会带回来。跟 /clear chain 上下文清空不同。")
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // 2026-05-07 隐藏系统 navigation bar 全自画 header (头像 + 搜索 同一水平线)
        .toolbar(.hidden, for: .navigationBar)
        // SwiftUI .searchable iOS 17+ 已知 bug: isPresented=false 程序 toggle 不真 dismiss
        // 改用 custom SearchBar conditional render 见 ChatListView body 顶部
        // 2026-05-03 用户 catch
        .onChange(of: vm.searchText) { _, newValue in
            if newValue.isEmpty {
                vm.serverSearchResults = []
                searchDebounceTask?.cancel()
                return
            }
            // debounce 500ms 自动 trigger server search 全量历史 (不需要用户点 prompt) 2026-05-03 用户 catch
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                await vm.searchServer()
            }
        }
        .onChange(of: showSearch) { _, isShown in
            if !isShown { vm.clearSearch() }
        }
        .onChange(of: vm.searchFilter) { _, _ in
            // filter 切到 file/link/audio/image 且没 keyword 时 从 DB 拉全部 (file 走 filesGrouped)
            if vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { await vm.loadAttachmentTab() }
            }
        }
        .onAppear { vm.start(); vm.reconcileLocalSendState(); Task { await vm.clearUnread() }; vm.restorePendingFailedMessages() }
        .onDisappear { vm.stop() }
        .onChange(of: scenePhase) { _, phase in
            vm.setPollingActive(phase == .active)
            if phase == .active {
                vm.reconcileLocalSendState()
                Task { await vm.clearUnread() }
            }
        }
    }

    // 2026-05-07 chatToolbar @ToolbarContentBuilder 整段删 (内容已搬到 body 顶部自画 header)
}

private struct MultiSelectActionBar: View {
    let selectedCount: Int
    let onCopy: () -> Void
    let onSaveImage: () -> Void
    let onShare: () -> Void
    let onFavorite: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    private var disabled: Bool { selectedCount == 0 }

    var body: some View {
        HStack(spacing: 4) {
            actionButton("复制", systemImage: "doc.on.doc", disabled: disabled, action: onCopy)
            actionButton("保存为图片", systemImage: "square.and.arrow.down", disabled: disabled, action: onSaveImage)
            actionButton("分享", systemImage: "square.and.arrow.up", disabled: disabled, action: onShare)
            actionButton("收藏", systemImage: "bookmark", disabled: disabled, action: onFavorite)
            actionButton("删除", systemImage: "trash", disabled: disabled, role: .destructive, action: onDelete)
            actionButton("取消", systemImage: "xmark.circle", disabled: false, action: onCancel)
        }
        .frame(maxWidth: .infinity)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        disabled: Bool,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                Text(title)
                    .font(.ccSerifAdaptive(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(disabled ? Color.ccTextDim.opacity(0.45) : Color.ccText)
        }
        .disabled(disabled)
        .buttonStyle(.plain)
    }
}

// 2026-05-14 build 194 — 同步历史进度浮条
private struct BackfillProgressBar: View {
    let state: ChatViewModel.BackfillState

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .running(let synced):
                ProgressView().controlSize(.small)
                Text("同步历史中... 已拉 \(synced) 条")
                    .font(.ccSerifAdaptive(size: 12))
                    .foregroundStyle(Color.ccText)
            case .done(let synced):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("同步完成 共 \(synced) 条")
                    .font(.ccSerifAdaptive(size: 12))
                    .foregroundStyle(Color.ccText)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("同步失败 网络断了或者 server 没回 重试")
                    .font(.ccSerifAdaptive(size: 12))
                    .foregroundStyle(Color.ccText)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.ccCard.opacity(0.95))
    }
}

private struct UploadQueueBar: View {
    let queue: [PendingUpload]
    let onRetry: (PendingUpload) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(queue) { item in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: item))
                        .foregroundStyle(color(for: item))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayName)
                            .font(.ccSerifAdaptive(size: 12, weight: .medium))
                            .lineLimit(1)
                        ProgressView(value: item.progress)
                            .tint(color(for: item))
                    }
                    Text(label(for: item))
                        .font(.ccSerifAdaptive(size: 11))
                        .foregroundStyle(Color.ccTextDim)
                    if case .failed = item.state {
                        Button {
                            onRetry(item)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.ccCard)
    }

    private func icon(for item: PendingUpload) -> String {
        if case .failed = item.state { return "exclamationmark.circle.fill" }
        return "icloud.and.arrow.up.fill"
    }

    private func color(for item: PendingUpload) -> Color {
        if case .failed = item.state { return .red }
        return Color.ccAccent
    }

    private func label(for item: PendingUpload) -> String {
        switch item.state {
        case .queued: return "等待"
        case .uploading: return "\(Int(item.progress * 100))%"
        case .failed: return "失败"
        }
    }
}

#if canImport(UIKit)
private struct ActivityShareView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
private struct ActivityShareView: View {
    let activityItems: [Any]

    var body: some View {
        Text("分享不可用")
    }
}
#endif

private struct ChatInputBar: View {
    // 2026-05-07 用户拍 placeholder 9 个英文备选每次 view 出现随机选一个 (onAppear 锁定 不每帧 re-evaluate 防字一直动)
    private static let placeholders = ["Waiting…", "I'm here", "Listening", "Tell me", "Say something", "Anything on your mind", "What's up", "Type to chat", "Yes?"]
    @State private var storedPlaceholder: String = ChatInputBar.placeholders.randomElement() ?? "Waiting…"

    @ObservedObject var vm: ChatViewModel
    @ObservedObject var speech: SpeechRecognizer
    let inputFocused: FocusState<Bool>.Binding
    @Binding var imagePreviews: [ImagePreview]
    let onImage: () -> Void
    let onFile: () -> Void
    let onCamera: () -> Void
    let onTodo: () -> Void
    let onLocation: () -> Void

    @State private var draftLocal: String = ""
    // 2026-05-07 用户 catch chain working 起一瞬间 stop button 闪一下 加 0.5s 延迟显示防闪
    @State private var delayedIsWorking: Bool = false
    @State private var commitPending: Bool = false
    // 2026-05-11 Phase A — slash command popover
    @State private var slashHighlightIndex: Int = 0

    private var hasContent: Bool { !draftLocal.isEmpty || !vm.draft.isEmpty || !imagePreviews.isEmpty }

    /// Phase A — derived from draftLocal. Empty list = popover not shown.
    private var slashCandidates: [SlashCommand] {
        SlashCommand.filtered(for: draftLocal)
    }
    private var slashPopoverVisible: Bool { !slashCandidates.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // Phase A — slash command popover (above input bar)
            if slashPopoverVisible {
                SlashCommandPopover(
                    commands: slashCandidates,
                    highlightIndex: $slashHighlightIndex,
                    onSelect: { cmd in selectSlashCommand(cmd) }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            inputBarHStack
        }
        .animation(.easeOut(duration: 0.12), value: slashPopoverVisible)
    }

    private var inputBarHStack: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    syncToVM()
                    onCamera()
                } label: { Label("拍照", systemImage: "camera") }
                Button {
                    syncToVM()
                    onFile()
                } label: { Label("文件", systemImage: "doc") }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.ccSerifAdaptive(size: 28, weight: .bold))
                    .foregroundStyle(Color.ccTextDim)
            }
            .disabled(vm.sending)

            // build 93: 图片单独按钮 摘出加号菜单
            Button {
                syncToVM()
                onImage()
            } label: {
                Image(systemName: "photo.fill")
                    .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                    .foregroundStyle(Color.ccTextDim)
            }
            .disabled(vm.sending)

            // build 93: 麦克风搬进 TextField 内右侧 inset 跟微信一致
            ZStack(alignment: .trailing) {
                // Phase 设置大砍 (item D) — 输入框单行起 自动扩高到 5 行 微信式 + Enter commit
                TextField(storedPlaceholder, text: $draftLocal, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 17))
                    .tint(Color.ccAccent)
                    .padding(.leading, 6)
                    .textFieldStyle(.roundedBorder)
                    .focused(inputFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        // Phase A — if slash popover visible, swallow submit to select highlighted instead
                        if slashPopoverVisible, slashCandidates.indices.contains(slashHighlightIndex) {
                            selectSlashCommand(slashCandidates[slashHighlightIndex])
                            return
                        }
                        commitFromSubmit()
                    }
                    .onChange(of: draftLocal) { oldValue, newValue in
                        // 2026-05-10 用户 push 实时同步 vm.draft 切 tab 不丢草稿 (view destroy + onAppear init from vm.draft)
                        vm.draft = newValue
                        // Phase A — if slash popover visible and user pressed enter (\n), swallow to select instead of commit
                        if newValue.hasSuffix("\n") && !oldValue.hasSuffix("\n") {
                            if slashPopoverVisible, slashCandidates.indices.contains(slashHighlightIndex) {
                                draftLocal = String(newValue.dropLast())
                                selectSlashCommand(slashCandidates[slashHighlightIndex])
                                return
                            }
                            draftLocal = String(newValue.dropLast())
                            commitFromSubmit()
                        }
                        // Reset highlight to 0 whenever filter changes
                        if SlashCommand.filtered(for: oldValue).count != SlashCommand.filtered(for: newValue).count {
                            slashHighlightIndex = 0
                        }
                    }
                    // 2026-05-07 给 mic / stop button 留 trailing 位 不让 button overlay 盖正文
                    .padding(.trailing, 40)

                if delayedIsWorking {
                    // 2026-05-07 用户 push: chain working 时 mic 位变 ⏹ stop 红圆 点击调 abortChain
                    // delayedIsWorking 加 0.5s 延迟防发送瞬间闪
                    Button {
                        Task { await vm.abortChain() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.ccSerifAdaptive(size: 18))
                            // 2026-05-07 用户拍砖红 #DD5050 + 0.85 不那么刺眼跟暖橙系协调
                            .foregroundStyle(Color(red: 0.866, green: 0.314, blue: 0.314).opacity(0.85))
                            .padding(.trailing, 10)
                    }
                } else if !inputFocused.wrappedValue {
                    Button {
                        Task { await speech.toggle() }
                    } label: {
                        Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                            .font(.ccSerifAdaptive(size: 17))
                            .foregroundStyle(speech.isRecording ? Color.red : Color.ccTextDim)
                            .padding(.trailing, 10)
                    }
                    .onChange(of: speech.transcript) { _, newValue in
                        if !newValue.isEmpty {
                            draftLocal = (draftLocal.isEmpty ? "" : draftLocal + " ") + newValue
                        }
                    }
                    .alert("语音识别问题", isPresented: Binding(
                        get: { speech.lastError != nil },
                        set: { if !$0 { speech.lastError = nil } }
                    )) {
                        Button("好") {}
                    } message: {
                        Text(speech.lastError ?? "")
                    }
                }
            }

            Button { commitFromSendButton() } label: {
                Image(systemName: (vm.sending || commitPending) ? "ellipsis.circle" : "paperplane.fill")
                    .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                    .scaleEffect(x: (vm.sending || commitPending) ? 1 : -1, y: 1)
                    .rotationEffect(.degrees((vm.sending || commitPending) ? 0 : -15))
                    .foregroundStyle(Color.ccAccent.opacity(hasContent ? 1.0 : 0.35))
            }
            .disabled(vm.sending || commitPending)
        }
        .padding(10)
        .background(Color.ccBg)
        .onAppear {
            // 2026-05-10 用户 push 切 tab 不丢草稿 view 重建 onAppear 从 vm.draft init draftLocal
            if draftLocal.isEmpty && !vm.draft.isEmpty { draftLocal = vm.draft }
            // 切 chat tab 回来时重选 placeholder (不每帧动)
            storedPlaceholder = ChatInputBar.placeholders.randomElement() ?? "Waiting…"
        }
        // 2026-05-07 stop button 加 0.5s 延迟显示防发送瞬间闪
        .onChange(of: vm.isCcWorking) { _, working in
            if working {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if vm.isCcWorking { delayedIsWorking = true }
                }
            } else {
                delayedIsWorking = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ccPasteFromClipboard)) { _ in
            pasteFromClipboard()
        }
    }

    private func pasteFromClipboard() {
        let pb = UIPasteboard.general
        for typeID in [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier] {
            if let data = pb.data(forPasteboardType: typeID) {
                imagePreviews.append(ImagePreview(data: data))
                return
            }
        }
        if let img = pb.image, let data = img.pngData() {
            imagePreviews.append(ImagePreview(data: data))
            return
        }
        if let str = pb.string, !str.isEmpty {
            draftLocal += str
        }
    }

    private func syncToVM() {
        vm.draft = draftLocal
    }

    /// Phase A — replace the slash-prefix portion of draftLocal with the selected command + space.
    /// Cursor implicitly ends up at the new draftLocal end (SwiftUI TextField default).
    private func selectSlashCommand(_ cmd: SlashCommand) {
        // Replace from start up to first whitespace (or whole string) with insertion.
        let firstSpaceIdx = draftLocal.firstIndex(where: { $0.isWhitespace })
        if let idx = firstSpaceIdx {
            // Should not normally happen because popover hides once a space is typed,
            // but if user pasted a slash + spaces, only replace the head.
            draftLocal = cmd.insertion + String(draftLocal[idx...]).trimmingCharacters(in: .whitespaces)
        } else {
            draftLocal = cmd.insertion
        }
        slashHighlightIndex = 0
    }

    private func commitFromSendButton() {
        guard !commitPending else { return }
        commitPending = true
        inputFocused.wrappedValue = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            commit()
            commitPending = false
        }
    }

    private func commitFromSubmit() {
        // 2026-05-12 send race fix — Enter path now shares the same
        // commitPending guard as the send-button path so an Enter that fires
        // while the previous send is still in flight (or while .onChange just
        // re-triggered) can't double-commit.
        guard !commitPending else { return }
        commitPending = true
        inputFocused.wrappedValue = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            commit()
            commitPending = false
        }
    }

    private func commit() {
        let rawText = draftLocal.isEmpty ? vm.draft : draftLocal
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !imagePreviews.isEmpty {
            let previews = imagePreviews
            imagePreviews = []
            let caption = text
            let quotedShared = vm.quoting?.ts
            vm.quoting = nil
            draftLocal = ""
            Task {
                for (idx, preview) in previews.enumerated() {
                    await vm.upload(
                        data: preview.data,
                        filename: "image_\(Int(Date().timeIntervalSince1970))_\(idx).jpg",
                        caption: idx == 0 ? caption : "",
                        quotedTs: idx == 0 ? quotedShared : nil
                    )
                }
            }
            return
        }
        guard !text.isEmpty else { return }
        // 2026-05-12 send race fix — hand off an explicit snapshot so the
        // upcoming `draftLocal = ""` (and its onChange, which writes vm.draft)
        // can't blank the value before the async send actually reads it.
        // vm.quoting is left for send() to consume + clear since picking a
        // quoted message is a separate user action without a race window.
        draftLocal = ""
        vm.draft = ""
        // 2026-05-07 macCatalyst SwiftUI TextField axis:.vertical 跟 @State binding 同步 race 加 main.async 双重 clear
        DispatchQueue.main.async { self.draftLocal = "" }
        Task { await vm.send(text: text) }
    }
}

private struct ImagePreviewStrip: View {
    @Binding var previews: [ImagePreview]
    var onEdit: ((ImagePreview) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(previews) { preview in
                    ZStack(alignment: .topTrailing) {
                        #if os(iOS)
                        if let img = UIImage(data: preview.data) {
                            ZStack(alignment: .bottomLeading) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                // 2026-05-07 用户 push 微信式发送前编辑 缩略图左下显式入口 替代长按 contextMenu
                                Button {
                                    onEdit?(preview)
                                } label: {
                                    HStack(spacing: 2) {
                                        Image(systemName: "pencil")
                                            .font(.ccSerifAdaptive(size: 9, weight: .semibold))
                                        Text("编辑")
                                            .font(.ccSerifAdaptive(size: 10, weight: .medium))
                                    }
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                            }
                            .frame(width: 72, height: 72)
                        }
                        #endif
                        Button {
                            previews.removeAll { $0.id == preview.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.black.opacity(0.55))
                                .font(.ccSerifAdaptive(size: 16))
                        }
                        .padding(2)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color.ccCard)
    }
}

private struct TodoInputSheet: View {
    let onSubmit: (String) -> Void
    @State private var text: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("待办内容", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                Spacer()
            }
            .navigationTitle("添加待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        onSubmit(t)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ChatToolbarLeading: View {
    let multiSelectMode: Bool
    let status: String
    let statusColor: Color
    let isBreathing: Bool
    let aiName: String
    let aiAvatarEmoji: String
    let aiAvatarPath: String
    let onCancel: () -> Void

    @State private var pulseScale: CGFloat = 0.85

    private var avatarView: some View {
        CcAvatarView(role: .ai, size: 38)
    }

    var body: some View {
        if multiSelectMode {
            Button("取消", action: onCancel)
                .font(.ccSerifAdaptive(size: 17))
                .foregroundStyle(Color.ccAccent)
        } else {
            HStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    avatarView

                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .scaleEffect(pulseScale)
                        .offset(x: 2, y: -2)
                        .onAppear {
                            if isBreathing {
                                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                                    pulseScale = 1.05
                                }
                            } else {
                                pulseScale = 1.0
                            }
                        }
                        .onChange(of: isBreathing) { _, breathing in
                            if breathing {
                                pulseScale = 0.85
                                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                                    pulseScale = 1.05
                                }
                            } else {
                                withAnimation(.easeOut(duration: 0.15)) { pulseScale = 1.0 }
                            }
                        }
                }
                Text(aiName)
                    .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                    // 2026-05-14 build 198 — ccAssistant 在 terminal theme = Color.clear 导致 AI 名字看不见
                    // 改用 ccAccent (每个主题都有可见 accent: warm 橙 / terminal 浅青 / night 暖橙)
                    .foregroundStyle(Color.ccAccent)
            }
            .accessibilityLabel("\(aiName) \(status)")
        }
    }
}

private struct ChatToolbarPrincipal: View {
    let multiSelectMode: Bool
    let selectedCount: Int
    let aiName: String
    let aiAvatarEmoji: String

    var body: some View {
        if multiSelectMode {
            Text("已选 \(selectedCount) 条")
                .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                .foregroundStyle(Color.ccText)
        } else {
            HStack(spacing: 6) {
                Text(aiAvatarEmoji)
                    .font(.ccSerifAdaptive(size: 22, weight: .bold))
                Text(aiName)
                    .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                    .foregroundStyle(Color.ccText)
            }
        }
    }
}

private struct ChatToolbarTrailing: View {
    let multiSelectMode: Bool
    let selectedCount: Int
    let displayedCount: Int
    let showSearch: Bool
    let onToggleAll: () -> Void
    let onToggleSearch: () -> Void
    let onEnterRP: () -> Void
    var onShowFavorites: (() -> Void)? = nil
    // 2026-05-12 clear-button restore — 砍后重加.
    var onClearChat: (() -> Void)? = nil

    var body: some View {
        if multiSelectMode {
            Button(selectedCount == displayedCount ? "清除" : "全选", action: onToggleAll)
                .font(.ccSerifAdaptive(size: 17))
                .foregroundStyle(Color.ccAccent)
        } else {
            HStack(spacing: 12) {
                Button(action: onToggleSearch) {
                    Image(systemName: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                        .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                        .foregroundStyle(Color.ccAccent)
                }
                .accessibilityLabel("搜索")
                // Phase 设置大砍 (item C) — 直接 inline "收藏夹" 入口
                if let showFav = onShowFavorites {
                    Button(action: showFav) {
                        Image(systemName: "bookmark.fill")
                            .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                            .foregroundStyle(Color.ccAccent)
                    }
                    .accessibilityLabel("收藏夹")
                }
                if let clear = onClearChat {
                    Menu {
                        Button(role: .destructive, action: clear) {
                            Label("清空本地聊天", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                            .foregroundStyle(Color.ccAccent)
                    }
                    .accessibilityLabel("更多")
                }
            }
        }
    }
}

private struct QuotePreviewBar: View {
    let message: ChatMessage
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "quote.bubble")
                .foregroundStyle(Color.ccAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.isUser ? "回复你自己" : "回复 Cc")
                    .font(.ccSerifAdaptive(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
                Text(message.text)
                    .font(.ccSerifAdaptive(size: 12))
                    .foregroundStyle(Color.ccTextDim)
                    .lineLimit(2)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.ccTextDim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.ccCard)
        .overlay(Rectangle().frame(width: 2).foregroundStyle(Color.ccAccent), alignment: .leading)
    }
}

private struct ChatListView: View {
    @ObservedObject var vm: ChatViewModel
    let inputFocused: Bool
    @Binding var hasScrolledInitially: Bool
    var scrollToken: Int = 0
    var onEnterRP: ((String) -> Void)? = nil
    var onImageTap: ((URL) -> Void)? = nil
    // Phase F (item 2) — chat 背景图存在时, ChatListView 自身 background 走 clear, 让外层 ZStack 的图透出来
    @AppStorage("chat_background_path") private var chatBackgroundPath: String = ""

    private func bottomScrollTargetId() -> String? {
        vm.displayedRowsCache.last?.id ?? vm.displayedMessages.last?.id
    }

    private func scrollToBottom(proxy: ScrollViewProxy, delay: TimeInterval = 0, animated: Bool = false) {
        let action = {
            guard let target = bottomScrollTargetId() else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .bottom)
                }
            } else {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    proxy.scrollTo(target, anchor: .bottom)
                }
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    private func scrollBottom(proxy: ScrollViewProxy) {
        // Build 183: scroll to the last stable row id after List layout settles.
        // The old bottom sentinel moved index on every append and could race
        // SwiftUI's UICollectionView batch commit.
        scrollToBottom(proxy: proxy, delay: 0.05)
        scrollToBottom(proxy: proxy, delay: 0.2)
        scrollToBottom(proxy: proxy, delay: 0.6)
    }
    // Bug 3 fix: block scroll/haptic while user is in QuickLook preview
    @State private var previewActive: Bool = false
    @State private var lastSoundedMessageId: String? = nil
    @State private var lastSoundTime: Date? = nil
    // unread indicator state — 微信式 N 条新消息
    @State private var isUserScrolledUp: Bool = false
    @State private var unreadCount: Int = 0
    // Phase F (item 8) — loadEarlier 期间禁用自动 scroll-bottom, 防 prepend 旧消息把 view 弹到底.
    @State private var suppressBottomScrollUntil: Date = .distantPast

    // 2026-05-07 用户 push 时间分组 helper
    static func groupByTime(_ msgs: [ChatMessage]) -> [String: [ChatMessage]] {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var groups: [String: [ChatMessage]] = ["本周": [], "这个月": [], "更早": []]
        for msg in msgs {
            let key: String
            if let date = formatter.date(from: msg.ts) {
                let interval = now.timeIntervalSince(date)
                if interval < 7 * 86400 { key = "本周" }
                else if interval < 30 * 86400 { key = "这个月" }
                else { key = "更早" }
            } else {
                key = "更早"
            }
            groups[key, default: []].append(msg)
        }
        return groups
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if vm.searchState != .idle {
                            SearchStateContent(vm: vm, proxy: proxy, onImageTap: onImageTap)
                        } else {
                            // Phase E amend (2026-05-11) — "加载更早 200 条" 按钮砍, 改顶部 pull-to-refresh.
                            // refreshable 挂在 ScrollView, 这里只留个轻提示当还有可拉时.
                            if vm.hasMoreEarlier && vm.loadingEarlier {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("加载更早...")
                                        .font(.ccSerifAdaptive(size: 12))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .foregroundStyle(Color.ccTextDim)
                            }
                            ForEach(vm.displayedRowsCache) { row in
                                chatRowView(row)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if let err = vm.lastError {
                            ChatErrorRow(error: err)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                // Phase F (item 2) — bg image 存在时走 clear 透出 image, 否则走 ccBg
                .background(chatBackgroundPath.isEmpty ? Color.ccBg : Color.clear)
                // Phase E amend (2026-05-11) — 顶部下拉触发 loadEarlier (取代旧"加载更早 200 条"按钮)
                // Phase F (item 8) — load 期间锁 isUserScrolledUp=true, 防 prepend 来的旧消息触发 onChange
                // 跳到底. load 完留 token 短暂保持 (200ms) 兜底 onChange race.
                .refreshable {
                    if vm.hasMoreEarlier {
                        let anchor = vm.displayedRowsCache.first?.id
                        isUserScrolledUp = true
                        suppressBottomScrollUntil = Date().addingTimeInterval(2.0)
                        await vm.loadEarlier()
                        if let anchor {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                proxy.scrollTo(anchor, anchor: .top)
                            }
                        }
                        // 再延 200ms 兜底 onChange race
                        suppressBottomScrollUntil = Date().addingTimeInterval(0.2)
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        #if os(iOS)
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        #endif
                    }
                )
                // 2026-05-14 build 189 — 给 ScrollView 一段持久 bottom inset 防 TypingStatusBar / 输入栏
                // 加进 view tree 时挤压 chat 最后一行 视觉上"输入栏没到底""遮一部分 chat"的根
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: 8)
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    // 距离底部 > 350pt 视为 scrolled up (350 比 200 留足 keyboard 弹起 viewport 收缩的余量)
                    let distanceFromBottom = geo.contentSize.height - (geo.contentOffset.y + geo.containerSize.height)
                    return distanceFromBottom > 350
                } action: { _, scrolledUp in
                    // keyboard 弹起期间不更新 isUserScrolledUp (viewport 收缩会让 distanceFromBottom 自动变大 误判)
                    guard !inputFocused else { return }
                    // 2026-05-14 build 189 — isCcTyping 切换时 TypingStatusBar 出现/消失会瞬间改变
                    // contentSize/containerSize, 触发本回调而非用户真滑. 在 typing 状态下跳过更新, 等 typing
                    // 结束后状态会通过下一次真正滑动 reset.
                    guard !vm.isCcTyping else { return }
                    isUserScrolledUp = scrolledUp
                    if !scrolledUp {
                        // 用户回到底部 自动清 unread
                        unreadCount = 0
                        vm.resetVisibleWindowToRecent()
                    }
                }
                .onChange(of: inputFocused) { _, focused in
                    if focused {
                        // keyboard 弹起 用户在打字 强制按"在底部"处理 不要让 keyboard 弹起触发 scroll geometry 误判
                        isUserScrolledUp = false
                        unreadCount = 0
                    }
                    // 2026-05-14 build 189 — 老代码有两条 scrollToBottom (inline asyncAfter 加 handleInputFocusChange)
                    // 双 scroll 在 keyboard 动画期间撞 race 视觉上 chat 列表抖. 只留 handleInputFocusChange 那一条.
                    handleInputFocusChange(focused: focused, proxy: proxy)
                }
                .onChange(of: vm.messages.count) { oldCount, count in
                    triggerSoundAndHaptic(oldCount: oldCount, count: count)
                    let delta = max(0, count - oldCount)
                    // 自己刚发 vs 别人发 分开处理 (role=user 不算 unread role=task pill 也不算)
                    // Phase E amend (2026-05-11) — cccompanion 未读 bubble 漏 修: 之前 suffix(delta) 在
                    // backfill 把消息插中段时 trailing 不一定是新消息. 改用 lastTs/firstTs 不变也兜底, 同时
                    // 即便 newOthersCount=0 但 delta>0 视作有变化 (assistant typing pill 不带 ts 也算).
                    let newOthersCount: Int
                    let hasUserMessage: Bool
                    if delta > 0 && oldCount < count {
                        let recentMessages = Array(vm.messages.suffix(delta))
                        let filtered = recentMessages.filter { $0.role != "user" && $0.role != "task" }.count
                        newOthersCount = filtered > 0 ? filtered : delta  // 兜底: delta>0 时至少计 delta
                        hasUserMessage = recentMessages.contains(where: { $0.role == "user" })
                    } else {
                        newOthersCount = 0
                        hasUserMessage = false
                    }
                    // Phase F (item 8) — loadEarlier 窗口期内 prepend 来的旧消息不能触发 scroll-bottom
                    let suppressActive = Date() < suppressBottomScrollUntil
                    // 自己刚发了消息 → 强制 scroll bottom + 清 unread (绕过 isUserScrolledUp 误判)
                    if hasUserMessage && !suppressActive {
                        unreadCount = 0
                        isUserScrolledUp = false
                        vm.resetVisibleWindowToRecent()
                        // Build 184 crash fix: LazyVStack has no UICollectionView batch update.
                        scrollToBottom(proxy: proxy, delay: 0.05)
                        return
                    }
                    if (isUserScrolledUp || suppressActive) && newOthersCount > 0 {
                        // 用户在上面看历史 / loadEarlier 期间 不 auto scroll 累计 unread (只算别人发的)
                        if !suppressActive { unreadCount += newOthersCount }
                    } else {
                        unreadCount = 0
                        vm.resetVisibleWindowToRecent()
                        // 不带动画 直接 scroll 不再跟 cache append 撞 视觉上稳
                        scrollToBottom(proxy: proxy, delay: 0.05)
                    }
                }
                .onAppear {
                    scrollBottom(proxy: proxy)
                    hasScrolledInitially = true
                }
                .onChange(of: scrollToken) { _, _ in
                    scrollBottom(proxy: proxy)
                    unreadCount = 0
                    isUserScrolledUp = false
                    vm.resetVisibleWindowToRecent()
                }
                .onChange(of: vm.returnToBottomBump) { _, _ in
                    // 2026-05-08 patch1: 搜索取消触发回最底
                    scrollBottom(proxy: proxy)
                    unreadCount = 0
                    isUserScrolledUp = false
                    vm.resetVisibleWindowToRecent()
                }
                .onChange(of: vm.jumpScrollTarget) { _, target in
                    guard let target else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            vm.jumpScrollTarget = nil
                        }
                    }
                }
                .onChange(of: vm.displayedRowsCache.count) { oldCount, newCount in
                    // build 93: rows 真正进 cache 时再 scroll 一次 过 hydrate race
                    // 2026-05-07 jumpScrollTarget 不空时不 scroll bottom 会覆盖跳老消息
                    if !isUserScrolledUp && newCount > oldCount && vm.jumpScrollTarget == nil {
                        scrollToBottom(proxy: proxy, delay: 0.05)
                    }
                }
                // unread indicator overlay — 微信式
                if unreadCount > 0 {
                    Button {
                        scrollToBottom(proxy: proxy, animated: true)
                        unreadCount = 0
                        isUserScrolledUp = false
                        vm.resetVisibleWindowToRecent()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.down")
                                .font(.ccSerifAdaptive(size: 11, weight: .bold))
                            Text("\(unreadCount) 条新消息")
                                .font(.ccSerifAdaptive(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.ccCard)
                        .foregroundStyle(Color.ccAccent)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 80)
                    .transition(.scale.combined(with: .opacity))
                }
            } // ZStack
        }
    }

    @ViewBuilder
    private func chatRowView(_ row: ChatRowItem) -> some View {
        switch row {
        case .separator(let label, _):
            ChatSeparatorRow(label: label)
        case .toolStack(let stack):
            ToolActivityStackView(stack: stack)
                .id("stack_\(stack.id)")
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
        case .message(let msg, let showTime):
            ChatMessageListRow(
                message: msg,
                showTime: showTime,
                multiSelectMode: vm.multiSelectMode,
                selected: vm.selectedTs.contains(msg.ts),
                onToggleSelection: { vm.toggleSelection(msg) },
                onEnterMultiSelect: { vm.enterMultiSelect(with: msg) },
                onReact: { emoji in Task { await vm.react(msg, emoji: emoji) } },
                onQuote: { vm.quoting = msg },
                onCopyText: vm.assistantTurnEndsTs.contains(msg.ts)
                    ? { UIPasteboard.general.string = vm.turnTexts(endingAt: msg.ts).joined(separator: "\n\n"); CcToastBus.shared.show("已复制") }
                    : nil,
                onFavorite: { Task { await vm.addToFavorites(msg) } },
                onAddTodo: { Task { await vm.addTodo(msg.text) } },
                onDelete: { Task { await vm.delete(msg) } },
                onRegenerate: msg.ts == vm.lastAssistantTurnLastTs
                    ? { Task { await vm.regenerate(messageTs: vm.lastAssistantTurnFirstTs ?? msg.ts, extraReplaceIds: vm.lastAssistantTurnExtraTs) } }
                    : nil,
                onFavoriteTurn: vm.assistantTurnEndsTs.contains(msg.ts)
                    ? {
                        if FavoritedTurnsCache.shared.contains(msg.ts) {
                            // Already favorited → toggle off
                            FavoritedTurnsCache.shared.remove(msg.ts)
                            Task { await vm.unfavoriteTurn(endingAt: msg.ts); CcToastBus.shared.show("已取消收藏") }
                        } else {
                            FavoritedTurnsCache.shared.insert(msg.ts)
                            Task { await vm.addManyToFavorites(vm.turnMessages(endingAt: msg.ts)); CcToastBus.shared.show("已收藏") }
                        }
                    }
                    : nil,
                onChoiceSelect: { value in Task { await vm.send(text: value) } },
                onPreviewActiveChanged: { active in previewActive = active },
                onEnterRP: onEnterRP.map { cb in { cb(msg.text) } },
                onImageTap: onImageTap,
                sendStatus: vm.sendStatus(forId: msg.id),
                onRetry: msg.isUser ? { vm.retryFailedSend(id: msg.id) } : nil,
                onDiscardFailed: msg.isUser ? { vm.discardFailedSend(id: msg.id) } : nil
            )
            .id(msg.id)
            .padding(.vertical, 4)
            .padding(.trailing, 12)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .bottom)),
                removal: .opacity
            ))
        }
    }

    private func handleInputFocusChange(focused: Bool, proxy: ScrollViewProxy) {
        if focused {
            scrollToBottom(proxy: proxy, animated: true)
        }
    }

    // sound + haptic only — scroll is handled by onChange in body
    private func triggerSoundAndHaptic(oldCount: Int, count: Int) {
        guard count > 0, let last = vm.displayedMessages.last else { return }
        if previewActive { return }
        // 2026-05-08 用户 push: 切 tab 时 view 重建 onChange of count 会 false-positive
        // 只 single new append (count == oldCount + 1) 触发 sound/haptic 跳过 batch jump
        let isSingleAppend = count == oldCount + 1
        if hasScrolledInitially && isSingleAppend && last.role != "user" {
            // dedup: same message id → skip
            guard last.id != lastSoundedMessageId else { return }
            // throttle: < 2s since last sound → skip
            if let t = lastSoundTime, Date().timeIntervalSince(t) < 2.0 { return }
            lastSoundedMessageId = last.id
            lastSoundTime = Date()
            if last.role == "task" {
                #if os(iOS)
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.prepare()
                gen.impactOccurred(intensity: 0.35)
                #endif
                if vm.taskSoundEnabled {
                    AudioServicesPlaySystemSound(1075)
                }
            } else {
                #if os(iOS)
                let gen = UIImpactFeedbackGenerator(style: .soft)
                gen.prepare()
                gen.impactOccurred(intensity: 0.6)
                #endif
                if vm.chatSoundEnabled {
                    AudioServicesPlaySystemSound(1003)
                }
            }
        }
    }
}

private struct SearchServerPromptRow: View {
    let isSearching: Bool
    let onSearch: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: onSearch) {
                Label(isSearching ? "搜索中..." : "搜全部历史", systemImage: "magnifyingglass.circle")
                    .font(.ccSerifAdaptive(size: 12))
            }
            .disabled(isSearching)
            Spacer()
        }
    }
}

private struct SearchFilterBar: View {
    let selected: ChatViewModel.SearchFilter
    let onSelect: (ChatViewModel.SearchFilter) -> Void
    var onDate: (() -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ChatViewModel.SearchFilter.allCases) { filter in
                    Button {
                        onSelect(filter)
                    } label: {
                        Text(filter.rawValue)
                            .font(.footnote.weight(selected == filter ? .semibold : .regular))
                            .foregroundStyle(selected == filter ? Color.white : Color.ccText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(selected == filter ? Color.ccAccent : Color.ccCard)
                            )
                    }
                    .buttonStyle(.plain)
                }
                if let onDate {
                    Button {
                        onDate()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.ccSerifAdaptive(size: 11))
                            Text("日期")
                                .font(.footnote)
                        }
                        .foregroundStyle(Color.ccText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.ccCard))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color.ccBg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ccCard)
                .frame(height: 0.5)
        }
    }
}

// MARK: - Timeline rail (git commit graph 风)
// 行内自绘 rail + node. 不依赖 List background / GeometryReader.
// 普通 bubble = 大 node (13pt), task = 小 dot (7pt). 上下竖线 row 间衔接.
private enum TimelineNodeKind: Equatable {
    case user
    case cc
    case task
    case separator
    case other(String)
}

private struct TimelineNodeRow<Content: View>: View {
    let kind: TimelineNodeKind
    let isFirst: Bool
    let isLast: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(lineColor)
                    .frame(width: 1)
                    .opacity(isFirst ? 0 : 1)
                node
                    .padding(.vertical, 2)
                Rectangle()
                    .fill(lineColor)
                    .frame(width: 1)
                    .opacity(isLast ? 0 : 1)
            }
            .frame(width: 32)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 6)
    }

    private var nodeSize: CGFloat { kind == .task ? 7 : 13 }

    private var node: some View {
        Circle()
            .fill(color)
            .frame(width: nodeSize, height: nodeSize)
            .overlay(Circle().stroke(Color.ccBg, lineWidth: 2))
    }

    private var color: Color {
        switch kind {
        case .user: return Color.ccAccent
        case .cc: return Color.ccAccent
        case .task: return Color.ccTextDim.opacity(0.55)
        case .separator: return Color.ccTextDim.opacity(0.4)
        case .other(let role): return Self.hashColor(role)
        }
    }

    private var lineColor: Color {
        Color.ccTextDim.opacity(0.25)
    }

    private static func hashColor(_ s: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .green]
        let idx = abs(s.hashValue) % palette.count
        return palette[idx]
    }
}

private func timelineKind(for msg: ChatMessage) -> TimelineNodeKind {
    if msg.role == "task" { return .task }
    if msg.role == "user" { return .user }
    if msg.role == "assistant" { return .cc }
    return .other(msg.role)
}

private struct ChatSeparatorRow: View {
    let label: String

    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(.ccSerifAdaptive(size: 11))
                .foregroundStyle(Color.ccTextDim)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.ccCard.opacity(0.7))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12))
    }
}

private struct ToolActivityStackView: View {
    let stack: ToolStack
    @State private var isExpanded: Bool = false
    @State private var pulseScale: CGFloat = 0.6

    private var runningPrefix: String {
        let a = stack.agent
        if a.isEmpty || a.lowercased() == "system" || a == "unknown" { return "" }
        return "\(a) "
    }

    var body: some View {
        Group {
            if stack.isRunning {
                runningView
            } else {
                collapsedView
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 2)
    }

    private var runningView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.ccAccent)
                .frame(width: 6, height: 6)
                .scaleEffect(pulseScale)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulseScale)
            Text(runningPrefix + "正在执行 \(stack.tools.last?.text ?? "...")")
                .font(.ccSerifAdaptive(size: 11))
                .foregroundStyle(Color.ccTextDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.ccCard.opacity(0.5))
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            pulseScale = 1.1
        }
    }

    private var collapsedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.ccSerifAdaptive(size: 11))
                        .foregroundStyle(Color.ccTextDim)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.ccSerifAdaptive(size: 11))
                        .foregroundStyle(Color.ccAccent)
                    Text(stack.summary)
                        .font(.ccSerifAdaptive(size: 11, weight: .medium))
                        .foregroundStyle(Color.ccTextDim)
                        
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.ccCard.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(stack.tools, id: \.id) { tool in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: iconForTaskText(tool.text))
                                .font(.ccSerifAdaptive(size: 11))
                                .foregroundStyle(Color.ccAccent)
                            Text(tool.text)
                                .font(.ccSerifAdaptive(size: 11))
                                .foregroundStyle(Color.ccTextDim)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
        // 不再 maxWidth .infinity 让折叠栏宽度自适应内容
    }
}

private struct ChatErrorRow: View {
    let error: String

    var body: some View {
        Text(error)
            .font(.ccSerifAdaptive(size: 12))
            .foregroundStyle(.red)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }
}

private struct ChatMessageListRow: View {
    let message: ChatMessage
    let showTime: Bool
    let multiSelectMode: Bool
    let selected: Bool
    let onToggleSelection: () -> Void
    let onEnterMultiSelect: () -> Void
    let onReact: (String) -> Void
    let onQuote: () -> Void
    let onCopyText: (() -> Void)?
    let onFavorite: () -> Void
    let onAddTodo: () -> Void
    let onDelete: () -> Void
    let onRegenerate: (() -> Void)?
    // build 129 — 整段收藏外挂 (turn 级 仅最后 assistant turn 最后一条)
    let onFavoriteTurn: (() -> Void)?
    let onChoiceSelect: ((String) -> Void)?
    let onPreviewActiveChanged: ((Bool) -> Void)?
    let onEnterRP: (() -> Void)?
    var onImageTap: ((URL) -> Void)? = nil
    // 2026-05-12 optimistic-send
    var sendStatus: SendStatus = .sent
    var onRetry: (() -> Void)? = nil
    var onDiscardFailed: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            if multiSelectMode {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? Color.ccAccent : Color.ccTextDim)
                    .frame(width: 28)
            }
            ChatBubble(
                message: message,
                showTime: showTime,
                onChoiceSelect: onChoiceSelect,
                onPreviewActiveChanged: onPreviewActiveChanged,
                onImageTap: onImageTap,
                onRegenerate: message.isUser ? nil : onRegenerate,
                onFavoriteTurn: message.isUser ? nil : onFavoriteTurn,
                onCopyText: message.isUser ? nil : onCopyText,
                sendStatus: sendStatus,
                onRetry: onRetry,
                onDiscardFailed: onDiscardFailed
            )
        }
        // macCatalyst — 整 row 不加 contentShape/onTapGesture 否则抢 mouse hit-test 让 bubble 内部 Text textSelection 失效
        // 多选 tap 入口 Mac 端走 hover ⋯ 后续补 (TODO 下 spec)
        #if !targetEnvironment(macCatalyst)
        .contentShape(Rectangle())
        .onTapGesture {
            if multiSelectMode {
                onToggleSelection()
            }
        }
        #endif
        // build 129+ macCatalyst — 外层 row contextMenu 抢 mouse hit-test 导致 bubble 内部 Text textSelection 失效
        // iPhone 端保留 长按出大菜单 是主要交互路径
        // Mac 端关掉外层 优先选词 大菜单后续走 hover ⋯ 入口补回 (TODO 下 spec)
        #if !targetEnvironment(macCatalyst)
        .contextMenu {
            if !multiSelectMode {
                Button(action: onEnterMultiSelect) {
                    Label("选择多条", systemImage: "checkmark.circle")
                }
                Button(action: onQuote) {
                    Label("引用回复", systemImage: "quote.bubble")
                }
                if !message.isUser {
                    Button(action: { UIPasteboard.general.string = message.text }) {
                        Label("复制本条", systemImage: "doc.on.doc")
                    }
                }
                // 2026-05-14 build 198 — 翻译选项删 (build 190 加进来 用户 6:33 推删 用不上)
                // build 129 — 复制整段 已外挂到 bubble 下面 这里 contextMenu 不再重复
                if !message.isUser, let fn = onRegenerate {
                    Button(action: fn) {
                        Label("重新说", systemImage: "arrow.clockwise")
                    }
                }
                Button(action: onFavorite) {
                    Label("收藏本条", systemImage: "bookmark")
                }
                Button(action: onAddTodo) {
                    Label("添加到待办", systemImage: "checklist.checked")
                }
                if let enterRP = onEnterRP {
                    Button(action: enterRP) {
                        Label("进入 RP", systemImage: "theatermasks")
                    }
                }
                if let url = message.attachmentFullURL() {
                    ShareLink(
                        item: url,
                        preview: SharePreview(message.attachmentFilename ?? "附件")
                    ) {
                        Label(message.attachmentType == "image" ? "保存图片 / 分享" : "保存 / 分享", systemImage: "square.and.arrow.down")
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        #endif
    }
}

// MARK: - Typing dots animation

struct ThinkingVerb {
    let en: String
    let zh: String
}

let thinkingVerbs: [ThinkingVerb] = [
    ThinkingVerb(en: "Thinking", zh: "思考"),
    ThinkingVerb(en: "Pondering", zh: "沉思"),
    ThinkingVerb(en: "Cogitating", zh: "深思"),
    ThinkingVerb(en: "Cerebrating", zh: "动脑"),
    ThinkingVerb(en: "Contemplating", zh: "凝想"),
    ThinkingVerb(en: "Considering", zh: "斟酌"),
    ThinkingVerb(en: "Deliberating", zh: "掂量"),
    ThinkingVerb(en: "Mulling", zh: "琢磨"),
    ThinkingVerb(en: "Musing", zh: "遐想"),
    ThinkingVerb(en: "Ruminating", zh: "反刍"),
    ThinkingVerb(en: "Ideating", zh: "灵感中"),
    ThinkingVerb(en: "Imagining", zh: "想象"),
    ThinkingVerb(en: "Envisioning", zh: "构想"),
    ThinkingVerb(en: "Philosophising", zh: "哲学中"),
    ThinkingVerb(en: "Pontificating", zh: "宣讲"),
    ThinkingVerb(en: "Bloviating", zh: "吹水"),
    ThinkingVerb(en: "Noodling", zh: "瞎想"),
    ThinkingVerb(en: "Doodling", zh: "涂鸦"),
    ThinkingVerb(en: "Puzzling", zh: "犯难"),
    ThinkingVerb(en: "Dithering", zh: "纠结"),
    ThinkingVerb(en: "Befuddling", zh: "迷糊"),
    ThinkingVerb(en: "Flummoxing", zh: "懵圈"),
    ThinkingVerb(en: "Discombobulating", zh: "晕乎"),
    ThinkingVerb(en: "Combobulating", zh: "理顺"),
    ThinkingVerb(en: "Recombobulating", zh: "重整"),
    ThinkingVerb(en: "Deciphering", zh: "破译"),
    ThinkingVerb(en: "Elucidating", zh: "揭晓"),
    ThinkingVerb(en: "Inferring", zh: "推断"),
    ThinkingVerb(en: "Calculating", zh: "演算"),
    ThinkingVerb(en: "Computing", zh: "计算"),
    ThinkingVerb(en: "Crunching", zh: "啃数据"),
    ThinkingVerb(en: "Processing", zh: "处理"),
    ThinkingVerb(en: "Determining", zh: "判定"),
    ThinkingVerb(en: "Channeling", zh: "通灵"),
    ThinkingVerb(en: "Manifesting", zh: "显化"),
    ThinkingVerb(en: "Conjuring", zh: "召唤"),
    ThinkingVerb(en: "Prestidigitating", zh: "变戏法"),
    ThinkingVerb(en: "Enchanting", zh: "施法"),
    ThinkingVerb(en: "Levitating", zh: "悬浮"),
    ThinkingVerb(en: "Hyperspacing", zh: "曲速"),
    ThinkingVerb(en: "Warping", zh: "扭曲"),
    ThinkingVerb(en: "Orbiting", zh: "盘旋"),
    ThinkingVerb(en: "Beaming", zh: "传送"),
    ThinkingVerb(en: "Ionizing", zh: "电离"),
    ThinkingVerb(en: "Quantumizing", zh: "量子化"),
    ThinkingVerb(en: "Nebulizing", zh: "雾化"),
    ThinkingVerb(en: "Misting", zh: "起雾"),
    ThinkingVerb(en: "Sublimating", zh: "升华"),
    ThinkingVerb(en: "Evaporating", zh: "蒸发"),
    ThinkingVerb(en: "Crystallizing", zh: "结晶"),
    ThinkingVerb(en: "Coalescing", zh: "凝聚"),
    ThinkingVerb(en: "Precipitating", zh: "析出"),
    ThinkingVerb(en: "Metamorphosing", zh: "蜕变"),
    ThinkingVerb(en: "Transfiguring", zh: "变形"),
    ThinkingVerb(en: "Transmuting", zh: "嬗变"),
    ThinkingVerb(en: "Cooking", zh: "烹饪"),
    ThinkingVerb(en: "Brewing", zh: "酿造"),
    ThinkingVerb(en: "Marinating", zh: "腌渍"),
    ThinkingVerb(en: "Fermenting", zh: "发酵"),
    ThinkingVerb(en: "Simmering", zh: "慢炖"),
    ThinkingVerb(en: "Stewing", zh: "焖煮"),
    ThinkingVerb(en: "Steeping", zh: "浸泡"),
    ThinkingVerb(en: "Caramelizing", zh: "焦糖化"),
    ThinkingVerb(en: "Seasoning", zh: "调味"),
    ThinkingVerb(en: "Tempering", zh: "回火"),
    ThinkingVerb(en: "Whisking", zh: "搅打"),
    ThinkingVerb(en: "Kneading", zh: "揉面"),
    ThinkingVerb(en: "Leavening", zh: "发面"),
    ThinkingVerb(en: "Proofing", zh: "醒发"),
    ThinkingVerb(en: "Frosting", zh: "上糖霜"),
    ThinkingVerb(en: "Garnishing", zh: "点缀"),
    ThinkingVerb(en: "Drizzling", zh: "淋汁"),
    ThinkingVerb(en: "Zesting", zh: "刨皮屑"),
    ThinkingVerb(en: "Julienning", zh: "切丝"),
    ThinkingVerb(en: "Infusing", zh: "注入"),
    ThinkingVerb(en: "Percolating", zh: "渗滤"),
    ThinkingVerb(en: "Churning", zh: "翻搅"),
    ThinkingVerb(en: "Smooshing", zh: "捣鼓"),
    ThinkingVerb(en: "Concocting", zh: "调制"),
    ThinkingVerb(en: "Crafting", zh: "打磨"),
    ThinkingVerb(en: "Composing", zh: "编写"),
    ThinkingVerb(en: "Creating", zh: "创作"),
    ThinkingVerb(en: "Generating", zh: "生成"),
    ThinkingVerb(en: "Forging", zh: "锻造"),
    ThinkingVerb(en: "Hatching", zh: "孵化"),
    ThinkingVerb(en: "Incubating", zh: "酝酿"),
    ThinkingVerb(en: "Sprouting", zh: "发芽"),
    ThinkingVerb(en: "Germinating", zh: "萌发"),
    ThinkingVerb(en: "Cultivating", zh: "培育"),
    ThinkingVerb(en: "Pollinating", zh: "授粉"),
    ThinkingVerb(en: "Propagating", zh: "繁衍"),
    ThinkingVerb(en: "Pruning", zh: "修剪"),
    ThinkingVerb(en: "Sketching", zh: "速写"),
    ThinkingVerb(en: "Shading", zh: "勾影"),
    ThinkingVerb(en: "Embellishing", zh: "添花"),
    ThinkingVerb(en: "Architecting", zh: "构筑"),
    ThinkingVerb(en: "Choreographing", zh: "编舞"),
    ThinkingVerb(en: "Orchestrating", zh: "编排"),
    ThinkingVerb(en: "Harmonizing", zh: "调和"),
    ThinkingVerb(en: "Synthesizing", zh: "合成"),
    ThinkingVerb(en: "Improvising", zh: "即兴"),
    ThinkingVerb(en: "Boogieing", zh: "蹦跶"),
    ThinkingVerb(en: "Jitterbugging", zh: "摇摆"),
    ThinkingVerb(en: "Moonwalking", zh: "太空步"),
    ThinkingVerb(en: "Grooving", zh: "律动"),
    ThinkingVerb(en: "Shimmying", zh: "扭动"),
    ThinkingVerb(en: "Frolicking", zh: "嬉戏"),
    ThinkingVerb(en: "Gallivanting", zh: "闲逛"),
    ThinkingVerb(en: "Galloping", zh: "飞奔"),
    ThinkingVerb(en: "Scampering", zh: "蹦跳"),
    ThinkingVerb(en: "Scurrying", zh: "疾走"),
    ThinkingVerb(en: "Pouncing", zh: "扑跳"),
    ThinkingVerb(en: "Waddling", zh: "踱步"),
    ThinkingVerb(en: "Moseying", zh: "溜达"),
    ThinkingVerb(en: "Meandering", zh: "漫游"),
    ThinkingVerb(en: "Wandering", zh: "游荡"),
    ThinkingVerb(en: "Roaming", zh: "漫步"),
    ThinkingVerb(en: "Perambulating", zh: "踱行"),
    ThinkingVerb(en: "Skedaddling", zh: "溜走"),
    ThinkingVerb(en: "Schlepping", zh: "搬腾"),
    ThinkingVerb(en: "Slithering", zh: "蛇行"),
    ThinkingVerb(en: "Burrowing", zh: "钻洞"),
    ThinkingVerb(en: "Spelunking", zh: "探洞"),
    ThinkingVerb(en: "Nesting", zh: "筑巢"),
    ThinkingVerb(en: "Roosting", zh: "栖息"),
    ThinkingVerb(en: "Lollygagging", zh: "磨蹭"),
    ThinkingVerb(en: "Puttering", zh: "捣腾"),
    ThinkingVerb(en: "Tinkering", zh: "鼓捣"),
    ThinkingVerb(en: "Wrangling", zh: "周旋"),
    ThinkingVerb(en: "Finagling", zh: "捣鼓"),
    ThinkingVerb(en: "Boondoggling", zh: "瞎忙"),
    ThinkingVerb(en: "Tomfoolering", zh: "犯傻"),
    ThinkingVerb(en: "Shenaniganing", zh: "搞怪"),
    ThinkingVerb(en: "Razzmatazzing", zh: "炫技"),
    ThinkingVerb(en: "Hullaballooing", zh: "喧腾"),
    ThinkingVerb(en: "Canoodling", zh: "缠绵"),
    ThinkingVerb(en: "Wibbling", zh: "颤动"),
    ThinkingVerb(en: "Fluttering", zh: "扑闪"),
    ThinkingVerb(en: "Undulating", zh: "起伏"),
    ThinkingVerb(en: "Swirling", zh: "回旋"),
    ThinkingVerb(en: "Spinning", zh: "旋转"),
    ThinkingVerb(en: "Twisting", zh: "缠绕"),
    ThinkingVerb(en: "Unfurling", zh: "舒展"),
    ThinkingVerb(en: "Unravelling", zh: "解开"),
    ThinkingVerb(en: "Cascading", zh: "倾泻"),
    ThinkingVerb(en: "Billowing", zh: "翻涌"),
    ThinkingVerb(en: "Whirlpooling", zh: "卷流"),
    ThinkingVerb(en: "Swooping", zh: "俯冲"),
    ThinkingVerb(en: "Catapulting", zh: "弹射"),
    ThinkingVerb(en: "Bootstrapping", zh: "自举"),
    ThinkingVerb(en: "Reticulating", zh: "织网"),
    ThinkingVerb(en: "Interleaving", zh: "交错"),
    ThinkingVerb(en: "Clauding", zh: "Claude 中"),
    ThinkingVerb(en: "Gitifying", zh: "Git 化"),
]

private struct TypingStatusBar: View {
    @State private var currentVerb: ThinkingVerb = ThinkingVerb(en: "Thinking", zh: "思考")
    @State private var startTime: Date = Date()
    @State private var elapsedSec: Int = 0
    @AppStorage("ai_name") private var aiName: String = CcDefaultAIName
    // Phase D — toggle "仿 cc 终端文字" default true (旧行为). 关掉走通用 "[AI名字] 正在输入..."
    @AppStorage("typing_verbs_enabled") private var typingVerbsEnabled: Bool = true
    // 2026-05-14 build 191 — 订阅 ThemeStore 让切主题时这条 bar 真刷颜色
    // (ContentView .id(theme) 在 build 185 删了, chrome view 需要自己 observe).
    @ObservedObject private var theme = ThemeStore.shared

    private let verbTimer = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()
    private let tickTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            TypingDots()
            Text(typingVerbsEnabled
                 ? "\(aiName) 正在\(currentVerb.zh)… (\(elapsedSec)s)"
                 : "\(aiName) 正在输入… (\(elapsedSec)s)")
                .font(.ccSerifAdaptive(size: 12))
                // 2026-05-14 build 198 — terminal 主题下用 ccAccent (浅青) 比 ccText (白) 跟 dark
                // bg 对比更强 整条 typing bar 用户之前 catch 看不清
                .foregroundStyle(Color.ccAccent)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        // 2026-05-14 build 198 — bg 改 100% opaque 不再 .85 透明 不让背景透出来减对比
        .background(Color.ccCard)
        .onAppear {
            startTime = Date()
            elapsedSec = 0
            rotate()
        }
        .onReceive(verbTimer) { _ in rotate() }
        .onReceive(tickTimer) { _ in
            elapsedSec = Int(Date().timeIntervalSince(startTime))
        }
    }

    private func rotate() {
        if let next = thinkingVerbs.randomElement() {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentVerb = next
            }
        }
    }
}

struct TypingDots: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.ccAccent)
                    .frame(width: 5, height: 5)
                    .opacity(phase == i ? 1.0 : 0.3)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}

// MARK: - Link Preview (iMessage 同款 OG card)

#if canImport(LinkPresentation) && os(iOS)
struct LinkPreviewView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LPLinkView {
        let view = LPLinkView(url: url)
        view.translatesAutoresizingMaskIntoConstraints = false

        // 先用 cache (LPMetadataProvider 是 single-shot 不能复用)
        if let cached = LinkMetadataCache.shared.get(url: url) {
            view.metadata = cached
            return view
        }

        let provider = LPMetadataProvider()
        provider.timeout = 8
        provider.startFetchingMetadata(for: url) { metadata, _ in
            guard let metadata = metadata else { return }
            LinkMetadataCache.shared.set(url: url, metadata: metadata)
            DispatchQueue.main.async {
                view.metadata = metadata
            }
        }
        return view
    }

    func updateUIView(_ uiView: LPLinkView, context: Context) {
        if uiView.metadata.url != url, let cached = LinkMetadataCache.shared.get(url: url) {
            uiView.metadata = cached
        }
    }
}

final class LinkMetadataCache {
    static let shared = LinkMetadataCache()
    private var store: [URL: LPLinkMetadata] = [:]
    private let lock = NSLock()

    func get(url: URL) -> LPLinkMetadata? {
        lock.lock(); defer { lock.unlock() }
        return store[url]
    }

    func set(url: URL, metadata: LPLinkMetadata) {
        lock.lock(); defer { lock.unlock() }
        store[url] = metadata
    }
}
#endif

func extractFirstURL(in text: String) -> URL? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
        return nil
    }
    let range = NSRange(text.startIndex..., in: text)
    let match = detector.firstMatch(in: text, options: [], range: range)
    return match?.url
}

// chat bubble 文字 markdown 渲染 — inline 支持 (粗 / 斜 / code / link / 删除线)
func renderMarkdown(_ text: String) -> AttributedString {
    let opts = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    if let attr = try? AttributedString(markdown: text, options: opts) {
        return attr
    }
    return AttributedString(text)
}

// chat bubble 多段拆分 — fenced code block + 普通文字段
fileprivate enum BubbleSegment {
    case text(String)
    case codeBlock(language: String?, code: String)
}

fileprivate func parseBubbleSegments(_ text: String) -> [BubbleSegment] {
    var segments: [BubbleSegment] = []
    let lines = text.components(separatedBy: "\n")
    var inCode = false
    var codeLang: String? = nil
    var codeBuffer: [String] = []
    var textBuffer: [String] = []

    func flushText() {
        if !textBuffer.isEmpty {
            let joined = textBuffer.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(joined))
            }
            textBuffer.removeAll()
        }
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            if inCode {
                segments.append(.codeBlock(language: codeLang, code: codeBuffer.joined(separator: "\n")))
                codeBuffer.removeAll()
                codeLang = nil
                inCode = false
            } else {
                flushText()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLang = lang.isEmpty ? nil : lang
                inCode = true
            }
        } else if inCode {
            codeBuffer.append(line)
        } else {
            textBuffer.append(line)
        }
    }

    if inCode {
        segments.append(.codeBlock(language: codeLang, code: codeBuffer.joined(separator: "\n")))
    } else {
        flushText()
    }

    if segments.isEmpty {
        segments.append(.text(text))
    }
    return segments
}

// task notification 关键词 → SF Symbol mapping
func iconForTaskText(_ text: String) -> String {
    let t = text.lowercased()
    let map: [(String, String)] = [
        ("heartbeat", "heart.fill"),
        ("锁屏", "lock.fill"), ("lock", "lock.fill"), ("unlock", "lock.open.fill"),
        ("ship", "paperplane.fill"),
        ("upload", "icloud.and.arrow.up.fill"), ("上传", "icloud.and.arrow.up.fill"),
        ("download", "icloud.and.arrow.down.fill"), ("下载", "icloud.and.arrow.down.fill"),
        ("push", "bell.fill"),
        ("send", "paperplane.fill"), ("发", "paperplane.fill"),
        ("sync", "arrow.triangle.2.circlepath"), ("mirror", "arrow.triangle.2.circlepath"),
        ("build", "hammer.fill"), ("archive", "shippingbox.fill"),
        ("fastlane", "hammer.fill"),
        ("verify", "checkmark.seal.fill"), ("校验", "checkmark.seal.fill"), ("验证", "checkmark.seal.fill"),
        ("check", "checklist"),
        ("fix", "wrench.and.screwdriver.fill"), ("修", "wrench.and.screwdriver.fill"),
        ("read", "book.fill"), ("读", "book.fill"),
        ("write", "pencil"), ("写", "pencil"),
        ("edit", "square.and.pencil"),
        ("grep", "magnifyingglass"), ("find", "magnifyingglass"), ("search", "magnifyingglass"), ("查", "magnifyingglass"),
        ("跑", "play.fill"), ("run", "play.fill"), ("exec", "play.fill"),
        ("kill", "stop.fill"), ("stop", "stop.fill"), ("停", "stop.fill"),
        ("error", "exclamationmark.triangle.fill"), ("fail", "exclamationmark.triangle.fill"), ("错", "exclamationmark.triangle.fill"),
        ("done", "checkmark.circle.fill"), ("完成", "checkmark.circle.fill"), ("成功", "checkmark.circle.fill"), ("ok", "checkmark.circle.fill"),
        ("派", "person.fill.badge.plus"), ("dispatch", "person.fill.badge.plus"),
        ("枢", "person.crop.circle.fill"), ("sonnet", "person.crop.circle.fill"),
        ("delete", "trash.fill"), ("删", "trash.fill"),
        ("create", "plus.circle.fill"), ("新建", "plus.circle.fill"), ("加", "plus.circle.fill"),
        ("update", "arrow.up.circle.fill"), ("升级", "arrow.up.circle.fill"),
        ("install", "arrow.down.app.fill"),
        ("test", "checkerboard.shield"),
        ("commit", "checkmark.icloud.fill"), ("git", "arrow.triangle.branch"),
        ("server", "server.rack"),
        ("ipa", "shippingbox.fill"), ("testflight", "airplane"),
        ("api", "network"),
        ("hook", "link"),
        ("listen", "ear"), ("听", "ear"),
        ("speak", "waveform"), ("说", "bubble.right.fill"),
        ("notify", "bell.badge.fill"), ("通知", "bell.badge.fill"),
        ("monitor", "eye.fill"), ("watch", "eye.fill")
    ]
    for (kw, icon) in map {
        if t.contains(kw) { return icon }
    }
    return "circle.dashed"
}

// 第三方 app deep link 抓取 (bilibili / weixin / alipay / amap / dianping / didi 等)
func extractDeepLinks(in text: String) -> [URL] {
    let pattern = #"(bilibili|weixin|alipay|alipays|amap|iosamap|dianping|didi|sinaweibo|mqq|mqqapi|youku|iqiyi|qqmusic|netease|cloudmusic|douyin|snssdk1128|kwai|xhsdiscover|jdmobile|taobao|tmall|orpheus|spotify|youtube|tg|telegram|whatsapp|fb|fbauth|comgooglemaps|googlechrome|twitter|tweetbot)://[^\s]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, options: [], range: range)
    return matches.prefix(3).compactMap { m -> URL? in
        guard let r = Range(m.range, in: text) else { return nil }
        return URL(string: String(text[r]))
    }
}

// 相机拍照 picker — 系统 UIImagePickerController source=.camera
#if os(iOS)
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            // Bug 1 fix: flattenToSDR applies gain map so HDR photos are not dark
            if let img = info[.originalImage] as? UIImage,
               let data = img.flattenToSDR() {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif

// deep link 按钮 — bubble 下方渲染 tap 跳系统 app
struct DeepLinkButton: View {
    let url: URL

    var body: some View {
        Button(action: {
            #if os(iOS)
            UIApplication.shared.open(url)
            #endif
        }) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.ccSerifAdaptive(size: 16))
                    .foregroundStyle(Color.white)
                Text(label)
                    .font(.ccSerifAdaptive(size: 16, weight: .medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.ccSerifAdaptive(size: 11))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.50, blue: 0.25),
                        Color(red: 0.78, green: 0.35, blue: 0.15)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 280)
    }

    private var iconName: String {
        switch url.scheme?.lowercased() ?? "" {
        case "bilibili": return "tv.fill"
        case "weixin": return "bubble.left.fill"
        case "alipay", "alipays": return "yensign.circle.fill"
        case "amap", "iosamap", "comgooglemaps": return "map.fill"
        case "dianping": return "fork.knife"
        case "didi": return "car.fill"
        case "youku", "iqiyi", "youtube": return "play.rectangle.fill"
        case "qqmusic", "orpheus", "netease", "cloudmusic", "spotify": return "music.note"
        case "douyin", "snssdk1128", "kwai": return "video.fill"
        case "xhsdiscover": return "book.fill"
        case "jdmobile", "taobao", "tmall": return "bag.fill"
        case "tg", "telegram", "whatsapp", "twitter", "tweetbot", "fb", "fbauth": return "paperplane.fill"
        default: return "arrow.up.right.square.fill"
        }
    }

    private var label: String {
        let scheme = url.scheme?.lowercased() ?? ""
        let appName: String = {
            switch scheme {
            case "bilibili": return "B 站"
            case "weixin": return "微信"
            case "alipay", "alipays": return "支付宝"
            case "amap", "iosamap": return "高德"
            case "comgooglemaps": return "Google 地图"
            case "dianping": return "大众点评"
            case "didi": return "滴滴"
            case "youku": return "优酷"
            case "iqiyi": return "爱奇艺"
            case "qqmusic": return "QQ 音乐"
            case "netease", "cloudmusic", "orpheus": return "网易云"
            case "spotify": return "Spotify"
            case "douyin", "snssdk1128": return "抖音"
            case "kwai": return "快手"
            case "xhsdiscover": return "小红书"
            case "taobao", "tmall": return "淘宝"
            case "jdmobile": return "京东"
            case "youtube": return "YouTube"
            case "tg", "telegram": return "Telegram"
            case "whatsapp": return "WhatsApp"
            case "twitter", "tweetbot": return "Twitter"
            default: return scheme.capitalized
            }
        }()
        // 解析常见 query 给 hint — bilibili://search?keyword=X / amap://route?dname=Y / etc
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            if let kw = items.first(where: { ["keyword", "q", "query", "dname", "name"].contains($0.name) })?.value,
               !kw.isEmpty {
                return "打开 \(appName) · \(kw)"
            }
        }
        return "打开 \(appName)"
    }
}

// MARK: - 搜索结果摘要 row (微信式)

struct SearchResultRow: View {
    let message: ChatMessage
    let keyword: String
    @AppStorage("chat_font_size_level") private var chatFontLevel: String = "medium"
    private var chatBodySize: CGFloat { chatFontLevel == "small" ? 15 : chatFontLevel == "large" ? 18 : 17 }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // sender icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ccCard)
                CcAvatarView(role: message.isUser ? .user : .ai, size: 34)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.isUser ? CcNameResolver.name(for: .user) : CcNameResolver.name(for: .ai))
                        .font(.ccSerifAdaptive(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ccText)
                    Spacer()
                    Text(formatRelativeTime(message.ts))
                        .font(.ccSerifAdaptive(size: 11))
                        .foregroundStyle(Color.ccTextDim)
                }
                highlightedSnippet
                    .font(.ccSerifAdaptive(size: chatBodySize))
                    .foregroundStyle(Color.ccText)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    
            }
        }
        .padding(.vertical, 6)
    }

    private var highlightedSnippet: Text {
        let text = message.text.isEmpty
            ? (message.attachmentFilename.map { "[\($0)]" } ?? "[附件]")
            : message.text
        let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Text(text) }
        // 2026-05-07 用户 catch 显示不了原文 不截 ±20 字 全文显示 + keyword 高亮
        if let range = text.range(of: needle, options: .caseInsensitive) {
            let beforeKw = String(text[..<range.lowerBound])
            let kw = String(text[range])
            let afterKw = String(text[range.upperBound...])
            return Text(beforeKw)
                + Text(kw).foregroundStyle(Color.ccAccent).bold()
                + Text(afterKw)
        }
        return Text(text)
    }

    private func formatRelativeTime(_ ts: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: ts) else {
            return String(ts.prefix(10))
        }
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天"
        }
        let weekdaySymbols = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let comps = calendar.dateComponents([.weekday, .year], from: date)
        if let w = comps.weekday, comps.year == calendar.component(.year, from: now),
           now.timeIntervalSince(date) < 7 * 24 * 3600 {
            return weekdaySymbols[w]
        }
        let f = DateFormatter(); f.dateFormat = "M月d日"
        return f.string(from: date)
    }
}

/// 2026-05-07 用户 push: 多选复制成图片用的 lightweight renderer.
/// 用纯 SwiftUI VStack 渲选中的 message 不依赖 ChatBubble 那一档复杂依赖 (vm / quickLook / 等).
struct SelectedChatRenderer: View {
    let messages: [ChatMessage]
    let aiName: String

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ForEach(messages) { msg in
                    HStack(alignment: .top, spacing: 0) {
                        if msg.isUser { Spacer(minLength: 40) }

                        VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 4) {
                            Text(msg.isUser ? "眠" : aiName)
                                .font(.ccSerifAdaptive(size: 10, weight: .medium))
                                .foregroundStyle(Color.ccTextDim.opacity(0.8))
                                .padding(.horizontal, 4)

                            Text(msg.text)
                                .font(.ccSerifAdaptive(size: 14))
                                .foregroundStyle(msg.isUser ? Color.ccUserText : Color.ccAssistantText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(msg.isUser ? Color.ccUser : Color.ccAssistant)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .frame(maxWidth: 280, alignment: msg.isUser ? .trailing : .leading)

                        if !msg.isUser { Spacer(minLength: 40) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            // Phase D — footer watermark 删 (用户 push 长图无 from OTS 水印)
            // Spacer for bottom breathing room
            Color.clear.frame(height: 8)
        }
        .background(Color.ccBg)
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    var showTime: Bool = true
    var onChoiceSelect: ((String) -> Void)? = nil
    var onPreviewActiveChanged: ((Bool) -> Void)? = nil
    var onImageTap: ((URL) -> Void)? = nil  // 2026-05-07 用户 push 图片点击全屏 zoom 预览
    var onRegenerate: (() -> Void)? = nil
    // build 129 — 收藏整段 (turn 级 外挂 bookmark 按钮 仅最后 assistant turn 最后一条)
    var onFavoriteTurn: (() -> Void)? = nil
    @AppStorage("chat_font_size_level") private var chatFontLevel: String = "medium"
    private var chatBodySize: CGFloat { chatFontLevel == "small" ? 15 : chatFontLevel == "large" ? 18 : 17 }
    var onCopyText: (() -> Void)? = nil
    // 2026-05-12 optimistic send — bubble status indicator + retry
    var sendStatus: SendStatus = .sent
    var onRetry: (() -> Void)? = nil
    var onDiscardFailed: (() -> Void)? = nil
    @State private var quickLookURL: URL? = nil
    @State private var isDownloadingPreview: Bool = false
    // Phase 设置大砍 (item B) — observe favorite cache so bookmark icon flips state on tap
    @ObservedObject private var favoritedCache = FavoritedTurnsCache.shared

    var body: some View {
        Group {
            if message.role == "task" {
                // 右侧轻量 pill — rail 上有小 dot 节点 不再居中撑满
                HStack(spacing: 6) {
                    Image(systemName: iconForTaskText(message.text))
                        .font(.ccSerifAdaptive(size: 11))
                        .foregroundStyle(Color.ccTextDim)
                    Text(message.text)
                        .font(.ccSerifAdaptive(size: 11, weight: .medium))
                        .foregroundStyle(Color.ccTextDim)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.ccCard.opacity(0.5))
                .clipShape(Capsule())
            } else {
                chatRow
            }
        }
        // 2026-05-07 用户 push bubble 两侧对称内缩 16pt (之前 assistant 紧贴左边)
        .padding(.horizontal, 16)
        // Bug 3 fix: notify parent when QuickLook preview opens/closes
        .onChange(of: quickLookURL) { _, newURL in
            onPreviewActiveChanged?(newURL != nil)
        }
    }

    private var chatRow: some View {
        // Phase G2 2026-05-11 用户 push — bubble 靠 row 自己那侧 (AI 左 / USER 右), timestamp 在 bubble 下方同侧 (caption 风格).
        HStack(alignment: .bottom, spacing: 0) {
            if message.isUser { Spacer(minLength: 40) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 2) {
                if let q = message.quotedText, !q.isEmpty {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Color.ccAccent)
                            .frame(width: 2)
                        Text(q)
                            .font(.ccSerifAdaptive(size: 11))
                            .foregroundStyle(Color.ccTextDim)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(maxWidth: 240, alignment: message.isUser ? .trailing : .leading)
                }
                if message.hasMultiLangAudio {
                    AudioPlayerButton(audios: message.multiLangAudios())
                }
                if let url = message.attachmentFullURL() {
                    if message.attachmentType == "audio" {
                        AudioPlayerButton(audios: ["zh": url])
                    } else if message.attachmentType == "image" {
                        CachedImage(url: url) { img in
                            img.resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240, maxHeight: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } placeholder: {
                            ProgressView()
                                .frame(width: 200, height: 150)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onImageTap?(url) }
                    } else {
                        Button {
                            openWithQuickLook(remoteURL: url, filename: message.attachmentFilename ?? "附件")
                        } label: {
                            HStack(spacing: 8) {
                                if isDownloadingPreview {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 28, height: 28)
                                } else {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.ccAccent.opacity(0.18))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: iconForFile(message.attachmentFilename))
                                            .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                                            .foregroundStyle(Color.ccAccent)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(message.attachmentFilename ?? "附件")
                                        .font(.ccSerifAdaptive(size: 16, weight: .medium))
                                        .foregroundStyle(Color.ccText)
                                        .lineLimit(1)
                                    Text(isDownloadingPreview ? "加载中..." : "点击预览")
                                        .font(.ccSerifAdaptive(size: 11))
                                        .foregroundStyle(Color.ccTextDim)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.ccCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.ccAccent.opacity(0.15), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isDownloadingPreview)
                        #if canImport(QuickLook)
                        .quickLookPreview($quickLookURL)
                        #endif
                    }
                }
                if !message.text.isEmpty {
                    let segments = parseBubbleSegments(message.text)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                            switch seg {
                            case .text(let s):
                                // 2026-05-14 build 190 — 删 .textSelection 加 inner contextMenu, 让外层 row 的
                                // 大 contextMenu (选择多条 / 引用回复 / 复制本条 / 重新说 / 收藏 / 删除) 能正确响应
                                // 长按. 之前 List 时代 row-level 长按优先于 inner text 选词, LazyVStack 没这条
                                // magic 所以 inner 选词菜单覆盖了外层. 这次以外层菜单为准, 失去单词级选择能力,
                                // 通过外层"复制本条"补全复制路径, 翻译走外层 (下面 row contextMenu 增加).
                                Text(s)
                                    .font(.ccSerifAdaptive(size: chatBodySize))
                                    .foregroundStyle(message.isUser ? Color.ccUserText : Color.ccAssistantText)
                            case .codeBlock(let lang, let code):
                                VStack(alignment: .leading, spacing: 4) {
                                    if let lang, !lang.isEmpty {
                                        Text(lang)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        Text(code)
                                            .font(.system(.footnote, design: .monospaced))
                                            .textSelection(.enabled)
                                            .foregroundStyle(.white)
                                            .padding(.vertical, 2)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: 280, alignment: .leading)
                                .background(Color.black.opacity(0.45))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isUser ? Color.ccUser : Color.ccAssistant)
                    .foregroundStyle(message.isUser ? Color.ccUserText : Color.ccAssistantText)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if let loc = message.location {
                    Button {
                        openAppleMaps(lat: loc.lat, lon: loc.lon, label: loc.label ?? "位置")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "location.fill")
                                .font(.ccSerifAdaptive(size: 22, weight: .bold))
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.label ?? "位置")
                                    .font(.ccSerifAdaptive(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                                Text(String(format: "%.5f, %.5f", loc.lat, loc.lon))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                if let acc = loc.accuracy {
                                    Text("精度 ±\(Int(acc))m")
                                        .font(.ccSerifAdaptive(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(white: 0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                if let meta = message.metadata, meta.kind == "choice",
                   let opts = meta.options, !opts.isEmpty {
                    choiceButtons(opts)
                }
                // 2026-05-10 用户 push small card 比 inline button 更明显 但不撑 bubble (~60pt 高)
                #if canImport(LinkPresentation) && os(iOS)
                if let firstURL = extractFirstURL(in: message.text) {
                    LinkPreviewView(url: firstURL)
                        .frame(maxWidth: 280, minHeight: 56, idealHeight: 60, maxHeight: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.top, 4)
                }
                #endif
                let deeplinks = extractDeepLinks(in: message.text)
                if !deeplinks.isEmpty {
                    VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                        ForEach(deeplinks, id: \.absoluteString) { url in
                            DeepLinkButton(url: url)
                        }
                    }
                }
                if let reactions = message.reactions, !reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(Set(reactions)), id: \.self) { emoji in
                            let count = reactions.filter { $0 == emoji }.count
                            HStack(spacing: 2) {
                                Text(emoji).font(.ccSerifAdaptive(size: 12))
                                if count > 1 {
                                    Text("\(count)")
                                        .font(.ccSerifAdaptive(size: 11))
                                        .foregroundStyle(Color.ccTextDim)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.ccCard)
                            .clipShape(Capsule())
                        }
                    }
                }
                // Phase G2 2026-05-11 用户 push — timestamp 在 bubble 下方同侧 (caption 风格). copy/bookmark 紧跟其后 (assistant only).
                if showTime || (!message.isUser && (onCopyText != nil || onFavoriteTurn != nil)) || (message.isUser && sendStatus != .sent) {
                    HStack(spacing: 6) {
                        // 2026-05-12 optimistic-send: sending spinner / failed retry icon (user side only).
                        if message.isUser, sendStatus == .sending {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else if message.isUser, sendStatus == .failed, let retry = onRetry {
                            Menu {
                                Button(action: retry) {
                                    Label("重新发送", systemImage: "arrow.clockwise")
                                }
                                Button {
                                    UIPasteboard.general.string = message.text
                                } label: {
                                    Label("复制文字", systemImage: "doc.on.doc")
                                }
                                if let discard = onDiscardFailed {
                                    Divider()
                                    Button(role: .destructive, action: discard) {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            } label: {
                                Image(systemName: "exclamationmark.arrow.circlepath")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.866, green: 0.314, blue: 0.314))
                            }
                            .menuStyle(.button)
                            .accessibilityLabel("发送失败 长按重试或删除")
                            .simultaneousGesture(TapGesture().onEnded { retry() })
                        }
                        if showTime {
                            Text(displayTime(message.ts))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(message.isUser && sendStatus == .failed
                                                 ? Color(red: 0.866, green: 0.314, blue: 0.314).opacity(0.7)
                                                 : Color.ccTextDim)
                        }
                        if !message.isUser, let fn = onCopyText {
                            Button(action: fn) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.ccTextDim)
                            }
                            .buttonStyle(.plain)
                        }
                        if !message.isUser, let fn = onFavoriteTurn {
                            Button(action: fn) {
                                let favorited = favoritedCache.contains(message.ts)
                                Image(systemName: favorited ? "bookmark.fill" : "bookmark")
                                    .font(.system(size: 12))
                                    .foregroundStyle(favorited ? Color.ccAccent : Color.ccTextDim)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .fixedSize()
                    .padding(.top, 2)
                }
            }
            if !message.isUser { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private func choiceButtons(_ options: [ChoiceOption]) -> some View {
        // 整个 list 一张卡 内部 row 用 divider 分 不再每个 option 一个 bubble
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                if idx > 0 {
                    Divider()
                        .background(Color.ccAssistant.opacity(0.18))
                }
                choiceRow(opt, index: idx)
            }
        }
        .frame(maxWidth: 280)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ccCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.ccAssistant.opacity(0.25), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func choiceRow(_ opt: ChoiceOption, index: Int) -> some View {
        Button {
            onChoiceSelect?(opt.value)
        } label: {
            HStack(spacing: 10) {
                // 字母编号 ABCD
                Text(String(UnicodeScalar(0x41 + min(index, 25))!))
                    .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.ccAccent.opacity(0.14)))
                Text(opt.label)
                    .font(.system(.callout, design: .serif))  // New York 衬线 偏手帐
                    .foregroundStyle(Color.ccAccent)  // 橘红 不再黑
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.ccSerifAdaptive(size: 11))
                    .foregroundStyle(Color.ccTextDim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openAppleMaps(lat: Double, lon: Double, label: String) {
        let q = label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? label
        let urlStr = "http://maps.apple.com/?ll=\(lat),\(lon)&q=\(q)"
        if let url = URL(string: urlStr) {
            #if os(iOS)
            UIApplication.shared.open(url)
            #endif
        }
    }

    private func displayTime(_ ts: String) -> String {
        // 简单截 HH:mm
        let parts = ts.split(separator: "T")
        if parts.count >= 2 {
            let timePart = parts[1].prefix(5)
            return String(timePart)
        }
        return ts
    }

    private func iconForFile(_ name: String?) -> String {
        let ext = (name as NSString?)?.pathExtension.lowercased() ?? ""
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "md", "txt", "log": return "doc.text.fill"
        case "zip", "tar", "gz": return "doc.zipper"
        case "mp3", "wav", "m4a": return "waveform.circle.fill"
        case "mov", "mp4": return "play.rectangle.fill"
        case "csv", "xlsx": return "tablecells.fill"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        default: return "doc.fill"
        }
    }

    private func openWithQuickLook(remoteURL: URL, filename: String) {
        guard !isDownloadingPreview else { return }
        isDownloadingPreview = true
        Task {
            let localURL = await downloadToCache(remoteURL: remoteURL, filename: filename)
            await MainActor.run {
                isDownloadingPreview = false
                quickLookURL = localURL
            }
        }
    }

    private func downloadToCache(remoteURL: URL, filename: String) async -> URL? {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let previewDir = cachesDir.appendingPathComponent("cc_preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
        // 用 server 路径 hash + 原 filename 保留扩展名 — 不重复下载
        let safeName = "\(abs(remoteURL.absoluteString.hashValue))_\(filename)"
        let localURL = previewDir.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        do {
            let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
            try? FileManager.default.removeItem(at: localURL)
            try FileManager.default.moveItem(at: tmpURL, to: localURL)
            return localURL
        } catch {
            print("[ChatBubble] download fail: \(error)")
            return nil
        }
    }
}

#Preview {
    NavigationStack {
        ChatView()
    }
}
#if os(iOS)
import SwiftUI
import PencilKit
import UIKit

// 2026-05-07 用户 push: 微信式发送前编辑 五工具 涂鸦 / 文字 / 马赛克 / 裁剪 / 旋转
private enum PhotoEditMode: Hashable {
    case draw, text, mosaic, crop, rotate
}

private struct PhotoTextOverlay: Identifiable, Hashable {
    let id: UUID = UUID()
    var text: String
    var posNorm: CGPoint  // 归一化坐标 0..1 相对 image displayed frame
    var fontSize: CGFloat = 28
    var colorIndex: Int = 0  // 0=white 1=red 2=yellow 3=black
}

struct PhotoEditView: View {
    let imageData: Data
    let onComplete: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var currentData: Data
    @State private var rotation: Double = 0
    @State private var canvasView = PKCanvasView()
    @State private var toolPicker = PKToolPicker()
    @State private var showTools: Bool = false  // 2026-05-07 隐 PKToolPicker 不让它系统级浮起盖住底部 5-tab
    @State private var mode: PhotoEditMode = .draw
    @State private var textItems: [PhotoTextOverlay] = []
    @State private var mosaicLevel: Int = 0  // 0=off 1=10px 2=20px 3=40px
    @State private var showCropSheet: Bool = false
    @State private var editingTextID: UUID? = nil
    @State private var draftText: String = ""
    @State private var selectedDrawColor: UIColor = .black
    @State private var selectedDrawWidth: CGFloat = 8.0

    private static let textColors: [Color] = [.white, .red, .yellow, .black]
    private static let mosaicScales: [CGFloat] = [0, 10, 20, 40]
    private static let drawColors: [UIColor] = [.black, .systemRed, .systemBlue, .systemGreen, .systemOrange, .white]
    private static let drawWidths: [CGFloat] = [4.0, 8.0, 14.0]

    init(imageData: Data, onComplete: @escaping (Data) -> Void) {
        self.imageData = imageData
        self.onComplete = onComplete
        _currentData = State(initialValue: imageData)
    }

    private var uiImage: UIImage {
        UIImage(data: currentData) ?? UIImage()
    }

    private var displayedImage: UIImage {
        var img = uiImage
        if mosaicLevel > 0 {
            img = applyMosaic(img, scale: PhotoEditView.mosaicScales[mosaicLevel])
        }
        return img
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // 顶部 toolbar 取消 / 完成
                HStack(spacing: 16) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }

                    Spacer()

                    Button(action: undoStroke) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .disabled(mode != .draw)
                    .opacity(mode == .draw ? 1 : 0.4)

                    Button(action: clearAll) {
                        Image(systemName: "trash")
                            .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }

                    Spacer()

                    Button(action: complete) {
                        Text("完成")
                            .font(.ccSerifAdaptive(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.95, green: 0.50, blue: 0.25), Color(red: 0.78, green: 0.35, blue: 0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, max(geo.safeAreaInsets.top, 50) + 8)
                .padding(.bottom, 8)

                // 编辑区 image + canvas + text overlays
                GeometryReader { editGeo in
                    ZStack {
                        Image(uiImage: displayedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: editGeo.size.width, height: editGeo.size.height)
                            .contentShape(Rectangle())
                            .onTapGesture { loc in
                                if mode == .text {
                                    let normX = loc.x / editGeo.size.width
                                    let normY = loc.y / editGeo.size.height
                                    let item = PhotoTextOverlay(text: "", posNorm: CGPoint(x: normX, y: normY))
                                    textItems.append(item)
                                    editingTextID = item.id
                                    draftText = ""
                                }
                            }

                        if mode == .draw {
                            PencilCanvas(canvasView: $canvasView, toolPicker: $toolPicker, isVisible: $showTools)
                                .background(Color.clear)
                                .frame(width: editGeo.size.width, height: editGeo.size.height)
                        }

                        ForEach($textItems) { $item in
                            PhotoTextItemView(
                                item: $item,
                                containerSize: editGeo.size,
                                isEditing: editingTextID == item.id,
                                onCommit: { editingTextID = nil; draftText = "" },
                                onDelete: { textItems.removeAll { $0.id == item.id } }
                            )
                        }
                    }
                    .rotationEffect(.degrees(rotation))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)

                // 底部 5-tab 工具栏
                HStack(spacing: 0) {
                    toolButton(icon: "scribble", label: "涂鸦", target: .draw)
                    toolButton(icon: "textformat", label: "文字", target: .text)
                    toolButton(icon: "mosaic", label: "马赛克", target: .mosaic, fallback: "square.grid.3x3.square")
                    toolButton(icon: "crop", label: "裁剪", target: .crop)
                    toolButton(icon: "rotate.right.fill", label: "旋转", target: .rotate)
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, max(geo.safeAreaInsets.bottom, 12))
                .background(Color.black.opacity(0.55))

                // 模式专属浮动控制条
                modeControlBar()
                    .padding(.bottom, 4)
            }
            .background(Color.black)
            .ignoresSafeArea()
            .sheet(isPresented: $showCropSheet) {
                ImageCropper(imageData: currentData) { croppedData in
                    currentData = croppedData
                    rotation = 0  // crop 完后旋转重置 (crop 已应用旋转后视图)
                    showCropSheet = false
                } onCancel: {
                    showCropSheet = false
                }
            }
            .onAppear { applyDrawTool() }
            .onChange(of: mode) { _, newMode in
                if newMode == .draw { applyDrawTool() }
            }
        }
    }

    @ViewBuilder
    private func toolButton(icon: String, label: String, target: PhotoEditMode, fallback: String? = nil) -> some View {
        Button {
            switch target {
            case .rotate:
                rotate90()
            case .crop:
                showCropSheet = true
            default:
                mode = target
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: UIImage(systemName: icon) != nil ? icon : (fallback ?? icon))
                    .font(.ccSerifAdaptive(size: 20, weight: .semibold))
                Text(label).font(.ccSerifAdaptive(size: 11))
            }
            .foregroundStyle(mode == target ? Color.ccAccent : Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func applyDrawTool() {
        canvasView.tool = PKInkingTool(.pen, color: selectedDrawColor, width: selectedDrawWidth)
    }

    @ViewBuilder
    private func modeControlBar() -> some View {
        if mode == .draw {
            HStack(spacing: 14) {
                ForEach(PhotoEditView.drawColors, id: \.self) { c in
                    Button {
                        selectedDrawColor = c
                        applyDrawTool()
                    } label: {
                        Circle()
                            .fill(Color(c))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().stroke(selectedDrawColor == c ? Color.white : Color.white.opacity(0.3), lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Divider().frame(height: 16).background(Color.white.opacity(0.3))
                ForEach(PhotoEditView.drawWidths, id: \.self) { w in
                    Button {
                        selectedDrawWidth = w
                        applyDrawTool()
                    } label: {
                        Circle()
                            .fill(Color.white)
                            .frame(width: w + 4, height: w + 4)
                            .overlay(
                                Circle().stroke(selectedDrawWidth == w ? Color.ccAccent : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        } else if mode == .mosaic {
            HStack(spacing: 12) {
                Text("马赛克").font(.ccSerifAdaptive(size: 12)).foregroundStyle(.white.opacity(0.7))
                ForEach(0..<4, id: \.self) { lvl in
                    Button {
                        mosaicLevel = lvl
                    } label: {
                        Text(lvl == 0 ? "关" : "\(Int(PhotoEditView.mosaicScales[lvl]))")
                            .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(mosaicLevel == lvl ? Color.ccAccent : Color.white.opacity(0.15))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        } else if mode == .text {
            HStack(spacing: 8) {
                Text("点图加文字 长按拖动").font(.ccSerifAdaptive(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        } else {
            Color.clear.frame(height: 24)
        }
    }

    private func rotate90() {
        withAnimation(.easeInOut(duration: 0.25)) {
            rotation += 90
            if rotation >= 360 { rotation -= 360 }
        }
    }

    private func undoStroke() {
        var strokes = canvasView.drawing.strokes
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        canvasView.drawing = PKDrawing(strokes: strokes)
    }

    private func clearAll() {
        canvasView.drawing = PKDrawing()
        textItems.removeAll()
        mosaicLevel = 0
    }

    private func applyMosaic(_ image: UIImage, scale: CGFloat) -> UIImage {
        guard scale > 0, let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(scale, forKey: kCIInputScaleKey)
        let context = CIContext(options: nil)
        guard let output = filter?.outputImage,
              let cgImage = context.createCGImage(output, from: ciImage.extent) else {
            return image
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private func complete() {
        let baseImage = displayedImage  // 已含 mosaic
        let rotated = rotateImage(baseImage, degrees: rotation)
        let finalSize = rotated.size

        let drawingBounds = canvasView.bounds.size
        var drawingImage: UIImage? = nil
        if drawingBounds.width > 0 && drawingBounds.height > 0 {
            drawingImage = canvasView.drawing.image(from: canvasView.bounds, scale: UIScreen.main.scale)
        }

        let sdrFmt = UIGraphicsImageRendererFormat.default()
        sdrFmt.preferredRange = .standard
        sdrFmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: finalSize, format: sdrFmt)
        let merged = renderer.image { ctx in
            rotated.draw(in: CGRect(origin: .zero, size: finalSize))
            if let d = drawingImage {
                let dRect = CGRect(origin: .zero, size: finalSize)
                d.draw(in: dRect, blendMode: .normal, alpha: 1.0)
            }
            // 文字 overlay 烘焙到底图 (旋转之后坐标按 finalSize 重新解释)
            for item in textItems where !item.text.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: item.fontSize * (finalSize.width / 375.0), weight: .semibold),
                    .foregroundColor: PhotoEditView.uiColor(item.colorIndex)
                ]
                let str = NSAttributedString(string: item.text, attributes: attrs)
                let textSize = str.size()
                let cx = item.posNorm.x * finalSize.width
                let cy = item.posNorm.y * finalSize.height
                let rect = CGRect(x: cx - textSize.width / 2, y: cy - textSize.height / 2,
                                  width: textSize.width, height: textSize.height)
                str.draw(in: rect)
            }
        }

        if let outData = merged.jpegData(compressionQuality: 0.85) {
            onComplete(outData)
        }
        dismiss()
    }

    private static func uiColor(_ idx: Int) -> UIColor {
        switch idx {
        case 1: return .red
        case 2: return .yellow
        case 3: return .black
        default: return .white
        }
    }

    private func rotateImage(_ image: UIImage, degrees: Double) -> UIImage {
        guard degrees != 0 else { return image }
        let radians = degrees * .pi / 180
        var newSize = CGRect(origin: .zero, size: image.size)
            .applying(CGAffineTransform(rotationAngle: radians))
            .integral.size
        newSize.width = floor(newSize.width)
        newSize.height = floor(newSize.height)

        let sdrFmt = UIGraphicsImageRendererFormat.default()
        sdrFmt.preferredRange = .standard
        sdrFmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: sdrFmt)
        return renderer.image { ctx in
            let context = ctx.cgContext
            context.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            context.rotate(by: radians)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
        }
    }
}

private struct PhotoTextItemView: View {
    @Binding var item: PhotoTextOverlay
    let containerSize: CGSize
    let isEditing: Bool
    let onCommit: () -> Void
    let onDelete: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var editing: Bool = false

    private static let colors: [Color] = [.white, .red, .yellow, .black]

    var body: some View {
        let centerX = item.posNorm.x * containerSize.width + dragOffset.width
        let centerY = item.posNorm.y * containerSize.height + dragOffset.height

        Group {
            if editing || isEditing || item.text.isEmpty {
                TextField("文字", text: $item.text, onCommit: {
                    editing = false
                    if item.text.isEmpty { onDelete() } else { onCommit() }
                })
                .font(.system(size: item.fontSize, weight: .semibold))
                .foregroundStyle(PhotoTextItemView.colors[item.colorIndex])
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onAppear { editing = true }
            } else {
                Text(item.text)
                    .font(.system(size: item.fontSize, weight: .semibold))
                    .foregroundStyle(PhotoTextItemView.colors[item.colorIndex])
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.001))
                    .onTapGesture { editing = true }
                    .contextMenu {
                        Button("换色") {
                            item.colorIndex = (item.colorIndex + 1) % PhotoTextItemView.colors.count
                        }
                        Button("放大") { item.fontSize = min(item.fontSize + 6, 80) }
                        Button("缩小") { item.fontSize = max(item.fontSize - 6, 14) }
                        Button(role: .destructive) {
                            onDelete()
                        } label: { Text("删除") }
                    }
            }
        }
        .position(x: centerX, y: centerY)
        .gesture(
            DragGesture()
                .onChanged { v in dragOffset = v.translation }
                .onEnded { v in
                    let newCx = (item.posNorm.x * containerSize.width) + v.translation.width
                    let newCy = (item.posNorm.y * containerSize.height) + v.translation.height
                    item.posNorm = CGPoint(
                        x: max(0, min(1, newCx / containerSize.width)),
                        y: max(0, min(1, newCy / containerSize.height))
                    )
                    dragOffset = .zero
                }
        )
    }
}

struct PencilCanvas: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @Binding var toolPicker: PKToolPicker
    @Binding var isVisible: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        toolPicker.setVisible(isVisible, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        DispatchQueue.main.async {
            canvasView.becomeFirstResponder()
        }
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        toolPicker.setVisible(isVisible, forFirstResponder: uiView)
    }
}

// Bug 1 fix: flatten HDR gain-map image to SDR sRGB JPEG before upload.
// iPhone 16 Pro HDR photos store base SDR frame at near-zero luminance;
// all brightness lives in the gain map. jpegData() on the raw UIImage gives
// the dark base frame. Rendering through UIGraphicsImageRenderer(.standard)
// composites the gain map and produces the display-correct SDR result.
private extension UIImage {
    func flattenToSDR(quality: CGFloat = 0.85) -> Data? {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.preferredRange = .standard
        fmt.scale = scale
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        let flat = renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
        return flat.jpegData(compressionQuality: quality)
    }
}
#endif

// 2026-05-07 用户 push 图片点击全屏 zoom 预览 — 我发的图跟用户发的图都能预览
struct ImagePreviewURL: Identifiable {
    let id = UUID()
    let url: URL
}

#if os(iOS)
struct ImagePreviewView: View {
    let url: URL
    let onClose: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showActionSheet: Bool = false
    @State private var loadedImage: UIImage? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CachedImage(url: url) { img in
                img.resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
            } placeholder: {
                ProgressView().tint(.white)
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { v in scale = max(0.5, min(8.0, lastScale * v)) }
                    .onEnded { _ in lastScale = scale }
                    .simultaneously(with:
                        DragGesture()
                            .onChanged { v in
                                offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if scale > 1.01 {
                        scale = 1.0; lastScale = 1.0
                        offset = .zero; lastOffset = .zero
                    } else {
                        scale = 2.5; lastScale = 2.5
                    }
                }
            }
            .onTapGesture(count: 1) {
                if scale <= 1.01 { onClose() }
            }
            .onLongPressGesture { showActionSheet = true }

            VStack {
                HStack {
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(Color.white.opacity(0.85))
                            .padding(16)
                    }
                }
                Spacer()
                HStack(spacing: 24) {
                    Button {
                        Task { await saveToPhotos() }
                    } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                            .foregroundStyle(.white)
                    }
                    if let img = loadedImage {
                        ShareLink(item: Image(uiImage: img), preview: SharePreview("图片", image: Image(uiImage: img))) {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .confirmationDialog("图片操作", isPresented: $showActionSheet) {
            Button("保存到相册") { Task { await saveToPhotos() } }
            Button("取消", role: .cancel) {}
        }
        .task { await loadImage() }
    }

    private func loadImage() async {
        do {
            let (data, _) = try await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url))
            if let img = UIImage(data: data) {
                await MainActor.run { loadedImage = img }
            }
        } catch {}
    }

    private func saveToPhotos() async {
        if loadedImage == nil { await loadImage() }
        guard let img = loadedImage else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
    }
}
#endif

// MARK: - 2026-05-08 用户 push 取词翻译 — 有道式 free-select + 自动翻译 popover

#if canImport(Translation)
import Translation
#endif

/// 选中 ≥ 2 字符 0.2s 后自动出 Apple Translation system sheet (iOS 17.4+ / macCatalyst 17.4+).
/// 老版本 fallback SwiftUI Text + .textSelection (保留 word-by-word).
struct SelectableMarkdownText: View {
    let raw: String
    let textColor: UIColor

    @State private var selectedText: String = ""
    @State private var showTranslation: Bool = false

    var body: some View {
        #if targetEnvironment(macCatalyst)
        // translationPresentation unavailable on Mac Catalyst at compile time; Mac uses youdao popover instead
        if #available(iOS 17.4, macCatalyst 17.4, *) {
            SelectableUITextWrapper(
                raw: raw,
                textColor: textColor,
                selectedText: $selectedText,
                showTranslation: $showTranslation
            )
        } else {
            Text(renderMarkdown(raw))
                .textSelection(.enabled)
        }
        #else
        if #available(iOS 17.4, *) {
            SelectableUITextWrapper(
                raw: raw,
                textColor: textColor,
                selectedText: $selectedText,
                showTranslation: $showTranslation
            )
            .translationPresentation(isPresented: $showTranslation, text: selectedText)
        } else {
            Text(renderMarkdown(raw))
                .textSelection(.enabled)
        }
        #endif
    }
}

private struct SelectableUITextWrapper: UIViewRepresentable {
    let raw: String
    let textColor: UIColor
    @Binding var selectedText: String
    @Binding var showTranslation: Bool

    func makeUIView(context: Context) -> IntrinsicSelectableTextView {
        let tv = IntrinsicSelectableTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.delegate = context.coordinator
        tv.dataDetectorTypes = [.link]
        tv.tintColor = UIColor(Color.ccAccent)
        tv.linkTextAttributes = [
            .foregroundColor: UIColor(Color.ccAccent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        tv.adjustsFontForContentSizeCategory = true
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: IntrinsicSelectableTextView, context: Context) {
        let attr = renderMarkdown(raw)
        let nsBase: NSAttributedString = (try? NSAttributedString(attr, including: \.uiKit))
            ?? NSAttributedString(string: String(attr.characters))
        let ns = NSMutableAttributedString(attributedString: nsBase)
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let full = NSRange(location: 0, length: ns.length)
        ns.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            var newAttrs = attrs
            if newAttrs[NSAttributedString.Key.foregroundColor] == nil {
                newAttrs[NSAttributedString.Key.foregroundColor] = textColor
            }
            if let curFont = newAttrs[NSAttributedString.Key.font] as? UIFont {
                let descriptor = curFont.fontDescriptor
                let merged = UIFont(descriptor: descriptor, size: bodyFont.pointSize)
                newAttrs[NSAttributedString.Key.font] = merged
            } else {
                newAttrs[NSAttributedString.Key.font] = bodyFont
            }
            ns.setAttributes(newAttrs, range: range)
        }
        tv.attributedText = ns
        tv.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableUITextWrapper
        var debounce: DispatchWorkItem?

        init(_ p: SelectableUITextWrapper) { self.parent = p }

        func textViewDidChangeSelection(_ tv: UITextView) {
            debounce?.cancel()
            let captured = tv.selectedRange
            let textCopy = tv.text ?? ""
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if captured.length < 2 {
                    if self.parent.showTranslation {
                        self.parent.showTranslation = false
                    }
                    return
                }
                let ns = textCopy as NSString
                guard captured.location + captured.length <= ns.length else { return }
                let snippet = ns.substring(with: captured).trimmingCharacters(in: .whitespacesAndNewlines)
                guard snippet.count >= 2 else { return }
                self.parent.selectedText = snippet
                self.parent.showTranslation = true
            }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }
}

final class IntrinsicSelectableTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        let targetWidth = bounds.width > 0 ? bounds.width : preferredMaxLayoutWidth
        let width = targetWidth > 0 ? targetWidth : 280
        let fitting = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fitting.height))
    }

    private var preferredMaxLayoutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != preferredMaxLayoutWidth {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

// MARK: - 2026-05-08 search Phase1+2 — state-driven search results UI

/// 渲 search 状态 + 分 tab dispatch row 类型. 共享同一个 jumpToMessage 回调.
struct SearchStateContent: View {
    @ObservedObject var vm: ChatViewModel
    let proxy: ScrollViewProxy
    var onImageTap: ((URL) -> Void)? = nil

    var body: some View {
        switch vm.searchState {
        case .idle:
            EmptyView()
        case .searching:
            SearchPlaceholderRow(icon: nil, title: "搜索中…", showProgress: true)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
        case .empty:
            SearchPlaceholderRow(icon: "magnifyingglass", title: "没找到相关消息")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
        case .error(let msg):
            SearchPlaceholderRow(icon: "exclamationmark.triangle", title: msg)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
        case .results:
            resultsList
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        let groups = ChatListView.groupByTime(vm.displayedMessages)
        let order = ["本周", "这个月", "更早"]
        switch vm.searchFilter {
        case .all:
            ForEach(vm.displayedMessages) { msg in
                SearchResultRow(message: msg, keyword: vm.searchText)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .onTapGesture { Task { await vm.jumpToMessage(msg) } }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
        case .image:
            // 2026-05-08 patch1: 微信式 4 列 grid + 长按菜单
            ForEach(order, id: \.self) { section in
                if let msgs = groups[section], !msgs.isEmpty {
                    sectionHeader(section)
                    ImageGridSection(
                        messages: msgs,
                        onTapImage: { url in onImageTap?(url) },
                        onJumpToMessage: { msg in Task { await vm.jumpToMessage(msg) } }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                }
            }
        case .file:
            ForEach(order, id: \.self) { section in
                if let msgs = groups[section], !msgs.isEmpty {
                    sectionHeader(section)
                    ForEach(msgs) { msg in
                        FileResultRow(message: msg)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .onTapGesture { Task { await vm.jumpToMessage(msg) } }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
        case .link:
            ForEach(order, id: \.self) { section in
                if let msgs = groups[section], !msgs.isEmpty {
                    sectionHeader(section)
                    ForEach(msgs) { msg in
                        LinkResultRow(message: msg)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .onTapGesture { Task { await vm.jumpToMessage(msg) } }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
        case .audio:
            ForEach(order, id: \.self) { section in
                if let msgs = groups[section], !msgs.isEmpty {
                    sectionHeader(section)
                    ForEach(msgs) { msg in
                        AudioResultRow(message: msg)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .onTapGesture { Task { await vm.jumpToMessage(msg) } }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.ccSerifAdaptive(size: 11))
            .foregroundStyle(Color.ccTextDim.opacity(0.6))
            .textCase(.uppercase)
            .padding(.leading, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }
}

struct SearchPlaceholderRow: View {
    let icon: String?
    let title: String
    var showProgress: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            if showProgress {
                ProgressView().controlSize(.regular)
            } else if let icon {
                Image(systemName: icon)
                    .font(.ccSerifAdaptive(size: 28))
                    .foregroundStyle(Color.ccTextDim.opacity(0.6))
            }
            Text(title)
                .font(.ccSerifAdaptive(size: 14))
                .foregroundStyle(Color.ccTextDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

struct FileResultRow: View {
    let message: ChatMessage

    private var filename: String {
        message.attachmentFilename ?? (message.text.isEmpty ? "未命名文件" : message.text)
    }
    private var ext: String {
        let n = filename
        if let idx = n.lastIndex(of: ".") {
            return String(n[n.index(after: idx)...]).lowercased()
        }
        return ""
    }
    private var icon: String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx": return "rectangle.on.rectangle"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox"
        case "txt", "md", "rtf": return "doc.plaintext"
        default: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ccCard)
                Image(systemName: icon)
                    .font(.ccSerifAdaptive(size: 20))
                    .foregroundStyle(Color.ccAccent)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(filename)
                    .font(.ccSerifAdaptive(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ccText)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if !ext.isEmpty {
                        Text(ext.uppercased())
                            .font(.ccSerifAdaptive(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.ccCard))
                    }
                    Text(formatRelativeTime(message.ts))
                        .font(.ccSerifAdaptive(size: 11))
                        .foregroundStyle(Color.ccTextDim)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func formatRelativeTime(_ ts: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: ts) else { return String(ts.prefix(10)) }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let g = DateFormatter(); g.dateFormat = "HH:mm"; return g.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "昨天" }
        let g = DateFormatter(); g.dateFormat = "M月d日"; return g.string(from: date)
    }
}

struct LinkResultRow: View {
    let message: ChatMessage

    private var url: URL? { extractFirstURL(in: message.text) }
    private var host: String { url?.host ?? "链接" }
    private var title: String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ccCard)
                Image(systemName: "link")
                    .font(.ccSerifAdaptive(size: 18))
                    .foregroundStyle(Color.ccAccent)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(host)
                    .font(.ccSerifAdaptive(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
                    .lineLimit(1)
                Text(title)
                    .font(.ccSerifAdaptive(size: 14))
                    .foregroundStyle(Color.ccText)
                    .lineLimit(2)
                Text(formatRelativeTime(message.ts))
                    .font(.ccSerifAdaptive(size: 11))
                    .foregroundStyle(Color.ccTextDim)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func formatRelativeTime(_ ts: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: ts) else { return String(ts.prefix(10)) }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let g = DateFormatter(); g.dateFormat = "HH:mm"; return g.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "昨天" }
        let g = DateFormatter(); g.dateFormat = "M月d日"; return g.string(from: date)
    }
}

struct AudioResultRow: View {
    let message: ChatMessage

    private var sender: String {
        message.isUser ? CcNameResolver.name(for: .user) : CcNameResolver.name(for: .ai)
    }
    private var durationText: String {
        // ChatMessage 当前没存音频时长 (metadata 仅 kind/options) — 占位 "音频" 等下一阶段补
        return "音频"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ccCard)
                Image(systemName: "waveform")
                    .font(.ccSerifAdaptive(size: 20))
                    .foregroundStyle(Color.ccAccent)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sender)
                        .font(.ccSerifAdaptive(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ccText)
                    Spacer()
                    Text(formatRelativeTime(message.ts))
                        .font(.ccSerifAdaptive(size: 11))
                        .foregroundStyle(Color.ccTextDim)
                }
                HStack(spacing: 8) {
                    Text(durationText)
                        .font(.ccSerifAdaptive(size: 13, weight: .medium))
                        .foregroundStyle(Color.ccAccent)
                    if let name = message.attachmentFilename, !name.isEmpty {
                        Text(name)
                            .font(.ccSerifAdaptive(size: 12))
                            .foregroundStyle(Color.ccTextDim)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func formatRelativeTime(_ ts: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: ts) else { return String(ts.prefix(10)) }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let g = DateFormatter(); g.dateFormat = "HH:mm"; return g.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "昨天" }
        let g = DateFormatter(); g.dateFormat = "M月d日"; return g.string(from: date)
    }
}

/// 2026-05-08 patch1: 图片视频 tab 4 列 grid section.
struct ImageGridSection: View {
    let messages: [ChatMessage]
    let onTapImage: (URL) -> Void
    let onJumpToMessage: (ChatMessage) -> Void

    @AppStorage("ai_avatar_path") private var aiAvatarPath: String = ""
    @AppStorage("ai_avatar_emoji") private var aiAvatarEmoji: String = "🦀"
    @AppStorage("user_avatar_path") private var userAvatarPath: String = ""

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(messages) { msg in
                cell(msg)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func cell(_ msg: ChatMessage) -> some View {
        let url = msg.attachmentFullURL()
        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            Color.ccCard
                                .overlay { ProgressView().controlSize(.small) }
                        case .success(let img):
                            img.resizable().scaledToFill()
                        case .failure:
                            Color.ccCard
                                .overlay {
                                    Image(systemName: "photo")
                                        .foregroundStyle(Color.ccTextDim)
                                }
                        @unknown default:
                            Color.ccCard
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.width)
                    .clipped()
                } else {
                    Color.ccCard
                        .frame(width: geo.size.width, height: geo.size.width)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onTapGesture {
                if let url { onTapImage(url) }
            }
            .contextMenu {
                Button {
                    if let url { saveImage(from: url) }
                } label: {
                    Label("保存图片", systemImage: "square.and.arrow.down")
                }
                Button {
                    onJumpToMessage(msg)
                } label: {
                    Label("定位到聊天", systemImage: "arrow.uturn.right.circle")
                }
            }

            // avatar overlay removed (2026-05-08 用户 push 整体不需要 sender 标识)
        }
    }

    @ViewBuilder
    private func avatarOverlay(_ msg: ChatMessage) -> some View {
        let size: CGFloat = 18
        let path = msg.isUser ? userAvatarPath : aiAvatarPath
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.35))
                .frame(width: size + 2, height: size + 2)
            if !path.isEmpty, let ui = UIImage(contentsOfFile: path) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if msg.isUser {
                Image(systemName: "person.crop.circle.fill")
                    .font(.ccSerifAdaptive(size: size - 2, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: size, height: size)
            } else {
                Text(aiAvatarEmoji)
                    .font(.ccSerifAdaptive(size: size - 4))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white.opacity(0.9)))
            }
        }
    }

    private func saveImage(from url: URL) {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url))
                if let img = UIImage(data: data) {
                    await MainActor.run {
                        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                    }
                }
            } catch {
                // ignore — 保存失败不弹提示 contextMenu 体验保持轻
            }
        }
    }
}

struct DateJumpSheet: View {
    @Binding var selection: Date
    let onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    // 2026-05-08 patch1: 用 initial 标志吃掉 onAppear 时的第一次 onChange (避免一打开就 auto-jump 到 today).
    @State private var didMount: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker(
                    "选日期",
                    selection: $selection,
                    in: ...Date(),
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .tint(Color.ccAccent)
                .accentColor(Color.ccAccent)
                .padding(.horizontal, 16)
                Spacer()
            }
            .navigationTitle("跳到日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Color.ccAccent)
                }
            }
            .onAppear { didMount = true }
            .onChange(of: selection) { _, newDate in
                // 2026-05-08 patch1: pick 后直接跳 不再点 button
                guard didMount else { return }
                onPick(newDate)
            }
        }
    }
}
