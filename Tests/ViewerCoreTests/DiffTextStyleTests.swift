import XCTest
import CoreGraphics
@testable import ViewerCore

/// Teeth for the diff-body typography contract (TSK-766): the git-diff body must
/// track the SAME font-size source the Editor / Source view uses
/// (`contentFontSize × zoom`), so a hunk line reads identically to the same line
/// in the Source view. Pins it so a regression that re-hardcodes a size, or
/// decouples the diff body from the content font-size setting, fails the host
/// gate. The actual `.font(...)` application + live look is the VM render tail.
final class DiffTextStyleTests: XCTestCase {

    // MARK: - Body content size == editor/source content size

    func test_bodyFontSize_equalsContentFontSizingEffective() {
        // The diff body MUST be the exact same size the editor/source view binds
        // to (`DocumentModel.effectiveContentFontSize` =
        // `ContentFontSizing.effective`), so a line reads identically in both.
        for base in [8.0, 11.0, 13.0, 16.0, 20.0, 32.0] {
            for zoom in [0.5, 1.0, 1.25, 1.5, 2.0] {
                XCTAssertEqual(
                    DiffTextStyle.bodyFontSize(contentFontSize: base, zoom: zoom),
                    ContentFontSizing.effective(baseSize: base, zoom: zoom),
                    accuracy: 1e-9,
                    "diff body must equal the editor content size at base=\(base) zoom=\(zoom)")
            }
        }
    }

    func test_bodyFontSize_tracksContentFontSizeSetting() {
        // Same zoom, different content-font-size preference ⇒ different body
        // size. A regression that hardcoded a size would make these EQUAL.
        let small = DiffTextStyle.bodyFontSize(contentFontSize: 11, zoom: 1)
        let large = DiffTextStyle.bodyFontSize(contentFontSize: 22, zoom: 1)
        XCTAssertEqual(small, 11, accuracy: 1e-9)
        XCTAssertEqual(large, 22, accuracy: 1e-9)
        XCTAssertEqual(large, small * 2, accuracy: 1e-9,
                       "doubling the content font-size doubles the diff body size")
    }

    func test_bodyFontSize_tracksZoom() {
        let base = DiffTextStyle.bodyFontSize(contentFontSize: 13, zoom: 1)
        let zoomed = DiffTextStyle.bodyFontSize(contentFontSize: 13, zoom: 2)
        XCTAssertEqual(base, 13, accuracy: 1e-9)
        XCTAssertEqual(zoomed, 26, accuracy: 1e-9)
    }

    func test_bodyFontSize_atDefaultBaseAndZoom1_matchesHistorical() {
        // Behaviour anchor: at the default content base, the body lands on 13 —
        // close to the old hardcoded `uiSize(11)`=11 it replaced, but now driven
        // by the SAME source as the Source view rather than the chrome scale.
        XCTAssertEqual(
            DiffTextStyle.bodyFontSize(
                contentFontSize: PreferencesStore.defaultContentFontSize, zoom: 1),
            13, accuracy: 1e-9)
    }

    // MARK: - Prefix tracks body 1:1

    func test_prefixFontSize_equalsBody() {
        for base in [8.0, 13.0, 32.0] {
            for zoom in [0.5, 1.0, 2.0] {
                XCTAssertEqual(
                    DiffTextStyle.prefixFontSize(contentFontSize: base, zoom: zoom),
                    DiffTextStyle.bodyFontSize(contentFontSize: base, zoom: zoom),
                    accuracy: 1e-9,
                    "the +/- gutter prefix tracks the body 1:1")
            }
        }
    }

    // MARK: - Line-number gutter stays proportional to body

    func test_lineNumberFontSize_isProportionalToBody() {
        // Preserves the historical 10/11 visual hierarchy (line numbers a notch
        // smaller than content) — but as a RATIO of the body, not a fixed size,
        // so it scales with the content font-size setting too.
        for base in [8.0, 13.0, 32.0] {
            for zoom in [0.5, 1.0, 2.0] {
                let body = DiffTextStyle.bodyFontSize(contentFontSize: base, zoom: zoom)
                let ln = DiffTextStyle.lineNumberFontSize(contentFontSize: base, zoom: zoom)
                XCTAssertEqual(ln, body * (10.0 / 11.0), accuracy: 1e-9)
                XCTAssertLessThan(ln, body, "line numbers stay a notch smaller than the body")
            }
        }
    }

    func test_lineNumberFontSize_tracksContentFontSizeSetting() {
        // A regression that hardcoded the gutter size would make these equal.
        let small = DiffTextStyle.lineNumberFontSize(contentFontSize: 11, zoom: 1)
        let large = DiffTextStyle.lineNumberFontSize(contentFontSize: 22, zoom: 1)
        XCTAssertEqual(large, small * 2, accuracy: 1e-9)
    }
}
