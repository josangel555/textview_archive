import XCTest
@testable import ViewerCore

/// Headless (Tier 1) coverage for the dep-free ANSI/VT parser + screen
/// buffer. Feeds byte sequences and asserts grid text / colours / cursor
/// / erase / scroll. The LIVE PTY/shell path is NOT exercised here — it
/// can't be unit-tested on the host without forking a real shell (see the
/// implementation note on `PTYProcess`).
final class ANSIParserTests: XCTestCase {

    private func parser(_ rows: Int = 5, _ cols: Int = 20) -> ANSIParser {
        ANSIParser(rows: rows, cols: cols)
    }

    private func feed(_ p: inout ANSIParser, _ s: String) {
        p.feed(Array(s.utf8))
    }

    // MARK: - Printable text

    func test_plainText_writesAtCursorAndAdvances() {
        var p = parser()
        feed(&p, "hello")
        XCTAssertEqual(p.screen.line(0), "hello")
        XCTAssertEqual(p.screen.cursor.col, 5)
        XCTAssertEqual(p.screen.cursor.row, 0)
    }

    func test_utf8_multibyte_splitAcrossChunks_decodesCorrectly() {
        var p = parser()
        // "é" is 0xC3 0xA9 — feed the two bytes in separate calls.
        p.feed([0xC3])
        p.feed([0xA9])
        feed(&p, "x")
        XCTAssertEqual(p.screen.line(0), "éx")
    }

    func test_emoji_rendersInSingleCell() {
        var p = parser()
        feed(&p, "a😀b")
        // The emoji is one grapheme = one cell in our model.
        XCTAssertEqual(p.screen.line(0), "a😀b")
    }

    // MARK: - C0 controls

    func test_carriageReturn_resetsColumn_overwrite() {
        var p = parser()
        feed(&p, "hello\rJ")
        XCTAssertEqual(p.screen.line(0), "Jello")
    }

    func test_newline_movesDownSameColumnSemantics_withCRLF() {
        var p = parser()
        feed(&p, "ab\r\ncd")
        XCTAssertEqual(p.screen.line(0), "ab")
        XCTAssertEqual(p.screen.line(1), "cd")
        XCTAssertEqual(p.screen.cursor.row, 1)
    }

    func test_backspace_movesCursorLeft_noErase() {
        var p = parser()
        // Shell rubout pattern: write, BS, space, BS.
        feed(&p, "abc")
        feed(&p, "\u{08} \u{08}")
        XCTAssertEqual(p.screen.line(0), "ab")
        XCTAssertEqual(p.screen.cursor.col, 2)
    }

    func test_tab_advancesToNextTabStop() {
        var p = parser(5, 40)
        feed(&p, "a\tb")
        // 'a' at col0, TAB → col8, 'b' at col8.
        XCTAssertEqual(p.screen.cursor.col, 9)
        let line = p.screen.line(0)
        XCTAssertTrue(line.hasPrefix("a"))
        XCTAssertEqual(Array(line).count, 9)        // a + 7 spaces + b
        XCTAssertEqual(Array(line).last, "b")
    }

    // MARK: - Auto-wrap

    func test_autoWrap_atRightEdge_wrapsToNextLine() {
        var p = parser(5, 4)
        feed(&p, "abcde")
        XCTAssertEqual(p.screen.line(0), "abcd")
        XCTAssertEqual(p.screen.line(1), "e")
        XCTAssertEqual(p.screen.cursor.row, 1)
        XCTAssertEqual(p.screen.cursor.col, 1)
    }

    // MARK: - Cursor moves (CSI)

    func test_CUP_movesToRowCol_1based() {
        var p = parser()
        feed(&p, "\u{1B}[3;5HX")     // row 3, col 5 (1-based)
        XCTAssertEqual(p.screen.cursor.row, 2)  // before the write
        // X was written at (2,4), cursor advanced to col5.
        XCTAssertEqual(p.screen.cursor.col, 5)
        XCTAssertEqual(String(Array(p.screen.line(2))[4]), "X")
    }

    func test_CUP_noParams_homesCursor() {
        var p = parser()
        feed(&p, "\u{1B}[3;5H\u{1B}[HZ")
        XCTAssertEqual(String(Array(p.screen.line(0))[0]), "Z")
    }

