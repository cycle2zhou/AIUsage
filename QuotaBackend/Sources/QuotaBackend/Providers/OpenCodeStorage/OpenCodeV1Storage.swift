import Foundation
import SQLite3
import os.log

// MARK: - OpenCode V1 Storage
// v1 schema 读取：`message` 表（data JSON 顶层 role/providerID/modelID）+ 独立 `part` 表（tool 调用）
// + auth.json 文件凭据。本文件只承载 v1 差异，v2/v3 新增不触碰。

private let openCodeV1Log = Logger(subsystem: "com.aiusage.quotabackend", category: "OpenCodeV1Storage")

struct OpenCodeV1Storage: OpenCodeStorage {
    let homeDirectory: String
    let environment: [String: String]
    let schema: OpenCodeSchema = .v1

    var credentialFilePaths: [String] { [authJSONPath] }

    init(homeDirectory: String, environment: [String: String]) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    // MARK: - Message

    /// v1 message.data 中本 reader 关心的子集（顶层 role/providerID/modelID，无 reasoning）。
    private struct V1MessageData: Decodable {
        struct Tokens: Decodable {
            struct Cache: Decodable {
                let read: Int?
                let write: Int?
            }
            let input: Int?
            let output: Int?
            let cache: Cache?
        }
        struct TimeInfo: Decodable {
            let created: Int64?
            let completed: Int64?
        }

        let role: String?
        let providerID: String?
        let modelID: String?
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

        // v1 无 type 列，SQL 层不区分 assistant，读全行后按 role 过滤。
        var sql = "SELECT id, session_id, time_created, data FROM message"
        var binds: [BindValue] = []
        var whereParts: [String] = []
        if let since = query.sinceMillis {
            whereParts.append("time_created >= ?")
            binds.append(.int64(since))
        }
        if let dataLike = query.dataLike {
            whereParts.append("data LIKE ?")
            binds.append(.text(dataLike))
        }
        if !whereParts.isEmpty {
            sql += " WHERE " + whereParts.joined(separator: " AND ")
        }
        // 稳定倒序：recent 取前 N 条需最新在前，否则 stats 页 recent 列表顺序随 sqlite 扫描顺序漂移。
        sql += " ORDER BY time_created DESC, id DESC"

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

            guard let parsed = try? decoder.decode(V1MessageData.self, from: data),
                  parsed.role == "assistant" else {
                continue
            }
            messages.append(Self.normalizeMessage(id: id, sessionId: sessionId, millis: millis, parsed: parsed))
        }
        openCodeV1Log.debug("Fetched \(messages.count, privacy: .public) v1 message rows")
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

        var sql = "SELECT id, time_created, data FROM part WHERE data LIKE '%\"type\":\"tool\"%'"
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
            guard let idCString = sqlite3_column_text(statement, 0),
                  let dataCString = sqlite3_column_text(statement, 2) else {
                continue
            }
            let id = String(cString: idCString)
            let millis = sqlite3_column_int64(statement, 1)
            let data = Data(String(cString: dataCString).utf8)

            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let call = Self.normalizeTool(id: id, millis: millis, object: object) else {
                continue
            }
            calls.append(call)
        }
        openCodeV1Log.debug("Fetched \(calls.count, privacy: .public) v1 tool calls")
        return calls
    }

    // MARK: - Credential（auth.json）

    func loadAllCredentials() -> [String: String] {
        guard let root = loadAuthJSON() else { return [:] }
        var result: [String: String] = [:]
        for (providerId, value) in root {
            guard let entry = value as? [String: Any],
                  entry["type"] as? String == "api" else { continue }
            if let key = entry["key"] as? String {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result[providerId] = trimmed }
            }
        }
        return result
    }

    func upsertCredential(providerID: String, key: String) -> Bool {
        var root = loadAuthJSON() ?? [:]
        root[providerID] = ["type": "api", "key": key]
        return writeAuthJSON(root)
    }

    func deleteCredential(providerID: String) -> Bool {
        guard var root = loadAuthJSON() else { return true }
        root.removeValue(forKey: providerID)
        return writeAuthJSON(root)
    }

    // MARK: - Private helpers

    private var authJSONPath: String {
        (resolveOpenCodeDataDirectory(homeDirectory: homeDirectory, environment: environment) as NSString)
            .appendingPathComponent("auth.json")
    }

    private func loadAuthJSON() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: authJSONPath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return root
    }

    private func writeAuthJSON(_ root: [String: Any]) -> Bool {
        let directory = (authJSONPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: URL(fileURLWithPath: authJSONPath), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authJSONPath)
            return true
        } catch {
            openCodeV1Log.error("Failed to write auth.json: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func normalizeMessage(
        id: String,
        sessionId: String,
        millis: Int64,
        parsed: V1MessageData
    ) -> OpenCodeMessage {
        let input = parsed.tokens?.input ?? 0
        let output = parsed.tokens?.output ?? 0
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
            providerID: parsed.providerID,
            modelID: parsed.modelID,
            inputTokens: input,
            outputTokens: output,
            reasoningTokens: 0,
            cacheReadTokens: cacheRead,
            cacheCreateTokens: cacheWrite,
            costUsd: cost,
            durationMs: durationMs
        )
    }

    private static func normalizeTool(id: String, millis: Int64, object: [String: Any]) -> OpenCodeToolCall? {
        guard object["type"] as? String == "tool",
              let name = (object["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        let state = object["state"] as? [String: Any]
        let status = (state?["status"] as? String)?.lowercased()
        let inputName = (state?["input"] as? [String: Any])?["name"] as? String
        var durationMs: Double?
        if let time = state?["time"] as? [String: Any],
           let start = (time["start"] as? NSNumber)?.doubleValue,
           let end = (time["end"] as? NSNumber)?.doubleValue,
           end >= start {
            durationMs = end - start
        }
        return OpenCodeToolCall(
            id: id,
            name: name,
            timeCreatedMillis: millis,
            status: status,
            durationMs: durationMs,
            inputName: inputName
        )
    }
}
