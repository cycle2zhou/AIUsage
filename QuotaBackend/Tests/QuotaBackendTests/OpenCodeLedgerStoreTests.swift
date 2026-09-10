import XCTest
import Foundation
@testable import QuotaBackend

final class OpenCodeLedgerStoreTests: XCTestCase {
    func testMergeAccumulatesNewEntriesAcrossBatches() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        _ = await store.merge(homeDirectory: home.path, newEntries: [
            entry(id: "msg_1", tokens: 100),
            entry(id: "msg_2", tokens: 200),
        ], scanSucceeded: true)

        var days = await aggregatedDays(store, home: home.path)
        XCTAssertEqual(days["2026-01-01"]?.totalTokens, 300)
        XCTAssertEqual(days["2026-01-01"]?.usageRows, 2)

        // 第二批：新 msg_3 + 更新 msg_2（同 id 覆盖）
        _ = await store.merge(homeDirectory: home.path, newEntries: [
            entry(id: "msg_3", tokens: 300),
            entry(id: "msg_2", tokens: 250),
        ], scanSucceeded: true)

        days = await aggregatedDays(store, home: home.path)
        XCTAssertEqual(days["2026-01-01"]?.totalTokens, 650)  // 100 + 250 + 300
        XCTAssertEqual(days["2026-01-01"]?.usageRows, 3)
    }

    func testMergeRetainsEntriesNotInLaterBatch() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        _ = await store.merge(homeDirectory: home.path, newEntries: [
            entry(id: "msg_1", tokens: 100),
            entry(id: "msg_2", tokens: 200),
        ], scanSucceeded: true)

        // 模拟删除会话：第二批只含 msg_3（msg_1 已从 opencode.db 消失）
        _ = await store.merge(homeDirectory: home.path, newEntries: [
            entry(id: "msg_3", tokens: 300),
        ], scanSucceeded: true)

        let days = await aggregatedDays(store, home: home.path)
        XCTAssertEqual(days["2026-01-01"]?.totalTokens, 600)  // 100 + 200 + 300（msg_1 不丢）
    }

    func testMergeUpdatesExistingEntryWithoutDoubleCounting() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        _ = await store.merge(homeDirectory: home.path, newEntries: [entry(id: "msg_1", tokens: 100)], scanSucceeded: true)
        _ = await store.merge(homeDirectory: home.path, newEntries: [entry(id: "msg_1", tokens: 250)], scanSucceeded: true)

        let days = await aggregatedDays(store, home: home.path)
        XCTAssertEqual(days["2026-01-01"]?.totalTokens, 250)  // 更新覆盖，不重复计数
        XCTAssertEqual(days["2026-01-01"]?.usageRows, 1)
    }

    func testAggregateDaysGroupsByDayKey() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        _ = await store.merge(homeDirectory: home.path, newEntries: [
            entry(id: "msg_1", day: "2026-01-01", tokens: 100),
            entry(id: "msg_2", day: "2026-01-02", tokens: 200),
        ], scanSucceeded: true)

        let days = await aggregatedDays(store, home: home.path)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days["2026-01-01"]?.totalTokens, 100)
        XCTAssertEqual(days["2026-01-02"]?.totalTokens, 200)
    }

    func testAggregateDaysSumCostAndTokensByModel() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        _ = await store.merge(homeDirectory: home.path, newEntries: [
            entry(id: "msg_1", day: "2026-01-01", model: "anthropic/sonnet", tokens: 100, cost: 0.01),
            entry(id: "msg_2", day: "2026-01-01", model: "anthropic/sonnet", tokens: 200, cost: 0.02),
            entry(id: "msg_3", day: "2026-01-01", model: "openai/gpt-5", tokens: 300, cost: 0.03),
        ], scanSucceeded: true)

        let days = await aggregatedDays(store, home: home.path)
        let day = days["2026-01-01"]
        XCTAssertEqual(day?.totalTokens, 600)
        XCTAssertEqual(day?.estimatedCostUsd ?? 0, 0.06, accuracy: 0.0001)
        XCTAssertEqual(day?.models.count, 2)
        XCTAssertEqual(day?.models["anthropic/sonnet"]?.totalTokens, 300)
        XCTAssertEqual(day?.models["openai/gpt-5"]?.totalTokens, 300)
    }

    func testFullHistoryImportFlagPersists() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        var shouldImport = await store.consumeFullHistoryImportRequest(homeDirectory: home.path)
        XCTAssertTrue(shouldImport)

        _ = await store.merge(homeDirectory: home.path, newEntries: [entry(id: "msg_1")], scanSucceeded: true)

        shouldImport = await store.consumeFullHistoryImportRequest(homeDirectory: home.path)
        XCTAssertFalse(shouldImport)
    }

    func testFullHistoryImportFlagSetOnEmptyMerge() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        // 全量导入但 db 为空（无 assistant 消息）→ 仍标记已完成，避免每次重复全量扫描。
        _ = await store.merge(homeDirectory: home.path, newEntries: [], scanSucceeded: true)

        let shouldImport = await store.consumeFullHistoryImportRequest(homeDirectory: home.path)
        XCTAssertFalse(shouldImport)
    }

    func testScanFailureDoesNotMarkFullHistoryImport() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        _ = await store.merge(homeDirectory: home.path, newEntries: [entry(id: "msg_1")], scanSucceeded: false)

        let shouldImport = await store.consumeFullHistoryImportRequest(homeDirectory: home.path)
        XCTAssertTrue(shouldImport)
        let cursor = await store.lastSuccessfulScanMillis(homeDirectory: home.path)
        XCTAssertNil(cursor)
    }

    func testScanSuccessMarksFullHistoryAndAdvancesCursor() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        _ = await store.merge(homeDirectory: home.path, newEntries: [entry(id: "msg_1")], scanSucceeded: true)

        let shouldImport = await store.consumeFullHistoryImportRequest(homeDirectory: home.path)
        XCTAssertFalse(shouldImport)
        let cursor = await store.lastSuccessfulScanMillis(homeDirectory: home.path)
        XCTAssertNotNil(cursor)
    }

    func testScanFailureThenSuccessRecoversFullHistory() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        _ = await store.merge(homeDirectory: home.path, newEntries: [], scanSucceeded: false)
        var shouldImport = await store.consumeFullHistoryImportRequest(homeDirectory: home.path)
        XCTAssertTrue(shouldImport)

        _ = await store.merge(homeDirectory: home.path, newEntries: [entry(id: "msg_1"), entry(id: "msg_2")], scanSucceeded: true)
        shouldImport = await store.consumeFullHistoryImportRequest(homeDirectory: home.path)
        XCTAssertFalse(shouldImport)

        let entries = await store.allEntries(homeDirectory: home.path)
        XCTAssertEqual(entries.count, 2)
    }

    func testLegacyArchiveMigrationPreservesDeletedSessionHistory() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        var legacyBucket = CodexAggregateBucket.empty
        legacyBucket.record(row: CodexRow(
            dayKey: "2026-01-01",
            model: "anthropic/claude-sonnet",
            inputTokens: 12,
            cacheReadTokens: 0,
            outputTokens: 0,
            totalTokens: 12,
            estimatedCostUsd: 0.01
        ))

        _ = await store.merge(homeDirectory: home.path, newEntries: [], scanSucceeded: true)

        var needsMigration = await store.needsLegacyArchiveMigration(homeDirectory: home.path)
        XCTAssertTrue(needsMigration)
        await store.migrateLegacyArchiveIfNeeded(
            homeDirectory: home.path,
            legacyDays: ["2026-01-01": legacyBucket],
            ledgerSnapshotDays: [:],
            todayKey: "2026-01-02"
        )

        let migrated = await store.legacyResidualDays(homeDirectory: home.path)
        XCTAssertEqual(migrated["2026-01-01"]?.totalTokens, 12)
        XCTAssertEqual(migrated["2026-01-01"]?.estimatedCostUsd ?? 0, 0.01, accuracy: 0.0001)

        needsMigration = await store.needsLegacyArchiveMigration(homeDirectory: home.path)
        XCTAssertFalse(needsMigration)
    }

    func testLegacyArchiveMigrationSkipsToday() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        var pastBucket = CodexAggregateBucket.empty
        pastBucket.record(row: CodexRow(dayKey: "2026-01-01", model: "m", inputTokens: 10, cacheReadTokens: 0, outputTokens: 0, totalTokens: 10, estimatedCostUsd: 0.01))
        var todayBucket = CodexAggregateBucket.empty
        todayBucket.record(row: CodexRow(dayKey: "2026-01-02", model: "m", inputTokens: 5, cacheReadTokens: 0, outputTokens: 0, totalTokens: 5, estimatedCostUsd: 0.005))

        await store.migrateLegacyArchiveIfNeeded(
            homeDirectory: home.path,
            legacyDays: ["2026-01-01": pastBucket, "2026-01-02": todayBucket],
            ledgerSnapshotDays: [:],
            todayKey: "2026-01-02"
        )

        let migrated = await store.legacyResidualDays(homeDirectory: home.path)
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated["2026-01-01"]?.totalTokens, 10)
        XCTAssertNil(migrated["2026-01-02"])
    }

    func testResidualDaysPreservesPartialSameDayDeletion() {
        // 旧归档某日 100 tokens，同日账本快照仅 60（部分会话已删）→ 残差 40，不丢已删会话的差额。
        var legacyBucket = CodexAggregateBucket.empty
        legacyBucket.record(row: CodexRow(
            dayKey: "2026-01-01", model: "anthropic/claude-sonnet",
            inputTokens: 100, cacheReadTokens: 0, outputTokens: 0,
            totalTokens: 100, estimatedCostUsd: 0.10
        ))
        var ledgerBucket = CodexAggregateBucket.empty
        ledgerBucket.record(row: CodexRow(
            dayKey: "2026-01-01", model: "anthropic/claude-sonnet",
            inputTokens: 60, cacheReadTokens: 0, outputTokens: 0,
            totalTokens: 60, estimatedCostUsd: 0.06
        ))

        let residual = OpenCodeLedgerStore.residualDays(
            legacyDays: ["2026-01-01": legacyBucket],
            ledgerSnapshotDays: ["2026-01-01": ledgerBucket],
            todayKey: "2026-01-02"
        )

        XCTAssertEqual(residual["2026-01-01"]?.totalTokens, 40)
        XCTAssertEqual(residual["2026-01-01"]?.inputTokens, 40)
        XCTAssertEqual(residual["2026-01-01"]?.estimatedCostUsd ?? 0, 0.04, accuracy: 0.0001)
        XCTAssertEqual(residual["2026-01-01"]?.models["anthropic/claude-sonnet"]?.totalTokens, 40)
    }

    func testResidualDaysKeepsFullyDeletedDay() {
        // 旧归档某日 100，账本快照该日无记录（会话完全删除）→ 残差 100，不丢。
        var legacyBucket = CodexAggregateBucket.empty
        legacyBucket.record(row: CodexRow(
            dayKey: "2026-01-01", model: "anthropic/claude-sonnet",
            inputTokens: 100, cacheReadTokens: 0, outputTokens: 0,
            totalTokens: 100, estimatedCostUsd: 0.10
        ))

        let residual = OpenCodeLedgerStore.residualDays(
            legacyDays: ["2026-01-01": legacyBucket],
            ledgerSnapshotDays: [:],
            todayKey: "2026-01-02"
        )

        XCTAssertEqual(residual["2026-01-01"]?.totalTokens, 100)
        XCTAssertEqual(residual["2026-01-01"]?.usageRows, 1)
    }

    func testResidualDaysEmptyWhenFullyOverlapped() {
        // 旧归档某日 60，账本快照同日 60（完全重叠）→ 无残差，避免重复计数。
        var legacyBucket = CodexAggregateBucket.empty
        legacyBucket.record(row: CodexRow(
            dayKey: "2026-01-01", model: "anthropic/claude-sonnet",
            inputTokens: 60, cacheReadTokens: 0, outputTokens: 0,
            totalTokens: 60, estimatedCostUsd: 0.06
        ))
        var ledgerBucket = CodexAggregateBucket.empty
        ledgerBucket.record(row: CodexRow(
            dayKey: "2026-01-01", model: "anthropic/claude-sonnet",
            inputTokens: 60, cacheReadTokens: 0, outputTokens: 0,
            totalTokens: 60, estimatedCostUsd: 0.06
        ))

        let residual = OpenCodeLedgerStore.residualDays(
            legacyDays: ["2026-01-01": legacyBucket],
            ledgerSnapshotDays: ["2026-01-01": ledgerBucket],
            todayKey: "2026-01-02"
        )

        XCTAssertNil(residual["2026-01-01"])
    }

    // MARK: Helpers

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-opencode-ledger-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func aggregatedDays(_ store: OpenCodeLedgerStore, home: String) async -> [String: CodexAggregateBucket] {
        let entries = await store.allEntries(homeDirectory: home)
        return OpenCodeLedgerStore.aggregateDays(entries)
    }

    private func entry(
        id: String,
        day: String = "2026-01-01",
        model: String = "anthropic/claude-sonnet",
        tokens: Int = 100,
        cost: Double = 0.01
    ) -> OpenCodeLedgerEntry {
        OpenCodeLedgerEntry(
            messageId: id,
            sessionId: "sess-1",
            timeCreatedMillis: 1_700_000_000_000,
            dayKey: day,
            model: model,
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreateTokens: 0,
            totalTokens: tokens,
            estimatedCostUsd: cost
        )
    }
}
