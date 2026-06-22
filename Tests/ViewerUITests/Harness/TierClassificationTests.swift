import XCTest
@testable import ViewerUI

/// Teeth for TSK-1132: prove `TierGateObserver.isHeavyTier` actually classifies the
/// `WebViewTestCase` lane (and the retagged live-WebView suites) as heavy, so the
/// observer ENFORCES the #192 gate — a green that is shown to discriminate, not a
/// vacuous pass. The headless floor must stay non-heavy (it always runs in the gate).
final class TierClassificationTests: HeadlessUITestCase {
    func test_isHeavyTier_classifies_webview_lane_and_spares_headless() {
        // The new WebView base + the existing heavy bases are heavy.
        XCTAssertTrue(TierGateObserver.isHeavyTier(WebViewTestCase.self))
        XCTAssertTrue(TierGateObserver.isHeavyTier(LiveAppTestCase.self))
        XCTAssertTrue(TierGateObserver.isHeavyTier(PixelTestCase.self))
        // A retagged live-WebView suite inherits WebViewTestCase, so the superclass
        // walk classifies it heavy → the observer now enforces its #192 gate.
        XCTAssertTrue(TierGateObserver.isHeavyTier(ComponentVisualTests.self))
        XCTAssertTrue(TierGateObserver.isHeavyTier(MermaidHostingTests.self))
        // The headless floor (and this very test) are NOT heavy — they run in the gate.
        XCTAssertFalse(TierGateObserver.isHeavyTier(HeadlessUITestCase.self))
        XCTAssertFalse(TierGateObserver.isHeavyTier(TierClassificationTests.self))
    }
}
