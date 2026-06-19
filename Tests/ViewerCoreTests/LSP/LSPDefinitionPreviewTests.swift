import XCTest
@testable import ViewerCore

/// Pure-model coverage of the Preview Definition (Quick Definition /
/// Cmd+Y, TSK-708) snippet-window helper and the command gating. No
/// live LSP server, no AppKit — the popover render + the real keystroke
/// are the VM tail; this pins the model the popover renders and the
/// gate the menu item obeys.
final class LSPDefinitionPreviewTests: XCTestCase {

    private let file = """
    line0
    line1
    line2
    line3
    line4
    line5
    line6
    """

    private func loc(line: Int, char: Int = 0) -> LSPLocation {
        LSPLocation(
            uri: "file:///tmp/Foo.swift",
            range: .init(start: .init(line: line, character: char),
                         end: .init(line: line, character: char + 3)))
    }

    // MARK: - Centered window

    func test_snippet_centeredWindow_returnsContextAboveAndBelow() {
        let w = LSPDefinitionPreview.snippet(
            fromContents: file, target: loc(line: 3), contextLines: 2)
        let win = try! XCTUnwrap(w)
        XCTAssertEqual(win.lines, ["line1", "line2", "line3", "line4", "line5"])
        XCTAssertEqual(win.startLine, 1)
        XCTAssertEqual(win.endLine, 5)
        XCTAssertEqual(win.targetDocumentLine, 3)
        XCTAssertEqual(win.highlightIndex, 2)
        XCTAssertEqual(win.highlightedLine, "line3")
    }

    // MARK: - Clamping at file start

    func test_snippet_nearStart_clampsTopAndKeepsHighlight() {
        let w = LSPDefinitionPreview.snippet(
            fromContents: file, target: loc(line: 0), contextLines: 2)
        let win = try! XCTUnwrap(w)
        // No lines above line 0; window is line0..line2.
        XCTAssertEqual(win.lines, ["line0", "line1", "line2"])
        XCTAssertEqual(win.startLine, 0)
        XCTAssertEqual(win.highlightIndex, 0)
        XCTAssertEqual(win.highlightedLine, "line0")
    }

    func test_snippet_lineOne_clampsTopByOne() {
        let w = LSPDefinitionPreview.snippet(
            fromContents: file, target: loc(line: 1), contextLines: 2)
        let win = try! XCTUnwrap(w)
        XCTAssertEqual(win.lines, ["line0", "line1", "line2", "line3"])
        XCTAssertEqual(win.startLine, 0)
        XCTAssertEqual(win.highlightIndex, 1) // line1 is index 1 of window
        XCTAssertEqual(win.highlightedLine, "line1")
    }

    // MARK: - Clamping at file end

    func test_snippet_nearEnd_clampsBottom() {
        let w = LSPDefinitionPreview.snippet(
            fromContents: file, target: loc(line: 6), contextLines: 2)
        let win = try! XCTUnwrap(w)
        XCTAssertEqual(win.lines, ["line4", "line5", "line6"])
        XCTAssertEqual(win.startLine, 4)
        XCTAssertEqual(win.endLine, 6)
        XCTAssertEqual(win.highlightIndex, 2)
        XCTAssertEqual(win.highlightedLine, "line6")
    }

    // MARK: - Target past EOF clamps to last line

    func test_snippet_targetBeyondEOF_clampsToLastLine() {
        let w = LSPDefinitionPreview.snippet(
            fromContents: file, target: loc(line: 99), contextLines: 2)
        let win = try! XCTUnwrap(w)
        XCTAssertEqual(win.targetDocumentLine, 6) // clamped to last
        XCTAssertEqual(win.highlightedLine, "line6")
        XCTAssertEqual(win.endLine, 6)
    }

    func test_snippet_negativeTarget_clampsToFirstLine() {
        let w = LSPDefinitionPreview.snippet(
            fromContents: file, targetLine: -5, contextLines: 1)
        let win = try! XCTUnwrap(w)
        XCTAssertEqual(win.targetDocumentLine, 0)
        XCTAssertEqual(win.highlightedLine, "line0")
        XCTAssertEqual(win.startLine, 0)
    }

    // MARK: - Context-line variants

    func test_snippet_zeroContext_returnsOnlyTargetLine() {
        let w = LSPDefinitionPreview.snippet(
            fromContents: file, target: loc(line: 3), contextLines: 0)
        let win = try! XCTUnwrap(w)
        XCTAssertEqual(win.lines, ["line3"])
        XCTAssertEqual(win.highlightIndex, 0)
        XCTAssertEqual(win.startLine, 3)
        XCTAssertEqual(win.endLine, 3)
    }

