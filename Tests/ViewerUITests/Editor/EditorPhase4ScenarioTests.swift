import XCTest
import Foundation

/// VM-only E2E coverage for Phase 4 (v2) of the CM6 editor.
///
/// **Do not run on host.** Per CLAUDE.md these scenarios boot the
/// live `.app` and drive it via script verbs. The harness skips
/// automatically when `dist/TextView.app` isn't built; for the dev
/// machine they're rsync'd to the macOS15 VM and exercised by
/// `bash scripts/vm-smoke.sh` / `ssh macOS15 'cd markdown_viewer &&
/// swift test'`.
///
/// What Phase 4 verifies end-to-end (since the JS bridge isn't
/// reachable from XCUITest, every assertion is on the Swift-side
/// state machine that backs the CM6 webview):
///
///   1. v2 incrementalChange round-trips with the same end-state as
///      v1 setText would have produced — large-doc edits don't lose
///      bytes when the JS emitter accumulates a multi-edit batch.
///   2. Big-file cap kicks in at 50 MB+ — the editor should refuse
///      to materialise a buffer for a 60 MB file (would otherwise
///      blow the WebContent JS heap).
///   3. UTF-8 / multibyte payloads survive multi-cycle edits via the
///      v2 path.
///
/// Each method bundles N scenarios so a single app launch amortises.
@MainActor
final class EditorPhase4ScenarioTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "EditorPhase4" }
    override class var defaultScenarioTimeout: TimeInterval { 30 }

    private func makeEditableFile(_ name: String, contents: String) throws -> URL {
        let dir = try harness.makeDir("editor-phase4")
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func diskContents(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - v2 batch edits survive multi-step transcript

    /// Drive a long-ish edit transcript through the same script verb
    /// the editor uses for typed input. Whether the JS emitter ships
    /// as v1 `change` or v2 `incrementalChange`, the Swift-side
    /// `EditorBuffer` must reach the same final text. Pins the
    /// regression where the v2 accumulator could lose a slice if the
    /// debounce window fired between batches.
    func test_v2_multiEditTranscript_endsAtCanonicalText() throws {
        let url = try makeEditableFile("transcript.txt", contents: "alpha")
        try runScenarios([
            Scenario(
                name: "type-replace-append-cycle",
                argFile: url,
                script: """
                    editor-set-mode editor
                    editor-set-text alpha beta
                    editor-set-text alpha beta gamma
                    editor-set-text rewritten contents here
                    editor-set-text alpha
                    editor-save
                    """
            ) { [self] dumps, file, line in
                XCTAssertEqual(dumps.count, 6, file: file, line: line)
                XCTAssertEqual(diskContents(at: url), "alpha",
                               file: file, line: line)
            },
        ])
    }

    /// Empty in-between states must round-trip cleanly through the
    /// v2 path — pure-delete batches are the easiest edge case to lose
    /// in an incremental encoder.
    func test_v2_emptyIntermediateStateThenRewrite() throws {
        let url = try makeEditableFile("clear-rewrite.txt", contents: "first")
        try runScenarios([
            Scenario(
                name: "clear-then-rewrite",
                argFile: url,
                script: """
                    editor-set-mode editor
                    editor-set-text
                    editor-set-text totally fresh
                    editor-save
                    """
            ) { [self] dumps, file, line in
                XCTAssertEqual(dumps.count, 4, file: file, line: line)
                XCTAssertEqual(diskContents(at: url), "totally fresh",
                               file: file, line: line)
            },
        ])
    }

    // MARK: - UTF-8 / surrogate-pair payloads (v2 UTF-16 indexing)

    /// Multibyte payloads cross the v2 `incrementalChange` boundary
    /// in UTF-16-indexed batches. A regression in the applier's
    /// UTF-16 slicing would clip surrogates and emit replacement
    /// characters — disk content would not equal the typed text.
    func test_v2_surrogatePairsRoundTrip() throws {
        let url = try makeEditableFile("emoji.txt", contents: "")
        try runScenarios([
            Scenario(
                name: "emoji-burst-saves-intact",
                argFile: url,
                script: """
                    editor-set-mode editor
                    editor-set-text 👨‍💻 héllo 🌟 — café 😀
                    editor-save
                    """
            ) { [self] dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                XCTAssertEqual(diskContents(at: url),
                               "👨‍💻 héllo 🌟 — café 😀",
                               file: file, line: line)
            },
        ])
    }

    // MARK: - Big-file cap (Phase 4 deliverable)

    /// A 60 MB file is past the editor cap (50 MB). Opening it in
    /// editor mode must surface the fallback UI rather than spawning
    /// a WebContent process with a 60 MB JS string. We can't see the
    /// SwiftUI fallback view from a dump directly, but the dump's
    /// `model.currentViewMode` should NOT report `.editor` for this
    /// tab (the activation gate refuses the upgrade).
    ///
    /// Skipped automatically on CI runs without 60 MB of free temp
    /// space — the failure shows up as a `Scenario.skip` reason.
    func test_v2_oversizedFile_doesNotEnterEditorMode() throws {
        let dir = try harness.makeDir("big-file")
        let url = dir.appendingPathComponent("oversized.txt")
        // Build a 60 MB doc by repeating a known line — keeps the
        // contents grep-able if the test fails and we want to look at
        // what got read.
        let unit = "abcdefghij\n" // 11 bytes
        let target = 60 * 1024 * 1024
        let reps = target / unit.utf8.count
        let bigPayload = String(repeating: unit, count: reps)
        try bigPayload.write(to: url, atomically: true, encoding: .utf8)

        try runScenarios([
            Scenario(
                name: "60mb-file-stays-out-of-editor-mode",
                argFile: url,
                script: """
                    editor-set-mode editor
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 1, file: file, line: line)
                // The dump exposes model.currentViewMode. If the gate
                // worked, the mode stays at its pre-existing value
                // (typically `.source` for a plain text file) — NOT
                // `.editor`. We assert "not editor" instead of "is
                // source" so the test isn't brittle to defaults.
                let model = dumps[0]["model"] as? [String: Any]
                let mode = model?["currentViewMode"] as? String ?? ""
                XCTAssertNotEqual(
                    mode, "editor",
                    "60 MB file should be gated out of editor mode (got \(mode))",
                    file: file, line: line)
            },
        ])
    }
}
