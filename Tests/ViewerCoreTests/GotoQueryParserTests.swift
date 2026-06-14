import XCTest
@testable import ViewerCore

/// TSK-727: the pure classifier behind the unified "Goto Anything" palette.
/// Pins the operator routing + `:line:column` parsing so the palette wiring
/// (the view/VM tail) builds on a host-verified model.
final class GotoQueryParserTests: XCTestCase {

    func testEmptyIsFiles() {
        let q = GotoQueryParser.parse("")
        XCTAssertEqual(q.mode, .files)
        XCTAssertEqual(q.term, "")
    }

    func testBareInputIsFilesWithWholeTerm() {
        let q = GotoQueryParser.parse("ReadMe.md")
        XCTAssertEqual(q.mode, .files)
        XCTAssertEqual(q.term, "ReadMe.md", "files mode keeps the whole input as the term")
    }

    func testCommandOperator() {
        let q = GotoQueryParser.parse(">Open Settings")
        XCTAssertEqual(q.mode, .command)
        XCTAssertEqual(q.term, "Open Settings", "the leading > is consumed")
    }

    func testCommandOperatorAloneListsAll() {
        // ">" with no term — matches the existing palette's "list all commands".
        let q = GotoQueryParser.parse(">")
        XCTAssertEqual(q.mode, .command)
        XCTAssertEqual(q.term, "")
    }

    func testSymbolOperator() {
        let q = GotoQueryParser.parse("@viewDidLoad")
        XCTAssertEqual(q.mode, .symbol)
        XCTAssertEqual(q.term, "viewDidLoad")
    }

    func testTextOperator() {
        let q = GotoQueryParser.parse("#TODO")
        XCTAssertEqual(q.mode, .text)
        XCTAssertEqual(q.term, "TODO")
    }

    func testLineOnly() {
        let q = GotoQueryParser.parse(":42")
        XCTAssertEqual(q.mode, .line)
        XCTAssertEqual(q.line, 42)
        XCTAssertNil(q.column)
    }

    func testLineAndColumn() {
        let q = GotoQueryParser.parse(":42:10")
        XCTAssertEqual(q.mode, .line)
        XCTAssertEqual(q.line, 42)
        XCTAssertEqual(q.column, 10)
    }

    func testBareColonHasNoLineYet() {
        // Typing just ":" is mid-entry — line mode, but nothing to jump to yet.
        let q = GotoQueryParser.parse(":")
        XCTAssertEqual(q.mode, .line)
        XCTAssertNil(q.line)
        XCTAssertNil(q.column)
    }

    func testLineWithTrailingColonNoColumn() {
        let q = GotoQueryParser.parse(":42:")
        XCTAssertEqual(q.mode, .line)
        XCTAssertEqual(q.line, 42)
        XCTAssertNil(q.column, "empty column part is not a usable column")
    }

    func testNonNumericLineIsNil() {
        let q = GotoQueryParser.parse(":abc")
        XCTAssertEqual(q.mode, .line)
        XCTAssertNil(q.line)
    }

    func testZeroAndNegativeLineRejected() {
        XCTAssertNil(GotoQueryParser.parse(":0").line, "lines are 1-based; 0 is invalid")
        XCTAssertNil(GotoQueryParser.parse(":-5").line, "negative line is invalid")
    }

    func testThirdColonDoesNotBecomeColumn() {
        // ":42:10:99" — only the first colon splits; "10:99" is not an Int → no column.
        let q = GotoQueryParser.parse(":42:10:99")
        XCTAssertEqual(q.line, 42)
        XCTAssertNil(q.column)
    }

    func testLeadingWhitespaceDisablesOperator() {
        // A space before the operator → plain file search (VS Code behaviour),
        // so " >foo" searches files for " >foo" rather than running a command.
        let q = GotoQueryParser.parse(" >foo")
        XCTAssertEqual(q.mode, .files)
        XCTAssertEqual(q.term, " >foo")
    }

    func testOperatorOnlyInFirstPositionMatters() {
        // An operator char later in the string is part of the term, not a mode.
        let q = GotoQueryParser.parse("foo@bar")
        XCTAssertEqual(q.mode, .files)
        XCTAssertEqual(q.term, "foo@bar")
    }

    func testTermPreservesInternalSpaces() {
        let q = GotoQueryParser.parse("@my method")
        XCTAssertEqual(q.mode, .symbol)
        XCTAssertEqual(q.term, "my method")
    }

    // MARK: - submitAction routing (palette Return dispatch)

    func testSubmitActionGoToLine() {
        XCTAssertEqual(GotoQueryParser.parse(":42").submitAction, .goToLine(42))
        XCTAssertEqual(GotoQueryParser.parse(":42:10").submitAction, .goToLine(42))
    }

    func testSubmitActionBareColonIsNone() {
        XCTAssertEqual(GotoQueryParser.parse(":").submitAction, .none)
        XCTAssertEqual(GotoQueryParser.parse(":abc").submitAction, .none)
        XCTAssertEqual(GotoQueryParser.parse(":0").submitAction, .none)
    }

    func testSubmitActionCommand() {
        XCTAssertEqual(GotoQueryParser.parse(">build").submitAction, .runCommand)
    }

    func testSubmitActionFilesAndUnsurfacedModesOpenFile() {
        XCTAssertEqual(GotoQueryParser.parse("readme").submitAction, .openFile)
        // @ / # are parsed but not yet surfaced → fall back to file open.
        XCTAssertEqual(GotoQueryParser.parse("@sym").submitAction, .openFile)
        XCTAssertEqual(GotoQueryParser.parse("#text").submitAction, .openFile)
    }

    func testEveryModeReachable() {
        // Guard: the operator table covers every GotoMode (a new mode without a
        // parse path would fail this).
        let reached = Set([
            GotoQueryParser.parse("x").mode,
            GotoQueryParser.parse(">x").mode,
            GotoQueryParser.parse("@x").mode,
            GotoQueryParser.parse(":1").mode,
            GotoQueryParser.parse("#x").mode,
        ])
        XCTAssertEqual(reached, Set(GotoMode.allCases))
    }
}
