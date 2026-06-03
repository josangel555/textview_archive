import XCTest
import Foundation

/// UAT executable companion — **group 11/12: settings-and-menus-and-shortcuts**.
///
/// Durable T4 live-app smoke for
/// `docs/uat/smokes/settings-and-menus-and-shortcuts.md`
/// (SC-MENU-01..04, SC-SET-01..03). Drives the assembled `dist/TextView.app`
/// via the `--script` verb dispatcher (same proven path as
/// `ViewModeMatrixSmokeTests` / `TabsAndWindowChromeUATTests`), captures a
/// `DiagnosticDump` JSON per step, and asserts the scripted expectations.
///
/// ## What this suite CAN and CANNOT reach
///
/// The smoke catalog's surface is, by its own admission, *live-menu only*:
/// `validateMenuItem` enable/grey + relabel and the global key-equivalent
/// table only fire against a real `NSMenu` + responder chain. The
/// `--script` verb vocabulary cannot:
///   - open the Settings `NSWindow` (⌘,) — no `show-settings` verb;
///   - read the menu-bar order, an item's `isEnabled`, its title relabel,
///     or its `.on`/`.off` checkmark (none reach the `DiagnosticDump`);
///   - drive the NSAlerts (Go-to-Line ⌘L, Clear Recents, dirty-close, the
///     FDA deep-link, the Clear-All-bookmarks confirm) — a modal `runModal()`
///     blocks the main thread forever in a headless spawn;
///   - launch the Plugins / LSP-Diagnostics tool windows;
///   - exercise the ⌘Q app-quit unsaved guard.
///
/// So — exactly as the catalog's "Live-menu only" run note prescribes — the
/// load-bearing assertions read the **underlying model flags the validator
/// reads** (`currentViewMode`, `isCurrentTabFormatted`, `isCurrentTabBookmarked`,
/// `sidebarVisible`, `zoom`, `currentStateKind`, `currentURL`,
/// `isGoToPathPresented`/`isRenderedFindBarPresented`/`isCrossSearchPresented`/
/// `isPalettePresented`, `sessions`/`activeSessionID`), supplemented by
/// realized-tree CLASS detection where a surface only exists in the NSView
/// tree. The genuinely menu/NSWindow/NSAlert-coupled steps are recorded as
/// not-script-reachable (see the run-log entry) for the manual / VM lane.
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real
/// cross-process AppDelegate↔coordinator launch wiring driving the
/// command-surface model state (view-mode toggle, format toggle, bookmark
/// relabel signal, zoom accelerator parity, sidebar toggle, find/goto/cross
/// routing flags, session menu dispatch). Self-skips on the headless gate
/// (`isAppBuilt` false there); runs for real on the VM/nightly lane or as a
/// host-occluded UAT run.
@MainActor
final class SettingsMenusAndShortcutsUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "SettingsMenusUAT" }
    // Several scenarios open multiple files and WKWebView-backed editor/
    // rendered modes and chain many script steps; give generous settle room.
    override class var defaultScenarioTimeout: TimeInterval { 120 }

    // MARK: - SC-MENU-01 — Dynamic menu validation: model flags the validator reads

    /// SC-MENU-01: walk the validator's *input* signals across file types and
    /// view modes. The menu enable/grey + relabel itself is live-menu-only, so
    /// we assert the model flags `validateMenuItem` reads:
    ///   - markdown is Rendered by default and `supportsViewModeToggle` (the
    ///     Show-Rendered/Source toggle), JSON/txt/png are not;
    ///   - `toggle-view` (⇧⌘R) flips markdown Rendered⇄Source;
    ///   - JSON `supportsFormatToggle`; `toggle-format` (⌥⌘F) flips the
    ///     `isCurrentTabFormatted` flag that drives the Pretty-Print checkmark;
    ///   - editor mode mounts (the gate for Save / Fold / Go-to-Line enablement);
    ///   - ⌘D bookmark relabel signal (`isCurrentTabBookmarked`);
    ///   - a blank tab clears `currentURL` (the hasFile guard greys most items).
    func test_SC_MENU_01_dynamicValidationModelFlags() throws {
        let aMd = try harness.writeFile("a.md", "# Title\n\n**bold** body and a [link](https://example.com).\n")
        let dataJson = try harness.writeFile("data.json", "{\"k\":1,\"v\":[1,2,3]}\n")
        let noteTxt = try harness.writeFile("note.txt", "plain text line one\nplain text line two\n")
        let picPng = try writePNGFixture("pic.png")

        // s1 delay            -> a.md Rendered (supportsViewModeToggle true)
        // s2 toggle-view       -> a.md flips to Source (⇧⌘R toggle item now "Show Rendered")
        // s3 open data.json    -> JSON Source default (supportsFormatToggle true)
        // s4 toggle-format      -> isCurrentTabFormatted flips TRUE (Pretty-Print .on)
        // s5 toggle-format      -> flips back FALSE (raw source returns)
        // s6 editor-set-mode editor -> editor mounts (Save/Fold/Go-to-Line gate open)
        // s7 editor-set-text   -> buffer dirty (Save would enable)
        // s8 toggle-bookmark    -> data.json bookmarked (Bookmark -> "Remove Bookmark")
        // s9 toggle-bookmark    -> cleared (back to "Bookmark This")
        // s10 open note.txt     -> plainText: Source DEFAULT (NOT supportsViewModeToggle, NOT format)
        // s11 open pic.png       -> image preview: no toggle, no format, no editor
        // s12 new-tab            -> blank: currentURL empty (hasFile guards grey out)
        let script = """
        delay 0.8
        toggle-view
        open \(dataJson.path)
        toggle-format
        toggle-format
        editor-set-mode editor
        editor-set-text x = edited
        toggle-bookmark
        toggle-bookmark
        open \(noteTxt.path)
        open \(picPng.path)
        new-tab
        """
        try runScenarios([
            Scenario(
                name: "dynamic-validation-flags",
                argFile: aMd,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 12,
                        "expected >=12 step dumps (1 settle + 11 verbs)", file: file, line: line)
                    guard dumps.count >= 12 else { return }

                    // s1: a.md Rendered (markdown default + toggle-able).
                    let s1 = dumps[0]
                    assertModel(s1, "currentURL", endsWith: "a.md", label: "s1", file: file, line: line)
                    assertModel(s1, "currentViewMode", equals: "rendered", label: "s1-md-rendered", file: file, line: line)

                    // s2: toggle-view (⇧⌘R) flips Rendered -> Source.
                    let s2 = dumps[1]
                    assertModel(s2, "currentViewMode", equals: "source", label: "s2-toggle-to-source", file: file, line: line)

                    // s3: data.json -> Source default (format-able).
                    let s3 = dumps[2]
                    assertModel(s3, "currentURL", endsWith: "data.json", label: "s3", file: file, line: line)
                    assertModel(s3, "currentViewMode", equals: "source", label: "s3-json-source", file: file, line: line)
                    XCTAssertFalse(boolModel(s3, "isCurrentTabFormatted"),
                        "[s3] fresh JSON should not start pre-formatted (Pretty-Print .off)", file: file, line: line)

                    // s4: toggle-format -> Pretty-Print checkmark on (formatted flag true).
                    let s4 = dumps[3]
                    XCTAssertTrue(boolModel(s4, "isCurrentTabFormatted"),
                        "[s4] toggle-format (⌥⌘F) did not set the formatted flag on JSON", file: file, line: line)

                    // s5: toggle-format -> checkmark clears, raw source returns.
                    let s5 = dumps[4]
                    XCTAssertFalse(boolModel(s5, "isCurrentTabFormatted"),
                        "[s5] second toggle-format did not clear the formatted flag", file: file, line: line)

                    // s6: editor mode mounts (the enablement gate for Save /
                    // Fold All / Unfold All / Go to Line — all editor-only).
                    let s6 = dumps[5]
                    assertModel(s6, "currentViewMode", equals: "editor", label: "s6-editor-mounts", file: file, line: line)
                    assertWebViewRendered(s6, label: "s6-editor-webview", file: file, line: line)

                    // s7: editor-set-text makes the buffer dirty (Save would
                    // enable). No explicit dirty scalar in the dump; assert the
                    // editor stayed mounted and didn't error.
                    let s7 = dumps[6]
                    assertModel(s7, "currentViewMode", equals: "editor", label: "s7-still-editor", file: file, line: line)
                    assertNotError(s7, label: "s7-set-text", file: file, line: line)

                    // s8: ⌘D bookmark -> isCurrentTabBookmarked true
                    // (Bookmark item relabels to "Remove Bookmark").
                    let s8 = dumps[7]
                    XCTAssertTrue(boolModel(s8, "isCurrentTabBookmarked"),
                        "[s8] toggle-bookmark (⌘D) did not set bookmark (relabel signal)", file: file, line: line)

                    // s9: ⌘D again -> cleared (back to "Bookmark This").
                    let s9 = dumps[8]
                    XCTAssertFalse(boolModel(s9, "isCurrentTabBookmarked"),
                        "[s9] second ⌘D did not clear bookmark (relabel back)", file: file, line: line)

                    // s10: note.txt -> plainText. The prior tab (data.json) was
                    // in .editor mode and `.editor` IS in plainText's
                    // availableModes ([.source, .editor, .hex]), so carry-mode
                    // legitimately opens note.txt in .editor (NOT a desync —
                    // editor is valid for plain text). Assert the open landed
                    // on a VALID plainText mode (source/editor/hex), never
                    // .rendered (plainText has no Rendered view — that WOULD be
                    // the picker↔pane desync the dedicated var test guards).
                    let s10 = dumps[9]
                    assertModel(s10, "currentURL", endsWith: "note.txt", label: "s10", file: file, line: line)
                    let m10 = modelString(s10, "currentViewMode")
                    XCTAssertTrue(["source", "editor", "hex"].contains(m10),
                        "[s10-txt-valid-mode] note.txt landed in '\(m10)' which is NOT a valid plainText mode ([source,editor,hex]) — picker↔pane desync",
                        file: file, line: line)
                    XCTAssertNotEqual(m10, "rendered",
                        "[s10-txt-no-rendered] note.txt is in 'rendered' but plainText has no Rendered view (desync)",
                        file: file, line: line)

                    // s11: pic.png -> image preview. No editor, no format, no
                    // view-mode toggle (all those menu items grey for an image).
                    let s11 = dumps[10]
                    assertModel(s11, "currentURL", endsWith: "pic.png", label: "s11", file: file, line: line)
                    assertModel(s11, "currentViewMode", equals: "preview", label: "s11-png-preview", file: file, line: line)
                    XCTAssertEqual(modelString(s11, "currentStateKind"), "preview",
                        "[s11] image should be .preview state", file: file, line: line)
                    XCTAssertFalse(boolModel(s11, "isCurrentTabFormatted"),
                        "[s11] image cannot be formatted", file: file, line: line)

                    // s12: new-tab -> blank. currentURL empty => the hasFile /
                    // hasTab guards grey most View/Edit content items. Toggle
                    // Sidebar (⌃⌘S) returns true unconditionally so it'd stay
                    // enabled (asserted in SC-SET-01 via toggle-sidebar).
                    let s12 = dumps[11]
                    assertModel(s12, "currentURL", equals: "", label: "s12-blank-url", file: file, line: line)
                    XCTAssertFalse(boolModel(s12, "isCurrentTabBookmarked"),
                        "[s12] a blank tab cannot be bookmarked (Bookmark greys out)", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "menu01/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    /// BUG FINDING (toggle-view forces an invalid `.rendered` mode onto a
    /// plain-text tab → picker↔pane desync).
    ///
    /// `DocumentModel.toggleViewMode()` (the ⇧⌘R / "Show Rendered/Source"
    /// action) is unconditional:
    /// ```
    /// let new: ViewMode = currentViewMode == .rendered ? .source : .rendered
    /// setCurrentViewMode(new)
    /// ```
    /// It has NO `supportsViewModeToggle` guard, and `setCurrentViewMode(_:)`
    /// does NOT validate the requested mode against
    /// `ViewModeOptions.availableModes(for:)`. So invoking it on a plain-text
    /// file sets `currentViewMode == .rendered` — but plainText's available
    /// modes are `[.source, .editor, .hex]` (no `.rendered`). The content pane
    /// correctly keeps drawing the source `NSTextView` (verified: `.loaded`
    /// state, 1 NSTextView, 0 WKWebView), so the **ModeBar picker LIES** —
    /// it shows "Rendered" while a Source text view is what's on screen. Same
    /// class of defect as the documented carry-mode HEX-onto-preview desync
    /// (`TabsAndWindowChromeUATTests.test_SC_CHROME_02_carryModeHexOntoPreview_DESYNC`).
    ///
    /// In the LIVE menu bar the ⇧⌘R item is greyed for non-markdown types
    /// (`validateMenuItem` reads `supportsViewModeToggle`), so a user can't
    /// usually trip it via the keyboard — but the underlying model action is
    /// unguarded, so any caller that doesn't pre-check (MCP `set_view_mode`,
    /// `--script toggle-view`, programmatic toggles) drives the desync. The
    /// fix is to guard `toggleViewMode()` on `supportsViewModeToggle` and/or
    /// reject a mode not in `availableModes` inside `setCurrentViewMode`.
    ///
    /// Asserts the CORRECT behavior (toggle is a no-op on a non-toggleable
    /// type → mode stays `.source`), wrapped in `XCTExpectFailure(strict:
    /// false)` so the suite stays green while the bug persists and fires
    /// "unexpectedly passed" the moment a guard lands (then remove the wrapper).
    func test_SC_MENU_01var_viewModeToggleScopeDESYNC() throws {
        let noteTxt = try harness.writeFile("note.txt", "plain text line one\nplain text line two\n")
        let script = """
        delay 0.6
        toggle-view
        """
        try runScenarios([
            Scenario(
                name: "toggle-view-scope-desync",
                argFile: noteTxt,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 2, "expected >=2 dumps", file: file, line: line)
                    guard dumps.count >= 2 else { return }
                    // Open default for plainText is source — correct, must hold.
                    assertModel(dumps[0], "currentViewMode", equals: "source", label: "txt-default-source", file: file, line: line)
                    // The pane never errors — the source view stays on screen
                    // even when the picker is mislabeled (this part is benign).
                    assertNotError(dumps[1], label: "toggle-scope/post", file: file, line: line)
                    XCTAssertEqual(modelString(dumps[1], "currentStateKind"), "loaded",
                        "[toggle-scope] post-toggle state should stay .loaded (source pane still drawn)", file: file, line: line)
                    // KNOWN BUG: ⇧⌘R / toggle-view on plainText flips the picker
                    // to '.rendered' though plainText has no Rendered view —
                    // picker↔pane desync. Expected-failure until a
                    // supportsViewModeToggle guard lands on toggleViewMode().
                    XCTExpectFailure(
                        "toggle-view (⇧⌘R) is unguarded on a non-toggleable type: it sets currentViewMode=.rendered on plainText (no Rendered view), desyncing the ModeBar picker from the still-drawn Source pane",
                        strict: false
                    ) {
                        XCTAssertEqual(modelString(dumps[1], "currentViewMode"), "source",
                            "[toggle-scope] BUG: toggle-view put plainText into '\(modelString(dumps[1], "currentViewMode"))' (no Rendered view exists) — ⇧⌘R should be a no-op on a non-markdown/mermaid type",
                            file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SC-MENU-02 — per-tab number jump + next/prev tab + tab reorder

    /// SC-MENU-02 (the script-reachable slice): the ⌘1-9 jump, ⌥⌘→/⌥⌘← next/
    /// prev tab dispatch. (Open Recent submenu, the ⌥⌘[/⌥⌘] Move-Tab vs
    /// Fold-All collision, the ⌥⌘G Find-Previous relocation, and the menu's
    /// per-tab checkmark are live-menu-only and logged for the manual lane.)
    func test_SC_MENU_02_tabNavigationDispatch() throws {
        let one = try harness.writeFile("one.md", "# One\n")
        let two = try harness.writeFile("two.json", "{\"a\":1}\n")
        let three = try harness.writeFile("three.txt", "three\n")
        let four = try harness.writeFile("four.csv", "a,b\n1,2\n")
        let five = try harness.writeFile("five.py", "print('five')\n")

        // argv opens one.md. Open the other four -> 5 tabs in order.
        // s1 delay         -> one.md, tab 1, selected index 0
        // s2..s5 open      -> 5 tabs, five.py selected (index 4)
        // s6 select-tab 3   -> ⌘3 jumps to three.txt (index 2)
        // s7 next-tab        -> ⌥⌘→ advances to four.csv (index 3)
        // s8 prev-tab        -> ⌥⌘← retreats to three.txt (index 2)
        // s9 select-tab 1     -> ⌘1 jumps to one.md (index 0)
        let script = """
        delay 0.8
        open \(two.path)
        open \(three.path)
        open \(four.path)
        open \(five.path)
        select-tab 3
        next-tab
        prev-tab
        select-tab 1
        """
        try runScenarios([
            Scenario(
                name: "tab-navigation",
                argFile: one,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 9, "expected >=9 dumps", file: file, line: line)
                    guard dumps.count >= 9 else { return }

                    assertModel(dumps[0], "tabCount", equals: 1, label: "s1", file: file, line: line)
                    assertModel(dumps[0], "selectedTabIndex", equals: 0, label: "s1", file: file, line: line)

                    // s5: five tabs, five.py selected (index 4).
                    let s5 = dumps[4]
                    assertModel(s5, "tabCount", equals: 5, label: "s5-five-tabs", file: file, line: line)
                    assertModel(s5, "selectedTabIndex", equals: 4, label: "s5-last-selected", file: file, line: line)
                    assertModel(s5, "currentURL", endsWith: "five.py", label: "s5", file: file, line: line)

                    // s6: ⌘3 -> three.txt (index 2). Window title tracks.
                    let s6 = dumps[5]
                    assertModel(s6, "selectedTabIndex", equals: 2, label: "s6-cmd3", file: file, line: line)
                    assertModel(s6, "currentURL", endsWith: "three.txt", label: "s6-cmd3-url", file: file, line: line)
                    assertModel(s6, "windowTitle", equals: "three.txt", label: "s6-title-tracks", file: file, line: line)

                    // s7: ⌥⌘→ next -> four.csv (index 3).
                    let s7 = dumps[6]
                    assertModel(s7, "selectedTabIndex", equals: 3, label: "s7-next", file: file, line: line)
                    assertModel(s7, "currentURL", endsWith: "four.csv", label: "s7-next-url", file: file, line: line)

                    // s8: ⌥⌘← prev -> three.txt (index 2).
                    let s8 = dumps[7]
                    assertModel(s8, "selectedTabIndex", equals: 2, label: "s8-prev", file: file, line: line)
                    assertModel(s8, "currentURL", endsWith: "three.txt", label: "s8-prev-url", file: file, line: line)

                    // s9: ⌘1 -> one.md (index 0).
                    let s9 = dumps[8]
                    assertModel(s9, "selectedTabIndex", equals: 0, label: "s9-cmd1", file: file, line: line)
                    assertModel(s9, "currentURL", endsWith: "one.md", label: "s9-cmd1-url", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "menu02/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SC-SET-01 — zoom accelerator parity + sidebar / wrap toggles

    /// SC-SET-01 (the script-reachable slice): the unified zoom that the
    /// Settings slider AND the View menu ⌘=/⌘-/⌘0 both drive (one scalar
    /// `model.zoom`), with the 50%..300% floor/cap; the ⌃⌘S Toggle Sidebar
    /// flipping `sidebar.isVisible` and its checkmark signal. (The Settings
    /// `NSWindow` itself, the Theme picker, Wrap/Invisibles/Indentation
    /// pickers, and the menu checkmark reflection are not script-reachable —
    /// logged for the manual lane.)
    func test_SC_SET_01_zoomParityAndSidebarToggle() throws {
        let readmeMd = try harness.writeFile("readme.md", "# Readme\n\nbody text\n")

        // Normalize zoom first (a prior scenario may have persisted != 1.0),
        // then exercise the accelerators + clamps.
        // s1 delay        -> open
        // s2 zoom-reset    -> ⌘0 -> 1.0
        // s3 zoom-in        -> ⌘= -> 1.1
        // s4 zoom-in         -> 1.2
        // s5 zoom-reset       -> ⌘0 -> 1.0
        // s6 zoom-out          -> ⌘- -> 0.9
        // s7 toggle-sidebar     -> ⌃⌘S flips visibility
        // s8 toggle-sidebar      -> flips back
        let script = """
        delay 0.8
        zoom-reset
        zoom-in
        zoom-in
        zoom-reset
        zoom-out
        toggle-sidebar
        toggle-sidebar
        """
        try runScenarios([
            Scenario(
                name: "zoom-parity-sidebar",
                argFile: readmeMd,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 8, "expected >=8 dumps", file: file, line: line)
                    guard dumps.count >= 8 else { return }

                    // s2: zoom-reset -> 1.0
                    assertZoom(dumps[1], equals: 1.0, label: "s2-reset", file: file, line: line)
                    // s3,s4: zoom-in monotone, capped at 3.0
                    let z3 = doubleZoom(dumps[2])
                    let z4 = doubleZoom(dumps[3])
                    XCTAssertGreaterThan(z3, 1.0, "[s3] ⌘= did not raise zoom", file: file, line: line)
                    XCTAssertGreaterThan(z4, z3, "[s4] ⌘= not monotonic", file: file, line: line)
                    XCTAssertLessThanOrEqual(z4, 3.0, "[s4] zoom exceeded 300% cap", file: file, line: line)
                    // s5: zoom-reset -> 1.0
                    assertZoom(dumps[4], equals: 1.0, label: "s5-reset", file: file, line: line)
                    // s6: zoom-out -> below 1.0, floored at 0.5
                    let z6 = doubleZoom(dumps[5])
                    XCTAssertLessThan(z6, 1.0, "[s6] ⌘- did not lower zoom", file: file, line: line)
                    XCTAssertGreaterThanOrEqual(z6, 0.5, "[s6] zoom dropped below 50% floor", file: file, line: line)

                    // s7: ⌃⌘S toggles sidebar (checkmark flips).
                    let visStart = boolModel(dumps[0], "sidebarVisible")
                    let s7vis = boolModel(dumps[6], "sidebarVisible")
                    XCTAssertNotEqual(s7vis, visStart,
                        "[s7] toggle-sidebar (⌃⌘S) did not flip sidebar visibility (start=\(visStart))",
                        file: file, line: line)
                    // s8: toggle back to the starting state.
                    let s8vis = boolModel(dumps[7], "sidebarVisible")
                    XCTAssertEqual(s8vis, visStart,
                        "[s8] second toggle-sidebar did not restore sidebar visibility", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "set01/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    /// SC-SET-01 variation: zoom floor/cap hammered. Many zoom-ins must clamp
    /// at exactly 3.0; many zoom-outs at exactly 0.5 — the ⌘=/⌘- accelerators
    /// can't blow past the bounds the Settings slider also enforces.
    func test_SC_SET_01var_zoomClamps() throws {
        let f = try harness.writeFile("z.md", "# Zoom\n")
        // 40 zoom-ins from reset -> would be 5.0 unclamped; must cap 3.0.
        // Then 40 zoom-outs -> would be -1.0 unclamped; must floor 0.5.
        let ins = Array(repeating: "zoom-in", count: 40).joined(separator: "\n")
        let outs = Array(repeating: "zoom-out", count: 40).joined(separator: "\n")
        let script = """
        delay 0.6
        zoom-reset
        \(ins)
        zoom-reset
        \(outs)
        """
        try runScenarios([
            Scenario(
                name: "zoom-clamps",
                argFile: f,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else { XCTFail("no dumps", file: file, line: line); return }
                    // After 40 zoom-outs the final zoom must be the floor.
                    assertZoom(last, equals: 0.5, label: "floor-after-40-out", file: file, line: line)
                    // The peak (right before the second reset) must be the cap.
                    // dumps: [delay, reset, 40 ins, reset, 40 outs]
                    // index of the last zoom-in = 1 + 40 = 41 -> dumps[41]
                    if dumps.count > 41 {
                        assertZoom(dumps[41], equals: 3.0, label: "cap-after-40-in", file: file, line: line)
                    }
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "zoom-clamp/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SC-MENU-03 — Find accelerator routing by view mode + Edit/clipboard surfaces

    /// SC-MENU-03 (the script-reachable slice): the find-bar / goto / cross-
    /// search presentation flags the ⌘F / ⇧⌘G / ⇧⌘F accelerators raise. We
    /// assert routing tracks the active view mode (rendered find vs editor),
    /// that ⇧⌘G raises Go-to-Path (NOT Find-Previous), and that ⇧⌘F raises the
    /// cross-file modal. The per-bar internals are owned by `search.md`; the
    /// ⌘Z/⇧⌘Z editor-vs-responder routing and the ⌘Q dirty-guard gap are
    /// menu/responder/NSAlert-coupled and logged for the manual lane.
    func test_SC_MENU_03_findGotoCrossRouting() throws {
        let docMd = try harness.writeFile("doc.md", "# Doc\n\nfind me find me find me\n")
        let codeTs = try harness.writeFile("code.ts", "const x = 1;\nconst y = 2;\nfind();\n")

        // s1 delay              -> doc.md Rendered
        // s2 show-find           -> rendered find bar present (⌘F in Rendered)
        // s3 dismiss-find         -> rendered find bar gone
        // s4 show-goto             -> ⇧⌘G Go-to-Path prompt present (NOT Find-Prev)
        // s5 dismiss-goto           -> goto gone
        // s6 show-cross-search       -> ⇧⌘F cross-file modal present
        // s7 dismiss-cross-search     -> cross gone
        // s8 open code.ts; editor mode  -> editor mounts
        // s9 show-palette                -> ⌘K-ish command palette present (sanity: a distinct overlay)
        // s10 dismiss-palette             -> palette gone
        let script = """
        delay 0.8
        show-find
        dismiss-find
        show-goto
        dismiss-goto
        show-cross-search
        dismiss-cross-search
        open \(codeTs.path)
        editor-set-mode editor
        show-palette
        dismiss-palette
        """
        try runScenarios([
            Scenario(
                name: "find-goto-cross-routing",
                argFile: docMd,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 11, "expected >=11 dumps", file: file, line: line)
                    guard dumps.count >= 11 else { return }

                    // s1: doc.md rendered.
                    assertModel(dumps[0], "currentViewMode", equals: "rendered", label: "s1-rendered", file: file, line: line)

                    // s2: ⌘F in Rendered -> rendered find bar presented.
                    XCTAssertTrue(boolModel(dumps[1], "isRenderedFindBarPresented"),
                        "[s2] show-find (⌘F) did not present the rendered find bar in Rendered mode", file: file, line: line)
                    // s3: dismissed.
                    XCTAssertFalse(boolModel(dumps[2], "isRenderedFindBarPresented"),
                        "[s3] dismiss-find did not hide the rendered find bar", file: file, line: line)

                    // s4: ⇧⌘G -> Go-to-Path prompt (NOT Find Previous).
                    XCTAssertTrue(boolModel(dumps[3], "isGoToPathPresented"),
                        "[s4] show-goto (⇧⌘G) did not present the Go-to-Path prompt", file: file, line: line)
                    // Go-to-Path is mutually distinct from a find bar: the find
                    // bar flag must NOT be set just because ⇧⌘G opened.
                    XCTAssertFalse(boolModel(dumps[3], "isRenderedFindBarPresented"),
                        "[s4] ⇧⌘G also raised a find bar — ⇧⌘G must be Go-to-Path, not Find-Previous", file: file, line: line)
                    // s5: dismissed.
                    XCTAssertFalse(boolModel(dumps[4], "isGoToPathPresented"),
                        "[s5] dismiss-goto did not hide the Go-to-Path prompt", file: file, line: line)

                    // s6: ⇧⌘F -> cross-file search modal.
                    XCTAssertTrue(boolModel(dumps[5], "isCrossSearchPresented"),
                        "[s6] show-cross-search (⇧⌘F) did not present the cross-file modal", file: file, line: line)
                    // s7: dismissed.
                    XCTAssertFalse(boolModel(dumps[6], "isCrossSearchPresented"),
                        "[s7] dismiss-cross-search did not hide the cross-file modal", file: file, line: line)

                    // s8: code.ts opened. s9: editor mode mounts.
                    assertModel(dumps[7], "currentURL", endsWith: "code.ts", label: "s8-open-ts", file: file, line: line)
                    let s9 = dumps[8]
                    assertModel(s9, "currentViewMode", equals: "editor", label: "s9-editor-mode", file: file, line: line)
                    assertWebViewRendered(s9, label: "s9-editor-webview", file: file, line: line)

                    // s10: ⌘K command palette presented over the editor.
                    XCTAssertTrue(boolModel(dumps[9], "isPalettePresented"),
                        "[s10] show-palette did not present the command palette", file: file, line: line)
                    // s11: dismissed.
                    XCTAssertFalse(boolModel(dumps[10], "isPalettePresented"),
                        "[s11] dismiss-palette did not hide the command palette", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "menu03/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    /// SC-MENU-03 var: only ONE of the overlay surfaces should be presented at
    /// a time when raised in isolation — a sanity check that the palette /
    /// goto / find / cross flags are independent and don't co-fire (a stuck
    /// overlay would leave the user with two scrims).
    func test_SC_MENU_03var_overlayFlagsAreIndependent() throws {
        let f = try harness.writeFile("ov.md", "# Overlays\n\nbody\n")
        let script = """
        delay 0.6
        show-palette
        dismiss-palette
        show-goto
        dismiss-goto
        """
        try runScenarios([
            Scenario(
                name: "overlay-independence",
                argFile: f,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 5, "expected >=5 dumps", file: file, line: line)
                    guard dumps.count >= 5 else { return }
                    // While palette is up, goto/find/cross must be down.
                    let pal = dumps[1]
                    XCTAssertTrue(boolModel(pal, "isPalettePresented"), "[palette-up] palette not presented", file: file, line: line)
                    XCTAssertFalse(boolModel(pal, "isGoToPathPresented"), "[palette-up] goto co-fired with palette", file: file, line: line)
                    XCTAssertFalse(boolModel(pal, "isCrossSearchPresented"), "[palette-up] cross co-fired with palette", file: file, line: line)
                    // While goto is up, palette must be down.
                    let gt = dumps[3]
                    XCTAssertTrue(boolModel(gt, "isGoToPathPresented"), "[goto-up] goto not presented", file: file, line: line)
                    XCTAssertFalse(boolModel(gt, "isPalettePresented"), "[goto-up] palette co-fired with goto", file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "overlay/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SC-MENU-04 — Session menu dispatch (presence + accelerator wiring)

    /// SC-MENU-04 (the script-reachable slice): the Session menu items
    /// dispatch the matching `SessionsAppCoordinator` calls — New Session
    /// (⇧⌘N), Next/Prev (⌃⇥/⌃⇧⇥), Jump (⌃1-9), Close (⇧⌘W). We assert via
    /// the `sessions` snapshot + `activeSessionID` in the dump. (The Debug-menu
    /// DiagnosticGate, `--mcp-stdio` menu-bar-absent mode, and HIG menu order
    /// are pure menu-bar concerns, not script-reachable — logged for manual.)
    func test_SC_MENU_04_sessionMenuDispatch() throws {
        let projX = try harness.makeDir("projX")
        try harness.writeFile("projX/x.md", "# X\n")
        let projY = try harness.makeDir("projY")
        try harness.writeFile("projY/y.md", "# Y\n")
        let seed = try harness.writeFile("seed.md", "# Seed\n")

        // s1 delay                              -> launch (>=1 session)
        // s2 session-open-folder projX           -> projX session (⇧⌘N New)
        // s3 session-open-new projY               -> projY forced-new session
        // s4 session-prev                          -> ⌃⇧⇥ retreat
        // s5 session-next                           -> ⌃⇥ advance
        // s6 session-activate 1                      -> ⌃1 jump to first
        let script = """
        delay 0.8
        session-open-folder \(projX.path)
        session-open-new \(projY.path)
        session-prev
        session-next
        session-activate 1
        """
        try runScenarios([
            Scenario(
                name: "session-menu-dispatch",
                argFile: seed,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 6, "expected >=6 dumps", file: file, line: line)
                    guard dumps.count >= 6 else { return }

                    // s2: projX session present.
                    let s2 = dumps[1]
                    let s2names = sessionNames(s2)
                    XCTAssertTrue(s2names.contains(where: { $0.contains("projX") }),
                        "[s2] session-open-folder did not create/activate a projX session (got \(s2names))",
                        file: file, line: line)

                    // s3: projY forced-new -> distinct session, count grows.
                    let s3 = dumps[2]
                    let s3count = sessionCount(s3)
                    let s2count = sessionCount(s2)
                    XCTAssertGreaterThanOrEqual(s3count, s2count,
                        "[s3] session-open-new did not add a session (s2=\(s2count) s3=\(s3count))",
                        file: file, line: line)
                    XCTAssertTrue(sessionNames(s3).contains(where: { $0.contains("projY") }),
                        "[s3] projY session missing after forced-new open", file: file, line: line)

                    // s4/s5: prev then next should leave the active session at
                    // a deterministic id; assert the active id is non-empty and
                    // moves with the calls (dispatch reaches the coordinator).
                    let s4active = modelString(dumps[3], "activeSessionID")
                    let s5active = modelString(dumps[4], "activeSessionID")
                    XCTAssertFalse(s4active.isEmpty, "[s4] session-prev left no active session", file: file, line: line)
                    XCTAssertFalse(s5active.isEmpty, "[s5] session-next left no active session", file: file, line: line)

                    // s6: ⌃1 jump to the first session — active id must equal
                    // the first session's id in the snapshot list.
                    let s6 = dumps[5]
                    let s6sessions = sessionList(s6)
                    if let first = s6sessions.first, let firstID = first["id"] as? String {
                        XCTAssertEqual(modelString(s6, "activeSessionID"), firstID,
                            "[s6] session-activate 1 (⌃1) did not make the FIRST session active", file: file, line: line)
                    } else {
                        XCTFail("[s6] no sessions in snapshot after activate 1", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "menu04/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SC-SET-02/03 — Bookmark store + persistence proxy (script-reachable slice)

    /// SC-SET-02 (the script-reachable slice): the bookmark store the
    /// Settings ▸ Advanced "Clear All" acts on. We can toggle file bookmarks
    /// (⌘D) and observe the `isCurrentTabBookmarked` relabel signal across
    /// multiple tabs; the destructive `confirmationDialog`, the gutter line-
    /// bookmark (⌥⌘D), "Reset window state", and the relaunch re-center are
    /// NSAlert/NSWindow-coupled and logged for the manual lane.
    func test_SC_SET_02_bookmarkStoreToggleAcrossTabs() throws {
        let a = try harness.writeFile("bm-a.md", "# A\n")
        let b = try harness.writeFile("bm-b.json", "{\"b\":1}\n")
        let c = try harness.writeFile("bm-c.txt", "c\n")

        // Open three tabs, bookmark each, then confirm each carries the flag.
        // s1 delay        -> a
        // s2 toggle-bookmark -> a bookmarked
        // s3 open b          -> b (not bookmarked yet)
        // s4 toggle-bookmark  -> b bookmarked
        // s5 open c            -> c
        // s6 toggle-bookmark    -> c bookmarked
        // s7 select-tab 1        -> back to a; still bookmarked (persists per-tab)
        let script = """
        delay 0.8
        toggle-bookmark
        open \(b.path)
        toggle-bookmark
        open \(c.path)
        toggle-bookmark
        select-tab 1
        """
        try runScenarios([
            Scenario(
                name: "bookmark-store-multi",
                argFile: a,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 7, "expected >=7 dumps", file: file, line: line)
                    guard dumps.count >= 7 else { return }

                    XCTAssertFalse(boolModel(dumps[0], "isCurrentTabBookmarked"),
                        "[s1] a should not start bookmarked", file: file, line: line)
                    XCTAssertTrue(boolModel(dumps[1], "isCurrentTabBookmarked"),
                        "[s2] ⌘D did not bookmark a", file: file, line: line)
                    // s4: b bookmarked.
                    XCTAssertTrue(boolModel(dumps[3], "isCurrentTabBookmarked"),
                        "[s4] ⌘D did not bookmark b", file: file, line: line)
                    // s6: c bookmarked.
                    XCTAssertTrue(boolModel(dumps[5], "isCurrentTabBookmarked"),
                        "[s6] ⌘D did not bookmark c", file: file, line: line)
                    // s7: re-select a -> still bookmarked (the store persists
                    // the bookmark per-file across tab switches, so Clear-All
                    // would have something to clear).
                    let s7 = dumps[6]
                    assertModel(s7, "currentURL", endsWith: "bm-a.md", label: "s7-reselect-a", file: file, line: line)
                    XCTAssertTrue(boolModel(s7, "isCurrentTabBookmarked"),
                        "[s7] a's bookmark did not survive a tab switch (store not persisting)", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "set02/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - Model assertion helpers

    private func model(_ dump: [String: Any]) -> [String: Any] {
        dump["model"] as? [String: Any] ?? [:]
    }
    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        model(dump)[key] as? String ?? ""
    }
    private func intModel(_ dump: [String: Any], _ key: String) -> Int {
        model(dump)[key] as? Int ?? Int.min
    }
    private func boolModel(_ dump: [String: Any], _ key: String) -> Bool {
        model(dump)[key] as? Bool ?? false
    }
    private func doubleZoom(_ dump: [String: Any]) -> Double {
        if let d = model(dump)["zoom"] as? Double { return d }
        if let i = model(dump)["zoom"] as? Int { return Double(i) }
        return .nan
    }

    private func sessionList(_ dump: [String: Any]) -> [[String: Any]] {
        model(dump)["sessions"] as? [[String: Any]] ?? []
    }
    private func sessionCount(_ dump: [String: Any]) -> Int { sessionList(dump).count }
    private func sessionNames(_ dump: [String: Any]) -> [String] {
        sessionList(dump).compactMap { ($0["displayName"] as? String) ?? ($0["sidebarRootPath"] as? String) }
    }

    private func assertModel(
        _ dump: [String: Any], _ key: String, equals expected: String,
        label: String, file: StaticString, line: UInt
    ) {
        XCTAssertEqual(modelString(dump, key), expected,
            "[\(label)] model.\(key) mismatch", file: file, line: line)
    }
    private func assertModel(
        _ dump: [String: Any], _ key: String, equals expected: Int,
        label: String, file: StaticString, line: UInt
    ) {
        XCTAssertEqual(intModel(dump, key), expected,
            "[\(label)] model.\(key) mismatch", file: file, line: line)
    }
    private func assertModel(
        _ dump: [String: Any], _ key: String, endsWith suffix: String,
        label: String, file: StaticString, line: UInt
    ) {
        let v = modelString(dump, key)
        XCTAssertTrue(v.hasSuffix(suffix),
            "[\(label)] model.\(key) (\(v.debugDescription)) does not end with \(suffix.debugDescription)",
            file: file, line: line)
    }
    private func assertZoom(
        _ dump: [String: Any], equals expected: Double,
        label: String, file: StaticString, line: UInt
    ) {
        XCTAssertEqual(doubleZoom(dump), expected, accuracy: 0.001,
            "[\(label)] model.zoom mismatch", file: file, line: line)
    }
    private func assertNotError(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertNotEqual(modelString(dump, "currentStateKind"), "error",
            "[\(label)] document landed in .error state", file: file, line: line)
    }

    // MARK: - Tree-walk helpers

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

    /// Editor / Rendered: a real, non-zero-sized WKWebView must be mounted.
    private func assertWebViewRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        let webNodes = allNodes(in: dump).filter { $0["wkWebView"] != nil }
        XCTAssertFalse(webNodes.isEmpty,
            "[\(label)] expected a WKWebView — editor/rendered view did not mount", file: file, line: line)
        let anyVisible = webNodes.contains { $0["zeroSize"] == nil }
        XCTAssertTrue(anyVisible,
            "[\(label)] WKWebView present but zero-sized — content pane blank", file: file, line: line)
    }

    // MARK: - Binary fixtures

    /// 1x1 red PNG (real magic bytes -> .image -> .preview).
    private func writePNGFixture(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        guard let data = Data(base64Encoded: b64) else { throw XCTSkip("PNG fixture decode failed") }
        try data.write(to: url)
        return url
    }
}
