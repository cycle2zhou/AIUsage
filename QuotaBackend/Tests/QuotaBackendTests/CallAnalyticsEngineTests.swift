import XCTest
@testable import QuotaBackend

final class CallAnalyticsEngineTests: XCTestCase {
    func testOpenCodeScanCutoffFullImportReturnsNil() {
        let cutoff = CallAnalyticsEngine.openCodeScanCutoff(
            ledgerNeedsFullImport: true,
            lastSuccessfulScanDate: Date(timeIntervalSince1970: 1_700_000_000),
            fallbackCutoff: Date(timeIntervalSince1970: 1_700_100_000)
        )
        XCTAssertNil(cutoff)
    }

    func testOpenCodeScanCutoffUsesCursorMinusOverlap() {
        let cursor = Date(timeIntervalSince1970: 1_700_000_000)
        let fallback = Date(timeIntervalSince1970: 1_700_100_000)

        let cutoff = CallAnalyticsEngine.openCodeScanCutoff(
            ledgerNeedsFullImport: false,
            lastSuccessfulScanDate: cursor,
            fallbackCutoff: fallback
        )

        XCTAssertEqual(cutoff, cursor.addingTimeInterval(-24 * 3600))
    }

    func testOpenCodeScanCutoffFallsBackWhenNoCursor() {
        let fallback = Date(timeIntervalSince1970: 1_700_100_000)

        let cutoff = CallAnalyticsEngine.openCodeScanCutoff(
            ledgerNeedsFullImport: false,
            lastSuccessfulScanDate: nil,
            fallbackCutoff: fallback
        )

        XCTAssertEqual(cutoff, fallback)
    }

    func testLegacyOpenCodeDroppedWhenLegacyArchiveMigrated() {
        let opencodeBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1
        )
        let claudeBash = CallAnalyticsEntry(
            source: .claude, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1
        )

        let deduped = CallAnalyticsEngine.deduplicateLegacyOpenCode(
            entries: [opencodeBash, claudeBash],
            legacyArchiveMigrated: true
        )

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.source, .claude)
    }

    func testLegacyOpenCodeEntryKeptWhenArchiveNotMigrated() {
        let opencodeBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1
        )

        let deduped = CallAnalyticsEngine.deduplicateLegacyOpenCode(
            entries: [opencodeBash],
            legacyArchiveMigrated: false
        )

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.source, .opencode)
    }

    func testResidualEntriesPreservesPartialSameDayDeletion() {
        let legacyBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 2, outcomeKnownCount: 2, successCount: 2
        )
        let legacyRead = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "read", server: nil,
            dayKey: "2026-01-01", count: 1, outcomeKnownCount: 1, successCount: 1
        )
        let ledgerBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1, outcomeKnownCount: 1, successCount: 1
        )

        let residual = CallAnalyticsEngine.residualEntries(
            legacy: [legacyBash, legacyRead],
            ledger: [ledgerBash]
        )

        XCTAssertEqual(residual.count, 2)
        XCTAssertEqual(residual.first(where: { $0.name == "bash" })?.count, 1)
        XCTAssertEqual(residual.first(where: { $0.name == "read" })?.count, 1)
    }

    func testResidualEntriesEmptyWhenFullyOverlapped() {
        let legacyBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1, outcomeKnownCount: 1, successCount: 1
        )
        let ledgerBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1, outcomeKnownCount: 1, successCount: 1
        )

        let residual = CallAnalyticsEngine.residualEntries(
            legacy: [legacyBash],
            ledger: [ledgerBash]
        )

        XCTAssertTrue(residual.isEmpty)
    }

    func testResidualEntriesKeepsFullyDeletedEntry() {
        let legacyBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 2, outcomeKnownCount: 2, successCount: 2
        )

        let residual = CallAnalyticsEngine.residualEntries(
            legacy: [legacyBash],
            ledger: []
        )

        XCTAssertEqual(residual.count, 1)
        XCTAssertEqual(residual.first?.count, 2)
    }
}
