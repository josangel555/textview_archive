import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Footer toggles for the two per-keystroke editor assists (spell-check +
/// autocomplete) — the txt typing-cost relief valves. Pins: defaults ON,
/// disabling spell publishes/clears the squiggle layer (incl. instantly on
/// toggle-off), disabling autocomplete short-circuits completion requests to
/// empty (no buffer scan), and the toggle VERBS flip the state through the
/// real dispatch.
@MainActor
final class EditorAssistToggleTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        // TSK-1567: the assist toggles now persist through the harness's OWN
        // hermetic defaults suite (EditorCoordinator.assistDefaults ←
        // preferences.defaults), never `UserDefaults.standard`. So each test
        // starts at defaults without touching (or racing on) the global store —
        // which was the `--parallel` flake this fixed.
        harness = HeadlessHarness(label: "EditorAssistToggleTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_defaults_areOn() {
        XCTAssertTrue(harness.model.editor.spellCheckEnabled)
        XCTAssertTrue(harness.model.editor.autocompleteEnabled)
    }

    func test_spellDisabled_skipsPass_andClearsInstantlyOnToggleOff() throws {
        let url = try harness.writeFile("prose.txt", "qzxqzx wrold helllo")
        harness.model.open(url: url)
        let id = harness.model.tabs.selected!.id

        // Enabled: the pass flags misspellings (host NSSpellChecker).
        harness.model.editor.runEditorSpellPass(
            text: "qzxqzx wrold helllo", url: url, forTabID: id)
        let flagged = harness.model.editor.pendingEditorDiagnostics[id] ?? []
        XCTAssertFalse(flagged.isEmpty, "sanity: the enabled pass flags misspellings")

        // Toggle OFF: existing squiggles clear INSTANTLY (no new pass needed).
        harness.model.editor.spellCheckEnabled = false
        XCTAssertEqual(harness.model.editor.pendingEditorDiagnostics[id] ?? [], [],
                       "toggle-off must clear the spell layer immediately")

        // And a subsequent pass publishes nothing.
        harness.model.editor.runEditorSpellPass(
            text: "qzxqzx wrold helllo", url: url, forTabID: id)
        XCTAssertEqual(harness.model.editor.pendingEditorDiagnostics[id] ?? [], [],
                       "disabled pass must not produce squiggles")
    }

    func test_autocompleteDisabled_returnsEmpty_noBufferScan() async throws {
        let url = try harness.writeFile("words.txt", "alpha alignment albatross\nal")
        harness.model.open(url: url)
        let id = harness.model.tabs.selected!.id
        _ = harness.model.editorBuffer(forTabID: id)   // materialize the buffer

        let request = CMHoverRequest(line: 1, character: 2, replyId: "t")

        // Enabled: the in-file fallback serves buffer words for the "al" prefix.
        let on = await harness.model.handleCompletionRequest(tabID: id, fileURL: url, request: request)
        XCTAssertFalse(on.isEmpty, "sanity: in-file completions serve the al- prefix")

        harness.model.editor.autocompleteEnabled = false
        let off = await harness.model.handleCompletionRequest(tabID: id, fileURL: url, request: request)
        XCTAssertTrue(off.isEmpty, "disabled autocomplete must short-circuit to empty")
    }

    func test_toggleVerbs_flipState_throughRealDispatch() {
        XCTAssertTrue(ScriptVerb.apply(verb: "toggle-spell-check", to: harness.model, sessions: harness.sessions))
        XCTAssertFalse(harness.model.editor.spellCheckEnabled)
        XCTAssertTrue(ScriptVerb.apply(verb: "toggle-autocomplete", to: harness.model, sessions: harness.sessions))
        XCTAssertFalse(harness.model.editor.autocompleteEnabled)
        _ = ScriptVerb.apply(verb: "toggle-spell-check", to: harness.model, sessions: harness.sessions)
        XCTAssertTrue(harness.model.editor.spellCheckEnabled)
    }

    /// TSK-1567 regression guard: two independent models (each its own hermetic
    /// defaults suite) must NOT share assist-toggle state. Before the fix both
    /// wrote `UserDefaults.standard`, so a toggle in one parallel test leaked into
    /// another — the `--parallel` flake. This is the teeth: it FAILS if the
    /// coordinator ever reverts to the global store.
    func test_toggleState_isIsolatedPerModel() {
        let a = HeadlessHarness(label: "AssistIsolationA")
        defer { a.cleanup() }
        let b = HeadlessHarness(label: "AssistIsolationB")
        defer { b.cleanup() }
        a.model.editor.autocompleteEnabled = false
        a.model.editor.spellCheckEnabled = false
        XCTAssertTrue(b.model.editor.autocompleteEnabled,
            "toggling model A's autocomplete must not leak into model B (separate suites)")
        XCTAssertTrue(b.model.editor.spellCheckEnabled,
            "toggling model A's spell-check must not leak into model B")
        // And A actually flipped (the write landed in A's own suite).
        XCTAssertFalse(a.model.editor.autocompleteEnabled)
        XCTAssertFalse(a.model.editor.spellCheckEnabled)
    }
}
