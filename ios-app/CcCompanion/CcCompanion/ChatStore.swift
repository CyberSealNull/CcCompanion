//
//  ChatStore.swift
//  CcCompanion
//
//  GRDB SQLite + FTS5 全文索引 (替换原 SwiftData @Model 实现).
//  API surface 跟原版完全一致 caller 不改一行.
//  老 SwiftData store 文件保留作 fallback 启动时一次性 migration 到 GRDB.
//

import Foundation
import GRDB

// MARK: - GRDB record

struct StoredChatMessage: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "stored_chat_message"

    var id: String
    var ts: String
    var role: String
    var text: String
    var source: String?
    var quotedTs: String?
    var quotedText: String?
    var quotedRole: String?
    var attachmentUrl: String?
    var attachmentType: String?
    var attachmentFilename: String?
    var reactionsJSON: String?
    var audioZh: String?
    var audioEn: String?
    var audioJa: String?
    var locationJSON: String?
    var metadataJSON: String?
    var stickerId: String?
    var patpatJSON: String?

    init(message: ChatMessage) {
        self.id = message.id
        self.ts = message.ts
        self.role = message.role
        self.text = message.text
        self.source = message.source
        self.quotedTs = message.quotedTs
        self.quotedText = message.quotedText
        self.quotedRole = message.quotedRole
        self.attachmentUrl = message.attachmentUrl
        self.attachmentType = message.attachmentType
        self.attachmentFilename = message.attachmentFilename
        self.reactionsJSON = Self.encode(message.reactions)
        self.audioZh = message.audioZh
        self.audioEn = message.audioEn
        self.audioJa = message.audioJa
        self.locationJSON = Self.encode(message.location)
        self.metadataJSON = Self.encode(message.metadata)
        self.stickerId = message.stickerId
        self.patpatJSON = Self.encode(message.patpat)
    }

    init(row: Row) {
        self.id = row["id"]
        self.ts = row["ts"]
        self.role = row["role"]
        self.text = row["text"]
        self.source = row["source"]
        self.quotedTs = row["quotedTs"]
        self.quotedText = row["quotedText"]
        self.quotedRole = row["quotedRole"]
        self.attachmentUrl = row["attachmentUrl"]
        self.attachmentType = row["attachmentType"]
        self.attachmentFilename = row["attachmentFilename"]
        self.reactionsJSON = row["reactionsJSON"]
        self.audioZh = row["audioZh"]
        self.audioEn = row["audioEn"]
        self.audioJa = row["audioJa"]
        self.locationJSON = row["locationJSON"]
        self.metadataJSON = row["metadataJSON"]
        self.stickerId = row["stickerId"]
        self.patpatJSON = row["patpatJSON"]
    }

    func chatMessage() -> ChatMessage {
        ChatMessage(
            ts: ts,
            role: role,
            text: text,
            source: source,
            quotedTs: quotedTs,
            quotedText: quotedText,
            quotedRole: quotedRole,
            attachmentUrl: attachmentUrl,
            attachmentType: attachmentType,
            attachmentFilename: attachmentFilename,
            reactions: Self.decode([String].self, from: reactionsJSON),
            audioZh: audioZh,
            audioEn: audioEn,
            audioJa: audioJa,
            location: Self.decode(ChatLocation.self, from: locationJSON),
            metadata: Self.decode(ChatMetadata.self, from: metadataJSON),
            stickerId: stickerId,
            patpat: Self.decode(PatPatPayload.self, from: patpatJSON)
        )
    }

    private static func encode<T: Encodable>(_ value: T?) -> String? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Scoped store (code review P0-1: computed 路由不保证跨 await 稳定)
//
// 一个 ChatStoreScope 绑死一个具体的 DatabaseQueue?, 一旦创建就不会因为全局 DirectAPIConfig.mode
// 变了而改指向. backfillHistory()/pollOnce()/sendDirectAPI() 这类跨越多个 await 挂起点的操作,
// 必须在操作开始时调 `ChatStore.shared.snapshot(.ccServer)` / `.snapshot(.directAPI)` 拿一份冻结的
// scope, 全程只用这一份 —— 不能像 UI 层单次同步读那样直接调 `chatStore.latest(...)`(那条路径内部
// 每次都用当前全局模式现算, 对没有 await 挂起的单次调用安全, 但对跨 await 的长操作不安全: 网络请求
// 在等待期间用户切了模式, 请求返回后如果重新读全局模式, 就会把旧模式的数据写进新模式的库).
struct ChatStoreScope {
    let queue: DatabaseQueue?