    func test_cursorMoves_CUU_CUD_CUF_CUB() {
        var p = parser()
        feed(&p, "\u{1B}[3;3H")       // → (2,2)
        feed(&p, "\u{1B}[A")          // up → (1,2)
        XCTAssertEqual(p.screen.cursor.row, 1)
        feed(&p, "\u{1B}[2B")         // down 2 → (3,2)
        XCTAssertEqual(p.screen.cursor.row, 3)
        feed(&p, "\u{1B}[4C")         // forward 4 → col 6
        XCTAssertEqual(p.screen.cursor.col, 6)
        feed(&p, "\u{1B}[2D")         // back 2 → col 4
        XCTAssertEqual(p.screen.cursor.col, 4)
    }

    func test_CHA_absoluteColumn_and_VPA_absoluteRow() {
        var p = parser()
        feed(&p, "\u{1B}[10G")        // col 10 (1-based) → col 9
        XCTAssertEqual(p.screen.cursor.col, 9)
        feed(&p, "\u{1B}[4d")         // row 4 (1-based) → row 3
        XCTAssertEqual(p.screen.cursor.row, 3)
    }

    func test_cursorMoves_clampToGrid() {
        var p = parser(3, 3)
        feed(&p, "\u{1B}[99;99H")
        XCTAssertEqual(p.screen.cursor.row, 2)
        XCTAssertEqual(p.screen.cursor.col, 2)
    }

    // MARK: - Erase

    func test_eraseLine_K0_fromCursorToEnd() {
        var p = parser()
        feed(&p, "abcdef")
        feed(&p, "\r\u{1B}[3C")       // CR then forward 3 → col 3
        feed(&p, "\u{1B}[K")          // erase to end of line
        XCTAssertEqual(p.screen.line(0), "abc")
    }

    func test_eraseLine_K1_startToCursor() {
        var p = parser()
        feed(&p, "abcdef")            // cursor at col 6
        feed(&p, "\r\u{1B}[3C")       // → col 3
        feed(&p, "\u{1B}[1K")         // erase start..cursor (cols 0..3)
        // cols 0,1,2,3 cleared; 'e','f' at cols 4,5 remain.
        XCTAssertEqual(p.screen.line(0), "    ef")
    }

    func test_eraseLine_K2_wholeLine() {
        var p = parser()
        feed(&p, "abcdef")
        feed(&p, "\u{1B}[2K")
        XCTAssertEqual(p.screen.line(0), "")
    }

    func test_eraseScreen_J2_clearsEverything() {
        var p = parser()
        feed(&p, "line1\r\nline2\r\nline3")
        feed(&p, "\u{1B}[2J")
        XCTAssertEqual(p.screen.plainText(), "\n\n\n\n")  // 5 blank rows
    }

    func test_eraseScreen_J0_fromCursorDown() {
        var p = parser()
        feed(&p, "AAAA\r\nBBBB\r\nCCCC")
        feed(&p, "\u{1B}[2;3H")       // row2 col3
        feed(&p, "\u{1B}[0J")         // erase from cursor to end
        XCTAssertEqual(p.screen.line(0), "AAAA")
        XCTAssertEqual(p.screen.line(1), "BB")   // cols 0,1 kept; rest erased
        XCTAssertEqual(p.screen.line(2), "")
    }

    // MARK: - Scroll

    func test_lineFeed_onLastRow_scrollsUp() {
        var p = parser(3, 5)
        feed(&p, "one\r\ntwo\r\nthree")
        XCTAssertEqual(p.screen.line(0), "one")
        feed(&p, "\r\nfour")          // LF on last row scrolls
        XCTAssertEqual(p.screen.line(0), "two")
        XCTAssertEqual(p.screen.line(1), "three")
        XCTAssertEqual(p.screen.line(2), "four")
    }

    func test_scrollUp_SU_and_scrollDown_SD() {
        var p = parser(3, 5)
        feed(&p, "aaa\r\nbbb\r\nccc")
        feed(&p, "\u{1B}[1S")          // scroll up 1
        XCTAssertEqual(p.screen.line(0), "bbb")
        XCTAssertEqual(p.screen.line(2), "")
        feed(&p, "\u{1B}[1T")          // scroll down 1
        XCTAssertEqual(p.screen.line(0), "")
        XCTAssertEqual(p.screen.line(1), "bbb")
    }

