import XCTest
@testable import ViewerCore

/// Golden coverage for the alternate screen buffer (TSK-490) — the real
/// `top`/`vim`/`less` fix. Drives `ANSIParser` with DEC private-mode escapes
/// and asserts the main grid + scrollback are preserved untouched, so a
/// full-screen app never churns the user's scrollback (the "constant scroll"
/// report). Pure ViewerCore logic; host-testable end to end.
final class TerminalAltScreenTests: XCTestCase {

    private let ESC = "\u{1B}"

    /// Feed a string to the parser as UTF-8 bytes.
    private func feed(_ p: inout ANSIParser, _ s: String) {
        p.feed(Array(s.utf8))
    }

    /// Build a parser whose main screen has known content AND scrollback:
    /// a 3-row grid fed 5 lines (A..E), so [A,B] scroll into history and the
    /// grid shows [C,D,E].
    private func mainWithScrollback() -> ANSIParser {
        var p = ANSIParser(rows: 3, cols: 20)
        feed(&p, "A\r\nB\r\nC\r\nD\r\nE")
        return p
    }

    // MARK: - Enter / exit basics

    func test_enter1049_swapsToBlankBuffer_noScrollback() {
        var p = mainWithScrollback()
        XCTAssertFalse(p.screen.inAltScreen)
        XCTAssertEqual(p.screen.scrollback.count, 2)

        feed(&p, "\(ESC)[?1049h")
        XCTAssertTrue(p.screen.inAltScreen)
        XCTAssertTrue(p.screen.scrollback.isEmpty, "alt screen has no scrollback")
        // Fresh blank grid + homed cursor.
        XCTAssertEqual(p.screen.plainText(), "\n\n")
        XCTAssertEqual(p.screen.cursor, TerminalCursor(row: 0, col: 0))

        feed(&p, "ALT")
        XCTAssertEqual(p.screen.line(0), "ALT")
    }

    func test_roundTrip_restoresMainGridScrollbackAndCursor() {
        var p = mainWithScrollback()
        let mainCells = p.screen.cells
        let mainScrollback = p.screen.scrollback
        let mainCursor = p.screen.cursor

        feed(&p, "\(ESC)[?1049h")        // enter
        feed(&p, "\(ESC)[Hgarbage\r\nmore")
        feed(&p, "\(ESC)[?1049l")        // exit

        XCTAssertFalse(p.screen.inAltScreen)
        XCTAssertEqual(p.screen.cells, mainCells, "main grid not restored")
        XCTAssertEqual(p.screen.scrollback, mainScrollback, "scrollback not restored")
        XCTAssertEqual(p.screen.cursor, mainCursor, "cursor not restored")
    }

    /// The headline scenario: a `top`-style refresh loop (home + clear +
    /// redraw, repeated) inside the alt screen must leave the user's
    /// scrollback completely pristine.
    func test_topLikeRefreshLoop_leavesScrollbackPristine() {
        var p = mainWithScrollback()
        let mainScrollback = p.screen.scrollback
        let mainCells = p.screen.cells

        feed(&p, "\(ESC)[?1049h")
        for i in 0..<8 {
            feed(&p, "\(ESC)[H\(ESC)[2J")               // home + clear
            feed(&p, "Processes \(i)\r\nload\r\nmem")    // redraw a few rows
        }
        feed(&p, "\(ESC)[?1049l")

        XCTAssertEqual(p.screen.scrollback, mainScrollback,
                       "top's refreshes churned the user's scrollback")
        XCTAssertEqual(p.screen.cells, mainCells, "main grid not restored after top")
    }

    // MARK: - scrollUp must not touch scrollback while in alt

    func test_scrollUpInAlt_doesNotGrowScrollback() {
        var p = ANSIParser(rows: 3, cols: 10)
        feed(&p, "\(ESC)[?1049h")
        // Force many line feeds past the bottom row → repeated scrollUp.
        for i in 0..<20 { feed(&p, "row\(i)\r\n") }
        XCTAssertTrue(p.screen.inAltScreen)
        XCTAssertTrue(p.screen.scrollback.isEmpty,
                      "alt-screen scrollUp must discard, never retain scrollback")
    }

    // MARK: - 47 / 1047 variants

    func test_mode47_togglesAltScreen() {
        var p = mainWithScrollback()
        feed(&p, "\(ESC)[?47h")
        XCTAssertTrue(p.screen.inAltScreen)
        feed(&p, "\(ESC)[?47l")
        XCTAssertFalse(p.screen.inAltScreen)
    }

    func test_mode1047_togglesAltScreen() {
        var p = mainWithScrollback()
        let mainCells = p.screen.cells
        feed(&p, "\(ESC)[?1047h")
        XCTAssertTrue(p.screen.inAltScreen)
        feed(&p, "junk")
        feed(&p, "\(ESC)[?1047l")
        XCTAssertFalse(p.screen.inAltScreen)
        XCTAssertEqual(p.screen.cells, mainCells)
    }

    // MARK: - Idempotence + robustness

    func test_doubleEnter_doesNotClobberSavedMain() {
        var p = mainWithScrollback()
        let mainCells = p.screen.cells
        feed(&p, "\(ESC)[?1049h")
        feed(&p, "first")
        feed(&p, "\(ESC)[?1049h")     // second enter — must be a no-op
        feed(&p, "second")
        feed(&p, "\(ESC)[?1049l")
        XCTAssertEqual(p.screen.cells, mainCells,
                       "double-enter clobbered the saved main buffer")
    }

    func test_exitWhenNotInAlt_isNoOp() {
        var p = mainWithScrollback()
        let mainCells = p.screen.cells
        feed(&p, "\(ESC)[?1049l")     // exit without ever entering
        XCTAssertFalse(p.screen.inAltScreen)
        XCTAssertEqual(p.screen.cells, mainCells)
    }

    func test_otherPrivateModes_stillIgnored_noAltScreen() {
        var p = mainWithScrollback()
        feed(&p, "\(ESC)[?25l")       // hide cursor
        feed(&p, "\(ESC)[?2004h")     // bracketed paste on
        feed(&p, "\(ESC)[?1000h")     // mouse tracking on
        XCTAssertFalse(p.screen.inAltScreen, "unrelated private modes must not enter alt")
    }

    // MARK: - Resize while in alt

    func test_resizeWhileInAlt_restoresCurrentGeometryOnExit() {
        var p = mainWithScrollback()                 // 3×20
        feed(&p, "\(ESC)[?1049h")
        p.resize(rows: 5, cols: 30)
        feed(&p, "\(ESC)[?1049l")
        // Main buffer restored at the NEW geometry, top-left content intact.
        XCTAssertEqual(p.screen.rows, 5)
        XCTAssertEqual(p.screen.cols, 30)
        XCTAssertEqual(p.screen.cells.count, 5)
        XCTAssertEqual(p.screen.cells[0].count, 30)
        XCTAssertEqual(p.screen.line(0), "C", "pre-alt main content lost across resize")
    }
}
