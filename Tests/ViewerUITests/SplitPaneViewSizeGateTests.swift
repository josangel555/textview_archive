import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// TSK-922 — the pure size-gate behind SplitPaneView's "File too large for split
/// view" placeholder. Host-safe (no window): exercises the extracted static
/// `isTooLargeForSyncRead`. The async off-main load + loading/error render states
/// are VM-lane tail; this pins the load-vs-placeholder DECISION.
final class SplitPaneViewSizeGateTests: XCTestCase {

    func test_isTooLargeForSyncRead_mediaNeverGated_textGatedByWatermark() {
        let cap = 5_000_000

        // Media categories never read bytes into Swift memory → never "too large",
        // even far above the watermark (they have their own native preview).
        for media in [FileCategory.image, .audio, .video, .pdf, .sqlite] {
            XCTAssertFalse(
                SplitPaneView.isTooLargeForSyncRead(
                    category: media, byteCount: cap * 100, softWarnBytes: cap),
                "media (\(media)) is never gated by the sync-read size guard")
        }

        // Text-ish categories: strictly ABOVE the watermark is gated.
        XCTAssertTrue(SplitPaneView.isTooLargeForSyncRead(
            category: .code, byteCount: cap + 1, softWarnBytes: cap))
        XCTAssertFalse(SplitPaneView.isTooLargeForSyncRead(
            category: .code, byteCount: cap, softWarnBytes: cap),
            "exactly at the watermark is NOT too large (strict >)")
        XCTAssertFalse(SplitPaneView.isTooLargeForSyncRead(
            category: .markdown, byteCount: 100, softWarnBytes: cap))

        // Unreadable / missing size ⇒ false (let the load attempt + surface its
        // own error rather than mis-gating to the too-large placeholder).
        XCTAssertFalse(SplitPaneView.isTooLargeForSyncRead(
            category: .code, byteCount: nil, softWarnBytes: cap))
    }
}
