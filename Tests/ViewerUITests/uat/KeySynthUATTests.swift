import XCTest
import Foundation

/// VM key-synthesis (T4) smoke — TSK-818.
///
/// The keyboard sibling of the `ui-click` interaction layer: this suite spawns
/// the real `dist/TextView.app`, opens a file in the CM6 editor, posts GENUINE
/// `keyDown`/`keyUp` CGEvents (`ui-type` / `ui-key`) into the focused editor
/// field, then asserts the live `DocumentModel`'s editor buffer received the
/// input (`model.editorText`). This is the force-multiplier that unblocks VM
/// validation of the whole CM6/AppKit key-routing bug tail (894/896/921/730/728):
/// before this, no T4 test could inject a real keystroke into the spawned app.
///
/// ## Why T4 (and VM-only)
/// CGEvent keyboard posting needs a real WindowServer + a GUI login session (a
/// fork/exec'd app on macOS 14+ can't self-activate; an occluded window never
/// becomes key, and a non-key field swallows synthesized input). The
/// `viaOpen: true` LaunchServices route is the only path that grants the
/// spawned app real activation, and that only works inside the VM GUI lane
/// (`MDV_VM_GUI_SESSION=1`). The host headless gate self-skips this whole tier
/// (`LiveAppTestCase` + `isAppBuilt` false), so the keycode/modifier/characters
/// MAPPING — the regression-prone half — is pinned host-side by
/// `UIKeySpecTests` (ViewerCoreTests) + `UIKeySynthTests` (ViewerUITests); this
/// suite proves the end-to-end injection→model round-trip on the VM.
///
/// TIER-JUSTIFY: T4 — the observable is a REAL keyDown CGEvent traversing the
/// genuine WindowServer → key-window → AppKit responder → CM6 WKWebView
/// first-responder → JS `insertText` → debounced bridge → `DocumentModel`
/// buffer pipeline. None of that exists in a bare in-process `(model,
/// sessions)` pair: the headless lane can only call `updateEditorText` directly
/// (the bridge's OUTPUT), never exercise the input-routing path the bug tail
/// lives on. Self-skips off the VM GUI lane.
@MainActor
final class KeySynthUATTests: LiveAppTestCase {

    private var harness: LaunchHarness!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { harness = LaunchHarness(label: "KeySynthUAT") }
    }

    override func tearDown() async throws {
        await MainActor.run { harness?.cleanup(); harness = nil }
        try await super.tearDown()
    }

    private func skipUnlessBuilt() throws {
        guard harness.isAppBuilt else {
            throw XCTSkip("VM GUI lane only (MDV_VM_GUI_SESSION=1) + built dist/TextView.app")
        }
    }

    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        (dump["model"] as? [String: Any])?[key] as? String ?? ""
    }

    private func modelBool(_ dump: [String: Any], _ key: String) -> Bool {
        (dump["model"] as? [String: Any])?[key] as? Bool ?? false
    }

    /// KEY-01 — type a literal string into the editor; the model's buffer
    /// receives it. Opens an empty file in editor mode, posts `ui-type Hello`,
    /// and asserts the document model's `editorText` ends up containing the
    /// injected text.
    func test_KEY_01_typeStringReachesEditorModel() throws {
        try skipUnlessBuilt()
        let file = try harness.writeFile("note.md", "")
        // editor mode flips the active tab to CM6, but `editor-set-mode editor`
        // alone does NOT give the CM6 WKWebView keyboard first-responder (the
        // KEY_01 root cause, TSK-1020) — synthesized keydowns then insert into
        // nothing. `editor-focus` bumps `editorFocusRequest`, which the CM6
        // representable consumes (`makeFirstResponder(webView)` + JS `.focus()`),
        // so the following `ui-type` posts real keydown/keyup into the focused
        // CM6 field. Delays let WindowServer deliver the focus + keys and the
        // CM6 bridge debounce-flush the change back to the model before the dump.
        let dumps = try harness.runScript(
            """
            delay 1.0
            editor-set-mode editor
            delay 0.5
            editor-focus
            delay 0.8
            ui-type Hello
            delay 1.0
            """,
            with: file, timeout: 30, viaOpen: true)

        XCTAssertFalse(dumps.isEmpty, "no step dumps — app may not have launched")
        guard let last = dumps.last else { return }
        XCTAssertTrue(modelString(last, "editorText").contains("Hello"),
                      "injected keystrokes did not reach the editor model — got '\(modelString(last, "editorText"))'; keyTrace=\((last["uiKeyTrace"] as? String) ?? "<none>")")
        XCTAssertTrue(modelBool(last, "editorIsDirty"),
                      "typing into the editor should mark the buffer dirty")
    }

    /// KEY-02 — a chord (⌘A select-all then a navigation key) posts without a
    /// parse error and keeps the app alive (the chord-routing smoke; the
    /// per-chord keycode/modifier mapping is host-pinned). Asserts the run
    /// produced a key trace showing events were posted.
    func test_KEY_02_chordPostsAndAppSurvives() throws {
        try skipUnlessBuilt()
        let file = try harness.writeFile("note.md", "seed line\n")
        let dumps = try harness.runScript(
            """
            delay 1.0
            editor-set-mode editor
            delay 0.8
            ui-key cmd+a
            delay 0.3
            ui-key right
            delay 0.5
            """,
            with: file, timeout: 30, viaOpen: true)

        XCTAssertFalse(dumps.isEmpty, "no step dumps — app may not have launched")
        guard let last = dumps.last else { return }
        // The model is still in a live, loaded state (the chord didn't crash or
        // derail the app), and the key layer recorded that it posted events.
        XCTAssertEqual(modelString(last, "currentStateKind"), "loaded",
                       "chord injection derailed the app state")
        let trace = (last["uiKeyTrace"] as? String) ?? ""
        XCTAssertTrue(trace.contains("posted="),
                      "no ui-key trace — events may not have posted: '\(trace)'")
    }
}
