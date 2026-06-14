import XCTest
@testable import ViewerUI

/// Host tests for the "Open Terminal Here" cwd resolver (TSK-769). Pure URL
/// logic — the terminal spawn is the VM tail, but the directory CHOICE
/// (file → its folder, folder → itself, non-file → nil) is pinned here.
final class TerminalCwdTests: XCTestCase {

    func test_file_resolvesToContainingFolder() {
        let url = URL(fileURLWithPath: "/Users/me/proj/src/main.swift")
        XCTAssertEqual(
            TerminalCwd.workingDirectory(forFocusedFile: url)?.path,
            "/Users/me/proj/src")
    }

    func test_directoryURL_resolvesToItself() {
        let dir = URL(fileURLWithPath: "/Users/me/proj", isDirectory: true)
        XCTAssertEqual(
            TerminalCwd.workingDirectory(forFocusedFile: dir)?.path,
            "/Users/me/proj")
    }

    func test_nil_returnsNil() {
        XCTAssertNil(TerminalCwd.workingDirectory(forFocusedFile: nil))
    }

    func test_nonFileURL_returnsNil() {
        let web = URL(string: "https://example.com/page.html")!
        XCTAssertNil(TerminalCwd.workingDirectory(forFocusedFile: web),
            "a non-file URL has no folder to anchor a terminal to")
    }
}