    // MARK: - SGR colours / attributes

    func test_SGR_foregroundColor_stampsCell() {
        var p = parser()
        feed(&p, "\u{1B}[31mR\u{1B}[0mN")  // red R, reset, default N
        XCTAssertEqual(p.screen.cells[0][0].attributes.fg, .red)
        XCTAssertEqual(p.screen.cells[0][1].attributes.fg, .default)
    }

    func test_SGR_bold_and_underline_and_inverse() {
        var p = parser()
        feed(&p, "\u{1B}[1;4;7mX")
        let a = p.screen.cells[0][0].attributes
        XCTAssertTrue(a.bold)
        XCTAssertTrue(a.underline)
        XCTAssertTrue(a.inverse)
    }

    func test_SGR_brightForeground_90s() {
        var p = parser()
        feed(&p, "\u{1B}[92mG")
        XCTAssertEqual(p.screen.cells[0][0].attributes.fg, .brightGreen)
    }

    func test_SGR_background_40s() {
        var p = parser()
        feed(&p, "\u{1B}[44mB")
        XCTAssertEqual(p.screen.cells[0][0].attributes.bg, .blue)
    }

    func test_SGR_reset_emptyParams() {
        var p = parser()
        feed(&p, "\u{1B}[31m\u{1B}[mX")   // ESC[m == reset
        XCTAssertEqual(p.screen.cells[0][0].attributes.fg, .default)
    }

    func test_SGR_256color_index_isApplied_notGarbled() {
        var p = parser()
        // ESC[38;5;200m sets a 256-colour index AND must NOT print the
        // params as text.
        feed(&p, "\u{1B}[38;5;200mX")
        XCTAssertEqual(p.screen.line(0), "X")
        XCTAssertEqual(p.screen.cells[0][0].attributes.fg, .indexed(200))
    }

    func test_SGR_256color_background_isApplied() {
        var p = parser()
        feed(&p, "\u{1B}[48;5;17mX")
        XCTAssertEqual(p.screen.cells[0][0].attributes.bg, .indexed(17))
    }

    func test_SGR_truecolor_isApplied_thenSubsequentSGRapplies() {
        var p = parser()
        // ESC[38;2;10;20;30;1m → truecolor fg (applied) + bold (applied).
        feed(&p, "\u{1B}[38;2;10;20;30;1mX")
        XCTAssertEqual(p.screen.line(0), "X")
        XCTAssertEqual(p.screen.cells[0][0].attributes.fg, .rgb(10, 20, 30))
        XCTAssertTrue(p.screen.cells[0][0].attributes.bold)
    }

    func test_SGR_truecolor_background_isApplied() {
        var p = parser()
        feed(&p, "\u{1B}[48;2;200;100;50mX")
        XCTAssertEqual(p.screen.cells[0][0].attributes.bg, .rgb(200, 100, 50))
    }

    func test_SGR_256color_index_outOfRange_isClamped() {
        var p = parser()
        // 999 is out of the 0–255 byte range; clamp to 255 rather than trap.
        feed(&p, "\u{1B}[38;5;999mX")
        XCTAssertEqual(p.screen.cells[0][0].attributes.fg, .indexed(255))
    }

    // MARK: - Ignored / stripped sequences

    func test_decPrivateMode_isStripped() {
        var p = parser()
        // ESC[?25l (hide cursor) + ESC[?2004h (bracketed paste) — ignored,
        // not printed.
        feed(&p, "\u{1B}[?25l\u{1B}[?2004hQ")
        XCTAssertEqual(p.screen.line(0), "Q")
    }

    func test_oscSequence_isSwallowed_BELterminated() {
        var p = parser()
        // OSC set-window-title: ESC]0;My Title BEL — must not print.
        feed(&p, "\u{1B}]0;My Title\u{07}done")
        XCTAssertEqual(p.screen.line(0), "done")
    }

    func test_oscSequence_isSwallowed_STterminated() {
        var p = parser()
        feed(&p, "\u{1B}]0;Title\u{1B}\\done")
        XCTAssertEqual(p.screen.line(0), "done")
    }

    func test_unknownCSIfinalByte_isStripped() {
        var p = parser()
        // ESC[5X (ECH erase-char, not modelled) — consumed, no garbage.
        feed(&p, "AB\u{1B}[5XCD")
        XCTAssertEqual(p.screen.line(0), "ABCD")
    }