    var isAvailable: Bool { queue != nil }

    func latest(limit: Int = 200) -> [ChatMessage] {
        guard let queue else { return [] }
        let rows: [StoredChatMessage] = (try? queue.read { db in
            try StoredChatMessage
                .order(Column("ts").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
        return rows.map { $0.chatMessage() }.sorted { $0.ts < $1.ts }
    }

    func before(ts: String, limit: Int = 200) -> [ChatMessage] {
        guard let queue else { return [] }
        let rows: [StoredChatMessage] = (try? queue.read { db in
            try StoredChatMessage
                .filter(Column("ts") < ts)
                .order(Column("ts").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
        return rows.map { $0.chatMessage() }.sorted { $0.ts < $1.ts }
    }

    /// 围绕 ts 取前 before 条 + 后 after 条 + 目标本身.
    func around(ts: String, before: Int = 25, after: Int = 25) -> [ChatMessage] {
        guard let queue else { return [] }
        let merged: [StoredChatMessage] = (try? queue.read { db in
            let pre = try StoredChatMessage
                .filter(Column("ts") < ts)
                .order(Column("ts").desc)
                .limit(before)
                .fetchAll(db)
            let post = try StoredChatMessage
                .filter(Column("ts") >= ts)
                .order(Column("ts").asc)
                .limit(after + 1)
                .fetchAll(db)
            return pre + post
        }) ?? []
        return merged.map { $0.chatMessage() }.sorted { $0.ts < $1.ts }
    }

    func oldestTs() -> String? {
        guard let queue else { return nil }
        return try? queue.read { db in
            try String.fetchOne(db, sql: "SELECT ts FROM stored_chat_message ORDER BY ts ASC LIMIT 1")
        } ?? nil
    }

    func newestTs() -> String? {
        guard let queue else { return nil }
        return try? queue.read { db in
            try String.fetchOne(db, sql: "SELECT ts FROM stored_chat_message ORDER BY ts DESC LIMIT 1")
        } ?? nil
    }

    func count() -> Int {
        guard let queue else { return 0 }
        return (try? queue.read { db in
            try StoredChatMessage.fetchCount(db)
        }) ?? 0
    }

    /// 全文 search 走 FTS5 MATCH 全表覆盖 不再受 cache cap 限制.
    func search(keyword: String, attachmentTypeFilter: String? = nil, linkOnly: Bool = false, limit: Int = 200) async -> [ChatMessage] {
        guard let queue else { return [] }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let ftsQuery = ChatStoreScope.buildFTSQuery(trimmed)
        let rows: [StoredChatMessage] = (try? await queue.read { db in
            var sql = """
                SELECT m.* FROM stored_chat_message m
                JOIN chat_message_fts f ON f.rowid = m.rowid
                WHERE chat_message_fts MATCH ?
                """
            var args: [DatabaseValueConvertible] = [ftsQuery]
            if let tf = attachmentTypeFilter {
                sql += " AND m.attachmentType = ?"
                args.append(tf)
            }
            sql += " ORDER BY m.ts DESC LIMIT ?"
            args.append(limit)
            // FTS5 MATCH 失败 (空 query / 异常 token) 兜底 LIKE.
            do {
                return try StoredChatMessage.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            } catch {
                var fallbackSQL = "SELECT * FROM stored_chat_message WHERE (text LIKE ? OR attachmentFilename LIKE ?)"
                let needle = "%" + trimmed + "%"
                var fbArgs: [DatabaseValueConvertible] = [needle, needle]
                if let tf = attachmentTypeFilter {
                    fallbackSQL += " AND attachmentType = ?"
                    fbArgs.append(tf)
                }
                fallbackSQL += " ORDER BY ts DESC LIMIT ?"
                fbArgs.append(limit)
                return (try? StoredChatMessage.fetchAll(db, sql: fallbackSQL, arguments: StatementArguments(fbArgs))) ?? []
            }
        }) ?? []
        var msgs = rows.map { $0.chatMessage() }
        if linkOnly {
            msgs = msgs.filter { $0.text.range(of: #"https?://[^\s]+"#, options: .regularExpression) != nil }
        }
        return msgs
    }

    /// 把用户输入转 FTS5 query: 拆 token + 加前缀通配 + 转义双引号.
    private static func buildFTSQuery(_ keyword: String) -> String {
        let cleaned = keyword.replacingOccurrences(of: "\"", with: " ")
        let parts = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "\"\(cleaned)\"" }
        // 每个 token 用引号包 + 后缀 * 支持前缀匹配 / 中文已被 unicode61 tokenize 拆字.
        return parts.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// 文件 tab 时间分组: 本周 / 本月 / 更早. 按 ts 倒序.
    func filesGrouped(limit: Int = 1000) -> [(group: String, files: [ChatMessage])] {
        guard let queue else { return [] }
        let rows: [StoredChatMessage] = (try? queue.read { db in
            try StoredChatMessage
                .filter(Column("attachmentType") == "file")
                .order(Column("ts").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
        let msgs = rows.map { $0.chatMessage() }
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var thisWeek: [ChatMessage] = []
        var thisMonth: [ChatMessage] = []
        var earlier: [ChatMessage] = []
        for msg in msgs {
            let interval: TimeInterval
            if let date = formatter.date(from: msg.ts) {
                interval = now.timeIntervalSince(date)
            } else {
                interval = .greatestFiniteMagnitude
            }
            if interval < 7 * 86400 { thisWeek.append(msg) }
            else if interval < 30 * 86400 { thisMonth.append(msg) }
            else { earlier.append(msg) }
        }
        var out: [(group: String, files: [ChatMessage])] = []
        if !thisWeek.isEmpty { out.append((group: "本周", files: thisWeek)) }
        if !thisMonth.isEmpty { out.append((group: "本月", files: thisMonth)) }
        if !earlier.isEmpty { out.append((group: "更早", files: earlier)) }
        return out
    }

    /// 那一天的所有消息 (按 ts 升序).
    func dateRange(day: String) -> [ChatMessage] {
        guard let queue else { return [] }
        let prefix = day + "%"
        let rows: [StoredChatMessage] = (try? queue.read { db in
            try StoredChatMessage.fetchAll(
                db,
                sql: "SELECT * FROM stored_chat_message WHERE ts LIKE ? ORDER BY ts ASC LIMIT 5000",
                arguments: [prefix]
            )
        }) ?? []
        return rows.map { $0.chatMessage() }
    }

    func coverage() -> ChatStore.Coverage {
        ChatStore.Coverage(
            count: count(),
            oldest: oldestTs(),
            newest: newestTs(),
            complete: UserDefaults.standard.bool(forKey: "backfillComplete"),
            lastBackfillAt: UserDefaults.standard.object(forKey: "lastBackfillAt") as? TimeInterval
        )
    }

    func upsert(_ messages: [ChatMessage]) {
        guard let queue, !messages.isEmpty else { return }
        try? queue.write { db in
            for message in messages {
                var rec = StoredChatMessage(message: message)
                try? rec.save(db)
            }
        }
    }

    /// 大批量 upsert: 每 batch 条一个 transaction + yield 让主线程渲染.
    func upsertAsync(_ messages: [ChatMessage], batch: Int = 100) async {
        guard let queue, !messages.isEmpty else { return }
        var idx = 0
        let total = messages.count
        while idx < total {
            let end = min(idx + batch, total)
            let chunk = Array(messages[idx..<end])
            try? await queue.write { db in
                for message in chunk {
                    var rec = StoredChatMessage(message: message)
                    try? rec.save(db)
                }
            }
            idx = end
            await Task.yield()
        }
    }

    func deleteOldest(_ n: Int) {
        guard let queue, n > 0 else { return }
        try? queue.write { db in
            try db.execute(
                sql: "DELETE FROM stored_chat_message WHERE id IN (SELECT id FROM stored_chat_message ORDER BY ts ASC LIMIT ?)",
                arguments: [n]
            )
        }
    }

    func enforceCacheCap(_ cap: Int = 5000) {
        let cur = count()
        if cur > cap {
            deleteOldest(cur - cap)
        }
    }

    func delete(ids: Set<String>) {
        guard let queue, !ids.isEmpty else { return }
        try? queue.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let args = StatementArguments(Array(ids))
            try db.execute(sql: "DELETE FROM stored_chat_message WHERE id IN (\(placeholders))", arguments: args)
        }
    }

    func deleteAll() {
        guard let queue else { return }
        try? queue.write { db in
            try db.execute(sql: "DELETE FROM stored_chat_message")
        }
    }
}

// MARK: - Store facade

@MainActor
final class ChatStore {
    static let shared = ChatStore()

    // P0 直连: directAPI 历史与 ccServer 缓存分库(各自独立 SQLite 文件), 不共表不共行.
    private let ccServerQueue: DatabaseQueue?
    private let directAPIQueue: DatabaseQueue?

    /// UI 层单次同步调用安全的当前模式 scope(每次访问现算, 不跨 await 持有).
    private var current: ChatStoreScope {
        ChatStoreScope(queue: DirectAPIConfig.isActive ? directAPIQueue : ccServerQueue)
    }

    /// 跨 await 的长操作(backfill/poll/SSE)必须调这个冻结身份, 不能反复读 `current`.
    func snapshot(_ mode: ChatBackendMode) -> ChatStoreScope {
        ChatStoreScope(queue: mode == .directAPI ? directAPIQueue : ccServerQueue)
    }

    private init() {
        self.ccServerQueue = Self.openQueue(filename: "ChatCache.db")
        self.directAPIQueue = Self.openQueue(filename: "ChatCacheDirectAPI.db")
        // 启动一次性 migration: SwiftData → GRDB. 老数据都是 ccServer 来源, 只写进 ccServer 库.
        if let ccServerQueue {
            SwiftDataMigration.migrateChatIfNeeded { rows in
                NSLog("[migration] chat sink received \(rows.count) rows")
                guard !rows.isEmpty else { return }
                try? ccServerQueue.write { db in
                    for r in rows {
                        var rec = StoredChatMessage(legacy: r)
                        try? rec.save(db)
                    }
                }
                let after = (try? ccServerQueue.read { db in try StoredChatMessage.fetchCount(db) }) ?? -1
                NSLog("[migration] chat done, GRDB count=\(after)")
            }
        }
    }

    private static func openQueue(filename: String) -> DatabaseQueue? {
        do {
            let url = try SwiftDataCacheURL.url(filename: filename)
            var config = Configuration()
            config.label = "ChatStore-\(filename)"
            let q = try DatabaseQueue(path: url.path, configuration: config)
            try migrate(q)
            return q
        } catch {
            return nil
        }
    }

    /// internal(不是 private): 二审(P0-4) ChatStoreScopeSelfTest 需要用真 schema 开临时 DatabaseQueue
    /// 验证模式切换隔离, 复用这份真实 migration 逻辑, 不允许在测试里另写一份容易跟真 schema drift 的副本.
    static func migrate(_ q: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_stored_chat_message") { db in
            try db.create(table: "stored_chat_message", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("ts", .text).notNull().indexed()
                t.column("role", .text).notNull()
                t.column("text", .text).notNull()
                t.column("source", .text)
                t.column("quotedTs", .text)
                t.column("quotedText", .text)
                t.column("attachmentUrl", .text)
                t.column("attachmentType", .text)
                t.column("attachmentFilename", .text)
                t.column("reactionsJSON", .text)
                t.column("audioZh", .text)
                t.column("audioEn", .text)
                t.column("audioJa", .text)
                t.column("locationJSON", .text)
                t.column("metadataJSON", .text)
            }
            // FTS5 虚拟表 + trigger.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS chat_message_fts USING fts5(
                    text,
                    attachment_filename,
                    content='stored_chat_message',
                    content_rowid='rowid',
                    tokenize='unicode61'
                );
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS chat_message_ai AFTER INSERT ON stored_chat_message BEGIN
                    INSERT INTO chat_message_fts(rowid, text, attachment_filename)
                    VALUES (new.rowid, new.text, COALESCE(new.attachmentFilename, ''));
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS chat_message_ad AFTER DELETE ON stored_chat_message BEGIN
                    INSERT INTO chat_message_fts(chat_message_fts, rowid, text, attachment_filename)
                    VALUES ('delete', old.rowid, old.text, COALESCE(old.attachmentFilename, ''));
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS chat_message_au AFTER UPDATE ON stored_chat_message BEGIN
                    INSERT INTO chat_message_fts(chat_message_fts, rowid, text, attachment_filename)
                    VALUES ('delete', old.rowid, old.text, COALESCE(old.attachmentFilename, ''));
                    INSERT INTO chat_message_fts(rowid, text, attachment_filename)
                    VALUES (new.rowid, new.text, COALESCE(new.attachmentFilename, ''));
                END;
            """)
        }
        // 微信主题 v2.7: 表情包 sticker_id + 反向拍一拍 patpat 持久化.
        migrator.registerMigration("v2_add_sticker_patpat") { db in
            try db.alter(table: "stored_chat_message") { t in
                t.add(column: "stickerId", .text)
                t.add(column: "patpatJSON", .text)
            }
        }
        migrator.registerMigration("v3_add_quoted_role") { db in
            try db.alter(table: "stored_chat_message") { t in
                t.add(column: "quotedRole", .text)
            }
        }
        try migrator.migrate(q)
    }

    // MARK: - 转发给 current(单次同步调用安全). 调用点(ChatViewModel 里 ~15 处 chatStore.xxx())零改动.

    var isAvailable: Bool { current.isAvailable }
    func latest(limit: Int = 200) -> [ChatMessage] { current.latest(limit: limit) }
    func before(ts: String, limit: Int = 200) -> [ChatMessage] { current.before(ts: ts, limit: limit) }
    func around(ts: String, before: Int = 25, after: Int = 25) -> [ChatMessage] { current.around(ts: ts, before: before, after: after) }
    func oldestTs() -> String? { current.oldestTs() }
    func newestTs() -> String? { current.newestTs() }
    func count() -> Int { current.count() }
    func search(keyword: String, attachmentTypeFilter: String? = nil, linkOnly: Bool = false, limit: Int = 200) async -> [ChatMessage] {
        await current.search(keyword: keyword, attachmentTypeFilter: attachmentTypeFilter, linkOnly: linkOnly, limit: limit)
    }
    func filesGrouped(limit: Int = 1000) -> [(group: String, files: [ChatMessage])] { current.filesGrouped(limit: limit) }
    func dateRange(day: String) -> [ChatMessage] { current.dateRange(day: day) }

    struct Coverage {
        let count: Int
        let oldest: String?
        let newest: String?
        let complete: Bool
        let lastBackfillAt: TimeInterval?
    }

    func coverage() -> Coverage { current.coverage() }
    func upsert(_ messages: [ChatMessage]) { current.upsert(messages) }
    func upsertAsync(_ messages: [ChatMessage], batch: Int = 100) async { await current.upsertAsync(messages, batch: batch) }
    func deleteOldest(_ n: Int) { current.deleteOldest(n) }
    func enforceCacheCap(_ cap: Int = 5000) { current.enforceCacheCap(cap) }
    func delete(ids: Set<String>) { current.delete(ids: ids) }
    func deleteAll() { current.deleteAll() }
}

// MARK: - Legacy bridge

private extension StoredChatMessage {
    init(legacy: LegacyStoredChatMessage) {
        self.id = legacy.id
        self.ts = legacy.ts
        self.role = legacy.role
        self.text = legacy.text
        self.source = legacy.source
        self.quotedTs = legacy.quotedTs
        self.quotedText = legacy.quotedText
        self.quotedRole = nil
        self.attachmentUrl = legacy.attachmentUrl
        self.attachmentType = legacy.attachmentType
        self.attachmentFilename = legacy.attachmentFilename
        self.reactionsJSON = legacy.reactionsJSON
        self.audioZh = legacy.audioZh
        self.audioEn = legacy.audioEn
        self.audioJa = legacy.audioJa
        self.locationJSON = legacy.locationJSON
        self.metadataJSON = legacy.metadataJSON
        self.stickerId = nil
        self.patpatJSON = nil
    }
}
