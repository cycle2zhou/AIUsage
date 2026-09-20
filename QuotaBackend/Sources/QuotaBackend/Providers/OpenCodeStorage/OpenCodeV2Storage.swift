import Foundation
import SQLite3
import os.log

// MARK: - OpenCode V2 Storage
// v2 schema 读取：`session_message` 表（data JSON 嵌套 model 对象 + reasoning）+ tool 调用内联 data.content
// + credential 表凭据。本文件只承载 v2 差异，v1/v3 新增不触碰。

private let openCodeV2Log = Logger(subsystem: "com.aiusage.quotabackend", category: "OpenCodeV2Storage")

struct OpenCodeV2Storage: OpenCodeStorage {
    let homeDirectory: String
    let environment: [String: String]
    let schema: OpenCodeSchema = .v2

    var credentialFilePaths: [String] { [] }

    init(homeDirectory: String, environment: [String: String]) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    // MARK: - Message

    private struct V2MessageData: Decodable {
        struct ModelRef: Decodable {
            let id: String?
            let providerID: String?
        }
        struct Tokens: Decodable {
            struct Cache: Decodable {
                let read: Int?
                let write: Int?
            }
            let input: Int?
            let output: Int?
            let reasoning: Int?
            let cache: Cache?
        }
        struct TimeInfo: Decodable {
            let created: Int64?
            let completed: Int64?
        }

        let type: String?
        let model: ModelRef?
        let cost: Double?
        let tokens: Tokens?
        let time: TimeInfo?
    }