    func test_snippet_negativeContext_treatedAsZero() {
        let w = LSPDefinitionPreview.snippet(
            fromContents: file, target: loc(line: 3), contextLines: -4)
        let win = try! XCTUnwrap(w)
        XCTAssertEqual(win.lines, ["line3"])
    }

    func test_snippet_contextLargerThanFile_returnsWholeFile() {
        let w = LSPDefinitionPreview.snippet(
            fromContents: file, target: loc(line: 3), contextLines: 100)
        let win = try! XCTUnwrap(w)
        XCTAssertEqual(win.lines.count, 7)
        XCTAssertEqual(win.startLine, 0)
        XCTAssertEqual(win.endLine, 6)
        XCTAssertEqual(win.highlightIndex, 3)
    }

    // MARK: - Empty / edge contents

    func test_snippet_emptyFile_returnsNil() {
        XCTAssertNil(LSPDefinitionPreview.snippet(
            fromContents: "", target: loc(line: 0), contextLines: 2))
    }

    func test_snippet_singleLineFile() {
        let w = LSPDefinitionPreview.snippet(
            fromContents: "only", target: loc(line: 0), contextLines: 3)
        let win = try! XCTUnwrap(w)
        XCTAssertEqual(win.lines, ["only"])
        XCTAssertEqual(win.highlightIndex, 0)
    }

    // MARK: - Line splitting (CRLF, trailing newline, blank lines)

    func test_splitLines_trailingNewline_noPhantomBlankLine() {
        XCTAssertEqual(LSPDefinitionPreview.splitLines("a\nb\n"), ["a", "b"])
    }

    func test_splitLines_crlf_stripsCarriageReturn() {
        XCTAssertEqual(
            LSPDefinitionPreview.splitLines("a\r\nb\r\nc"), ["a", "b", "c"])
    }

    func test_splitLines_bareCR_isLineBreak() {
        XCTAssertEqual(LSPDefinitionPreview.splitLines("a\rb"), ["a", "b"])
    }

    func test_splitLines_preservesInteriorBlankLines() {
        XCTAssertEqual(
            LSPDefinitionPreview.splitLines("a\n\nb"), ["a", "", "b"])
    }

    func test_splitLines_emptyString_isEmptyArray() {
        XCTAssertEqual(LSPDefinitionPreview.splitLines(""), [])
    }

    func test_snippet_crlfFile_highlightsCorrectLine() {
        let crlf = "alpha\r\nbravo\r\ncharlie\r\ndelta"
        let w = LSPDefinitionPreview.snippet(
            fromContents: crlf, target: loc(line: 2), contextLines: 1)
        let win = try! XCTUnwrap(w)
        XCTAssertEqual(win.lines, ["bravo", "charlie", "delta"])
        XCTAssertEqual(win.highlightedLine, "charlie")
        // No stray \r tails.
        XCTAssertFalse(win.lines.contains { $0.contains("\r") })
    }

    // MARK: - Command availability (gating)

    func test_availability_allPreconditionsMet_isEnabled() {
        let a = LSPDefinitionPreview.availability(
            hasActiveDocument: true,
            hasLanguageServer: true,
            definitionProviderAdvertised: true)
        XCTAssertTrue(a.isEnabled)
        XCTAssertEqual(a.reason, .available)
    }

    func test_availability_noActiveDocument_disabled() {
        let a = LSPDefinitionPreview.availability(
            hasActiveDocument: false,
            hasLanguageServer: true,
            definitionProviderAdvertised: true)
        XCTAssertFalse(a.isEnabled)
        XCTAssertEqual(a.reason, .noActiveDocument)
    }

    func test_availability_noLanguageServer_disabled() {
        let a = LSPDefinitionPreview.availability(
            hasActiveDocument: true,
            hasLanguageServer: false,
            definitionProviderAdvertised: true)
        XCTAssertFalse(a.isEnabled)
        XCTAssertEqual(a.reason, .noLanguageServer)
    }

    func test_availability_definitionUnsupported_disabled() {
        let a = LSPDefinitionPreview.availability(
            hasActiveDocument: true,
            hasLanguageServer: true,
            definitionProviderAdvertised: false)
        XCTAssertFalse(a.isEnabled)
        XCTAssertEqual(a.reason, .definitionUnsupported)
    }

    /// Gate precedence: noActiveDocument wins even when other prereqs
    /// also fail (so the menu shows the most fundamental reason first).
    func test_availability_precedence_noDocBeatsNoServer() {
        let a = LSPDefinitionPreview.availability(
            hasActiveDocument: false,
            hasLanguageServer: false,
            definitionProviderAdvertised: false)
        XCTAssertEqual(a.reason, .noActiveDocument)
    }
}
