import XCTest
@testable import ViewerCore

/// TSK-1176 — the input-side command-boundary detector that populates the terminal
/// command history. Pure-logic, host-tested (the populate-wiring + search UI are the
/// render follow-ons). These pin the conservative contract: capture cleanly-typed
/// commands, NEVER record garbage from line-editing / recall / completion.
final class TerminalInputLineAccumulatorTests: XCTestCase {

    func test_simpleCommand_onEnter() {
        var acc = TerminalInputLineAccumulator()
        XCTAssertEqual(acc.feed("ls\r"), ["ls"])
    }

    func test_acceptsLF_asEnter() {
        var acc = TerminalInputLineAccumulator()
        XCTAssertEqual(acc.feed("pwd\n"), ["pwd"])
    }

    func test_accumulatesAcrossFeeds_perKeystroke() {
        var acc = TerminalInputLineAccumulator()
        XCTAssertEqual(acc.feed("l"), [])
        XCTAssertEqual(acc.feed("s"), [])
        XCTAssertEqual(acc.feed("\r"), ["ls"])
    }

    func test_backspace_editsLine() {
        var acc = TerminalInputLineAccumulator()
        // "lz" then DEL removes 'z' then 's' → "ls".
        XCTAssertEqual(acc.feed("lz\u{7f}s\r"), ["ls"])
        // BS (\u{08}) too.
        XCTAssertEqual(acc.feed("ab\u{08}\r"), ["a"])
    }

    func test_backspace_onEmptyLine_isNoop() {
        var acc = TerminalInputLineAccumulator()
        XCTAssertEqual(acc.feed("\u{7f}\u{7f}x\r"), ["x"])
    }

    func test_multiLinePaste_emitsEachCommand() {
        var acc = TerminalInputLineAccumulator()
        XCTAssertEqual(acc.feed("a\nb\nc\n"), ["a", "b", "c"])
    }

    func test_blankAndWhitespaceOnlyLines_skipped() {
        var acc = TerminalInputLineAccumulator()
        XCTAssertEqual(acc.feed("\r"), [])
        XCTAssertEqual(acc.feed("   \r"), [])
        XCTAssertEqual(acc.feed("\t\r"), [])   // tab → dropping → nothing
    }

    func test_commandWithSpaces_preserved() {
        var acc = TerminalInputLineAccumulator()
        XCTAssertEqual(acc.feed("git status\r"), ["git status"])
    }

    func test_escapeSequence_dropsWholeLine_noGarbage() {
        var acc = TerminalInputLineAccumulator()
        // Up-arrow (ESC [ A) mid-line → the line is untrackable → dropped, and the
        // escape-sequence BODY ("[A") must NOT be recorded as a command.
        XCTAssertEqual(acc.feed("ls\u{1b}[A\r"), [])
    }

    func test_tab_dropsWholeLine() {
        var acc = TerminalInputLineAccumulator()
        // Tab-completion changes the line in ways the input stream can't follow.
        XCTAssertEqual(acc.feed("cd Doc\u{09}\r"), [])
    }

    func test_droppingResets_afterEnter_soNextLineIsCaptured() {
        var acc = TerminalInputLineAccumulator()
        XCTAssertEqual(acc.feed("x\u{1b}[B\r"), [])     // dropped line
        XCTAssertEqual(acc.feed("ok\r"), ["ok"])         // fresh line captured
    }

    func test_ctrlC_clearsPartial_butKeepsCapturingTheLine() {
        var acc = TerminalInputLineAccumulator()
        // Ctrl-C (\u{03}) abandons the partial; a fresh retype on the same prompt
        // is still captured (unlike ESC/Tab which drop until Enter).
        XCTAssertEqual(acc.feed("abc\u{03}def\r"), ["def"])
    }

    func test_ctrlU_clearsLine() {
        var acc = TerminalInputLineAccumulator()
        XCTAssertEqual(acc.feed("wrong\u{15}right\r"), ["right"])
    }
}
