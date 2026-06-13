import XCTest
import CoreGraphics
@testable import ViewerUI

/// Tier 1 (host-safe) coverage for the source line-hover geometry (TSK-263).
/// The pointer→line mapping is the testable kernel of the hover highlight;
/// the drawing/interaction itself is view-layer (human review-gated). These
/// pin the inverse-of-the-gutter math so a coordinate regression fails here.
final class SourceHoverGeometryTests: XCTestCase {

    private func state(offsetY: CGFloat = 0, lineHeight: CGFloat = 16,
                       lineCount: Int = 100, topInset: CGFloat = 10,
                       viewportHeight: CGFloat = 400) -> SourceScrollState {
        SourceScrollState(offsetY: offsetY, viewportHeight: viewportHeight,
                          lineHeight: lineHeight, lineCount: lineCount, topInset: topInset)
    }

    func test_pointerInTopInset_isAboveFirstLine_returnsNil() {
        // y within the 10pt top inset → above glyph row 1.
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(0, in: state()))
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(9.9, in: state()))
    }

    func test_firstAndSubsequentLines_noScroll() {
        let s = state()
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(10, in: s), 1)   // top of line 1
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(25, in: s), 1)   // still line 1 (10..26)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(26, in: s), 2)   // line 2
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(42, in: s), 3)   // 10 + 2*16
    }

    func test_scrolled_mapsToDocumentLine() {
        // Scrolled down 160pt == 10 lines; top of viewport now shows line 11.
        let s = state(offsetY: 160)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(10, in: s), 11)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(26, in: s), 12)
    }

    func test_pastLastLine_returnsNil() {
        // lineHeight 16, topInset 10 → line 3 occupies viewport-y [42, 58).
        let s = state(lineCount: 3)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(47, in: s), 3)   // within line 3
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(57, in: s), 3)   // last px of line 3
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(58, in: s))        // first px past line 3
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(500, in: s))
    }

    func test_degenerateGeometry_returnsNil() {
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(50, in: state(lineHeight: 0)))
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(50, in: state(lineCount: 0)))
    }

    func test_lineViewportY_isInverseOfPointerMapping() {
        let s = state(offsetY: 160)
        // Line 11 sits at the top of the viewport after scrolling 160pt.
        XCTAssertEqual(SourceHoverGeometry.lineViewportY(11, in: s), 10, accuracy: 0.001)
        // Round-trip: the viewport-y of a line maps back to that same line.
        for line in [1, 5, 11, 42, 99] {
            let y = SourceHoverGeometry.lineViewportY(line, in: s)
            XCTAssertEqual(SourceHoverGeometry.lineAtPointer(y, in: s), line,
                           "round-trip failed for line \(line)")
        }
    }

    // TSK-736: the hover handler dedupes its @State write — `if line !=
    // hoveredSourceLine`. Its whole value rests on lineAtPointer being LINE-
    // QUANTIZED: every pointer-y within one line maps to the SAME index, so an
    // intra-line pointer move produces no write (no re-body / no find repaint),
    // collapsing a per-pixel storm into one update per line crossing.
    func test_intraLineSweep_isConstant_thenChangesAtCrossing_dedupePremise() {
        let s = state()   // lineHeight 16, topInset 10 → line 1 = viewport-y [10, 26)
        // 32 sub-pixel samples across the whole of line 1 all read as line 1.
        let samples = stride(from: CGFloat(10), to: 26, by: 0.5)
            .map { SourceHoverGeometry.lineAtPointer($0, in: s) }
        XCTAssertEqual(Set(samples), [1],
            "every intra-line sample maps to one line → the dedupe guard skips all of them")
        // Crossing into the next line DOES change the value (the guard writes).
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(25.99, in: s), 1)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(26.0, in: s), 2)
    }
}
