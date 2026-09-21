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