    func fetchMessages(dbPath: String, query: OpenCodeMessageQuery) throws -> [OpenCodeMessage] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(db)
            throw ProviderError("db_open_failed", SensitiveDataRedactor.redactPaths(in: message))
        }
        defer { sqlite3_close(db) }

        var sql = "SELECT id, session_id, time_created, data FROM session_message WHERE type='assistant'"
        var binds: [BindValue] = []
        if let since = query.sinceMillis {
            sql += " AND time_created >= ?"
            binds.append(.int64(since))
        }
        if let dataLike = query.dataLike {
            sql += " AND data LIKE ?"
            binds.append(.text(dataLike))
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError("db_query_failed", SensitiveDataRedactor.redactPaths(in: String(cString: sqlite3_errmsg(db))))
        }
        defer { sqlite3_finalize(statement) }

        bind(binds, to: statement)

        let decoder = JSONDecoder()
        var messages: [OpenCodeMessage] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw ProviderError("db_step_failed", SensitiveDataRedactor.redactPaths(in: String(cString: sqlite3_errmsg(db))))
            }
            guard let idCString = sqlite3_column_text(statement, 0),
                  let sessionCString = sqlite3_column_text(statement, 1),
                  let dataCString = sqlite3_column_text(statement, 3) else {
                continue
            }
            let id = String(cString: idCString)
            let sessionId = String(cString: sessionCString)
            let millis = sqlite3_column_int64(statement, 2)
            let data = Data(String(cString: dataCString).utf8)

            guard let parsed = try? decoder.decode(V2MessageData.self, from: data) else {
                continue
            }
            messages.append(Self.normalizeMessage(id: id, sessionId: sessionId, millis: millis, parsed: parsed))
        }
        openCodeV2Log.debug("Fetched \(messages.count, privacy: .public) v2 message rows")
        return messages
    }

    // MARK: - Tool

    func fetchToolCalls(dbPath: String, sinceMillis: Int64?) throws -> [OpenCodeToolCall] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(db)
            throw ProviderError("db_open_failed", SensitiveDataRedactor.redactPaths(in: message))
        }
        defer { sqlite3_close(db) }

        var sql = "SELECT id, time_created, data FROM session_message WHERE type='assistant'"
        if sinceMillis != nil {
            sql += " AND time_created >= ?"
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError("db_query_failed", SensitiveDataRedactor.redactPaths(in: String(cString: sqlite3_errmsg(db))))
        }
        defer { sqlite3_finalize(statement) }

        if let sinceMillis {
            sqlite3_bind_int64(statement, 1, sinceMillis)
        }

        var calls: [OpenCodeToolCall] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw ProviderError("db_step_failed", SensitiveDataRedactor.redactPaths(in: String(cString: sqlite3_errmsg(db))))
            }
            guard let dataCString = sqlite3_column_text(statement, 2) else { continue }
            let fallbackMillis = sqlite3_column_int64(statement, 1)
            let data = Data(String(cString: dataCString).utf8)

            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = object["content"] as? [[String: Any]] else {
                continue
            }
            for item in content {
                if let call = Self.normalizeTool(fallbackMillis: fallbackMillis, object: item) {
                    calls.append(call)
                }
            }
        }
        openCodeV2Log.debug("Fetched \(calls.count, privacy: .public) v2 tool calls")
        return calls
    }

    // MARK: - Credential（credential 表）

    func loadAllCredentials() -> [String: String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(openCodeDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT integration_id, value FROM credential WHERE active = 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let integrationCString = sqlite3_column_text(statement, 0),
                  let valueCString = sqlite3_column_text(statement, 1) else { continue }
            let providerId = String(cString: integrationCString)
            guard let value = Self.parseKey(from: String(cString: valueCString)) else { continue }
            result[providerId] = value
        }
        return result
    }

    func upsertCredential(providerID: String, key: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(openCodeDBPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            openCodeV2Log.error("Failed to open db for credential upsert")
            return false
        }
        defer { sqlite3_close(db) }

        guard let valueJSON = Self.makeKeyValueJSON(key: key) else { return false }
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)

        // 已有 active 凭据 → 原地更新；否则同 integration_id 先置 inactive 再插入。
        let existingID = queryCredentialID(db: db, providerID: providerID)
        if let existingID {
            let sql = "UPDATE credential SET value = ?, time_updated = ? WHERE id = ?"
            guard let statement = prepare(db, sql) else { return false }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, valueJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(statement, 2, nowMillis)
            sqlite3_bind_text(statement, 3, existingID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            return sqlite3_step(statement) == SQLITE_DONE
        }

        exec(db, "UPDATE credential SET active = 0 WHERE integration_id = ?", .text(providerID))
        let newID = "cred_" + UUID().uuidString
        let sql = "INSERT INTO credential (id, integration_id, label, value, active, time_created, time_updated) VALUES (?, ?, 'default', ?, 1, ?, ?)"
        guard let statement = prepare(db, sql) else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, newID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, providerID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 3, valueJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(statement, 4, nowMillis)
        sqlite3_bind_int64(statement, 5, nowMillis)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    func deleteCredential(providerID: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(openCodeDBPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        exec(db, "DELETE FROM credential WHERE integration_id = ?", .text(providerID))
        return true
    }

    // MARK: - Private helpers

    private var openCodeDBPath: String {
        (resolveOpenCodeDataDirectory(homeDirectory: homeDirectory, environment: environment) as NSString)
            .appendingPathComponent("opencode.db")
    }

    private func prepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        return statement
    }

    private func exec(_ db: OpaquePointer?, _ sql: String, _ bind: BindValue?) {
        guard let statement = prepare(db, sql) else { return }
        defer { sqlite3_finalize(statement) }
        if let bind {
            switch bind {
            case .int64(let int): sqlite3_bind_int64(statement, 1, int)
            case .text(let str): sqlite3_bind_text(statement, 1, str, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
        _ = sqlite3_step(statement)
    }

    private func queryCredentialID(db: OpaquePointer?, providerID: String) -> String? {
        let sql = "SELECT id FROM credential WHERE integration_id = ? AND active = 1 LIMIT 1"
        guard let statement = prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, providerID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let idCString = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: idCString)
    }

    private static func parseKey(from valueString: String) -> String? {
        guard let data = valueString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "key",
              let key = object["key"] as? String else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func makeKeyValueJSON(key: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "key", "key": key]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func normalizeMessage(
        id: String,
        sessionId: String,
        millis: Int64,
        parsed: V2MessageData
    ) -> OpenCodeMessage {
        let input = parsed.tokens?.input ?? 0
        let output = parsed.tokens?.output ?? 0
        let reasoning = parsed.tokens?.reasoning ?? 0
        let cacheRead = parsed.tokens?.cache?.read ?? 0
        let cacheWrite = parsed.tokens?.cache?.write ?? 0
        let cost = parsed.cost ?? 0
        var durationMs: Int?
        if let created = parsed.time?.created, let completed = parsed.time?.completed, completed >= created {
            durationMs = Int(completed - created)
        }
        return OpenCodeMessage(
            id: id,
            sessionId: sessionId,
            timeCreatedMillis: millis,
            providerID: parsed.model?.providerID,
            modelID: parsed.model?.id,
            inputTokens: input,
            outputTokens: output,
            reasoningTokens: reasoning,
            cacheReadTokens: cacheRead,
            cacheCreateTokens: cacheWrite,
            costUsd: cost,
            durationMs: durationMs
        )
    }

    private static func normalizeTool(fallbackMillis: Int64, object: [String: Any]) -> OpenCodeToolCall? {
        guard object["type"] as? String == "tool",
              let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        let state = object["state"] as? [String: Any]
        let status = (state?["status"] as? String)?.lowercased()
        let inputName = (state?["input"] as? [String: Any])?["name"] as? String
        let time = object["time"] as? [String: Any]
        let createdMillis = (time?["created"] as? NSNumber)?.int64Value ?? fallbackMillis
        var durationMs: Double?
        let ran = (time?["ran"] as? NSNumber)?.doubleValue
        let completed = (time?["completed"] as? NSNumber)?.doubleValue
        if let completed {
            if let ran, completed >= ran {
                durationMs = completed - ran
            } else if completed >= Double(createdMillis) {
                durationMs = completed - Double(createdMillis)
            }
        }
        return OpenCodeToolCall(
            id: (object["id"] as? String) ?? UUID().uuidString,
            name: name,
            timeCreatedMillis: createdMillis,
            status: status,
            durationMs: durationMs,
            inputName: inputName
        )
    }
}
