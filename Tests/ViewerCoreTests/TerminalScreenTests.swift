import XCTest
@testable import ViewerCore

/// Pure-logic coverage for `TerminalScreen` (the terminal grid that the
/// ANSIParser drives and the view snapshots — #226). It shipped with zero
/// unit tests despite rich mutator semantics: auto-wrap, line-feed scroll,
/// resize anchoring, the erase family, and scroll up/down clamping. All
/// 0-based, Foundation-only, deterministic.
final class TerminalScreenTests: XCTestCase {

    private func type(_ s: String, into screen: inout TerminalScreen) {
        for ch in s { screen.write(ch) }
    }

    // MARK: - init

    func test_init_clampsToMinimumSize_andStartsBlankAtOrigin() {
        let s = TerminalScreen(rows: 0, cols: 0)
        XCTAssertEqual(s.rows, 1)
        XCTAssertEqual(s.cols, 1)
        XCTAssertEqual(s.cursor, TerminalCursor(row: 0, col: 0))
        XCTAssertEqual(s.plainText(), "")
    }

    // MARK: - write + plainText/line

    func test_write_stampsAndAdvances() {
        var s = TerminalScreen(rows: 3, cols: 10)
        type("hello", into: &s)
        XCTAssertEqual(s.line(0), "hello")
        XCTAssertEqual(s.cursor, TerminalCursor(row: 0, col: 5))
    }

    func test_line_trimsTrailingBlanksButKeepsInterior() {
        var s = TerminalScreen(rows: 1, cols: 10)
        type("a b", into: &s)   // 'a', ' ', 'b'
        XCTAssertEqual(s.line(0), "a b")
    }

    func test_plainText_joinsRowsWithNewline_trimmingEachRow() {
        var s = TerminalScreen(rows: 3, cols: 6)
        type("ab", into: &s)
        s.lineFeed(); s.carriageReturn()
        type("cd", into: &s)
        XCTAssertEqual(s.plainText(), "ab\ncd\n")
    }

    func test_write_autoWrapsAtRightEdgeToNextRow() {
        var s = TerminalScreen(rows: 3, cols: 3)
        type("abcd", into: &s)   // abc fills row 0, d wraps to row 1
        XCTAssertEqual(s.line(0), "abc")
        XCTAssertEqual(s.line(1), "d")
        XCTAssertEqual(s.cursor, TerminalCursor(row: 1, col: 1))
    }

    func test_write_autoWrapOnLastRowScrolls() {
        var s = TerminalScreen(rows: 2, cols: 2)
        type("ab", into: &s)     // row0 = ab, cursor col==2
        type("cd", into: &s)     // wrap -> row1 = cd
        XCTAssertEqual(s.plainText(), "ab\ncd")
        type("ef", into: &s)     // wrap on last row -> scroll: ab falls off
        XCTAssertEqual(s.line(0), "cd")
        XCTAssertEqual(s.line(1), "ef")
    }

    // MARK: - cursor movement + clamping

    func test_cursorMovement_clampsToGrid() {
        var s = TerminalScreen(rows: 4, cols: 5)
        s.moveCursor(row: 99, col: 99)
        XCTAssertEqual(s.cursor, TerminalCursor(row: 3, col: 4))
        s.cursorUp(99); XCTAssertEqual(s.cursor.row, 0)
        s.cursorBackward(99); XCTAssertEqual(s.cursor.col, 0)
        s.cursorDown(2); XCTAssertEqual(s.cursor.row, 2)
        s.cursorForward(3); XCTAssertEqual(s.cursor.col, 3)
        s.moveCursor(row: -5, col: -5)
        XCTAssertEqual(s.cursor, TerminalCursor(row: 0, col: 0))
    }

    func test_carriageReturn_andBackspace() {
        var s = TerminalScreen(rows: 2, cols: 8)
        type("abcd", into: &s)
        s.carriageReturn(); XCTAssertEqual(s.cursor.col, 0)
        s.moveCursorCol(3); s.backspace(); XCTAssertEqual(s.cursor.col, 2)
        s.moveCursorCol(0); s.backspace(); XCTAssertEqual(s.cursor.col, 0, "no underflow")
    }

    func test_tab_advancesToEightColumnStops_clampedToLastCol() {
        var s = TerminalScreen(rows: 1, cols: 20)
        s.tab(); XCTAssertEqual(s.cursor.col, 8)
        s.tab(); XCTAssertEqual(s.cursor.col, 16)
        s.tab(); XCTAssertEqual(s.cursor.col, 19, "clamped to last column")
    }

