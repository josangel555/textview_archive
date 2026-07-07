import XCTest
@testable import ViewerCore

/// TSK-1500 — recreate-a-deleted-file from Local History (O_EXCL, fenced).
final class FileResurrectionTests: XCTestCase {

    private var ws: URL!

    override func setUpWithError() throws {
        ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-resurrect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: ws)
    }

    func test_recreates_deletedFile_withExactContent() throws {
        let target = ws.appendingPathComponent("notes.md").path
        let content = "# Recovered\n\nunicode: 😀 · ümlaut\n"
        let outcome = FileResurrection.recreate(
            content: content, atPath: target, workspaceRoot: ws.path)
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), content,
                       "content round-trips exactly")
    }

    func test_recreates_parentDirectories() throws {
        // The file went down with its folder — intermediate dirs come back.
        let target = ws.appendingPathComponent("a/b/c/deep.txt").path
        let outcome = FileResurrection.recreate(
            content: "deep", atPath: target, workspaceRoot: ws.path)
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "deep")
    }

    func test_refuses_whenSomethingExistsAtThePath() throws {
        // A file re-appeared (user re-created it / sync restored it): the
        // O_EXCL guard refuses and the EXISTING content is untouched.
        let target = ws.appendingPathComponent("live.txt")
        try "precious live content".write(to: target, atomically: true, encoding: .utf8)
        let outcome = FileResurrection.recreate(
            content: "stale history bytes", atPath: target.path, workspaceRoot: ws.path)
        XCTAssertEqual(outcome, .refusedExists)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8),
                       "precious live content", "existing file must be untouched")
    }

    func test_refuses_outsideTheWorkspace() {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-outside-\(UUID().uuidString).txt").path
        let outcome = FileResurrection.recreate(
            content: "x", atPath: outside, workspaceRoot: ws.path)
        XCTAssertEqual(outcome, .refusedOutsideWorkspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside),
                       "nothing written outside the fence")
    }

    func test_refuses_prefixSiblingTrick() {
        // "/ws-evil/f" must NOT pass as inside "/ws" (prefix-with-separator).
        let sibling = ws.path + "-evil"
        defer { try? FileManager.default.removeItem(atPath: sibling) }
        let outcome = FileResurrection.recreate(
            content: "x", atPath: sibling + "/f.txt", workspaceRoot: ws.path)
        XCTAssertEqual(outcome, .refusedOutsideWorkspace)
    }

    func test_dotDotTraversal_isStandardizedAndFenced() {
        // ws/sub/../../escape.txt standardizes OUTSIDE the workspace → refuse.
        let sneaky = ws.appendingPathComponent("sub/../../escape-\(UUID().uuidString).txt").path
        let outcome = FileResurrection.recreate(
            content: "x", atPath: sneaky, workspaceRoot: ws.path)
        XCTAssertEqual(outcome, .refusedOutsideWorkspace)
    }

    func test_emptyContent_createsEmptyFile() throws {
        let target = ws.appendingPathComponent("empty.txt").path
        XCTAssertEqual(
            FileResurrection.recreate(content: "", atPath: target, workspaceRoot: ws.path),
            .created)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "")
    }

    func test_workspaceRootItself_isRefused() {
        XCTAssertEqual(
            FileResurrection.recreate(content: "x", atPath: ws.path, workspaceRoot: ws.path),
            .refusedExists, "the root is a directory — never a resurrection target")
    }
}
