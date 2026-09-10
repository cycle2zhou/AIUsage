import Foundation
import SQLite3
import XCTest
@testable import QuotaBackend

// MARK: - OpenCode 旧归档残差迁移端到端回归
// 覆盖 owner 评审阻塞项：按整日覆盖/让位会丢失「同日部分会话已删、只存在于旧归档」的记录。
// 用真实旧归档 JSON 文件 + 真实 opencode.db（message/part 表）+ 真实 provider/engine 全链路验证，
// 而非只测辅助函数：迁移后展示「当前账本 + 持久化残差」，迁移后新增记录继续正常累加。

final class OpenCodeLegacyMigrationIntegrationTests: XCTestCase {

    // MARK: - 用量：同日部分删除不丢、迁移后新增累加

    func testLegacyUsageArchivePartialSameDayDeletionIsPreserved() async throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let utc = TimeZone(identifier: "UTC")!
        let legacyDayMillis = utcMillis(year: 2026, month: 1, day: 10)

        // 升级前旧归档：2026-01-10 = 100 tokens（其中 40 属于同日已删会话）。
        try writeLegacyUsageArchive(home: home, dayKey: "2026-01-10", inputTokens: 100, cost: 0.10)

        // 升级后 opencode.db：同日仅剩 60 tokens（部分会话已删）。
        let xdg = home.appendingPathComponent("xdg", isDirectory: true)
        let dbDir = xdg.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("opencode.db").path
        try executeSQL(
            """
            CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            INSERT INTO message VALUES ('msg_1', 'sess_1', \(legacyDayMillis), '\(messageData(tokens: 60, cost: 0.06))');
            """,
            databasePath: dbPath
        )

        let provider = OpenCodeCostProvider(
            homeDirectory: home.path,
            timeZone: utc,
            environment: ["XDG_DATA_HOME": xdg.path]
        )

        // 第一次 fetch：触发残差迁移，展示 100 = 账本 60 + 残差 40（已删会话不丢）。
        let first = try await provider.fetchUsage()
        XCTAssertEqual(first.extra["overall.totalTokens"]?.value as? Int, 100)

