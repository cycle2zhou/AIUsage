import Foundation
import SQLite3
import os.log

// MARK: - OpenCode Call Event Source
// 解析 OpenCode 的 opencode.db `part` 表，提取工具 / MCP / Skill 调用计数。
// 数据来源: ~/.local/share/opencode/opencode.db（或 $XDG_DATA_HOME / Application Support）。
// part 行 data(JSON)：{ "type":"tool", "tool":"<名>", "state":{ "status":..., "input":{...} } }。
// 复制临时只读快照后查询（OpenCode 运行中持有 WAL 写锁）。

private let openCodeCallLog = Logger(subsystem: "com.aiusage.quotabackend", category: "CallAnalytics")

struct OpenCodeCallEventSource {
    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]
    /// 已配置的 OpenCode MCP server 名（来自 opencode.json）。用于把工具名 `<server>_<tool>`
    /// 按已知 server 做最长前缀匹配，处理 server 名本身含 `_`/`-` 的情况；缺省回退首个 `_` 启发式。
    var knownMCPServers: Set<String> = []

    private static let databaseFilename = "opencode.db"
    /// OpenCode 内置工具名（单词、无下划线）。其余含下划线者按 MCP 处理（启发式，见 classify）。
    private static let builtinTools: Set<String> = [
        "read", "write", "edit", "multiedit", "bash", "glob", "grep",
        "list", "webfetch", "patch", "task", "question", "todowrite", "todoread", "invalid"
    ]

    func collect(cutoff: Date?) -> (entries: [OpenCodeCallLedgerEntry], status: CallSourceStatus) {
        let clock = CallAnalyticsClock(timeZone: timeZone)
        guard let dataDirectory = resolveDataDirectory() else {
            return ([], CallSourceStatus(source: .opencode, available: false, eventCount: 0, filesScanned: 0, errorCode: nil))
        }

        let snapshotPath: String
        do {
            snapshotPath = try makeDatabaseSnapshot(dataDirectory: dataDirectory)
        } catch {
            let code = (error as? ProviderError)?.code ?? "db_snapshot_failed"
            return ([], CallSourceStatus(source: .opencode, available: true, eventCount: 0, filesScanned: 0, errorCode: code))
        }
        defer { cleanupDatabaseSnapshot(snapshotPath) }

        let sinceMillis: Int64? = cutoff.map { Int64($0.timeIntervalSince1970 * 1000) }
        var entries: [OpenCodeCallLedgerEntry] = []
        do {
            try forEachToolPart(databasePath: snapshotPath, sinceMillis: sinceMillis) { partId, millis, data in
                if let entry = parsePart(partId: partId, data, millis: millis, clock: clock) {
                    entries.append(entry)
                }
            }
        } catch {
            let code = (error as? ProviderError)?.code ?? "db_query_failed"
            return ([], CallSourceStatus(source: .opencode, available: true, eventCount: 0, filesScanned: 0, errorCode: code))
        }

        let status = CallSourceStatus(
            source: .opencode,
            available: true,
            eventCount: entries.count,
            filesScanned: 1,
            errorCode: nil
        )
        return (entries, status)
    }

    // MARK: - Parsing

    private func parsePart(
        partId: String,
        _ data: Data,
        millis: Int64,
        clock: CallAnalyticsClock
    ) -> OpenCodeCallLedgerEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "tool",
              let tool = (object["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tool.isEmpty else {
            return nil
        }
        let dayKey = clock.dayKey(fromMillis: millis)
        let state = object["state"] as? [String: Any]
        return classify(partId: partId, tool: tool, state: state, dayKey: dayKey)
    }

    private func classify(
        partId: String,
        tool: String,
        state: [String: Any]?,
        dayKey: String
    ) -> OpenCodeCallLedgerEntry {
        let lower = tool.lowercased()
        // OpenCode 每条 tool part 自带 status 与 time，故成功率/耗时对所有类别（MCP/技能/工具）通用。
        let success = Self.outcome(from: state)
        let durationMs = Self.durationMs(from: state)

        if lower == "skill" {
            let input = state?["input"] as? [String: Any]
            let raw = (input?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let skillName = raw.isEmpty ? "(unknown)" : raw
            return OpenCodeCallLedgerEntry(partId: partId, dayKey: dayKey, kind: .skill, name: skillName, server: nil, success: success, durationMs: durationMs)
        }

        if Self.builtinTools.contains(lower) {
            let kind: CallKind = lower == "webfetch" ? .webSearch : .builtin
            return OpenCodeCallLedgerEntry(partId: partId, dayKey: dayKey, kind: kind, name: tool, server: nil, success: success, durationMs: durationMs)
        }

        // 优先用已装 server 名做最长前缀匹配（server 名本身含 `_`/`-` 时切分才准），匹配不到再回退。
        if let match = matchKnownServer(tool: tool) {
            return OpenCodeCallLedgerEntry(
                partId: partId,
                dayKey: dayKey,
                kind: .mcp,
                name: CallAnalyticsNaming.mcpDisplayName(server: match.server, tool: match.tool),
                server: match.server,
                success: success,
                durationMs: durationMs
            )
        }

        // 回退启发式：OpenCode 把 MCP 工具命名为 `<server>_<tool>`；非内置且含下划线者归为 MCP。
        if let sep = tool.firstIndex(of: "_") {
            let server = String(tool[tool.startIndex..<sep])
            let toolName = String(tool[tool.index(after: sep)...])
            if !server.isEmpty, !toolName.isEmpty {
                return OpenCodeCallLedgerEntry(
                    partId: partId,
                    dayKey: dayKey,
                    kind: .mcp,
                    name: CallAnalyticsNaming.mcpDisplayName(server: server, tool: toolName),
                    server: server,
                    success: success,
                    durationMs: durationMs
                )
            }
        }

        return OpenCodeCallLedgerEntry(partId: partId, dayKey: dayKey, kind: .other, name: tool, server: nil, success: success, durationMs: durationMs)
    }

    /// 从 part.state 判定成功/失败：completed→成功，error→失败，其余（pending/running 等）→nil（不计入分母）。
    private static func outcome(from state: [String: Any]?) -> Bool? {
        guard let status = (state?["status"] as? String)?.lowercased() else { return nil }
        switch status {
        case "completed": return true
        case "error": return false
        default: return nil
        }
    }

    /// 从 part.state.time.{start,end}（毫秒时间戳）算耗时；缺失或非法返回 nil。
    private static func durationMs(from state: [String: Any]?) -> Double? {
        guard let time = state?["time"] as? [String: Any],
              let start = (time["start"] as? NSNumber)?.doubleValue,
              let end = (time["end"] as? NSNumber)?.doubleValue,
              end >= start else { return nil }
        return end - start
    }

    /// 在已装 server 名里找能作为 `tool` 前缀的最长者（`<server>_<tool>`）。
    /// 同时尝试把 server 名的 `-` 归一为 `_` 比较，兼容工具命名替换连字符的情况；
    /// 返回的 server 用配置原名，保证与零调用清单对得上。
    private func matchKnownServer(tool: String) -> (server: String, tool: String)? {
        guard !knownMCPServers.isEmpty else { return nil }
        for server in knownMCPServers.sorted(by: { $0.count > $1.count }) {
            for candidate in [server, server.replacingOccurrences(of: "-", with: "_")] {
                let prefix = candidate + "_"
                if tool.hasPrefix(prefix) {
                    let toolName = String(tool.dropFirst(prefix.count))
                    if !toolName.isEmpty { return (server, toolName) }
                }
            }
        }
        return nil
    }

    // MARK: - Discovery + snapshot

    private func resolveDataDirectory() -> String? {
        var candidates: [String] = []
        if let xdg = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            candidates.append((xdg as NSString).appendingPathComponent("opencode"))
        }
        candidates.append((homeDirectory as NSString).appendingPathComponent(".local/share/opencode"))
        candidates.append((homeDirectory as NSString).appendingPathComponent("Library/Application Support/opencode"))

        return candidates.first { directory in
            FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(Self.databaseFilename))
        }
    }

    private func makeDatabaseSnapshot(dataDirectory: String) throws -> String {
        let sourcePath = (dataDirectory as NSString).appendingPathComponent(Self.databaseFilename)
        let snapshotPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("aiusage-callanalytics-\(UUID().uuidString).db")
        do {
            try FileManager.default.copyItem(atPath: sourcePath, toPath: snapshotPath)
        } catch {
            throw ProviderError("db_snapshot_failed", SensitiveDataRedactor.redactedMessage(for: error))
        }
        try? FileManager.default.copyItem(atPath: sourcePath + "-wal", toPath: snapshotPath + "-wal")
        try? FileManager.default.copyItem(atPath: sourcePath + "-shm", toPath: snapshotPath + "-shm")
        return snapshotPath
    }

    private func cleanupDatabaseSnapshot(_ snapshotPath: String) {
        try? FileManager.default.removeItem(atPath: snapshotPath)
        try? FileManager.default.removeItem(atPath: snapshotPath + "-wal")
        try? FileManager.default.removeItem(atPath: snapshotPath + "-shm")
    }

    private func forEachToolPart(
        databasePath: String,
        sinceMillis: Int64?,
        onRow: (String, Int64, Data) -> Void
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
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
            let message = String(cString: sqlite3_errmsg(db))
            throw ProviderError("db_query_failed", SensitiveDataRedactor.redactPaths(in: message))
        }
        defer { sqlite3_finalize(statement) }

        if let sinceMillis {
            sqlite3_bind_int64(statement, 1, sinceMillis)
        }

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                let message = String(cString: sqlite3_errmsg(db))
                throw ProviderError("db_step_failed", SensitiveDataRedactor.redactPaths(in: message))
            }
            guard let idCString = sqlite3_column_text(statement, 0) else { continue }
            let partId = String(cString: idCString)
            let millis = sqlite3_column_int64(statement, 1)
            guard let dataCString = sqlite3_column_text(statement, 2) else { continue }
            onRow(partId, millis, Data(String(cString: dataCString).utf8))
        }
        openCodeCallLog.debug("OpenCode call-analytics scanned part rows")
    }
}
