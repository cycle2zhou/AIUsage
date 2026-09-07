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
        ], completedFullHistory: true)

        var days = await aggregatedDays(store, home: home.path)
        XCTAssertEqual(days["2026-01-01"]?.totalTokens, 300)
        XCTAssertEqual(days["2026-01-01"]?.usageRows, 2)

        // 第二批：新 msg_3 + 更新 msg_2（同 id 覆盖）
        _ = await store.merge(homeDirectory: home.path, newEntries: [
            entry(id: "msg_3", tokens: 300),
            entry(id: "msg_2", tokens: 250),
        ], completedFullHistory: false)

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
        ], completedFullHistory: true)

        // 模拟删除会话：第二批只含 msg_3（msg_1 已从 opencode.db 消失）
        _ = await store.merge(homeDirectory: home.path, newEntries: [
            entry(id: "msg_3", tokens: 300),
        ], completedFullHistory: false)

        let days = await aggregatedDays(store, home: home.path)
        XCTAssertEqual(days["2026-01-01"]?.totalTokens, 600)  // 100 + 200 + 300（msg_1 不丢）
    }

    func testMergeUpdatesExistingEntryWithoutDoubleCounting() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        _ = await store.merge(homeDirectory: home.path, newEntries: [entry(id: "msg_1", tokens: 100)], completedFullHistory: true)
        _ = await store.merge(homeDirectory: home.path, newEntries: [entry(id: "msg_1", tokens: 250)], completedFullHistory: false)

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
        ], completedFullHistory: true)

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
        ], completedFullHistory: true)

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

        _ = await store.merge(homeDirectory: home.path, newEntries: [entry(id: "msg_1")], completedFullHistory: true)

        shouldImport = await store.consumeFullHistoryImportRequest(homeDirectory: home.path)
        XCTAssertFalse(shouldImport)
    }

    func testFullHistoryImportFlagSetOnEmptyMerge() async {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OpenCodeLedgerStore()

        // 全量导入但 db 为空（无 assistant 消息）→ 仍标记已完成，避免每次重复全量扫描。
        _ = await store.merge(homeDirectory: home.path, newEntries: [], completedFullHistory: true)

        let shouldImport = await store.consumeFullHistoryImportRequest(homeDirectory: home.path)
        XCTAssertFalse(shouldImport)
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
