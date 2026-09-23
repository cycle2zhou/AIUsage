import Foundation
import SQLite3
import XCTest
@testable import QuotaBackend

// MARK: - opencode v2 兼容单测
// 覆盖 v2 适配里可脱离数据库纯测的核心逻辑：
//   1. 版本探测 isV2（防止 GUI PATH 受限误判 v1 回归）
//   2. v2 tool call 归一化 + Code Mode execute 容器展开（MCP 排行无数据根因修复）
//   3. 工具归类 classify（skill 名 / builtin / MCP 前缀匹配 / 插件 namespace 工具误归）
//   4. MCP server 清单解析 addServerKeys（v2 mcp.servers 嵌套 vs v1 平铺）

// MARK: 版本探测

final class OpenCodeVersionDetectionTests: XCTestCase {
    func testV2VersionStringsAreDetected() {
        XCTAssertTrue(isV2("opencode v2.0.11"))
        XCTAssertTrue(isV2("2.0.11"))
        XCTAssertTrue(isV2("v2.0.11"))
        XCTAssertTrue(isV2("2"))
        XCTAssertTrue(isV2("2.1.0"))
    }

    func testV1VersionStringsAreNotDetectedAsV2() {
        XCTAssertFalse(isV2("1.5.0"))
        XCTAssertFalse(isV2("opencode 0.1.0"))
        XCTAssertFalse(isV2("v1.0.0"))
        XCTAssertFalse(isV2("1"))
    }
}

// MARK: v2 tool call 归一化 + execute 展开

final class OpenCodeV2ToolNormalizationTests: XCTestCase {
    func testExecuteContainerExpandsMCPToolCallsToUnderscoreNames() {
        let object: [String: Any] = [
            "type": "tool",
            "name": "execute",
            "id": "tool_exec_1",
            "state": [
                "status": "completed",
                "metadata": [
                    "toolCalls": [
                        ["tool": "dbx.dbx_execute_query", "status": "completed"],
                        ["tool": "jetbrains_idea.analyze_calls", "status": "error"],
                    ]
                ],
            ],
        ]
        let calls = OpenCodeV2Storage.normalizeTool(fallbackMillis: 0, object: object)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "dbx_dbx_execute_query")
        XCTAssertEqual(calls[0].status, "completed")
        XCTAssertEqual(calls[1].name, "jetbrains_idea_analyze_calls")
        XCTAssertEqual(calls[1].status, "error")
    }

    func testExecuteWithEmptyToolCallsFallsBackToExecuteItself() {
        let object: [String: Any] = [
            "type": "tool",
            "name": "execute",
            "state": ["status": "completed", "metadata": ["toolCalls": []]],
        ]
        let calls = OpenCodeV2Storage.normalizeTool(fallbackMillis: 0, object: object)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "execute")
    }

    func testSkillNameReadsMetadataNameFirst() {
        let object: [String: Any] = [
            "type": "tool",
            "name": "skill",
            "state": [
                "status": "completed",
                "metadata": ["name": "effect"],
                "input": ["id": "tigerstyle"],
            ],
        ]
        let calls = OpenCodeV2Storage.normalizeTool(fallbackMillis: 0, object: object)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "skill")
        XCTAssertEqual(calls[0].inputName, "effect")
    }

    func testSkillNameFallsBackToInputID() {
        let object: [String: Any] = [
            "type": "tool",
            "name": "skill",
            "state": ["status": "completed", "input": ["id": "tigerstyle"]],
        ]
        let calls = OpenCodeV2Storage.normalizeTool(fallbackMillis: 0, object: object)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].inputName, "tigerstyle")
    }

    func testNonToolObjectYieldsNoCalls() {
        let object: [String: Any] = ["type": "text", "text": "hello"]
        XCTAssertTrue(OpenCodeV2Storage.normalizeTool(fallbackMillis: 0, object: object).isEmpty)
    }
}