    func test_escSequenceSplitAcrossChunks() {
        var p = parser()
        // Split "ESC[31m" across feed calls.
        p.feed(Array("\u{1B}[3".utf8))
        p.feed(Array("1mZ".utf8))
        XCTAssertEqual(p.screen.cells[0][0].attributes.fg, .red)
        XCTAssertEqual(p.screen.line(0), "Z")
    }

    func test_charsetDesignator_isSwallowed() {
        var p = parser()
        // ESC(B selects ASCII charset — the 'B' must not print.
        feed(&p, "\u{1B}(Bhi")
        XCTAssertEqual(p.screen.line(0), "hi")
    }

    // MARK: - Resize

    func test_resize_preservesTopLeftContent_andClampsCursor() {
        var p = parser(4, 10)
        feed(&p, "hello\r\nworld")
        p.resize(rows: 2, cols: 3)
        XCTAssertEqual(p.screen.line(0), "hel")
        XCTAssertEqual(p.screen.line(1), "wor")
        XCTAssertLessThan(p.screen.cursor.row, 2)
        XCTAssertLessThan(p.screen.cursor.col, 3)
    }

    // MARK: - Realistic prompt fragment

    func test_realisticColoredPrompt() {
        var p = parser(3, 40)
        // A zsh-ish coloured prompt + a command echo.
        feed(&p, "\u{1B}[32muser@host\u{1B}[0m:\u{1B}[34m~/dir\u{1B}[0m$ ls")
        XCTAssertEqual(p.screen.line(0), "user@host:~/dir$ ls")
        XCTAssertEqual(p.screen.cells[0][0].attributes.fg, .green)
        // ':' is at index 9 with default colour.
        XCTAssertEqual(p.screen.cells[0][9].attributes.fg, .default)
        // '~' starts the blue run.
        XCTAssertEqual(p.screen.cells[0][10].attributes.fg, .blue)
    }

    // MARK: - In-line edits DCH / ICH / ECH / IL / DL (TSK-740)

    func test_DCH_deletesCharsAndShiftsLeft() {
        var p = parser()
        feed(&p, "abcde")
        feed(&p, "\r")                 // cursor → col 0
        feed(&p, "\u{1b}[2P")          // DCH 2 → delete a,b; cde shifts left
        XCTAssertEqual(p.screen.line(0), "cde",
            "DCH must remove the deleted chars — they used to linger (the bug)")
    }

    func test_DCH_default1() {
        var p = parser()
        feed(&p, "abc")
        feed(&p, "\r")
        feed(&p, "\u{1b}[P")           // DCH (no param) defaults to 1
        XCTAssertEqual(p.screen.line(0), "bc")
    }

    func test_ICH_insertsBlanksAndShiftsRight() {
        var p = parser()
        feed(&p, "abcde")
        feed(&p, "\r")
        feed(&p, "\u{1b}[2@")          // ICH 2 → "  abcde"
        XCTAssertEqual(p.screen.line(0), "  abcde")
    }

    func test_ECH_erasesInPlaceNoShift() {
        var p = parser()
        feed(&p, "abcde")
        feed(&p, "\r")
        feed(&p, "\u{1b}[2X")          // ECH 2 → blank cols 0,1 in place
        XCTAssertEqual(p.screen.line(0), "  cde")
    }

    func test_DL_deletesLinesAndShiftsUp() {
        var p = parser()
        feed(&p, "L0\r\nL1\r\nL2")
        feed(&p, "\u{1b}[1;1H")        // home
        feed(&p, "\u{1b}[1M")          // DL 1 → drop L0, shift up
        XCTAssertEqual(p.screen.line(0), "L1")
        XCTAssertEqual(p.screen.line(1), "L2")
    }

    func test_IL_insertsBlankLineAndShiftsDown() {
        var p = parser()
        feed(&p, "L0\r\nL1")
        feed(&p, "\u{1b}[1;1H")        // home
        feed(&p, "\u{1b}[1L")          // IL 1 → blank row 0, shift down
        XCTAssertEqual(p.screen.line(0), "")
        XCTAssertEqual(p.screen.line(1), "L0")
        XCTAssertEqual(p.screen.line(2), "L1")
    }
}
