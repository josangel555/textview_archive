import XCTest
@testable import ViewerCore

/// Pure, headless coverage for `TerminalSelection` — the selection
/// geometry + text-extraction that backs mouse-drag copy in the terminal.
/// No AppKit; this is exactly the layer the owner asked to be verifiable
/// without a live window.
final class TerminalSelectionTests: XCTestCase {

    /// Build a screen of `rows × cols` with `lines` written top-down,
    /// CR/LF separated (trailing cells stay blank).
    private func makeScreen(cols: Int = 20, rows: Int = 5, _ lines: [String]) -> TerminalScreen {
        var parser = ANSIParser(rows: rows, cols: cols)
        parser.feed(Data(lines.joined(separator: "\r\n").utf8))
        return parser.screen
    }

    private func P(_ row: Int, _ col: Int) -> TerminalSelection.Point {
        TerminalSelection.Point(row: row, col: col)
    }

    // MARK: - ordered / isSinglePoint

    func test_ordered_normalizesReversedSelection() {
        let sel = TerminalSelection(anchor: P(2, 5), head: P(0, 1))
        XCTAssertEqual(sel.ordered.start, P(0, 1))
        XCTAssertEqual(sel.ordered.end, P(2, 5))
    }

    func test_isSinglePoint() {
        XCTAssertTrue(TerminalSelection(anchor: P(1, 1), head: P(1, 1)).isSinglePoint)
        XCTAssertFalse(TerminalSelection(anchor: P(1, 1), head: P(1, 2)).isSinglePoint)
    }

    // MARK: - columnRange (endpoint cell inclusive → end-exclusive +1)

    func test_columnRange_singleRow_inclusiveOfBothEndpoints() {
        let sel = TerminalSelection(anchor: P(0, 2), head: P(0, 5))
        XCTAssertEqual(sel.columnRange(forRow: 0, cols: 80), 2..<6)
    }

    func test_columnRange_reversed_sameSpan() {
        let sel = TerminalSelection(anchor: P(0, 5), head: P(0, 2))
        XCTAssertEqual(sel.columnRange(forRow: 0, cols: 80), 2..<6)
    }

    func test_columnRange_multiRow_firstMiddleLast() {
        let sel = TerminalSelection(anchor: P(0, 3), head: P(2, 1))
        XCTAssertEqual(sel.columnRange(forRow: 0, cols: 10), 3..<10, "first row: anchor col → end of line")
        XCTAssertEqual(sel.columnRange(forRow: 1, cols: 10), 0..<10, "middle row: full width")
        XCTAssertEqual(sel.columnRange(forRow: 2, cols: 10), 0..<2,  "last row: start → endpoint inclusive")
    }

    func test_columnRange_rowOutsideSelection_isNil() {
        let sel = TerminalSelection(anchor: P(1, 0), head: P(2, 3))
        XCTAssertNil(sel.columnRange(forRow: 0, cols: 10))
        XCTAssertNil(sel.columnRange(forRow: 3, cols: 10))
    }

    func test_columnRange_clampsToCols() {
        let sel = TerminalSelection(anchor: P(0, 0), head: P(0, 99))
        XCTAssertEqual(sel.columnRange(forRow: 0, cols: 10), 0..<10)
    }

    // MARK: - selectedText

    func test_selectedText_singleRow_trimsTrailingSpaces() {
        let screen = makeScreen(["hello world"])
        // Select the whole first row including trailing blanks.
        let sel = TerminalSelection(anchor: P(0, 0), head: P(0, 19))
        XCTAssertEqual(sel.selectedText(from: screen), "hello world")
    }

    func test_selectedText_partialRow() {
        let screen = makeScreen(["hello world"])
        let sel = TerminalSelection(anchor: P(0, 6), head: P(0, 10))   // "world"
        XCTAssertEqual(sel.selectedText(from: screen), "world")
    }

    func test_selectedText_multiRow_joinedWithNewline() {
        let screen = makeScreen(["hello world", "foo bar"])
        let sel = TerminalSelection(anchor: P(0, 6), head: P(1, 2))    // "world" → "foo"
        XCTAssertEqual(sel.selectedText(from: screen), "world\nfoo")
    }

    func test_selectedText_singleCell() {
        let screen = makeScreen(["hello world"])
        let sel = TerminalSelection(anchor: P(0, 0), head: P(0, 0))
        XCTAssertEqual(sel.selectedText(from: screen), "h")
    }

    // MARK: - word / line / all constructors

    func test_word_selectsContiguousNonSpaceRun() {
        let screen = makeScreen(["hello world"])
        let sel = TerminalSelection.word(at: P(0, 7), in: screen)       // inside "world"
        XCTAssertEqual(sel.anchor, P(0, 6))
        XCTAssertEqual(sel.head, P(0, 10))
        XCTAssertEqual(sel.selectedText(from: screen), "world")
    }

    func test_word_onLeadingToken() {
        let screen = makeScreen(["hello world"])
        let sel = TerminalSelection.word(at: P(0, 0), in: screen)       // inside "hello"
        XCTAssertEqual(sel.selectedText(from: screen), "hello")
    }

    func test_word_onBlankCell_isSinglePoint() {
        let screen = makeScreen(["hello world"])
        let sel = TerminalSelection.word(at: P(0, 5), in: screen)       // the space
        XCTAssertTrue(sel.isSinglePoint)
    }

    func test_line_selectsWholeRow_trimmed() {
        let screen = makeScreen(["hello world", "foo bar"])
        let sel = TerminalSelection.line(1, in: screen)
        XCTAssertEqual(sel.selectedText(from: screen), "foo bar")
    }

    func test_all_coversGrid() {
        let screen = makeScreen(cols: 20, rows: 3, ["alpha", "beta"])
        let sel = TerminalSelection.all(in: screen)
        XCTAssertEqual(sel.anchor, P(0, 0))
        XCTAssertEqual(sel.head, P(2, 19))
        let text = sel.selectedText(from: screen)
        XCTAssertEqual(text, "alpha\nbeta\n")
    }

    func test_selectedText_outOfRangeRows_areSkippedSafely() {
        // A selection that runs past the bottom of a shrunk grid must not
        // crash (the view keeps a coordinate selection across resizes).
        let screen = makeScreen(cols: 10, rows: 2, ["hi"])
        let sel = TerminalSelection(anchor: P(0, 0), head: P(9, 5))
        XCTAssertEqual(sel.selectedText(from: screen).hasPrefix("hi"), true)
    }
}