// MARK: 工具归类

final class OpenCodeCallClassificationTests: XCTestCase {
    private func makeSource(servers: Set<String> = []) -> OpenCodeCallEventSource {
        OpenCodeCallEventSource(
            homeDirectory: "/tmp",
            timeZone: TimeZone(identifier: "UTC")!,
            environment: [:],
            knownMCPServers: servers
        )
    }

    private func makeCall(
        _ name: String,
        status: String? = "completed",
        inputName: String? = nil
    ) -> OpenCodeToolCall {
        OpenCodeToolCall(
            id: "tool_1",
            name: name,
            timeCreatedMillis: 123,
            status: status,
            durationMs: nil,
            inputName: inputName
        )
    }

    func testSkillClassificationUsesInputName() {
        let entry = makeSource().classify(
            call: makeCall("skill", inputName: "remote-server-rmux"),
            dayKey: "2026-09-21"
        )
        XCTAssertEqual(entry.kind, .skill)
        XCTAssertEqual(entry.name, "remote-server-rmux")
    }

    func testSkillWithoutInputNameBecomesUnknown() {
        let entry = makeSource().classify(call: makeCall("skill"), dayKey: "2026-09-21")
        XCTAssertEqual(entry.kind, .skill)
        XCTAssertEqual(entry.name, "(unknown)")
    }

    func testBuiltinAndSearchToolsAreBuiltin() {
        XCTAssertEqual(makeSource().classify(call: makeCall("read"), dayKey: "d").kind, .builtin)
        // v2 Code Mode 内置搜索工具（无 namespace）。
        XCTAssertEqual(makeSource().classify(call: makeCall("search"), dayKey: "d").kind, .builtin)
    }

    func testWebFetchIsWebSearch() {
        XCTAssertEqual(makeSource().classify(call: makeCall("webfetch"), dayKey: "d").kind, .webSearch)
    }

    func testMCPServerExactPrefixMatch() {
        let entry = makeSource(servers: ["drawio_next"]).classify(
            call: makeCall("drawio_next_list_pages"),
            dayKey: "d"
        )
        XCTAssertEqual(entry.kind, .mcp)
        XCTAssertEqual(entry.server, "drawio_next")
        XCTAssertEqual(entry.name, "drawio_next/list_pages")
    }

    func testMCPServerNameContainingUnderscore() {
        let entry = makeSource(servers: ["jetbrains_idea"]).classify(
            call: makeCall("jetbrains_idea_analyze_calls"),
            dayKey: "d"
        )
        XCTAssertEqual(entry.kind, .mcp)
        XCTAssertEqual(entry.server, "jetbrains_idea")
    }

    func testPluginNamespaceToolIsNotMCPWhenServerListKnown() {
        // v2 内置插件（opencode/acp）也用 `<namespace>_<tool>` 命名，须归 .other 而非 .mcp。
        let entry = makeSource(servers: ["drawio_next"]).classify(
            call: makeCall("opencode_session_rename"),
            dayKey: "d"
        )
        XCTAssertEqual(entry.kind, .other)
    }

    func testFallbackHeuristicWhenServerListUnknown() {
        // 拿不到配置清单时，回退「含下划线即 MCP」启发式兜底。
        let entry = makeSource(servers: []).classify(
            call: makeCall("dbx_dbx_execute_query"),
            dayKey: "d"
        )
        XCTAssertEqual(entry.kind, .mcp)
        XCTAssertEqual(entry.server, "dbx")
    }

    func testOutcomeMapping() {
        XCTAssertEqual(OpenCodeCallEventSource.outcome(from: "completed"), true)
        XCTAssertEqual(OpenCodeCallEventSource.outcome(from: "error"), false)
        XCTAssertNil(OpenCodeCallEventSource.outcome(from: "running"))
        XCTAssertNil(OpenCodeCallEventSource.outcome(from: nil))
    }
}

