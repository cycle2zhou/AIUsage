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
}