    // MARK: - lineFeed

    func test_lineFeed_movesDown_thenScrollsOnLastRow() {
        var s = TerminalScreen(rows: 2, cols: 4)
        type("top", into: &s)
        s.lineFeed()
        XCTAssertEqual(s.cursor.row, 1, "moves down off the last row boundary")
        s.lineFeed()   // already last row -> scroll
        XCTAssertEqual(s.cursor.row, 1)
        XCTAssertEqual(s.line(0), "", "top line scrolled off / blank-filled bottom")
    }

    // MARK: - resize

    func test_resize_preservesTopLeft_growsWithBlanks_clampsCursor() {
        var s = TerminalScreen(rows: 2, cols: 3)
        type("abc", into: &s)    // row0 = abc
        s.moveCursor(row: 1, col: 2)
        s.resize(rows: 3, cols: 5)
        XCTAssertEqual(s.rows, 3); XCTAssertEqual(s.cols, 5)
        XCTAssertEqual(s.line(0), "abc")
        XCTAssertEqual(s.cursor, TerminalCursor(row: 1, col: 2), "still in bounds, unchanged")
    }

    func test_resize_shrink_dropsOverflow_andClampsCursor() {
        var s = TerminalScreen(rows: 3, cols: 6)
        type("abcdef", into: &s)            // row0 full
        s.moveCursor(row: 2, col: 5)
        s.resize(rows: 1, cols: 3)
        XCTAssertEqual(s.rows, 1); XCTAssertEqual(s.cols, 3)
        XCTAssertEqual(s.line(0), "abc", "kept top-left 3 cols")
        XCTAssertEqual(s.cursor, TerminalCursor(row: 0, col: 2), "clamped into new bounds")
    }

    func test_resize_sameSize_isNoOp() {
        var s = TerminalScreen(rows: 2, cols: 2)
        type("ab", into: &s)
        let before = s
        s.resize(rows: 2, cols: 2)
        XCTAssertEqual(s, before)
    }

    // MARK: - erase family

    func test_eraseScreen_clearsAll_keepsCursor() {
        var s = TerminalScreen(rows: 2, cols: 3)
        type("abcdef", into: &s)
        s.moveCursor(row: 1, col: 2)
        s.eraseScreen()
        XCTAssertEqual(s.plainText(), "\n")
        XCTAssertEqual(s.cursor, TerminalCursor(row: 1, col: 2))
    }

    func test_eraseLineFromCursor_andToCursor() {
        var s = TerminalScreen(rows: 1, cols: 6)
        type("abcdef", into: &s)
        s.moveCursorCol(3)
        s.eraseLineFromCursor()          // cols 3..5 blanked
        XCTAssertEqual(s.line(0), "abc")
        type("XYZ", into: &s); s.moveCursorCol(0)
        var s2 = TerminalScreen(rows: 1, cols: 6)
        type("abcdef", into: &s2)
        s2.moveCursorCol(2)
        s2.eraseLineToCursor()           // cols 0...2 blanked (inclusive)
        XCTAssertEqual(s2.line(0), "   def", "leading blanks kept; line() trims only trailing")
        XCTAssertEqual(s2.cells[0][0].char, " ")
        XCTAssertEqual(s2.cells[0][2].char, " ")
        XCTAssertEqual(s2.cells[0][3].char, "d")
    }

    func test_eraseLine_clearsWholeCursorRow() {
        var s = TerminalScreen(rows: 2, cols: 4)
        type("abcd", into: &s); s.lineFeed(); s.carriageReturn(); type("efgh", into: &s)
        s.moveCursor(row: 0, col: 2)
        s.eraseLine()
        XCTAssertEqual(s.line(0), "")
        XCTAssertEqual(s.line(1), "efgh", "other rows untouched")
    }

    func test_eraseScreenFromCursor_andToCursor() {
        func filled() -> TerminalScreen {
            var s = TerminalScreen(rows: 3, cols: 3)
            type("aaabbbccc", into: &s)   // row0 aaa, row1 bbb, row2 ccc
            return s
        }
        var from = filled(); from.moveCursor(row: 1, col: 1)
        from.eraseScreenFromCursor()      // row1 col1..2 + all of row2
        XCTAssertEqual(from.line(0), "aaa")
        XCTAssertEqual(from.line(1), "b")
        XCTAssertEqual(from.line(2), "")

        var to = filled(); to.moveCursor(row: 1, col: 1)
        to.eraseScreenToCursor()          // all row0 + row1 col0..1
        XCTAssertEqual(to.line(0), "")
        XCTAssertEqual(to.cells[1][0].char, " ")
        XCTAssertEqual(to.cells[1][1].char, " ")
        XCTAssertEqual(to.cells[1][2].char, "b")
        XCTAssertEqual(to.line(2), "ccc")
    }

