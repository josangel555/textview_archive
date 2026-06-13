import XCTest
@testable import ViewerUI

/// TSK-737: `SourceTextController.countLines` must equal `newlineCount + 1` for
/// non-empty text (0 for empty) — matching the empty final line fragment
/// NSLayoutManager lays out after a trailing `\n`. The old code subtracted 1 for
/// a trailing newline, under-counting by one → the gutter clamped its last row
/// off (no number on the bottom line of a `\n`-terminated log) and the same
/// count skewed the hover-highlight + pointer→line map.
@MainActor
final class SourceTextControllerLineCountTests: XCTestCase {

    private func count(_ s: String) -> Int { SourceTextController.countLines(in: s) }

    func test_empty_isZero() {
        XCTAssertEqual(count(""), 0)
    }

    func test_singleLine_noTrailingNewline() {
        XCTAssertEqual(count("a"), 1)
        XCTAssertEqual(count("hello world"), 1)
    }

    func test_noTrailingNewline_countsContentLines() {
        XCTAssertEqual(count("a\nb"), 2)
        XCTAssertEqual(count("a\nb\nc"), 3)
    }

    func test_trailingNewline_countsTheEmptyFinalLine() {
        // The bug: these used to under-count by one (returning N), dropping the
        // bottom row's gutter number. NSLayoutManager lays out an empty final
        // fragment, so the count is newlineCount + 1.
        XCTAssertEqual(count("a\n"), 2)
        XCTAssertEqual(count("a\nb\n"), 3, "the TSK-737 case — was 2 before the fix")
        XCTAssertEqual(count("a\nb\nc\n"), 4)
    }

    func test_blankLinesCounted() {
        XCTAssertEqual(count("\n"), 2)      // empty line + empty trailing
        XCTAssertEqual(count("a\n\nb"), 3)  // a, blank, b
    }
}
