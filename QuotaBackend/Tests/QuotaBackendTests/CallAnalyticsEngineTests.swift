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

    func testLegacyCallArchiveDoesNotDoubleCountAfterLedgerMigration() {
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
            day: "2026-01-01",
            ledgerFullyImported: true,
            ledgerOpenCodeDayKeys: ["2026-01-01"]
        )

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.source, .claude)
    }

    func testLegacyOpenCodeEntryPreservedWhenLedgerHasNoThatDay() {
        let opencodeBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1
        )

        let deduped = CallAnalyticsEngine.deduplicateLegacyOpenCode(
            entries: [opencodeBash],
            day: "2026-01-01",
            ledgerFullyImported: true,
            ledgerOpenCodeDayKeys: []
        )

        XCTAssertEqual(deduped.count, 1)
    }

    func testLegacyOpenCodeEntryKeptWhenLedgerNotFullyImported() {
        let opencodeBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1
        )

        let deduped = CallAnalyticsEngine.deduplicateLegacyOpenCode(
            entries: [opencodeBash],
            day: "2026-01-01",
            ledgerFullyImported: false,
            ledgerOpenCodeDayKeys: ["2026-01-01"]
        )

        XCTAssertEqual(deduped.count, 1)
    }
}
