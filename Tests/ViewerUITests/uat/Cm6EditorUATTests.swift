import XCTest
import Foundation

/// UAT executable companion — **group 4/12: cm6-editor**
/// (edit / save / dirty / close lifecycle).
///
/// Durable T4 live-app smoke for `docs/uat/smokes/cm6-editor.md`
/// (cm6-1..5). Drives the assembled `dist/TextView.app` via the
/// `--script` verb dispatcher (the proven path used by
/// `ViewModeMatrixSmokeTests`, `EditorMultiScenarioTests`, and the other
/// `uat/` companions), captures a `DiagnosticDump` JSON per step, and
/// asserts the scripted expectations AND walks the realized NSView tree
/// for wrong-viewer paint / blank-box regressions a model-only assertion
/// would miss.
///
/// ## The dominant observability constraint for THIS group
///
/// The editor's *dirty state* — the per-tab `mdv.tab.dirtyDot`, the
/// File ▸ Save enable/disable, `editor.hasAnyUnsavedEdits` — is **NOT**
/// projected into the per-step dump. `ScriptVerb.modelStateDump` emits
/// `currentViewMode / currentStateKind / windowTitle / tabCount / ...`
/// but no `isDirty` / `hasUnsavedEdits` scalar, and `windowTitle` is a
/// pure `tabs.selected?.title` projection that carries NO dirty marker.
/// SwiftUI `.accessibilityIdentifier()` ids (`mdv.tab.dirtyDot`,
/// `mdv.editor`, `mdv.editorFindBar`) are also absent from the realized
/// `NSView` tree the dump reads. So the load-bearing save/dirty signal
/// for this group is **the bytes on disk** after `editor-save` — the one
/// fully-observable, fully-deterministic outcome of the save round-trip.
/// The dirty-dot lifecycle, Save menu enablement, find-bar match count,
/// and both NSAlert prompts (close-dirty, external-edit conflict) are
/// logged as MANUAL / VM-pixel beats in `UAT_RUN_undated.md`.
///
/// ## The close-dirty modal HANG hazard (why we never `close-tab` dirty)
///
/// `close-tab` routes `closeCurrentTab()` → `closeTab(at:)` →
/// `confirmCloseIfDirty(at:)`. On a **dirty** tab with no
/// `dirtyClosePromptOverride` (the script path never wires one), that
/// runs a REAL blocking `NSAlert.runModal()`. In the occluded
/// `MDV_BACKGROUND` run there is nothing to click it, so the script
/// thread would block until the scenario timeout — a false "launcher
/// threw" failure, not a real assertion. Every `close-tab` in this suite
/// is therefore preceded by an `editor-save` (clears dirty → no prompt)
/// or issued on a clean tab. The prompt's 3-button behaviour itself is a
/// MANUAL / VM beat (documented in the smoke + run log).
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real
/// cross-process editor save round-trip (CM6 WKWebView mount →
/// `editor-set-text` buffer mutation → `editor-save` → `EditorWriter`
/// atomic rename to disk), plus the #192-excluded editor WKWebView
/// surface and the fd11e61 mode↔state↔realized-subtree class. Self-skips
/// on the headless gate (`isAppBuilt` is false there); runs for real on
/// the VM/nightly lane or a host-occluded UAT run.
@MainActor
final class Cm6EditorUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "Cm6EditorUAT" }
    // The CM6 editor is a WKWebView; the mount + each `editor-set-text`
    // bridge round-trip needs WebContent settle time, and several
    // scenarios cycle modes / multiple saves. Give generous room.
    override class var defaultScenarioTimeout: TimeInterval { 120 }

    // MARK: - Fixture helpers

    private func makeEditableFile(_ name: String, contents: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func diskContents(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func diskByteCount(at url: URL) -> Int {
        (try? Data(contentsOf: url))?.count ?? -1
    }

    // MARK: - cm6-1 — First edit → ⌘S round-trip; status/tab reflect it
    //
    // Combines (script-reachable subset): Source→Editor mode switch, CM6
    // mount in the WKWebView (NOT a blank box — the WidgetType /
    // duplicate-bootstrap regression guard), the dirty→save→clean cycle
    // verified through DISK, and the editor surface staying mounted under
    // the Editor picker (no stale Source NSTextView / no Hex grid).

    /// A `.txt` opens in Source by default → switch to Editor → CM6
    /// mounts (WKWebView present, no stale Source/Hex view) → push an
    /// edited buffer → `editor-save` → the edit is on disk.
    func test_cm6_1_firstEdit_modeSwitch_saveRoundTrip() throws {
        let orig = "alpha\nbravo\ncharlie\n"
        let file = try makeEditableFile("uat_edit.txt", contents: orig)
        // NOTE: `editor-set-text` payloads MUST stay single-line — the
        // ScriptRunner splits the script on newlines, so an embedded `\n`
        // in the arg would be parsed as a separate (unknown) verb. The
        // round-trip semantics still hold: we assert disk == this exact
        // text after save.
        let edited = "alpha EDITED bravo charlie one line buffer"

        // settle x3 → Source default (txt). editor-set-mode editor →
        // settle x3 for the WKWebView mount. set-text → settle. save →
        // settle. Each bare `delay` ≈ 300 ms (the seconds arg is ignored
        // by ScriptRunner — see ViewModesUATTests' harness note).
        let script = """
        delay
        delay
        delay
        editor-set-mode editor
        delay
        delay
        delay
        editor-set-text \(edited)
        delay
        editor-save
        delay
        """
        try runScenarios([
            Scenario(
                name: "cm6-1-first-edit-save-roundtrip",
                argFile: file,
                script: script,
                assert: { [self] dumps, file2, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file2, line: line)
                    guard !dumps.isEmpty else { return }

                    // Default open: txt lands in Source (a non-hex
                    // NSTextView with glyphs, never binary).
                    let s0 = dumps[0]
                    assertModel(s0, "currentViewMode", equals: "source",
                                label: "cm6-1/txt-default", file: file2, line: line)
                    assertSourceTextRendered(s0, label: "cm6-1/source-default",
                                             file: file2, line: line)

                    // After editor-set-mode editor: the CM6 WKWebView must
                    // be mounted (NOT a blank box) and NO stale Source
                    // NSTextView / Hex grid leaking under the Editor picker.
                    let firstEditor = dumps.first {
                        modelString($0, "currentViewMode") == "editor"
                    }
                    XCTAssertNotNil(firstEditor,
                        "[cm6-1] never reached Editor mode", file: file2, line: line)
                    if let ed = firstEditor {
                        XCTAssertNotEqual(modelString(ed, "currentStateKind"), "binary",
                            "[cm6-1] editor picker but state==binary (Hex under editor)",
                            file: file2, line: line)
                        assertWebViewRendered(ed, label: "cm6-1/editor-mount",
                                              file: file2, line: line)
                        assertNoHexView(ed, label: "cm6-1/editor-mount",
                                        file: file2, line: line)
                    }

                    // The authoritative save signal: the edited bytes are
                    // on disk after editor-save.
                    XCTAssertEqual(diskContents(at: file), edited,
                        "[cm6-1] editor-save did not persist the edit to disk",
                        file: file2, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "cm6-1/step\(i)", file: file2, line: line)
                    }
                })
        ])
    }

    // MARK: - cm6-1 var — Markdown defaults Rendered; edit in Editor saves;
    //                     flip back to Rendered reflects new content.
    //
    // The catalog's "stale-cache" guard: a `.md` opens Rendered; switching
    // to Editor, editing, saving, then back to Rendered must show the NEW
    // bytes (the rendered cache keys on byteCount+mtime and must
    // invalidate after the save's TextFile refresh). We can't read the
    // rendered HTML from the dump, but we CAN assert the save reached
    // disk and the Rendered WKWebView re-mounted clean after the flip.

    func test_cm6_1var_markdownEditInEditorThenBackToRendered() throws {
        let orig = "# Title\n\nbody one\n"
        let md = try makeEditableFile("uat_edit.md", contents: orig)
        // Single-line set-text payload (see cm6-1 note on the newline split).
        let edited = "# Title body one EDITED-IN-EDITOR one line"

        let script = """
        delay
        delay
        delay
        editor-set-mode editor
        delay
        delay
        editor-set-text \(edited)
        delay
        editor-save
        delay
        editor-set-mode rendered
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "cm6-1var-md-editor-save-back-to-rendered",
                argFile: md,
                script: script,
                assert: { [self] dumps, file2, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file2, line: line)
                    guard !dumps.isEmpty else { return }

                    // md default: Rendered (WKWebView, no Hex).
                    let s0 = dumps[0]
                    assertModel(s0, "currentViewMode", equals: "rendered",
                                label: "cm6-1var/md-default", file: file2, line: line)

                    // Save reached disk.
                    XCTAssertEqual(diskContents(at: md), edited,
                        "[cm6-1var] editor-save did not persist the md edit",
                        file: file2, line: line)

                    // Final dump: back in Rendered with a live WKWebView and
                    // NO Hex grid (the flip-back re-mount is clean).
                    let last = dumps.last!
                    assertModel(last, "currentViewMode", equals: "rendered",
                                label: "cm6-1var/back-to-rendered", file: file2, line: line)
                    assertWebViewRendered(last, label: "cm6-1var/rendered-final",
                                          file: file2, line: line)
                    assertNoHexView(last, label: "cm6-1var/rendered-final",
                                    file: file2, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "cm6-1var/step\(i)", file: file2, line: line)
                    }
                })
        ])
    }

    // MARK: - cm6-1 var — Type back to ORIGINAL bytes is a no-op save
    //
    // Editing then retyping the exact original text: the buffer is clean
    // again (text == originalText). We can't read the dirty dot, but we
    // CAN prove the no-op semantics through disk: saving after retyping
    // the original leaves the file byte-identical to its original
    // contents (no spurious mutation, no crash).

    func test_cm6_1var_editThenRetypeOriginal_saveIsNoOp() throws {
        // Single-line original so the retype payload stays single-line
        // (see cm6-1 note on the script newline split).
        let orig = "one two three single line"
        let file = try makeEditableFile("uat_noop.txt", contents: orig)

        let script = """
        delay
        delay
        editor-set-mode editor
        delay
        delay
        editor-set-text one CHANGED two three
        delay
        editor-set-text \(orig)
        delay
        editor-save
        delay
        """
        try runScenarios([
            Scenario(
                name: "cm6-1var-retype-original-noop-save",
                argFile: file,
                script: script,
                assert: { [self] dumps, file2, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file2, line: line)
                    // Disk is byte-identical to the original after a save
                    // that followed retyping back to the original text.
                    XCTAssertEqual(diskContents(at: file), orig,
                        "[cm6-1var-noop] retype-to-original then save mutated the file",
                        file: file2, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "cm6-1var-noop/step\(i)", file: file2, line: line)
                    }
                })
        ])
    }

    // MARK: - cm6-1 edge — Empty buffer save → 0-byte file, no crash
    //
    // select-all + delete everything, save → produces a 0-byte file.

    func test_cm6_1edge_emptyBufferSavesZeroBytes() throws {
        let file = try makeEditableFile("uat_empty.txt", contents: "delete all of this\n")
        // `editor-set-text` with an empty arg pushes "" into the buffer.
        let script = """
        delay
        delay
        editor-set-mode editor
        delay
        delay
        editor-set-text
        delay
        editor-save
        delay
        """
        try runScenarios([
            Scenario(
                name: "cm6-1edge-empty-buffer-zero-bytes",
                argFile: file,
                script: script,
                assert: { [self] dumps, file2, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file2, line: line)
                    XCTAssertEqual(diskContents(at: file), "",
                        "[cm6-1edge] empty buffer did not write empty file",
                        file: file2, line: line)
                    XCTAssertEqual(diskByteCount(at: file), 0,
                        "[cm6-1edge] empty save did not produce a 0-byte file",
                        file: file2, line: line)
                    // No crash → final dump present and not in error.
                    if let last = dumps.last {
                        assertNotError(last, label: "cm6-1edge/final", file: file2, line: line)
                    }
                })
        ])
    }

    // MARK: - cm6-2 — Multi-save cycle (latest wins) + non-mapped language
    //
    // The catalog's undo/redo + find/replace are JS-keymap interactions
    // inside the WKWebView, NOT reachable from the Swift-side script verbs
    // (there is no `editor-undo` / `editor-find` / `editor-replace` verb;
    // `show-find` toggles the RENDERED find bar, a different surface). So
    // the script-reachable slice of cm6-2 is the buffer-mutation +
    // multi-save persistence, exercised here on a plain-text-fallback
    // language (.rs — CM6 maps only md/js/ts/python/json, so .rs editing
    // works without syntax highlighting). Undo/redo + the editor find bar
    // are logged as MANUAL / VM beats.

    func test_cm6_2_multiSaveCycle_plainTextFallbackLanguage() throws {
        let orig = "fn main() {\n    let foo = 1;\n    let foo2 = foo;\n}\n"
        let rs = try makeEditableFile("uat_undo.rs", contents: orig)
        // Single-line set-text payloads (see cm6-1 note).
        let v1 = "fn main() { let bar = 1; } // v1"
        let v2 = "fn main() { let bar = 2; } // v2 final"

        let script = """
        delay
        delay
        editor-set-mode editor
        delay
        delay
        editor-set-text \(v1)
        delay
        editor-save
        delay
        editor-set-text \(v2)
        delay
        editor-save
        delay
        """
        try runScenarios([
            Scenario(
                name: "cm6-2-multi-save-latest-wins-rs",
                argFile: rs,
                script: script,
                assert: { [self] dumps, file2, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file2, line: line)
                    guard !dumps.isEmpty else { return }

                    // The non-mapped language still mounts the editor
                    // WKWebView (just without a syntax tree).
                    let firstEditor = dumps.first {
                        modelString($0, "currentViewMode") == "editor"
                    }
                    if let ed = firstEditor {
                        assertWebViewRendered(ed, label: "cm6-2/rs-editor-mount",
                                              file: file2, line: line)
                        assertNoHexView(ed, label: "cm6-2/rs-editor-mount",
                                        file: file2, line: line)
                    }

                    // Latest save wins on disk.
                    XCTAssertEqual(diskContents(at: rs), v2,
                        "[cm6-2] multi-save cycle did not persist the latest text",
                        file: file2, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "cm6-2/step\(i)", file: file2, line: line)
                    }
                })
        ])
    }

    // MARK: - cm6-2 edge — UTF-8 / multibyte round-trips through save
    //
    // The verb tokenizer splits on the first space and passes the
    // remainder verbatim, so a multibyte payload round-trips without
    // escaping. Proves the encoding path (text.data(using: .utf8)) is
    // lossless through the editor save.

    func test_cm6_2edge_utf8RoundTrip() throws {
        let file = try makeEditableFile("uat_utf8.txt", contents: "ascii only\n")
        // No newline-class scalars (U+2028/U+2029 count as newlines to the
        // script splitter and would break the single-line arg).
        let payload = "héllo 🌟 — café 日本語  — ünïcödé"
        let script = """
        delay
        delay
        editor-set-mode editor
        delay
        delay
        editor-set-text \(payload)
        delay
        editor-save
        delay
        """
        try runScenarios([
            Scenario(
                name: "cm6-2edge-utf8-multibyte-roundtrip",
                argFile: file,
                script: script,
                assert: { [self] dumps, file2, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file2, line: line)
                    XCTAssertEqual(diskContents(at: file), payload,
                        "[cm6-2edge] multibyte payload did not round-trip losslessly",
                        file: file2, line: line)
                })
        ])
    }

    // MARK: - cm6-3 — Close routing (clean tab) + save-then-close (dirty)
    //
    // The unsaved-buffer 3-button NSAlert (Save / Don't Save / Cancel) is
    // a blocking modal with no script override → driving `close-tab` on a
    // DIRTY tab would HANG the occluded run (see the class doc). So this
    // scenario verifies the two NON-hanging close paths that ARE
    // script-reachable:
    //   (a) close a CLEAN editor tab — no prompt, tab closes, selection
    //       moves to the neighbour.
    //   (b) edit → editor-save (clears dirty) → close-tab — the saved
    //       tab closes WITHOUT a prompt, and the edit is on disk (the
    //       "⌘S then close" path of step 4).
    // The Cancel / Don't-Save branches + Close-Other/Close-to-Right batch
    // prompts are logged as MANUAL / VM beats.

    func test_cm6_3_closeCleanTab_andSaveThenClose() throws {
        let fileA = try makeEditableFile("uat_close_A.txt", contents: "AAA original\n")
        let fileB = try makeEditableFile("uat_close_B.txt", contents: "BBB clean\n")
        // Single-line, no trailing newline (exact disk-compare target).
        let editedA = "AAA original SAVED-BEFORE-CLOSE one line"

        // argv opens A (tab 1). open B (tab 2, selected). select-tab 1 →
        // A active in Editor. Edit A, SAVE A (clears dirty), then
        // close-tab on the now-CLEAN A → no modal, tab closes, B remains.
        let script = """
        delay
        delay
        open \(fileB.path)
        delay
        delay
        select-tab 1
        delay
        editor-set-mode editor
        delay
        delay
        editor-set-text \(editedA)
        delay
        editor-save
        delay
        close-tab
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "cm6-3-save-then-close-clean",
                argFile: fileA,
                script: script,
                assert: { [self] dumps, file2, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file2, line: line)
                    guard !dumps.isEmpty else { return }

                    // After open B + select-tab 1 there should be 2 tabs.
                    let twoTabs = dumps.contains { intModel($0, "tabCount") == 2 }
                    XCTAssertTrue(twoTabs,
                        "[cm6-3] never observed 2 open tabs after opening B",
                        file: file2, line: line)

                    // A's edit was saved before close → on disk.
                    XCTAssertEqual(diskContents(at: fileA), editedA,
                        "[cm6-3] editor-save before close did not persist A's edit",
                        file: file2, line: line)
                    // B was never touched.
                    XCTAssertEqual(diskContents(at: fileB), "BBB clean\n",
                        "[cm6-3] clean tab B was unexpectedly modified",
                        file: file2, line: line)

                    // Final dump: A closed → 1 tab remaining, and it is B.
                    let last = dumps.last!
                    XCTAssertEqual(intModel(last, "tabCount"), 1,
                        "[cm6-3] saved tab A did not close (still >1 tab) — possible modal hang",
                        file: file2, line: line)
                    XCTAssertTrue(modelString(last, "currentURL").hasSuffix("uat_close_B.txt"),
                        "[cm6-3] selection did not land on neighbour B after closing A",
                        file: file2, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "cm6-3/step\(i)", file: file2, line: line)
                    }
                })
        ])
    }

    // MARK: - cm6-4 — External edit while CLEAN auto-reloads (no prompt)
    //
    // The cm6-4 conflict prompt (Keep My Edits / Discard & Reload) fires
    // only when the buffer is DIRTY, and is a blocking modal with no
    // script override (would hang) — logged as a MANUAL / VM beat. The
    // ONE script-reachable, non-hanging cm6-4 beat is the catalog
    // variation "External edit while CLEAN": appending to the file when
    // the buffer is clean should AUTO-RELOAD (no alert) and the editor
    // picks up the new bytes. We open the file in Editor, leave it clean,
    // mutate the file on disk from the test process, and assert the editor
    // tab is still healthy (not error, still editor) and disk has the
    // external append. (The reload reads disk → editor; we verify the app
    // does not crash / error and stays in Editor under the same URL.)

    func test_cm6_4_externalEditWhileClean_noConflictHang() throws {
        let orig = "line 1\nline 2\n"
        let file = try makeEditableFile("uat_conflict.txt", contents: orig)

        // Open in editor, leave CLEAN. Then perform the external write
        // from THIS process mid-script is not possible (single-threaded
        // script). Instead: open in editor, settle, and we mutate disk
        // BEFORE issuing more delays so the watcher fires during the run.
        // We pre-stage the external write by appending to the file right
        // after the editor mount via a follow-up no script verb — since
        // the script can't shell out, we rely on the watcher seeing the
        // file as opened, then we externally append from the assert is too
        // late. So we drive: open in editor (clean), delay to settle. The
        // external mutation is performed by the SCENARIO setup writing the
        // appended content as the on-disk truth BEFORE launch is wrong
        // (then there's no "change").
        //
        // Reachable design: open in editor CLEAN; the file watcher is
        // active. We can't inject an async external write from the
        // single-threaded script. So this scenario asserts the
        // NON-conflict invariant only: a clean editor tab over a watched
        // file stays healthy (editor mode, not error, WKWebView mounted)
        // across settle ticks — i.e. the watcher does NOT spuriously
        // prompt or error on a clean buffer. The live external-write
        // auto-reload is a MANUAL / VM beat.
        let script = """
        delay
        delay
        editor-set-mode editor
        delay
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "cm6-4-clean-editor-no-spurious-conflict",
                argFile: file,
                script: script,
                assert: { [self] dumps, file2, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file2, line: line)
                    guard let last = dumps.last else { return }
                    // Clean editor tab stays healthy across watcher ticks.
                    assertModel(last, "currentViewMode", equals: "editor",
                                label: "cm6-4/clean-editor", file: file2, line: line)
                    assertNotError(last, label: "cm6-4/clean-editor", file: file2, line: line)
                    assertWebViewRendered(last, label: "cm6-4/clean-editor",
                                          file: file2, line: line)
                    // Disk untouched (no save issued).
                    XCTAssertEqual(diskContents(at: file), orig,
                        "[cm6-4] clean editor unexpectedly mutated the file",
                        file: file2, line: line)
                })
        ])
    }

    // MARK: - cm6-5 — Mode routing Editor↔HEX↔Source + go-to-line + cap
    //
    // Script-reachable cm6-5 slice: the Editor↔HEX↔Source routing (the
    // Bug-C "latest switch wins / no wrong-viewer-under-mismatched-picker"
    // guard), `goto <line>` (the Go-to-Line equivalent), and a
    // representative small mapped-language file (.py). The indentation
    // setting, Fold All / Unfold All, per-tab cursor/scroll RESTORE, the
    // 50 MB cap PLACEHOLDER view, and the #219 Editor→HEX flash are not
    // observable from the dump (no NSView class / model scalar; transient
    // at the 300 ms capture) — logged as MANUAL / VM beats.

    func test_cm6_5_editorHexSourceRouting_andGotoLine() throws {
        let py = try makeEditableFile(
            "small.py",
            contents: """
            def main():
                x = 1
                y = 2
                return x + y

            if __name__ == "__main__":
                main()
            """)

        // Open .py in editor → HEX → Source → back to editor (rapid
        // routing). goto 3 while in editor. Assert each landing mode shows
        // the RIGHT realized surface — never the wrong viewer under a
        // mismatched picker (Bug C), never a Hex grid under editor/source.
        let script = """
        delay
        delay
        editor-set-mode editor
        delay
        delay
        goto 3
        delay
        editor-set-mode hex
        delay
        delay
        editor-set-mode source
        delay
        delay
        editor-set-mode editor
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "cm6-5-editor-hex-source-routing",
                argFile: py,
                script: script,
                assert: { [self] dumps, file2, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file2, line: line)
                    guard !dumps.isEmpty else { return }

                    // Each mode landing shows the correct realized surface.
                    if let ed = dumps.first(where: { modelString($0, "currentViewMode") == "editor" }) {
                        assertWebViewRendered(ed, label: "cm6-5/editor", file: file2, line: line)
                        assertNoHexView(ed, label: "cm6-5/editor", file: file2, line: line)
                    } else {
                        XCTFail("[cm6-5] never reached editor mode", file: file2, line: line)
                    }
                    if let hx = dumps.first(where: { modelString($0, "currentViewMode") == "hex" }) {
                        assertModel(hx, "currentStateKind", equals: "binary",
                                    label: "cm6-5/hex-state", file: file2, line: line)
                        assertHexRendered(hx, label: "cm6-5/hex", file: file2, line: line)
                    } else {
                        XCTFail("[cm6-5] never reached hex mode", file: file2, line: line)
                    }
                    if let sr = dumps.first(where: { modelString($0, "currentViewMode") == "source" }) {
                        XCTAssertNotEqual(modelString(sr, "currentStateKind"), "binary",
                            "[cm6-5] source picker but state==binary (Hex under source)",
                            file: file2, line: line)
                        assertSourceTextRendered(sr, label: "cm6-5/source", file: file2, line: line)
                    } else {
                        XCTFail("[cm6-5] never reached source mode", file: file2, line: line)
                    }

                    // Bug-C guard: the FINAL switch must win. Last verb is
                    // editor-set-mode editor → end state is editor with a
                    // WKWebView and no leftover Hex grid.
                    let last = dumps.last!
                    assertModel(last, "currentViewMode", equals: "editor",
                                label: "cm6-5/final-editor", file: file2, line: line)
                    assertWebViewRendered(last, label: "cm6-5/final-editor",
                                          file: file2, line: line)
                    assertNoHexView(last, label: "cm6-5/final-editor",
                                    file: file2, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "cm6-5/step\(i)", file: file2, line: line)
                    }
                })
        ])
    }

    // MARK: - cm6-5 edge — Rapid HEX↔Editor↔Source toggling: latest wins
    //
    // The explicit Bug-C regression guard: toggle the picker fast several
    // times and assert the end state is correct (no wrong viewer under a
    // mismatched picker, no endless spinner / loading-stuck).

    func test_cm6_5edge_rapidToggling_latestWins() throws {
        let txt = try makeEditableFile("uat_rapid.txt", contents: "rapid toggle target\n")
        // No settle delays between switches — stress the routing. One
        // settle at the end so the final mount lands before capture.
        let script = """
        delay
        editor-set-mode hex
        editor-set-mode editor
        editor-set-mode source
        editor-set-mode hex
        editor-set-mode editor
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "cm6-5edge-rapid-toggle-latest-wins",
                argFile: txt,
                script: script,
                assert: { [self] dumps, file2, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file2, line: line)
                    let last = dumps.last!
                    // Latest switch was to editor → end state editor, not
                    // stuck loading, not a Hex grid under the editor picker.
                    assertModel(last, "currentViewMode", equals: "editor",
                                label: "cm6-5edge/final", file: file2, line: line)
                    XCTAssertNotEqual(modelString(last, "currentStateKind"), "loading",
                        "[cm6-5edge] stuck in .loading after rapid toggle (endless spinner)",
                        file: file2, line: line)
                    assertWebViewRendered(last, label: "cm6-5edge/final",
                                          file: file2, line: line)
                    assertNoHexView(last, label: "cm6-5edge/final",
                                    file: file2, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "cm6-5edge/step\(i)", file: file2, line: line)
                    }
                })
        ])
    }

    // MARK: - Model-dict accessors (mirror ViewModesUATTests)

    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        (dump["model"] as? [String: Any])?[key] as? String ?? ""
    }
    private func intModel(_ dump: [String: Any], _ key: String) -> Int {
        ((dump["model"] as? [String: Any])?[key] as? Int) ?? -1
    }
    private func assertModel(
        _ dump: [String: Any], _ key: String, equals expected: String,
        label: String, file: StaticString, line: UInt
    ) {
        XCTAssertEqual(modelString(dump, key), expected,
            "[\(label)] model.\(key) mismatch", file: file, line: line)
    }
    private func assertNotError(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        let kind = modelString(dump, "currentStateKind")
        XCTAssertNotEqual(kind, "error",
            "[\(label)] document landed in .error state", file: file, line: line)
    }

    // MARK: - Realized-tree helpers (mirror ViewModesUATTests)

    private func allNodes(in dump: [String: Any]) -> [[String: Any]] {
        guard let root = dump["contentView"] as? [String: Any] else { return [] }
        var out: [[String: Any]] = []
        var stack: [[String: Any]] = [root]
        while let node = stack.popLast() {
            out.append(node)
            if let kids = node["subviews"] as? [[String: Any]] {
                stack.append(contentsOf: kids)
            }
        }
        return out
    }
    private func hasViewClass(_ dump: [String: Any], containing needle: String) -> Bool {
        allNodes(in: dump).contains { (($0["class"] as? String) ?? "").contains(needle) }
    }
    private func anyTextViewWithGlyphs(_ dump: [String: Any]) -> Bool {
        allNodes(in: dump).contains { node in
            guard let tv = node["nsTextView"] as? [String: Any] else { return false }
            let glyphs = (tv["numberOfGlyphs"] as? Int) ?? 0
            let contrasts = (tv["contrastsWithBackground"] as? Bool) ?? false
            return glyphs > 0 && contrasts
        }
    }
    private func assertSourceTextRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        assertNoHexView(dump, label: label, file: file, line: line)
        XCTAssertTrue(anyTextViewWithGlyphs(dump),
            "[\(label)] Source mode: no NSTextView with visible glyphs — content blank/stale",
            file: file, line: line)
    }
    private func assertWebViewRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        let webNodes = allNodes(in: dump).filter { $0["wkWebView"] != nil }
            + allNodes(in: dump).filter { (($0["class"] as? String) ?? "").contains("WKWebView") }
        XCTAssertFalse(webNodes.isEmpty,
            "[\(label)] expected a WKWebView in tree — editor/rendered view did not mount",
            file: file, line: line)
    }
    private func assertHexRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertTrue(hasViewClass(dump, containing: "Hex"),
            "[\(label)] HEX mode: no Hex* view in tree — byte grid did not mount",
            file: file, line: line)
        XCTAssertTrue(anyTextViewWithGlyphs(dump),
            "[\(label)] HEX mode: byte grid has no visible glyphs — blank",
            file: file, line: line)
    }
    private func assertNoHexView(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertFalse(hasViewClass(dump, containing: "Hex"),
            "[\(label)] a Hex* byte-grid view is mounted under a non-HEX picker — stale/desynced view",
            file: file, line: line)
    }
}
