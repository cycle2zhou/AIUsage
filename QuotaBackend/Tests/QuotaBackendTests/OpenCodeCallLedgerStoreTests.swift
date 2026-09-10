import XCTest

@testable import QuotaBackend

final class OpenCodeCallLedgerStoreTests: XCTestCase {

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-opencode-call-ledger-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEntry(
        partId: String,
        dayKey: String = "2026-09-07",
        kind: CallKind = .builtin,
        name: String = "bash",
        server: String? = nil,
        success: Bool? = true,
        durationMs: Double? = 100
    ) -> OpenCodeCallLedgerEntry {
        OpenCodeCallLedgerEntry(
            partId: partId,
            dayKey: dayKey,
            kind: kind,
            name: name,
            server: server,
            success: success,
            durationMs: durationMs
        )
    }

    func testMergeAccumulatesNewEntriesAcrossBatches() {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = OpenCodeCallLedgerStore(homeDirectory: tempRoot.path)

        _ = store.merge(newEntries: [makeEntry(partId: "prt_1"), makeEntry(partId: "prt_2")], scanSucceeded: true)
        _ = store.merge(newEntries: [makeEntry(partId: "prt_3")], scanSucceeded: true)

        let all = store.allEntries()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.partId)), ["prt_1", "prt_2", "prt_3"])
    }

    func testMergeRetainsEntriesNotInLaterBatch() {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = OpenCodeCallLedgerStore(homeDirectory: tempRoot.path)

        _ = store.merge(
            newEntries: [makeEntry(partId: "prt_1"), makeEntry(partId: "prt_2"), makeEntry(partId: "prt_3")],
            scanSucceeded: true
        )
        // 第二批只扫到 prt_1（prt_2、prt_3 对应会话被删除），账本应保留它们。
        _ = store.merge(newEntries: [makeEntry(partId: "prt_1")], scanSucceeded: true)

        let all = store.allEntries()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.partId)), ["prt_1", "prt_2", "prt_3"])
    }

    func testMergeUpdatesExistingEntryWithoutDoubleCounting() {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = OpenCodeCallLedgerStore(homeDirectory: tempRoot.path)

        _ = store.merge(newEntries: [makeEntry(partId: "prt_1", success: false, durationMs: 50)], scanSucceeded: true)
        // 同一条 part 状态从 running 更新为 completed：应覆盖旧值而非新增一条。
        _ = store.merge(newEntries: [makeEntry(partId: "prt_1", success: true, durationMs: 200)], scanSucceeded: true)

        let all = store.allEntries()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.success, true)
        XCTAssertEqual(all.first?.durationMs, 200)
    }

    func testAggregateGroupsByDayKey() {
        let entries = [
            makeEntry(partId: "prt_1", dayKey: "2026-09-06"),
            makeEntry(partId: "prt_2", dayKey: "2026-09-07"),
        ]
        let aggregated = OpenCodeCallLedgerStore.aggregate(entries)
        XCTAssertEqual(Set(aggregated.map(\.dayKey)), ["2026-09-06", "2026-09-07"])
    }

    func testAggregateSumCountAndSignalsByKindAndName() {
        let entries = [
            makeEntry(partId: "prt_1", kind: .builtin, name: "bash", success: true, durationMs: 100),
            makeEntry(partId: "prt_2", kind: .builtin, name: "bash", success: false, durationMs: 300),
            makeEntry(partId: "prt_3", kind: .builtin, name: "read", success: nil, durationMs: nil),
        ]
        let aggregated = OpenCodeCallLedgerStore.aggregate(entries)

        let bash = aggregated.first { $0.name == "bash" }
        XCTAssertEqual(bash?.count, 2)
        XCTAssertEqual(bash?.outcomeKnownCount, 2)
        XCTAssertEqual(bash?.successCount, 1)
        XCTAssertEqual(bash?.durationSampleCount, 2)
        XCTAssertEqual(bash?.durationMsTotal, 400)

        let read = aggregated.first { $0.name == "read" }
        XCTAssertEqual(read?.count, 1)
        XCTAssertEqual(read?.outcomeKnownCount, 0)
        XCTAssertEqual(read?.successCount, 0)
        XCTAssertEqual(read?.durationSampleCount, 0)
        XCTAssertEqual(read?.durationMsTotal, 0)
    }

    func testAggregateMCPKeepsServer() {
        let entries = [
            makeEntry(partId: "prt_1", kind: .mcp, name: "server/tool", server: "server"),
        ]
        let aggregated = OpenCodeCallLedgerStore.aggregate(entries)
        XCTAssertEqual(aggregated.count, 1)
        XCTAssertEqual(aggregated.first?.server, "server")
        XCTAssertEqual(aggregated.first?.source, .opencode)
    }

    func testFullHistoryImportFlagPersists() {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = OpenCodeCallLedgerStore(homeDirectory: tempRoot.path)

        _ = store.merge(newEntries: [makeEntry(partId: "prt_1")], scanSucceeded: true)
        XCTAssertTrue(store.fullHistoryImported)

        // 重新实例化（模拟重启）后标记仍在。
        let reopened = OpenCodeCallLedgerStore(homeDirectory: tempRoot.path)
        XCTAssertTrue(reopened.fullHistoryImported)
    }

    func testFullHistoryImportFlagSetOnEmptyMerge() {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = OpenCodeCallLedgerStore(homeDirectory: tempRoot.path)

        _ = store.merge(newEntries: [], scanSucceeded: true)
        XCTAssertTrue(store.fullHistoryImported)
    }

    func testScanFailureDoesNotMarkFullHistoryImport() {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = OpenCodeCallLedgerStore(homeDirectory: tempRoot.path)

        _ = store.merge(newEntries: [makeEntry(partId: "prt_1")], scanSucceeded: false)
        XCTAssertFalse(store.fullHistoryImported)
        XCTAssertNil(store.lastSuccessfulScanDate)

        let reopened = OpenCodeCallLedgerStore(homeDirectory: tempRoot.path)
        XCTAssertFalse(reopened.fullHistoryImported)
        XCTAssertNil(reopened.lastSuccessfulScanDate)
    }

    func testScanSuccessMarksFullHistoryAndAdvancesCursor() {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = OpenCodeCallLedgerStore(homeDirectory: tempRoot.path)

        _ = store.merge(newEntries: [makeEntry(partId: "prt_1")], scanSucceeded: true)
        XCTAssertTrue(store.fullHistoryImported)
        XCTAssertNotNil(store.lastSuccessfulScanDate)

        let reopened = OpenCodeCallLedgerStore(homeDirectory: tempRoot.path)
        XCTAssertTrue(reopened.fullHistoryImported)
        XCTAssertNotNil(reopened.lastSuccessfulScanDate)
    }

    func testScanFailureThenSuccessRecoversFullHistory() {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = OpenCodeCallLedgerStore(homeDirectory: tempRoot.path)

        _ = store.merge(newEntries: [], scanSucceeded: false)
        XCTAssertFalse(store.fullHistoryImported)

        _ = store.merge(newEntries: [makeEntry(partId: "prt_1"), makeEntry(partId: "prt_2")], scanSucceeded: true)
        XCTAssertTrue(store.fullHistoryImported)
        XCTAssertEqual(store.allEntries().count, 2)
    }
}
