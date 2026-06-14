import XCTest
import CoreGraphics
@testable import ViewerCore

/// Teeth for the content text-size interaction (TSK-358): on-screen size is the
/// absolute base point size × the unified zoom. Pins the "font-size AND zoom"
/// contract so a regression that drops the base (or the multiply) fails the host
/// gate; the font application to the CM6 editor / source view is the render tail.
final class ContentFontSizingTests: XCTestCase {

    func test_baseTimesZoom() {
        XCTAssertEqual(ContentFontSizing.effective(baseSize: 13, zoom: 1), 13, accuracy: 1e-9)
        XCTAssertEqual(ContentFontSizing.effective(baseSize: 13, zoom: 2), 26, accuracy: 1e-9)
        XCTAssertEqual(ContentFontSizing.effective(baseSize: 16, zoom: 1.5), 24, accuracy: 1e-9)
    }

    func test_defaultBaseAtZoom1_matchesHistoricalContentSize() {
        // Behaviour-neutral: an un-set base (13) at zoom 1 reproduces the old
        // hard-coded `13 * zoom` content size exactly.
        XCTAssertEqual(
            ContentFontSizing.effective(baseSize: PreferencesStore.defaultContentFontSize, zoom: 1),
            13, accuracy: 1e-9)
    }

    func test_zoomBelowOne_shrinksProportionally() {
        XCTAssertEqual(ContentFontSizing.effective(baseSize: 20, zoom: 0.5), 10, accuracy: 1e-9)
    }

    // MARK: - markdownScale (TSK-358 rendered-markdown half)

    func test_markdownScale_defaultIsNeutral() {
        // The default content base scales rendered markdown by 1.0 (15px stays
        // 15px) — behaviour-neutral on upgrade.
        XCTAssertEqual(ContentFontSizing.markdownScale(
            contentFontSize: PreferencesStore.defaultContentFontSize), 1.0, accuracy: 1e-9)
    }

    func test_markdownScale_scalesProportionally() {
        XCTAssertEqual(ContentFontSizing.markdownScale(contentFontSize: 26), 2.0, accuracy: 1e-9)
        XCTAssertEqual(ContentFontSizing.markdownScale(contentFontSize: 6.5), 0.5, accuracy: 1e-9)
        // The clamped max (32pt) over the 13pt base.
        XCTAssertEqual(ContentFontSizing.markdownScale(contentFontSize: 32),
                       32.0 / 13.0, accuracy: 1e-9)
    }
}
