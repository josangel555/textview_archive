import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// TSK-842: the off-main open-deferral routing. The live "no UI freeze on open"
/// is VM-felt, but the routing DECISION (which files take the off-main path) is
/// a pure function pinned here. The threshold (`TextFileLoader.deferReadOffMainBytes`,
/// default 4 MiB) is far below the old 64 MiB `softWarnBytes` cliff, so a sync
/// main-thread read of a cold / iCloud-stubbed large file no longer freezes.
///
/// Tier: window-free pure assertions — host-safe.
@MainActor
final class OpenDeferThresholdTests: XCTestCase {

    private var threshold: Int { TextFileLoader().deferReadOffMainBytes }

    func testLargeTextFileDefersOffMain() {
        XCTAssertTrue(DocumentModel.shouldDeferOpen(
            category: .plainText, bytes: 5_000_000, threshold: threshold))
        XCTAssertTrue(DocumentModel.shouldDeferOpen(
            category: .code, bytes: 8_000_000, threshold: threshold))
    }

    func testSmallTextFileStaysSync() {
        // The common case — config/source/docs almost all < threshold — stays
        // instant-sync (no .loading flash).
        XCTAssertFalse(DocumentModel.shouldDeferOpen(
            category: .plainText, bytes: 100_000, threshold: threshold))
        XCTAssertFalse(DocumentModel.shouldDeferOpen(
            category: .markdown, bytes: 500_000, threshold: threshold))
    }

    func testThresholdBoundaryIsExclusive() {
        let t = threshold
        XCTAssertFalse(DocumentModel.shouldDeferOpen(category: .code, bytes: t, threshold: t),
                       "exactly at threshold stays sync (the test is strictly >)")
        XCTAssertTrue(DocumentModel.shouldDeferOpen(category: .code, bytes: t + 1, threshold: t))
    }

    func testNativePreviewCategoriesNeverDefer() {
        // image/audio/video/pdf/sqlite render via the .preview state (no text
        // read on this path), so they never take the off-main text load — even
        // when huge.
        for c: FileCategory in [.image, .audio, .video, .pdf, .sqlite] {
            XCTAssertFalse(
                DocumentModel.shouldDeferOpen(category: c, bytes: 999_999_999, threshold: 0),
                "\(c) loads via .preview, never the deferred text path")
        }
    }

    func testThresholdLoweredFromTheOld64MiBCliff() {
        // Guard the chosen value: well below the old softWarnBytes (64 MiB)
        // cliff, comfortably above the common small-file range.
        XCTAssertEqual(threshold, 4 * 1024 * 1024)
        XCTAssertLessThan(threshold, TextFileLoader().softWarnBytes)
    }
}
