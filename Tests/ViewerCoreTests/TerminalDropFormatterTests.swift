import XCTest
@testable import ViewerCore

/// TSK-920 — dropping a file on the terminal pastes its (shell-quoted) path.
final class TerminalDropFormatterTests: XCTestCase {

    func test_simplePath_bare_withTrailingSpace() {
        XCTAssertEqual(
            TerminalDropFormatter.shellPaste(for: [URL(fileURLWithPath: "/usr/bin/swift")]),
            "/usr/bin/swift ")
    }

    func test_pathWithSpace_isSingleQuoted() {
        XCTAssertEqual(
            TerminalDropFormatter.shellPaste(for: [URL(fileURLWithPath: "/Users/me/My Docs/a.txt")]),
            "'/Users/me/My Docs/a.txt' ")
    }

    func test_pathWithSingleQuote_isEscaped() {
        XCTAssertEqual(
            TerminalDropFormatter.shellPaste(for: [URL(fileURLWithPath: "/tmp/it's.txt")]),
            "'/tmp/it'\\''s.txt' ")
    }

    func test_multiplePaths_spaceJoined() {
        let urls = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b c/d.txt")]
        XCTAssertEqual(
            TerminalDropFormatter.shellPaste(for: urls),
            "/a '/b c/d.txt' ")
    }

    func test_nonFileURL_isFiltered() {
        XCTAssertEqual(
            TerminalDropFormatter.shellPaste(for: [URL(string: "https://example.com")!]),
            "")
    }

    func test_empty_isEmpty() {
        XCTAssertEqual(TerminalDropFormatter.shellPaste(for: []), "")
    }

    func test_pathWithShellSpecials_isQuoted() {
        // `$`, `;`, `&`, `(`, `)`, `*` etc. must be neutralised by quoting.
        XCTAssertEqual(
            TerminalDropFormatter.shellPaste(for: [URL(fileURLWithPath: "/tmp/a;b $c & (d).txt")]),
            "'/tmp/a;b $c & (d).txt' ")
    }
}
