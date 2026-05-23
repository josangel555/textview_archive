import XCTest
import Foundation

/// VM-only E2E coverage for the CM6 editor flow.
///
/// **Do not run on host.** These tests boot the live `.app` and drive
/// the running process via script verbs (`editor-set-mode`,
/// `editor-set-text`, `editor-save`). The harness skips automatically
/// when `dist/TextView.app` isn't built — but per CLAUDE.md they
/// belong on the UTM macOS15 VM, not on the developer machine.
///
/// The CM6 webview itself isn't reachable from XCUITest, so we drive
/// the Swift-side state machine that backs it (the same surface
/// `EditorFlowIntegrationTests.swift` covers headless) and assert
/// against the disk + the dump's model snapshot.
///
/// Each test method bundles N scenarios so the launch cost amortizes.
@MainActor
final class EditorMultiScenarioTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "EditorFlow" }
    override class var defaultScenarioTimeout: TimeInterval { 25 }

    /// Build a tmp file with known contents that the script will then
    /// open in `.editor` mode and rewrite.
    private func makeEditableFile(_ name: String, contents: String) throws -> URL {
        let dir = try harness.makeDir("editor")
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func diskContents(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Round-trip via script verbs

    /// Bundle the basic edit-and-save flow across a handful of payloads
    /// so a single launch covers append / delete / replace / unicode.
    func test_editor_writeRoundTrips_acrossPayloads() throws {
        let appendURL  = try makeEditableFile("append.txt", contents: "hello")
        let deleteURL  = try makeEditableFile("delete.txt", contents: "hello world")
        let replaceURL = try makeEditableFile("replace.txt", contents: "old contents here")
        let utf8URL    = try makeEditableFile("utf8.txt", contents: "")

        try runScenarios([
            Scenario(
                name: "append-chars-writes-to-disk",
                argFile: appendURL,
                script: """
                    editor-set-mode editor
                    editor-set-text hello world
                    editor-save
                    """
            ) { [self] dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                XCTAssertEqual(diskContents(at: appendURL), "hello world",
                               file: file, line: line)
            },

            Scenario(
                name: "delete-chars-shortens-file",
                argFile: deleteURL,
                script: """
                    editor-set-mode editor
                    editor-set-text hello
                    editor-save
                    """
            ) { [self] dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                XCTAssertEqual(diskContents(at: deleteURL), "hello",
                               file: file, line: line)
            },

            Scenario(
                name: "replace-whole-content-exact-match",
                argFile: replaceURL,
                script: """
                    editor-set-mode editor
                    editor-set-text totally different
                    editor-save
                    """
            ) { [self] dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                XCTAssertEqual(diskContents(at: replaceURL), "totally different",
                               file: file, line: line)
            },

            // The script-verb tokenizer splits on the first space and
            // passes the remainder verbatim, so multibyte payloads
            // round-trip without escaping.
            Scenario(
                name: "utf8-emoji-round-trips",
                argFile: utf8URL,
                script: """
                    editor-set-mode editor
                    editor-set-text héllo 🌟 — café
                    editor-save
                    """
            ) { [self] dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                XCTAssertEqual(diskContents(at: utf8URL), "héllo 🌟 — café",
                               file: file, line: line)
            },
        ])
    }

    /// Empty-document save: setting the buffer to "" should write a
    /// zero-byte file. The verb passes the arg verbatim so an empty
    /// arg means empty buffer.
    func test_editor_emptyDocument_writesZeroBytes() throws {
        let url = try makeEditableFile("empty.txt", contents: "non-empty")
        try runScenarios([
            Scenario(
                name: "empty-document-writes-zero-bytes",
                argFile: url,
                script: """
                    editor-set-mode editor
                    editor-set-text
                    editor-save
                    """
            ) { [self] dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                XCTAssertEqual(diskContents(at: url), "",
                               file: file, line: line)
                let bytes = (try? Data(contentsOf: url))?.count ?? -1
                XCTAssertEqual(bytes, 0, file: file, line: line)
            },
        ])
    }

    /// Multi-cycle: edit → save → edit again → save. The latest set
    /// must be what's on disk.
    func test_editor_multiSaveCycle_persistsLatest() throws {
        let url = try makeEditableFile("cycle.txt", contents: "v0")
        try runScenarios([
            Scenario(
                name: "edit-save-edit-save-latest-wins",
                argFile: url,
                script: """
                    editor-set-mode editor
                    editor-set-text v1
                    editor-save
                    editor-set-text v2 final
                    editor-save
                    """
            ) { [self] dumps, file, line in
                XCTAssertEqual(dumps.count, 5, file: file, line: line)
                XCTAssertEqual(diskContents(at: url), "v2 final",
                               file: file, line: line)
            },
        ])
    }
}