        // 迁移后新增 10 tokens（今天）→ 展示 110 = 100 + 今天新增 10。
        try executeSQL(
            "INSERT INTO message VALUES ('msg_2', 'sess_1', \(Int64(Date().timeIntervalSince1970 * 1000)), '\(messageData(tokens: 10, cost: 0.01))');",
            databasePath: dbPath
        )
        let second = try await provider.fetchUsage()
        XCTAssertEqual(second.extra["overall.totalTokens"]?.value as? Int, 110)
    }

    // MARK: - 用量：数据目录暂不可用时旧归档回退、迁移保持 pending

    func testPendingMigrationKeepsLegacyUsageVisibleWhenDataDirectoryUnavailable() async throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let utc = TimeZone(identifier: "UTC")!
        let legacyDayMillis = utcMillis(year: 2026, month: 1, day: 10)

        // 升级前旧归档：2026-01-10 = 12 tokens / $0.01。
        try writeLegacyUsageArchive(home: home, dayKey: "2026-01-10", inputTokens: 12, cost: 0.01)

        // OpenCode 数据目录暂不可用：XDG_DATA_HOME 指向无 opencode.db 的目录（home 下所有候选目录均无 db）。
        let xdg = home.appendingPathComponent("xdg", isDirectory: true)
        let provider = OpenCodeCostProvider(
            homeDirectory: home.path,
            timeZone: utc,
            environment: ["XDG_DATA_HOME": xdg.path]
        )

        // 第一次 fetch：数据目录不可用，过去日回退旧归档展示 12（不报 no_usage_data），迁移保持 pending。
        let first = try await provider.fetchUsage()
        XCTAssertEqual(first.extra["overall.totalTokens"]?.value as? Int, 12)
        XCTAssertTrue(await OpenCodeCostProvider.ledger.needsLegacyArchiveMigration(homeDirectory: home.path))
        XCTAssertFalse(await OpenCodeCostProvider.ledger.isFullHistoryImported(homeDirectory: home.path))
        XCTAssertTrue(await OpenCodeCostProvider.ledger.legacyResidualDays(homeDirectory: home.path).isEmpty)

        // 数据库恢复：opencode.db 含昨日 8 tokens（4 tokens 会话已删）→ 残差 12-8=4，展示 12 不重复不丢。
        let dbDir = xdg.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("opencode.db").path
        try executeSQL(
            """
            CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            INSERT INTO message VALUES ('msg_1', 'sess_1', \(legacyDayMillis), '\(messageData(tokens: 8, cost: 0.01))');
            """,
            databasePath: dbPath
        )

        // 第二次 fetch：全量导入完成 + 残差迁移，展示 = 账本 8 + 残差 4 = 12。
        let second = try await provider.fetchUsage()
        XCTAssertEqual(second.extra["overall.totalTokens"]?.value as? Int, 12)
        XCTAssertFalse(await OpenCodeCostProvider.ledger.needsLegacyArchiveMigration(homeDirectory: home.path))
        XCTAssertTrue(await OpenCodeCostProvider.ledger.isFullHistoryImported(homeDirectory: home.path))
        XCTAssertEqual(await OpenCodeCostProvider.ledger.legacyResidualDays(homeDirectory: home.path)["2026-01-10"]?.totalTokens, 4)
    }

    // MARK: - 调用：同日部分删除不丢、迁移后新增累加

    func testLegacyCallArchivePartialSameDayDeletionIsPreserved() async throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let utc = TimeZone(identifier: "UTC")!
        let legacyDayMillis = utcMillis(year: 2026, month: 1, day: 10)

        // 升级前旧归档：2026-01-10 opencode bash=2/read=1。
        let legacyBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-10", count: 2, outcomeKnownCount: 2, successCount: 2
        )
        let legacyRead = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "read", server: nil,
            dayKey: "2026-01-10", count: 1, outcomeKnownCount: 1, successCount: 1
        )
        try writeLegacyCallArchive(home: home, dayKey: "2026-01-10", entries: [legacyBash, legacyRead])

        // 升级后 opencode.db：part 表同日仅剩 1 个 bash（read 会话已删）。
        let xdg = home.appendingPathComponent("xdg", isDirectory: true)
        let dbDir = xdg.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("opencode.db").path
        try executeSQL(
            """
            CREATE TABLE part (id TEXT, time_created INTEGER, data TEXT);
            INSERT INTO part VALUES ('part_1', \(legacyDayMillis), '\(partData(tool: "bash"))');
            """,
            databasePath: dbPath
        )

        let engine = CallAnalyticsEngine(
            homeDirectory: home.path,
            timeZone: utc,
            environment: ["XDG_DATA_HOME": xdg.path]
        )

        // 第一次 computeSnapshot：触发残差迁移，bash=2/read=1（账本 bash=1 + 残差 bash=1/read=1）。
        let first = await engine.computeSnapshot(rangeKey: "all", cutoff: nil)
        XCTAssertEqual(totalCount(first.entries, name: "bash"), 2)
        XCTAssertEqual(totalCount(first.entries, name: "read"), 1)

        // 迁移后新增一次 bash（今天）→ bash=3/read=1。
        try executeSQL(
            "INSERT INTO part VALUES ('part_2', \(Int64(Date().timeIntervalSince1970 * 1000)), '\(partData(tool: "bash"))');",
            databasePath: dbPath
        )
        let second = await engine.computeSnapshot(rangeKey: "all", cutoff: nil)
        XCTAssertEqual(totalCount(second.entries, name: "bash"), 3)
        XCTAssertEqual(totalCount(second.entries, name: "read"), 1)
    }

    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-opencode-legacy-migration-tests-\(UUID())", isDirectory: true)
    }

    private func utcMillis(year: Int, month: Int, day: Int, hour: Int = 12) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        let date = calendar.date(from: comps)!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func messageData(tokens: Int, cost: Double) -> String {
        let costStr = String(format: "%.4f", cost)
        return "{\"role\":\"assistant\",\"providerID\":\"anthropic\",\"modelID\":\"claude-sonnet\",\"cost\":\(costStr),\"tokens\":{\"input\":\(tokens),\"output\":0,\"cache\":{\"read\":0,\"write\":0}}}"
    }

    private func partData(tool: String) -> String {
        "{\"type\":\"tool\",\"tool\":\"\(tool)\",\"state\":{\"status\":\"completed\"}}"
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

    private func writeLegacyUsageArchive(home: URL, dayKey: String, inputTokens: Int, cost: Double) throws {
        var archive = CodexUsageArchive(
            version: 1, updatedAt: "", days: [:],
            fullHistoryImportedAt: "2026-01-05T00:00:00Z"
        )
        var bucket = CodexAggregateBucket.empty
        bucket.record(row: CodexRow(
            dayKey: dayKey,
            model: "anthropic/claude-sonnet",
            inputTokens: inputTokens,
            cacheReadTokens: 0,
            outputTokens: 0,
            totalTokens: inputTokens,
            estimatedCostUsd: cost
        ))
        archive.days[dayKey] = bucket
        let url = OpenCodeUsageArchiveStore.fileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }

    private func writeLegacyCallArchive(home: URL, dayKey: String, entries: [CallAnalyticsEntry]) throws {
        var archive = CallAnalyticsArchive(
            version: 1, updatedAt: "", fullHistoryImportedAt: "2026-01-05T00:00:00Z", days: [:]
        )
        archive.days[dayKey] = CallAnalyticsDayBucket(entries: entries, agentInvocations: [])
        let url = CallAnalyticsArchiveStore.fileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }

    private func totalCount(_ entries: [CallAnalyticsEntry], name: String) -> Int {
        entries.filter { $0.name == name }.reduce(0) { $0 + $1.count }
    }
}
