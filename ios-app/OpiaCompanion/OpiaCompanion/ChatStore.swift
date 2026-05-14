//
//  ChatStore.swift
//  OpiaCompanion
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
    var attachmentUrl: String?
    var attachmentType: String?
    var attachmentFilename: String?
    var reactionsJSON: String?
    var audioZh: String?
    var audioEn: String?
    var audioJa: String?
    var locationJSON: String?
    var metadataJSON: String?

    init(message: ChatMessage) {
        self.id = message.id
        self.ts = message.ts
        self.role = message.role
        self.text = message.text
        self.source = message.source
        self.quotedTs = message.quotedTs
        self.quotedText = message.quotedText
        self.attachmentUrl = message.attachmentUrl
        self.attachmentType = message.attachmentType
        self.attachmentFilename = message.attachmentFilename
        self.reactionsJSON = Self.encode(message.reactions)
        self.audioZh = message.audioZh
        self.audioEn = message.audioEn
        self.audioJa = message.audioJa
        self.locationJSON = Self.encode(message.location)
        self.metadataJSON = Self.encode(message.metadata)
    }

    init(row: Row) {
        self.id = row["id"]
        self.ts = row["ts"]
        self.role = row["role"]
        self.text = row["text"]
        self.source = row["source"]
        self.quotedTs = row["quotedTs"]
        self.quotedText = row["quotedText"]
        self.attachmentUrl = row["attachmentUrl"]
        self.attachmentType = row["attachmentType"]
        self.attachmentFilename = row["attachmentFilename"]
        self.reactionsJSON = row["reactionsJSON"]
        self.audioZh = row["audioZh"]
        self.audioEn = row["audioEn"]
        self.audioJa = row["audioJa"]
        self.locationJSON = row["locationJSON"]
        self.metadataJSON = row["metadataJSON"]
    }

    func chatMessage() -> ChatMessage {
        ChatMessage(
            ts: ts,
            role: role,
            text: text,
            source: source,
            quotedTs: quotedTs,
            quotedText: quotedText,
            attachmentUrl: attachmentUrl,
            attachmentType: attachmentType,
            attachmentFilename: attachmentFilename,
            reactions: Self.decode([String].self, from: reactionsJSON),
            audioZh: audioZh,
            audioEn: audioEn,
            audioJa: audioJa,
            location: Self.decode(ChatLocation.self, from: locationJSON),
            metadata: Self.decode(ChatMetadata.self, from: metadataJSON)
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

// MARK: - Store

@MainActor
final class ChatStore {
    static let shared = ChatStore()

    private let dbQueue: DatabaseQueue?

    private init() {
        let queue: DatabaseQueue?
        do {
            let url = try SwiftDataCacheURL.url(filename: "ChatCache.db")
            var config = Configuration()
            config.label = "ChatStore"
            let q = try DatabaseQueue(path: url.path, configuration: config)
            try Self.migrate(q)
            queue = q
        } catch {
            queue = nil
        }
        self.dbQueue = queue
        // 启动一次性 migration: SwiftData → GRDB.
        if let queue {
            SwiftDataMigration.migrateChatIfNeeded { rows in
                NSLog("[migration] chat sink received \(rows.count) rows")
                guard !rows.isEmpty else { return }
                try? queue.write { db in
                    for r in rows {
                        var rec = StoredChatMessage(legacy: r)
                        try? rec.save(db)
                    }
                }
                let after = (try? queue.read { db in try StoredChatMessage.fetchCount(db) }) ?? -1
                NSLog("[migration] chat done, GRDB count=\(after)")
            }
        }
    }

    private static func migrate(_ q: DatabaseQueue) throws {
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
        try migrator.migrate(q)
    }

    var isAvailable: Bool { dbQueue != nil }

    func latest(limit: Int = 200) -> [ChatMessage] {
        guard let dbQueue else { return [] }
        let rows: [StoredChatMessage] = (try? dbQueue.read { db in
            try StoredChatMessage
                .order(Column("ts").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
        return rows.map { $0.chatMessage() }.sorted { $0.ts < $1.ts }
    }

    func before(ts: String, limit: Int = 200) -> [ChatMessage] {
        guard let dbQueue else { return [] }
        let rows: [StoredChatMessage] = (try? dbQueue.read { db in
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
        guard let dbQueue else { return [] }
        let merged: [StoredChatMessage] = (try? dbQueue.read { db in
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
        guard let dbQueue else { return nil }
        return try? dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT ts FROM stored_chat_message ORDER BY ts ASC LIMIT 1")
        } ?? nil
    }

    func newestTs() -> String? {
        guard let dbQueue else { return nil }
        return try? dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT ts FROM stored_chat_message ORDER BY ts DESC LIMIT 1")
        } ?? nil
    }

    func count() -> Int {
        guard let dbQueue else { return 0 }
        return (try? dbQueue.read { db in
            try StoredChatMessage.fetchCount(db)
        }) ?? 0
    }

    /// 全文 search 走 FTS5 MATCH 全表覆盖 不再受 cache cap 限制.
    func search(keyword: String, attachmentTypeFilter: String? = nil, linkOnly: Bool = false, limit: Int = 200) async -> [ChatMessage] {
        guard let dbQueue else { return [] }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let ftsQuery = Self.buildFTSQuery(trimmed)
        let rows: [StoredChatMessage] = (try? await dbQueue.read { db in
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
        guard let dbQueue else { return [] }
        let rows: [StoredChatMessage] = (try? dbQueue.read { db in
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
        guard let dbQueue else { return [] }
        let prefix = day + "%"
        let rows: [StoredChatMessage] = (try? dbQueue.read { db in
            try StoredChatMessage.fetchAll(
                db,
                sql: "SELECT * FROM stored_chat_message WHERE ts LIKE ? ORDER BY ts ASC LIMIT 5000",
                arguments: [prefix]
            )
        }) ?? []
        return rows.map { $0.chatMessage() }
    }

    struct Coverage {
        let count: Int
        let oldest: String?
        let newest: String?
        let complete: Bool
        let lastBackfillAt: TimeInterval?
    }

    func coverage() -> Coverage {
        Coverage(
            count: count(),
            oldest: oldestTs(),
            newest: newestTs(),
            complete: UserDefaults.standard.bool(forKey: "backfillComplete"),
            lastBackfillAt: UserDefaults.standard.object(forKey: "lastBackfillAt") as? TimeInterval
        )
    }

    func upsert(_ messages: [ChatMessage]) {
        guard let dbQueue, !messages.isEmpty else { return }
        try? dbQueue.write { db in
            for message in messages {
                var rec = StoredChatMessage(message: message)
                try? rec.save(db)
            }
        }
    }

    /// 大批量 upsert: 每 batch 条一个 transaction + yield 让主线程渲染.
    func upsertAsync(_ messages: [ChatMessage], batch: Int = 100) async {
        guard let dbQueue, !messages.isEmpty else { return }
        var idx = 0
        let total = messages.count
        while idx < total {
            let end = min(idx + batch, total)
            let chunk = Array(messages[idx..<end])
            try? await dbQueue.write { db in
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
        guard let dbQueue, n > 0 else { return }
        try? dbQueue.write { db in
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
        guard let dbQueue, !ids.isEmpty else { return }
        try? dbQueue.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let args = StatementArguments(Array(ids))
            try db.execute(sql: "DELETE FROM stored_chat_message WHERE id IN (\(placeholders))", arguments: args)
        }
    }

    func deleteAll() {
        guard let dbQueue else { return }
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM stored_chat_message")
        }
    }
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
        self.attachmentUrl = legacy.attachmentUrl
        self.attachmentType = legacy.attachmentType
        self.attachmentFilename = legacy.attachmentFilename
        self.reactionsJSON = legacy.reactionsJSON
        self.audioZh = legacy.audioZh
        self.audioEn = legacy.audioEn
        self.audioJa = legacy.audioJa
        self.locationJSON = legacy.locationJSON
        self.metadataJSON = legacy.metadataJSON
    }
}
