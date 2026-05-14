//
//  SwiftDataMigration.swift
//  OpiaCompanion
//
//  一次性把老 SwiftData store 的数据导入 GRDB.
//  入口 SwiftDataMigration.migrateXxxIfNeeded(sink:) 在每个 GRDB store init 末尾调用.
//
//  v2 修复 (2026-05-07):
//  老版本走 SwiftData @Model class (LegacyXxx) 但 SwiftData 按 type name 找 entity 表
//  原表名是 StoredChatMessage / RPMessage / RPSession / StoredGroupMessage 改名后找不到 → 永远 fetch 0 条.
//  v2 改用 GRDB 直接打开老 SwiftData store 底层 SQLite 文件 走 CoreData 表名约定 (Z + UPPERCASE_NAME).
//  通过 sqlite_master 自适应发现实际表名跟字段 不再依赖 SwiftData type 系统.
//
//  完成后写 UserDefaults flag (v2) 下次启动直接 skip.
//  老 SwiftData 文件不删 留作 fallback rollback.
//

import Foundation
import GRDB

// MARK: - Legacy row 容器 (取代原 @Model 类)
//
// 这些结构纯粹是 migration 中转 不进 SwiftData 不进 GRDB.

struct LegacyStoredChatMessage {
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
}

struct LegacyRPMessage {
    var id: String
    var sid: String
    var characterId: String?
    var ts: String
    var role: String
    var text: String
}

struct LegacyRPSession {
    var sid: String
    var characterName: String
    var characterRole: String
    var characterCardJSON: String?
    var createdAt: String
    var lastActive: String
    var status: String
    var turns: Int
}

struct LegacyStoredGroupMessage {
    var id: String
    var ts: String
    var senderId: String
    var senderModel: String?
    var text: String
    var mentionsJSON: String?
    var parentMsgId: String?
    var source: String?
    var metadataJSON: String?
}

// MARK: - Migration runner

@MainActor
enum SwiftDataMigration {
    // v2 flag: v1 的 flag 旧版已 set true 必须用新 key 让 migration 重跑.
    private static let chatFlag = "grdb_migrated_v2_chat"
    private static let rpMsgFlag = "grdb_migrated_v2_rp_msg"
    private static let rpSessFlag = "grdb_migrated_v2_rp_session"
    private static let groupFlag = "grdb_migrated_v2_group"

    // MARK: chat

    static func migrateChatIfNeeded(sink: ([LegacyStoredChatMessage]) -> Void) {
        guard !UserDefaults.standard.bool(forKey: chatFlag) else { return }
        let candidates = candidatePaths(forSwiftDataStore: "ChatCache.store",
                                        defaultName: "default.store")
        let rows = readLegacyChat(from: candidates)
        NSLog("[migration] chat: scanned \(candidates.count) candidates, found \(rows.count) rows")
        sink(rows)
        UserDefaults.standard.set(true, forKey: chatFlag)
    }

    // MARK: rp messages

    static func migrateRPMessagesIfNeeded(sink: ([LegacyRPMessage]) -> Void) {
        guard !UserDefaults.standard.bool(forKey: rpMsgFlag) else { return }
        let candidates = candidatePaths(forSwiftDataStore: "RPMessageCache.store",
                                        defaultName: "default.store")
        let rows = readLegacyRPMessages(from: candidates)
        NSLog("[migration] rp_message: scanned \(candidates.count) candidates, found \(rows.count) rows")
        sink(rows)
        UserDefaults.standard.set(true, forKey: rpMsgFlag)
    }

    // MARK: rp sessions

    static func migrateRPSessionsIfNeeded(sink: ([LegacyRPSession]) -> Void) {
        guard !UserDefaults.standard.bool(forKey: rpSessFlag) else { return }
        let candidates = candidatePaths(forSwiftDataStore: "RPSessionCache.store",
                                        defaultName: "default.store")
        let rows = readLegacyRPSessions(from: candidates)
        NSLog("[migration] rp_session: scanned \(candidates.count) candidates, found \(rows.count) rows")
        sink(rows)
        UserDefaults.standard.set(true, forKey: rpSessFlag)
    }

    // MARK: group

    static func migrateGroupIfNeeded(sink: ([LegacyStoredGroupMessage]) -> Void) {
        guard !UserDefaults.standard.bool(forKey: groupFlag) else { return }
        let candidates = candidatePaths(forSwiftDataStore: "GroupChatCache.store",
                                        defaultName: "default.store")
        let rows = readLegacyGroup(from: candidates)
        NSLog("[migration] group: scanned \(candidates.count) candidates, found \(rows.count) rows")
        sink(rows)
        UserDefaults.standard.set(true, forKey: groupFlag)
    }

    // MARK: - 路径推导

