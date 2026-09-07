import Foundation
import SQLite3
import os.log

// MARK: - OpenCode SQLite Access
// 只读访问 OpenCode 的 opencode.db（先复制临时快照再打开，见 +Discovery）。
// schema 属于 OpenCode 内部实现（Drizzle 管理），所有读取均做防御处理：
// 表缺失 / 查询失败 → 包装为 ProviderError，由上层呈现为采集失败。

private let openCodeDatabaseLog = Logger(subsystem: "com.aiusage.quotabackend", category: "OpenCodeCost")

extension OpenCodeCostProvider {

    /// message 表的一行原始数据（data 为 OpenCode 的消息 JSON）。
    struct MessageRow: Sendable {
        let messageId: String
        let sessionId: String
        let timeCreatedMillis: Int64
        let data: Data
    }

    /// 从快照库中取出 message 行。`sinceMillis` 为空时全量（首次历史导入）。
    func fetchMessageRows(databasePath: String, sinceMillis: Int64?) throws -> [MessageRow] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(db)
            throw ProviderError("db_open_failed", SensitiveDataRedactor.redactPaths(in: message))
        }
        defer { sqlite3_close(db) }

        var sql = "SELECT id, session_id, time_created, data FROM message"
        if sinceMillis != nil {
            sql += " WHERE time_created >= ?"
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ProviderError("db_query_failed", SensitiveDataRedactor.redactPaths(in: message))
        }
        defer { sqlite3_finalize(statement) }

        if let sinceMillis {
            sqlite3_bind_int64(statement, 1, sinceMillis)
        }

        var rows: [MessageRow] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                let message = String(cString: sqlite3_errmsg(db))
                throw ProviderError("db_step_failed", SensitiveDataRedactor.redactPaths(in: message))
            }

            guard let idCString = sqlite3_column_text(statement, 0),
                  let sessionCString = sqlite3_column_text(statement, 1),
                  let dataCString = sqlite3_column_text(statement, 3) else {
                continue
            }
            rows.append(MessageRow(
                messageId: String(cString: idCString),
                sessionId: String(cString: sessionCString),
                timeCreatedMillis: sqlite3_column_int64(statement, 2),
                data: Data(String(cString: dataCString).utf8)
            ))
        }

        openCodeDatabaseLog.debug("Fetched \(rows.count, privacy: .public) OpenCode message rows")
        return rows
    }
}
