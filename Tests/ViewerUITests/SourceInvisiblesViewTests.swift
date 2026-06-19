import XCTest
@testable import ViewerUI

/// Tier 1 (host-safe) coverage for the visible-line slicing behind the
/// readable source-view invisibles overlay (TSK-364). The Canvas drawing
/// itself is view-layer (VM render tail); this pins the line window math so
/// the overlay only walks the visible slice and lands markers on the right
/// 1-based lines. A coordinate/off-by-one regression fails here on the host.
final class SourceInvisiblesViewTests: XCTestCase {

    private let doc = "line one\nline two\nline three\nfour\nfive"

    func test_singleLineWindow() {
        XCTAssertEqual(
            SourceInvisiblesView.visibleLines(in: doc, from: 1, through: 1),
            ["line one"]
        )
    }

    func test_middleWindow() {
        XCTAssertEqual(
            SourceInvisiblesView.visibleLines(in: doc, from: 2, through: 3),
            ["line two", "line three"]
        )
    }

    func test_lastLineNoTrailingNewline() {
        XCTAssertEqual(
            SourceInvisiblesView.visibleLines(in: doc, from: 5, through: 5),
            ["five"]
        )
    }

    func test_windowClampedPastEOF() {
        // Asking past the last line returns only what exists.
        XCTAssertEqual(
            SourceInvisiblesView.visibleLines(in: doc, from: 4, through: 99),
            ["four", "five"]
        )
    }

    func test_trailingNewlineProducesEmptyFinalLine() {
        // A file ending in \n has an empty final logical line (matching
        // SourceTextController.countLines / NSLayoutManager).
        let withTrailing = "a\nb\n"
        XCTAssertEqual(
            SourceInvisiblesView.visibleLines(in: withTrailing, from: 1, through: 3),
            ["a", "b", ""]
        )
    }

    func test_emptyDocument_noLines() {
        XCTAssertTrue(
            SourceInvisiblesView.visibleLines(in: "", from: 1, through: 10).isEmpty
        )
    }

    func test_invalidRange_returnsEmpty() {
        XCTAssertTrue(
            SourceInvisiblesView.visibleLines(in: doc, from: 0, through: 3).isEmpty
        )
        XCTAssertTrue(
            SourceInvisiblesView.visibleLines(in: doc, from: 3, through: 2).isEmpty
        )
    }

    func test_onlyVisibleSliceIsWalked_blankLinesPreserved() {
        let blanks = "x\n\n\ny"
        XCTAssertEqual(
            SourceInvisiblesView.visibleLines(in: blanks, from: 1, through: 4),
            ["x", "", "", "y"]
        )
    }
}
