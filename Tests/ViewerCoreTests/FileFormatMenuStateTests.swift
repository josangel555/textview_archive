import XCTest
@testable import ViewerCore

/// TSK-1480 — host tests for the Convert-submenu current-value resolution: which
/// encoding / line-ending choice gets the check-mark and the Indent submenu's
/// "Current:" header, so the user isn't converting blind. The AppKit application
/// (setting NSMenuItem.state / header title) is thin glue over this.
final class FileFormatMenuStateTests: XCTestCase {

    // The menus' offered choices (mirrors AppDelegate.encoding/lineEndingChoices).
    private let encodings: [String.Encoding] = [.utf8, .utf16, .windowsCP1252, .isoLatin1]
    private let lineEndings: [LineEnding] = [.lf, .crlf, .cr]

    func test_checksTheCurrentEncodingAndLineEnding() {
        let r = FileFormatMenuState.resolve(
            encoding: .utf16, lineEnding: .crlf, indent: .spaces(width: 4),
            encodingChoices: encodings, lineEndingChoices: lineEndings)
        XCTAssertEqual(r.checkedEncodingIndex, 1, "UTF-16 is the 2nd encoding choice")
        XCTAssertEqual(r.checkedLineEndingIndex, 1, "CRLF is the 2nd line-ending choice")
        XCTAssertEqual(r.indentHeader, "Current: Spaces:4")
    }

    func test_utf8LfTabs() {
        let r = FileFormatMenuState.resolve(
            encoding: .utf8, lineEnding: .lf, indent: .tabs,
            encodingChoices: encodings, lineEndingChoices: lineEndings)
        XCTAssertEqual(r.checkedEncodingIndex, 0)
        XCTAssertEqual(r.checkedLineEndingIndex, 0)
        XCTAssertEqual(r.indentHeader, "Current: Tabs")
    }

    func test_encodingNotOffered_checksNothing() {
        // ASCII isn't one of the offered choices → no check-mark (rather than a
        // wrong one).
        let r = FileFormatMenuState.resolve(
            encoding: .ascii, lineEnding: .lf, indent: .none,
            encodingChoices: encodings, lineEndingChoices: lineEndings)
        XCTAssertNil(r.checkedEncodingIndex)
    }

    func test_noLineEndingYet_checksNothing() {
        // A single-line / empty file has no current EOL convention to mark.
        let none = FileFormatMenuState.resolve(
            encoding: .utf8, lineEnding: .none, indent: .none,
            encodingChoices: encodings, lineEndingChoices: lineEndings)
        XCTAssertNil(none.checkedLineEndingIndex)
        // Mixed endings aren't one of the single-convention choices → nothing.
        let mixed = FileFormatMenuState.resolve(
            encoding: .utf8, lineEnding: .mixed, indent: .none,
            encodingChoices: encodings, lineEndingChoices: lineEndings)
        XCTAssertNil(mixed.checkedLineEndingIndex)
    }

    func test_indentHeader_alwaysPresent_evenWhenIndeterminate() {
        XCTAssertEqual(FileFormatMenuState.indentHeaderLabel(.none), "Current: —")
        XCTAssertEqual(FileFormatMenuState.indentHeaderLabel(.tabs), "Current: Tabs")
        XCTAssertEqual(FileFormatMenuState.indentHeaderLabel(.spaces(width: 2)), "Current: Spaces:2")
    }
}
