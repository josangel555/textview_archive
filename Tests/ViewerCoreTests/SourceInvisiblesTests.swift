import AppKit
import XCTest
@testable import ViewerCore

/// TSK-364 — the pure model behind the read-only source view's readable
/// "show invisibles" overlay (`·` space, `→` tab, `¶` line break) in a
/// secondary tone instead of the washed-out OS faint-grey. These pin the
/// marker placement + glyphs + theme-derived color so a regression in the
/// overlay's data layer fails the host gate even though the on-screen pixel
/// check is the VM-only render tail.
final class SourceInvisiblesTests: XCTestCase {

    // MARK: - markers(forLine:)

    func test_emptyLine_noMarkers() {
        XCTAssertTrue(SourceInvisibles.markers(forLine: "").isEmpty)
    }

    func test_noWhitespace_noMarkers() {
        XCTAssertTrue(SourceInvisibles.markers(forLine: "abc").isEmpty)
    }

    func test_leadingSpaces_markedAtColumns() {
        let m = SourceInvisibles.markers(forLine: "  x")
        XCTAssertEqual(m, [
            .init(column: 0, kind: .space),
            .init(column: 1, kind: .space),
        ])
    }

    func test_tab_marked() {
        let m = SourceInvisibles.markers(forLine: "\tx")
        XCTAssertEqual(m, [.init(column: 0, kind: .tab)])
    }

    func test_mixedSpacesTabsTrailing() {
        // "a b\t " -> space at 1, tab at 3, space at 4
        let m = SourceInvisibles.markers(forLine: "a b\t ")
        XCTAssertEqual(m, [
            .init(column: 1, kind: .space),
            .init(column: 3, kind: .tab),
            .init(column: 4, kind: .space),
        ])
    }

    func test_onlyAsciiSpaceAndTabMarked_notNbspOrOtherWhitespace() {
        // U+00A0 NO-BREAK SPACE and U+2003 EM SPACE must NOT be marked — only
        // ASCII 0x20 / 0x09. The nbsp is one UTF-16 unit; em space too.
        let line = "a\u{00A0}b\u{2003}c d"
        let m = SourceInvisibles.markers(forLine: line)
        // Columns: a=0, nbsp=1, b=2, emsp=3, c=4, space=5, d=6
        XCTAssertEqual(m, [.init(column: 5, kind: .space)])
    }

    func test_columnsAreUTF16_withMultiUnitContent() {
        // An emoji (👍, 2 UTF-16 units) precedes a space; the space's column
        // must be the UTF-16 offset (2), matching NSTextView glyph indexing.
        let line = "\u{1F44D} x"
        let m = SourceInvisibles.markers(forLine: line)
        XCTAssertEqual(m, [.init(column: 2, kind: .space)])
    }

    func test_markerGlyphs() {
        XCTAssertEqual(SourceInvisibles.Marker(column: 0, kind: .space).glyph, "\u{00B7}")
        XCTAssertEqual(SourceInvisibles.Marker(column: 0, kind: .tab).glyph, "\u{2192}")
        XCTAssertEqual(SourceInvisibles.lineBreakGlyph, "\u{00B6}")
    }

    func test_markersAreAscendingByColumn() {
        let m = SourceInvisibles.markers(forLine: "  \t a\t")
        let cols = m.map(\.column)
        XCTAssertEqual(cols, cols.sorted(), "markers must be in column order")
    }

    // MARK: - markerColor(for:)

    func test_isDark_classifiesShippedThemes() {
        XCTAssertFalse(SourceInvisibles.isDark(SyntaxTheme.xcodeLight.background))
        XCTAssertTrue(SourceInvisibles.isDark(SyntaxTheme.xcodeDark.background))
    }

    func test_markerColor_lightTheme_isReadableSecondaryTone_notOSGrey() {
        let c = SourceInvisibles.markerColor(for: .xcodeLight)
        let srgb = c.usingColorSpace(.sRGB)!
        // Tracks macOS secondaryLabelColor (light): ~rgba(60,60,67,0.55).
        XCTAssertEqual(srgb.redComponent, 60.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(srgb.greenComponent, 60.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(srgb.blueComponent, 67.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(srgb.alphaComponent, 0.55, accuracy: 0.01)
    }

    func test_markerColor_darkTheme_isLightTone() {
        let c = SourceInvisibles.markerColor(for: .xcodeDark)
        let srgb = c.usingColorSpace(.sRGB)!
        // Tracks macOS secondaryLabelColor (dark): ~rgba(235,235,245,0.50).
        XCTAssertEqual(srgb.redComponent, 235.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(srgb.alphaComponent, 0.50, accuracy: 0.01)
    }

    func test_markerColor_isVisibleAgainstThemeBackground() {
        // The whole point of the ticket: the marker must NOT blend into the
        // background. Assert a meaningful luminance gap on both themes.
        for theme in [SyntaxTheme.xcodeLight, SyntaxTheme.xcodeDark] {
            let bg = theme.background.usingColorSpace(.sRGB)!
            let mk = SourceInvisibles.markerColor(for: theme).usingColorSpace(.sRGB)!
            let bgLum = 0.299 * bg.redComponent + 0.587 * bg.greenComponent + 0.114 * bg.blueComponent
            let mkLum = 0.299 * mk.redComponent + 0.587 * mk.greenComponent + 0.114 * mk.blueComponent
            XCTAssertGreaterThan(abs(bgLum - mkLum), 0.15,
                "marker must contrast with \(theme.name) background")
        }
    }
}