    /// 给定一个 SwiftData store filename 返回所有候选磁盘路径 (按优先级).
    private static func candidatePaths(forSwiftDataStore custom: String, defaultName: String) -> [URL] {
        var urls: [URL] = []
        let fm = FileManager.default
        // 候选 1: SwiftDataCacheURL 自定义路径 (Application Support/OpiaCompanion/<custom>)
        if let u = try? SwiftDataCacheURL.url(filename: custom) {
            urls.append(u)
        }
        // 候选 2: SwiftData 无 url 默认路径 (Application Support/default.store)
        if let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: nil,
                                        create: false) {
            urls.append(appSupport.appendingPathComponent(defaultName))
            // SwiftData 在某些 SDK 上也写到 bundle id 子目录 这里不强求.
        }
        // 候选 3: Documents 目录下同名 (老老版本可能写过这里)
        if let docs = try? fm.url(for: .documentDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil,
                                  create: false) {
            urls.append(docs.appendingPathComponent(custom))
        }
        // 去重 + 仅保留实际存在的文件 (-shm/-wal 不存也无所谓 SQLite 自动 reattach).
        var seen = Set<String>()
        var existing: [URL] = []
        for u in urls {
            let p = u.path
            if seen.contains(p) { continue }
            seen.insert(p)
            let exists = fm.fileExists(atPath: p)
            NSLog("[migration] candidate path \(p) exists=\(exists)")
            if exists { existing.append(u) }
        }
        return existing
    }

    // MARK: - GRDB readers

    /// 打开老 SwiftData SQLite 文件 用 readonly DatabaseQueue.
    private static func openReadOnly(_ url: URL) -> DatabaseQueue? {
        var config = Configuration()
        config.readonly = true
        config.label = "SwiftDataMigrationReader"
        do {
            return try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            NSLog("[migration] open failed at \(url.path): \(error)")
            return nil
        }
    }

    /// 从 sqlite_master 找符合 entity 名的表 (CoreData 表名 = Z + UPPERCASE entity).
    /// 返回实际表名 + 字段名 set.
    private static func discoverTable(_ db: Database, entityCandidates: [String]) -> (table: String, columns: Set<String>)? {
        // 列出所有 Z 开头表名.
        let tables: [String] = (try? String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%'"
        )) ?? []
        for entity in entityCandidates {
            let upper = "Z" + entity.uppercased()
            if let hit = tables.first(where: { $0.uppercased() == upper }) {
                let cols = pragmaColumns(db, table: hit)
                return (hit, cols)
            }
        }
        return nil
    }

    private static func pragmaColumns(_ db: Database, table: String) -> Set<String> {
        let rows = (try? Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")) ?? []
        var out = Set<String>()
        for r in rows {
            if let n: String = r["name"] {
                out.insert(n)
                out.insert(n.uppercased())
            }
        }
        return out
    }

    /// 从 row 拿一个字符串 column 优先 ZNAME ZNAME_UPPER 不区分大小写.
    private static func str(_ row: Row, _ keys: String...) -> String? {
        for k in keys {
            if let v: String? = row[k], let s = v { return s }
            // 大写 fallback
            let up = "Z" + k.uppercased()
            if let v: String? = row[up], let s = v { return s }
        }
        return nil
    }

    private static func int(_ row: Row, _ keys: String...) -> Int? {
        for k in keys {
            if let v: Int? = row[k], let s = v { return s }
            let up = "Z" + k.uppercased()
            if let v: Int? = row[up], let s = v { return s }
        }
        return nil
    }

    // MARK: chat reader

    private static func readLegacyChat(from urls: [URL]) -> [LegacyStoredChatMessage] {
        var seen = Set<String>()
        var out: [LegacyStoredChatMessage] = []
        for url in urls {
            guard let q = openReadOnly(url) else { continue }
            do {
                try q.read { db in
                    guard let info = discoverTable(db, entityCandidates: ["StoredChatMessage"]) else {
                        NSLog("[migration] chat: no ZSTOREDCHATMESSAGE in \(url.lastPathComponent)")
                        return
                    }
                    NSLog("[migration] chat: table=\(info.table) cols=\(info.columns.count)")
                    let rows = (try? Row.fetchAll(db, sql: "SELECT * FROM \"\(info.table)\"")) ?? []
                    for r in rows {
                        guard let id = str(r, "ZID"),
                              let ts = str(r, "ZTS"),
                              let role = str(r, "ZROLE"),
                              let text = str(r, "ZTEXT") else { continue }
                        if seen.contains(id) { continue }
                        seen.insert(id)
                        out.append(LegacyStoredChatMessage(
                            id: id, ts: ts, role: role, text: text,
                            source: str(r, "ZSOURCE"),
                            quotedTs: str(r, "ZQUOTEDTS"),
                            quotedText: str(r, "ZQUOTEDTEXT"),
                            attachmentUrl: str(r, "ZATTACHMENTURL"),
                            attachmentType: str(r, "ZATTACHMENTTYPE"),
                            attachmentFilename: str(r, "ZATTACHMENTFILENAME"),
                            reactionsJSON: str(r, "ZREACTIONSJSON"),
                            audioZh: str(r, "ZAUDIOZH"),
                            audioEn: str(r, "ZAUDIOEN"),
                            audioJa: str(r, "ZAUDIOJA"),
                            locationJSON: str(r, "ZLOCATIONJSON"),
                            metadataJSON: str(r, "ZMETADATAJSON")
                        ))
                    }
                }
            } catch {
                NSLog("[migration] chat read failed at \(url.path): \(error)")
            }
        }
        return out
    }

    // MARK: rp message reader

    private static func readLegacyRPMessages(from urls: [URL]) -> [LegacyRPMessage] {
        var seen = Set<String>()
        var out: [LegacyRPMessage] = []
        for url in urls {
            guard let q = openReadOnly(url) else { continue }
            do {
                try q.read { db in
                    guard let info = discoverTable(db, entityCandidates: ["RPMessage"]) else {
                        NSLog("[migration] rp_message: no ZRPMESSAGE in \(url.lastPathComponent)")
                        return
                    }
                    NSLog("[migration] rp_message: table=\(info.table)")
                    let rows = (try? Row.fetchAll(db, sql: "SELECT * FROM \"\(info.table)\"")) ?? []
                    for r in rows {
                        guard let id = str(r, "ZID"),
                              let sid = str(r, "ZSID"),
                              let ts = str(r, "ZTS"),
                              let role = str(r, "ZROLE"),
                              let text = str(r, "ZTEXT") else { continue }
                        if seen.contains(id) { continue }
                        seen.insert(id)
                        out.append(LegacyRPMessage(
                            id: id, sid: sid,
                            characterId: str(r, "ZCHARACTERID"),
                            ts: ts, role: role, text: text
                        ))
                    }
                }
            } catch {
                NSLog("[migration] rp_message read failed at \(url.path): \(error)")
            }
        }
        return out
    }

    // MARK: rp session reader

    private static func readLegacyRPSessions(from urls: [URL]) -> [LegacyRPSession] {
        var seen = Set<String>()
        var out: [LegacyRPSession] = []
        for url in urls {
            guard let q = openReadOnly(url) else { continue }
            do {
                try q.read { db in
                    guard let info = discoverTable(db, entityCandidates: ["RPSession"]) else {
                        NSLog("[migration] rp_session: no ZRPSESSION in \(url.lastPathComponent)")
                        return
                    }
                    NSLog("[migration] rp_session: table=\(info.table)")
                    let rows = (try? Row.fetchAll(db, sql: "SELECT * FROM \"\(info.table)\"")) ?? []
                    for r in rows {
                        guard let sid = str(r, "ZSID"),
                              let name = str(r, "ZCHARACTERNAME"),
                              let role = str(r, "ZCHARACTERROLE"),
                              let createdAt = str(r, "ZCREATEDAT"),
                              let lastActive = str(r, "ZLASTACTIVE") else { continue }
                        if seen.contains(sid) { continue }
                        seen.insert(sid)
                        out.append(LegacyRPSession(
                            sid: sid,
                            characterName: name,
                            characterRole: role,
                            characterCardJSON: str(r, "ZCHARACTERCARDJSON"),
                            createdAt: createdAt,
                            lastActive: lastActive,
                            status: str(r, "ZSTATUS") ?? "active",
                            turns: int(r, "ZTURNS") ?? 0
                        ))
                    }
                }
            } catch {
                NSLog("[migration] rp_session read failed at \(url.path): \(error)")
            }
        }
        return out
    }

    // MARK: group reader

    private static func readLegacyGroup(from urls: [URL]) -> [LegacyStoredGroupMessage] {
        var seen = Set<String>()
        var out: [LegacyStoredGroupMessage] = []
        for url in urls {
            guard let q = openReadOnly(url) else { continue }
            do {
                try q.read { db in
                    guard let info = discoverTable(db, entityCandidates: ["StoredGroupMessage"]) else {
                        NSLog("[migration] group: no ZSTOREDGROUPMESSAGE in \(url.lastPathComponent)")
                        return
                    }
                    NSLog("[migration] group: table=\(info.table)")
                    let rows = (try? Row.fetchAll(db, sql: "SELECT * FROM \"\(info.table)\"")) ?? []
                    for r in rows {
                        guard let id = str(r, "ZID"),
                              let ts = str(r, "ZTS"),
                              let senderId = str(r, "ZSENDERID"),
                              let text = str(r, "ZTEXT") else { continue }
                        if seen.contains(id) { continue }
                        seen.insert(id)
                        out.append(LegacyStoredGroupMessage(
                            id: id, ts: ts, senderId: senderId,
                            senderModel: str(r, "ZSENDERMODEL"),
                            text: text,
                            mentionsJSON: str(r, "ZMENTIONSJSON"),
                            parentMsgId: str(r, "ZPARENTMSGID"),
                            source: str(r, "ZSOURCE"),
                            metadataJSON: str(r, "ZMETADATAJSON")
                        ))
                    }
                }
            } catch {
                NSLog("[migration] group read failed at \(url.path): \(error)")
            }
        }
        return out
    }
}