    // MARK: - scroll

    func test_scrollUp_shiftsContentAndBlankFills() {
        var s = TerminalScreen(rows: 3, cols: 3)
        type("aaabbbccc", into: &s)
        s.scrollUp(1)
        XCTAssertEqual(s.line(0), "bbb")
        XCTAssertEqual(s.line(1), "ccc")
        XCTAssertEqual(s.line(2), "")
    }

    func test_scrollDown_shiftsContentAndBlankFillsTop() {
        var s = TerminalScreen(rows: 3, cols: 3)
        type("aaabbbccc", into: &s)
        s.scrollDown(1)
        XCTAssertEqual(s.line(0), "")
        XCTAssertEqual(s.line(1), "aaa")
        XCTAssertEqual(s.line(2), "bbb")
    }

    func test_scroll_clampsCountAndIgnoresNonPositive() {
        var s = TerminalScreen(rows: 2, cols: 2)
        type("abcd", into: &s)
        s.scrollUp(99)                    // clamp to rows -> whole screen blank
        XCTAssertEqual(s.plainText(), "\n")
        var s2 = TerminalScreen(rows: 2, cols: 2)
        type("abcd", into: &s2)
        let before = s2
        s2.scrollUp(0); s2.scrollDown(-3) // no-ops
        XCTAssertEqual(s2, before)
    }

    // MARK: - Scrollback

    private func line(_ row: [TerminalCell]) -> String {
        var s = String(row.map(\.char))
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    func test_scrollUp_capturesEvictedLineIntoScrollback() {
        var s = TerminalScreen(rows: 2, cols: 3)
        type("aaabbb", into: &s)   // row0=aaa row1=bbb (auto-wrap)
        s.scrollUp(1)               // aaa evicted into scrollback
        XCTAssertEqual(s.scrollback.count, 1)
        XCTAssertEqual(line(s.scrollback[0]), "aaa")
        XCTAssertEqual(s.line(0), "bbb")
    }

    func test_scrollback_isBounded() {
        var s = TerminalScreen(rows: 1, cols: 2)
        for _ in 0..<(TerminalScreen.maxScrollback + 50) { s.scrollUp(1) }
        XCTAssertEqual(s.scrollback.count, TerminalScreen.maxScrollback)
    }

    func test_visibleLines_offsetZero_isLiveGrid() {
        var s = TerminalScreen(rows: 2, cols: 3)
        type("aaabbb", into: &s)
        s.scrollUp(1)               // grid now: bbb / blank, scrollback: [aaa]
        let live = s.visibleLines(scrollOffset: 0)
        XCTAssertEqual(live.map(line), ["bbb", ""])
    }

    func test_visibleLines_scrolledUp_showsHistoryAtTop() {
        var s = TerminalScreen(rows: 2, cols: 3)
        type("aaabbb", into: &s)     // aaa / bbb
        s.scrollUp(1)                // scrollback [aaa]; grid bbb / blank
        // Offset 1: window starts one line up → [aaa, bbb].
        let view = s.visibleLines(scrollOffset: 1)
        XCTAssertEqual(view.count, 2)
        XCTAssertEqual(line(view[0]), "aaa")
        XCTAssertEqual(line(view[1]), "bbb")
    }

    func test_visibleLines_clampsOffsetToScrollbackCount() {
        var s = TerminalScreen(rows: 2, cols: 3)
        type("aaabbb", into: &s)
        s.scrollUp(1)               // scrollback.count == 1
        // Over-scroll clamps to the same window as offset 1.
        XCTAssertEqual(s.visibleLines(scrollOffset: 99).map(line),
                       s.visibleLines(scrollOffset: 1).map(line))
    }

    func test_visibleLines_normalizesScrollbackRowToCurrentCols() {
        var s = TerminalScreen(rows: 2, cols: 4)
        type("wwwwxxxx", into: &s)   // row0 wwww (4 wide) / row1 xxxx
        s.scrollUp(1)                // scrollback [wwww] at width 4
        s.resize(rows: 2, cols: 2)   // shrink; scrollback row keeps width 4
        let view = s.visibleLines(scrollOffset: 1)
        XCTAssertEqual(view[0].count, 2, "scrollback row normalized to current cols")
        XCTAssertEqual(line(view[0]), "ww")
    }
}
