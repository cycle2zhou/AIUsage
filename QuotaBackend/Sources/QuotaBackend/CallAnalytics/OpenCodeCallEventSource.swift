import Foundation
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
        "list", "webfetch", "patch", "task", "question", "todowrite", "todoread", "invalid",
        // v2 Code Mode 内置搜索工具（无 namespace，execute 展开后 name="search"）。
        "search"
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
            let storage = resolveOpenCodeStorage(homeDirectory: homeDirectory, environment: environment)
            let calls = try storage.fetchToolCalls(dbPath: snapshotPath, sinceMillis: sinceMillis)
            for call in calls {
                let dayKey = clock.dayKey(fromMillis: call.timeCreatedMillis)
                entries.append(classify(call: call, dayKey: dayKey))
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

    /// 把一条归一化工具调用归为 skill / builtin / mcp / other。成功率/耗时取 OpenCodeToolCall 的
    /// status/durationMs（reader 已按版本归一化）。
    private func classify(call: OpenCodeToolCall, dayKey: String) -> OpenCodeCallLedgerEntry {
        let lower = call.name.lowercased()
        let success = Self.outcome(from: call.status)
        let durationMs = call.durationMs

        if lower == "skill" {
            let raw = (call.inputName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let skillName = raw.isEmpty ? "(unknown)" : raw
            return OpenCodeCallLedgerEntry(partId: call.id, dayKey: dayKey, kind: .skill, name: skillName, server: nil, success: success, durationMs: durationMs)
        }

        if Self.builtinTools.contains(lower) {
            let kind: CallKind = lower == "webfetch" ? .webSearch : .builtin
            return OpenCodeCallLedgerEntry(partId: call.id, dayKey: dayKey, kind: kind, name: call.name, server: nil, success: success, durationMs: durationMs)
        }

        // 优先用已装 server 名做最长前缀匹配（server 名本身含 `_`/`-` 时切分才准），匹配不到再回退。
        if let match = matchKnownServer(tool: call.name) {
            return OpenCodeCallLedgerEntry(
                partId: call.id,
                dayKey: dayKey,
                kind: .mcp,
                name: CallAnalyticsNaming.mcpDisplayName(server: match.server, tool: match.tool),
                server: match.server,
                success: success,
                durationMs: durationMs
            )
        }

        // 已知 server 清单可用时，匹配不上 matchKnownServer 的工具不是 MCP，而是插件 namespace 工具
        // （v2 内置插件如 opencode/acp 也用 `<namespace>_<tool>` 命名，会被旧启发式误归为 MCP）。
        // 仅在拿不到配置清单时，才回退「非内置且含下划线即 MCP」的启发式兜底。
        if knownMCPServers.isEmpty,
           let sep = call.name.firstIndex(of: "_") {
            let server = String(call.name[call.name.startIndex..<sep])
            let toolName = String(call.name[call.name.index(after: sep)...])
            if !server.isEmpty, !toolName.isEmpty {
                return OpenCodeCallLedgerEntry(
                    partId: call.id,
                    dayKey: dayKey,
                    kind: .mcp,
                    name: CallAnalyticsNaming.mcpDisplayName(server: server, tool: toolName),
                    server: server,
                    success: success,
                    durationMs: durationMs
                )
            }
        }

        return OpenCodeCallLedgerEntry(partId: call.id, dayKey: dayKey, kind: .other, name: call.name, server: nil, success: success, durationMs: durationMs)
    }

    /// 从归一化 status 判定成功/失败：completed→成功，error→失败，其余→nil（不计入分母）。
    private static func outcome(from status: String?) -> Bool? {
        guard let status else { return nil }
        switch status {
        case "completed": return true
        case "error": return false
        default: return nil
        }
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
}
