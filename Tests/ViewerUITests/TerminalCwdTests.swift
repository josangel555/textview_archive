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

    // TSK-914: explicit-isDirectory variant for sidebar nodes (don't trust
    // URL.hasDirectoryPath — sidebar folder URLs usually lack the trailing slash).

    func test_explicitFolder_resolvesToItself_evenWithoutTrailingSlash() {
        let dir = URL(fileURLWithPath: "/Users/me/proj/src")
        XCTAssertFalse(dir.hasDirectoryPath, "precondition: no trailing-slash marker")
        XCTAssertEqual(
            TerminalCwd.workingDirectory(for: dir, isDirectory: true)?.path,
            "/Users/me/proj/src")
    }

    func test_explicitFile_resolvesToContainingFolder() {
        let file = URL(fileURLWithPath: "/Users/me/proj/src/main.swift")
        XCTAssertEqual(
            TerminalCwd.workingDirectory(for: file, isDirectory: false)?.path,
            "/Users/me/proj/src")
    }

    func test_explicit_nonFileURL_returnsNil() {
        let web = URL(string: "https://example.com")!
        XCTAssertNil(TerminalCwd.workingDirectory(for: web, isDirectory: true))
    }

    // TSK-1178 — the spawn-dir fallback that makes Open-in-PWD land in the tab's dir.

    func test_effectiveSpawnDirectory_explicitWins() {
        let explicit = URL(fileURLWithPath: "/a/explicit")
        let initial = URL(fileURLWithPath: "/b/initial")
        XCTAssertEqual(TerminalCwd.effectiveSpawnDirectory(explicit: explicit, initial: initial),
                       explicit)
    }

    func test_effectiveSpawnDirectory_fallsBackToInitial() {
        let initial = URL(fileURLWithPath: "/b/initial")
        XCTAssertEqual(TerminalCwd.effectiveSpawnDirectory(explicit: nil, initial: initial),
                       initial, "start() with no explicit cwd uses the tab's initial cwd")
    }

    func test_effectiveSpawnDirectory_bothNil() {
        XCTAssertNil(TerminalCwd.effectiveSpawnDirectory(explicit: nil, initial: nil))
    }
}