// MARK: MCP server 清单解析

final class OpenCodeMCPServerInventoryTests: XCTestCase {
    private func makeInventory() -> CallAnalyticsInventory {
        CallAnalyticsInventory(homeDirectory: "/tmp", environment: [:])
    }

    func testV2NestedMCPServers() {
        let config: [String: Any] = [
            "mcp": ["servers": ["drawio_next": [String: Any](), "dbx": [String: Any]()]],
        ]
        var names = Set<String>()
        makeInventory().addServerKeys(from: config, into: &names)
        XCTAssertEqual(names, ["drawio_next", "dbx"])
    }

    func testV1FlatMCPServers() {
        let config: [String: Any] = ["mcp": ["docs": [String: Any]()]]
        var names = Set<String>()
        makeInventory().addServerKeys(from: config, into: &names)
        XCTAssertEqual(names, ["docs"])
    }

    func testClaudeFlatMCPServers() {
        let config: [String: Any] = ["mcpServers": ["github": [String: Any]()]]
        var names = Set<String>()
        makeInventory().addServerKeys(from: config, into: &names)
        XCTAssertEqual(names, ["github"])
    }
}

// MARK: v2 凭据快照/恢复（停用路径回滚下沉到 storage 层后的 db 集成测试）

final class OpenCodeCredentialSnapshotTests: XCTestCase {
    private func makeStorage(home: URL, xdg: URL) throws -> OpenCodeV2Storage {
        let dbDir = xdg.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("opencode.db").path
        try executeSQL(
            """
            CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, label TEXT NOT NULL, value TEXT NOT NULL, active INTEGER, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
            INSERT INTO credential VALUES ('c1', 'aiusage-a', 'default', '{"type":"key","key":"keyA"}', 1, 1, 1);
            INSERT INTO credential VALUES ('c2', 'aiusage-b', 'default', '{"type":"key","key":"keyB"}', 1, 1, 1);
            INSERT INTO credential VALUES ('c3', 'alibaba', 'default', '{"type":"key","key":"other"}', 1, 1, 1);
            """,
            databasePath: dbPath
        )
        return OpenCodeV2Storage(homeDirectory: home.path, environment: ["XDG_DATA_HOME": xdg.path])
    }

    func testSnapshotCredentialsFiltersByPredicate() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let xdg = home.appendingPathComponent("xdg", isDirectory: true)
        let storage = try makeStorage(home: home, xdg: xdg)

        let snapshot = storage.snapshotCredentials(matching: { $0.hasPrefix("aiusage") })
        XCTAssertEqual(snapshot, ["aiusage-a": "keyA", "aiusage-b": "keyB"])
    }

    func testRestoreCredentialsRestoresManagedAndKeepsOthers() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let xdg = home.appendingPathComponent("xdg", isDirectory: true)
        let storage = try makeStorage(home: home, xdg: xdg)

        // 停用前快照受管凭据。
        let snapshot = storage.snapshotCredentials(matching: { $0.hasPrefix("aiusage") })

        // 模拟停用：清空受管凭据，非受管保留。
        XCTAssertTrue(storage.restoreCredentials([:], matching: { $0.hasPrefix("aiusage") }))
        XCTAssertEqual(storage.loadAllCredentials(), ["alibaba": "other"])

        // 后续文件操作失败：写回快照，受管凭据恢复，非受管不受影响。
        XCTAssertTrue(storage.restoreCredentials(snapshot, matching: { $0.hasPrefix("aiusage") }))
        XCTAssertEqual(
            storage.loadAllCredentials(),
            ["aiusage-a": "keyA", "aiusage-b": "keyB", "alibaba": "other"]
        )
    }

    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-opencode-credential-tests-\(UUID())", isDirectory: true)
    }

    private func executeSQL(_ sql: String, databasePath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw ProviderError("db_open_failed", message)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ProviderError("db_exec_failed", message)
        }
    }
}
