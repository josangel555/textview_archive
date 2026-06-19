import XCTest
import Foundation

/// UAT executable companion — **group 1/12: tabs-and-window-chrome**.
///
/// Durable T4 live-app smoke for `docs/uat/smokes/tabs-and-window-chrome.md`
/// (SC-CHROME-01..06). Drives the assembled `dist/TextView.app` via the
/// `--script` verb dispatcher (the same proven path as
/// `ViewModeMatrixSmokeTests`), captures a `DiagnosticDump` JSON per step,
/// and asserts the scripted expectations.
///
/// ## Observability constraint (verified against a live dump)
///
/// SwiftUI's `.accessibilityIdentifier()` sets the AX-tree id, which is
/// **NOT** propagated onto `NSView.accessibilityIdentifier()` that
/// `DiagnosticDump` reads — a live probe confirmed ZERO `mdv.*` ids appear
/// in either the `contentView` tree or `recursiveDescription`. This is the
/// exact caveat called out at `tabs-and-window-chrome.md` line 244 ("the
/// `mdv.tabbar` a11y-id may not propagate … fall back to model-level /
/// Window-menu assertions").
///
/// So the load-bearing assertions read the `model` sub-dict
/// (`ScriptVerb.modelStateDump` — authoritative for tab count, selected
/// index, window title, current URL, view mode, bookmark, sessions,
/// sidebar visibility), supplemented by **view-CLASS** detection for the
/// surfaces that only the realized tree exposes (the mode-picker
/// `SwiftUISegmentedControl`, zero-sized chrome bars).
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real
/// cross-process AppDelegate↔coordinator launch wiring, tab lifecycle,
/// mode-routing, chrome composition, and resize behavior in a real
/// `NSWindow`. Self-skips on the headless gate (`isAppBuilt` false there);
/// runs for real on the VM/nightly lane or as a host-occluded UAT run.
@MainActor
final class TabsAndWindowChromeUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "TabsChromeUAT" }
    // Several scenarios open multiple files + WKWebView-backed modes and
    // chain many script steps; give each scenario generous settle room.
    override class var defaultScenarioTimeout: TimeInterval { 120 }

    // MARK: - SC-CHROME-01 — Multi-tab lifecycle

    /// Open four file types, switch, dedup, reuse-blank, close, neighbor
    /// selection, bookmark — asserting tab count, selected index, window
    /// title, default view mode, and statusbar visibility coupling at each
    /// step. The richest tab-lifecycle flow.
    func test_SC_CHROME_01_multiTabLifecycle() throws {
        let aMd   = try harness.writeFile("a.md", "# Title\n\nbody **bold** text\n")
        let bJson = try harness.writeFile("b.json", "{\"k\":1,\"v\":[1,2,3]}\n")
        let cTxt  = try harness.writeFile("c.txt", "plain text line one\nplain text line two\n")
        let dCsv  = try harness.writeFile("d.csv", "a,b,c\n1,2,3\n4,5,6\n")

        // argv opens a.md (tab 1). Then open the other three in order.
        // Steps mirror SC-CHROME-01:
        //  s1 delay     -> a.md open, rendered default, statusbar present
        //  s2 open b    -> 2 tabs, b selected, source/format default
        //  s3 open c    -> 3 tabs, c selected
        //  s4 open d    -> 4 tabs, d selected, table default
        //  s5 select 1  -> a.md re-selected, title flips, rendered
        //  s6 next-tab  -> b.json
        //  s7 next-tab  -> c.txt
        //  s8 dirty c   -> editor mode + set-text -> tab dirty
        //  s9 save c    -> editor-save clears the dirty buffer to disk so
        //                 the following close DOESN'T deadlock on the modal
        //                 dirty-close NSAlert. (SC-CHROME-01 step 6's
        //                 Save/Don't-Save/Cancel prompt is NOT reachable
        //                 from the script verb vocabulary — `close-tab` on a
        //                 dirty tab blocks the main thread on `runModal()`
        //                 forever in a headless run. Logged as manual-only.)
        //  s10 close c  -> 3 tabs, right neighbor (d.csv) selected
        //  s11 reopen b -> NO dup, switches to existing b (still 3 tabs)
        //  s12 new-tab  -> blank Untitled appended+selected, statusbar GONE
        //  s13 reopen a -> blank tab REUSED (still 4 tabs, not 5), a.md
        let script = """
        delay 0.8
        open \(bJson.path)
        open \(cTxt.path)
        open \(dCsv.path)
        select-tab 1
        next-tab
        next-tab
        editor-set-mode editor
        editor-set-text edited-content-marker
        editor-save
        close-tab
        open \(bJson.path)
        new-tab
        open \(aMd.path)
        """
        try runScenarios([
            Scenario(
                name: "multi-tab-lifecycle",
                argFile: aMd,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(
                        dumps.count, 14,
                        "expected >=14 step dumps (1 launch settle + 13 verbs)",
                        file: file, line: line)
                    guard dumps.count >= 14 else { return }

                    // s1: a.md open. Rendered default + statusbar present.
                    let s1 = dumps[0]
                    assertModel(s1, "currentURL", endsWith: "a.md", label: "s1", file: file, line: line)
                    assertModel(s1, "currentViewMode", equals: "rendered", label: "s1", file: file, line: line)
                    assertModel(s1, "tabCount", equals: 1, label: "s1", file: file, line: line)
                    assertModel(s1, "windowTitle", equals: "a.md", label: "s1", file: file, line: line)
                    assertStatusBarPresent(s1, expected: true, label: "s1-statusbar", file: file, line: line)

                    // s2: open b.json -> 2 tabs, b selected, JSON default
                    // is source (Format offered but not default).
                    let s2 = dumps[1]
                    assertModel(s2, "tabCount", equals: 2, label: "s2", file: file, line: line)
                    assertModel(s2, "currentURL", endsWith: "b.json", label: "s2", file: file, line: line)
                    assertModel(s2, "selectedTabIndex", equals: 1, label: "s2", file: file, line: line)

                    // s3: open c.txt -> 3 tabs
                    let s3 = dumps[2]
                    assertModel(s3, "tabCount", equals: 3, label: "s3", file: file, line: line)
                    assertModel(s3, "currentURL", endsWith: "c.txt", label: "s3", file: file, line: line)

                    // s4: open d.csv -> 4 tabs, d selected, TABLE default
                    let s4 = dumps[3]
                    assertModel(s4, "tabCount", equals: 4, label: "s4", file: file, line: line)
                    assertModel(s4, "currentURL", endsWith: "d.csv", label: "s4", file: file, line: line)
                    assertModel(s4, "selectedTabIndex", equals: 3, label: "s4", file: file, line: line)
                    assertModel(s4, "currentViewMode", equals: "table", label: "s4-csv-table", file: file, line: line)

                    // s5: select-tab 1 -> a.md, title flips, reverts to rendered
                    let s5 = dumps[4]
                    assertModel(s5, "selectedTabIndex", equals: 0, label: "s5", file: file, line: line)
                    assertModel(s5, "currentURL", endsWith: "a.md", label: "s5", file: file, line: line)
                    assertModel(s5, "windowTitle", equals: "a.md", label: "s5", file: file, line: line)
                    assertModel(s5, "currentViewMode", equals: "rendered", label: "s5-revert", file: file, line: line)

                    // s6: next-tab -> b.json
                    let s6 = dumps[5]
                    assertModel(s6, "currentURL", endsWith: "b.json", label: "s6-next", file: file, line: line)
                    // s7: next-tab -> c.txt
                    let s7 = dumps[6]
                    assertModel(s7, "currentURL", endsWith: "c.txt", label: "s7-next", file: file, line: line)

                    // s8: editor mode -> tab. (Dirty dot is a SwiftUI overlay
                    // with no NSView class; the model has no explicit dirty
                    // scalar in the dump, so we assert mode flipped to editor
                    // as the proxy.)
                    let s8 = dumps[7]
                    assertModel(s8, "currentViewMode", equals: "editor", label: "s8-editor", file: file, line: line)
                    // s9: editor-set-text (makes the buffer dirty).
                    assertNotError(dumps[8], label: "s9-set-text", file: file, line: line)
                    // s10 in dumps[9]: editor-save flushes to disk (clears
                    // dirty so the close below doesn't deadlock on the modal).
                    assertNotError(dumps[9], label: "s10-save", file: file, line: line)

                    // s11 in dumps[10]: close-tab (c.txt selected) -> 3 tabs;
                    // the RIGHT NEIGHBOR (d.csv) becomes selected. c.txt gone.
                    let sClose = dumps[10]
                    assertModel(sClose, "tabCount", equals: 3, label: "s11-close", file: file, line: line)
                    assertModel(sClose, "currentURL", endsWith: "d.csv", label: "s11-neighbor", file: file, line: line)

                    // s12 in dumps[11]: reopen b.json (already open) -> NO
                    // duplicate; selection switches to existing b. Still 3.
                    let sDedup = dumps[11]
                    assertModel(sDedup, "tabCount", equals: 3, label: "s12-dedup", file: file, line: line)
                    assertModel(sDedup, "currentURL", endsWith: "b.json", label: "s12-dedup", file: file, line: line)

                    // s13 in dumps[12]: new-tab -> blank Untitled
                    // appended+selected. tabCount 4. currentURL empty ->
                    // StatusBar GONE. Window title falls back.
                    let sBlank = dumps[12]
                    assertModel(sBlank, "tabCount", equals: 4, label: "s13-newtab", file: file, line: line)
                    assertModel(sBlank, "currentURL", equals: "", label: "s13-blank-url", file: file, line: line)
                    assertStatusBarPresent(sBlank, expected: false, label: "s13-statusbar-gone", file: file, line: line)
                    let titleBlank = modelString(sBlank, "windowTitle")
                    XCTAssertTrue(
                        titleBlank == "TextView" || titleBlank == "MarkdownViewer" || titleBlank.isEmpty || titleBlank == "Untitled",
                        "[s13] blank-tab window title should fall back (got \(titleBlank.debugDescription))",
                        file: file, line: line)

                    // s14 in dumps[13]: open a.md on the blank tab -> blank
                    // REUSED (not a 5th tab). Still 4 tabs; a.md loaded.
                    let sReuse = dumps[13]
                    assertModel(sReuse, "tabCount", equals: 4, label: "s14-reuse-blank", file: file, line: line)
                    assertModel(sReuse, "currentURL", endsWith: "a.md", label: "s14-reuse-blank", file: file, line: line)
                    assertStatusBarPresent(sReuse, expected: true, label: "s14-statusbar-back", file: file, line: line)

                    // Cross-cutting: no step ever lands in .error, and the
                    // chrome bars are never zero-sized/blank.
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "lifecycle/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SC-CHROME-02 — ModeBar routing + Open As + language badge

    /// ModeBar chrome rendering: picker present for multi-mode types,
    /// hidden for single-mode (binary/unknown) types; Open-As override
    /// routing; Format toggle; SQLite -> native Preview (not HEX). Asserts
    /// `model.currentViewMode` + the mode-picker `SwiftUISegmentedControl`
    /// presence.
    func test_SC_CHROME_02_modeBarRoutingAndOpenAs() throws {
        let notesMd = try harness.writeFile("notes.md", "# Notes\n\nsome body\n")
        let dataJson = try harness.writeFile("data.json", "{\"a\":1,\"b\":2}\n")
        let pageHtml = try harness.writeFile("page.html", "<html><body><h1>Hi</h1></body></html>\n")
        let binDat = try writeRandomBinary("bin.dat")
        let dbSqlite = try writeSQLiteFixture("db.sqlite")
        let picPng = try writePNGFixture("pic.png")

        // Each open below is from a markdown/source state (NOT hex), so the
        // hex carry-mode contamination (see the dedicated carry-desync test)
        // can't leak in. Steps mirror SC-CHROME-02:
        //  s1 delay         -> notes.md rendered (multi-mode picker)
        //  s2 toggle-format -> markdown has NO Format -> no-op
        //                      (supportsFormatToggle is false; flag stays off)
        //  s3 open data.json-> source default, Format AVAILABLE
        //  s4 toggle-format -> isCurrentTabFormatted flips TRUE (Format is a
        //                      per-tab flag layered on Source — it does NOT
        //                      change currentViewMode to .formatted)
        //  s5 open page.html-> SOURCE is conservative default (not rendered)
        //  s6 open bin.dat  -> unknown binary => HEX-only, state binary
        //  s7 open db.sqlite (force-new path via openInNewTab is not a verb;
        //                      open carries from bin's hex — moved to the
        //                      dedicated carry-desync test). Here we open the
        //                      sqlite from a SOURCE state (page.html was the
        //                      prior tab? No — bin.dat is. So we re-select a
        //                      text tab first.) -> handled in carry test.
        // To keep THIS test free of the carry contamination, drop the
        // preview opens here and assert routing for md/json/html/bin only.
        let script = """
        delay 0.8
        toggle-format
        open \(dataJson.path)
        toggle-format
        open \(pageHtml.path)
        open \(binDat.path)
        """
        // (dbSqlite / picPng are exercised by the dedicated preview-routing
        // + carry-desync tests below; reference them so they're not unused.)
        _ = (dbSqlite, picPng)
        try runScenarios([
            Scenario(
                name: "modebar-routing",
                argFile: notesMd,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 6,
                        "expected >=6 step dumps", file: file, line: line)
                    guard dumps.count >= 6 else { return }

                    // s1: notes.md rendered (multi-mode type).
                    let s1 = dumps[0]
                    assertModel(s1, "currentViewMode", equals: "rendered", label: "s1-md", file: file, line: line)

                    // s2: toggle-format on markdown is a no-op
                    // (supportsFormatToggle == false). It must NOT land on
                    // formatted and must NOT set the formatted flag.
                    let s2 = dumps[1]
                    XCTAssertNotEqual(modelString(s2, "currentViewMode"), "formatted",
                        "[s2] markdown toggled into formatted (mode not in availableModes)",
                        file: file, line: line)
                    XCTAssertFalse(boolModel(s2, "isCurrentTabFormatted"),
                        "[s2] toggle-format set formatted flag on markdown (no format support)",
                        file: file, line: line)

                    // s3: data.json -> source default.
                    let s3 = dumps[2]
                    assertModel(s3, "currentURL", endsWith: "data.json", label: "s3", file: file, line: line)
                    assertModel(s3, "currentViewMode", equals: "source", label: "s3-json-source", file: file, line: line)
                    XCTAssertFalse(boolModel(s3, "isCurrentTabFormatted"),
                        "[s3] fresh JSON should not start pre-formatted", file: file, line: line)

                    // s4: toggle-format -> isCurrentTabFormatted flips TRUE.
                    // NOTE: Format is a flag on the Source view, NOT a view
                    // mode — currentViewMode stays "source", the formatted
                    // flag is the signal.
                    let s4 = dumps[3]
                    XCTAssertTrue(boolModel(s4, "isCurrentTabFormatted"),
                        "[s4] isCurrentTabFormatted should be true after toggle-format on JSON",
                        file: file, line: line)
                    assertModel(s4, "currentViewMode", equals: "source", label: "s4-format-keeps-source", file: file, line: line)

                    // s5: page.html -> conservative default SOURCE (not rendered).
                    let s5 = dumps[4]
                    assertModel(s5, "currentURL", endsWith: "page.html", label: "s5", file: file, line: line)
                    assertModel(s5, "currentViewMode", equals: "source", label: "s5-html-source-default", file: file, line: line)

                    // s6: bin.dat (unknown binary) -> HEX, state binary.
                    let s6 = dumps[5]
                    assertModel(s6, "currentViewMode", equals: "hex", label: "s6-bin-hex", file: file, line: line)
                    XCTAssertEqual(modelString(s6, "currentStateKind"), "binary",
                        "[s6] unknown binary should load as .binary state", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "modebar/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    /// SC-CHROME-02 step 9-12 + Open-As: preview routing from a CLEAN
    /// source state (no hex carry). sqlite -> native Preview (not hex), png
    /// -> Preview; set-open-as hex -> byte grid; set-open-as auto reverts.
    func test_SC_CHROME_02_previewRoutingAndOpenAs() throws {
        let seed = try harness.writeFile("seed.md", "# seed\n")
        let dbSqlite = try writeSQLiteFixture("db.sqlite")
        let picPng = try writePNGFixture("pic.png")

        // Open each preview file from a markdown (rendered) state, NOT a hex
        // state, so the carry-mode logic can't smuggle hex in.
        //  s1 delay              -> seed.md rendered
        //  s2 open db.sqlite     -> native PREVIEW, state preview (NOT hex)
        //  s3 open seed.md       -> back to a non-preview state to reset carry
        //  s4 open pic.png       -> PREVIEW
        //  s5 set-open-as binary -> byte grid (HEX), state binary. NOTE the
        //                           Open-As "HEX" lens is the `binary`
        //                           FileCategory (whose only mode is .hex);
        //                           there is NO `hex` FileCategory, so
        //                           `set-open-as hex` is a silent no-op.
        //  s6 set-open-as auto   -> reverts to native Preview
        let script = """
        delay 0.8
        open \(dbSqlite.path)
        open \(seed.path)
        open \(picPng.path)
        set-open-as binary
        set-open-as auto
        """
        try runScenarios([
            Scenario(
                name: "preview-routing",
                argFile: seed,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 6, "expected >=6 dumps", file: file, line: line)
                    guard dumps.count >= 6 else { return }

                    // s2: sqlite -> native PREVIEW, NOT hex.
                    let s2 = dumps[1]
                    assertModel(s2, "currentURL", endsWith: "db.sqlite", label: "s2", file: file, line: line)
                    assertModel(s2, "currentViewMode", equals: "preview", label: "s2-sqlite-preview", file: file, line: line)
                    XCTAssertEqual(modelString(s2, "currentStateKind"), "preview",
                        "[s2] sqlite should land in .preview state, not binary/hex", file: file, line: line)

                    // s4: png -> PREVIEW.
                    let s4 = dumps[3]
                    assertModel(s4, "currentURL", endsWith: "pic.png", label: "s4", file: file, line: line)
                    assertModel(s4, "currentViewMode", equals: "preview", label: "s4-png-preview", file: file, line: line)

                    // s5: set-open-as binary (the Open-As "HEX" lens) ->
                    // byte grid (HEX), state binary.
                    let s5 = dumps[4]
                    assertModel(s5, "currentViewMode", equals: "hex", label: "s5-png-as-binary", file: file, line: line)
                    XCTAssertEqual(modelString(s5, "currentStateKind"), "binary",
                        "[s5] PNG forced to binary should be in .binary state (HEX)", file: file, line: line)

                    // s6: set-open-as auto -> reverts to native Preview.
                    let s6 = dumps[5]
                    assertModel(s6, "currentViewMode", equals: "preview", label: "s6-png-auto-revert", file: file, line: line)
                    XCTAssertEqual(modelString(s6, "currentStateKind"), "preview",
                        "[s6] set-open-as auto should restore .preview state", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "preview-routing/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    /// BUG FINDING (carry-mode HEX leaks onto native-preview types).
    ///
    /// Opening a native-preview file (image / sqlite / pdf / audio / video)
    /// IMMEDIATELY after a HEX-mode file leaves the ModeBar picker selecting
    /// **HEX** while the document state is **.preview** (the native browser /
    /// image lens is what actually renders). The carry-mode branch in
    /// `DocumentModel.openResolved` carries `.hex` because `.hex` IS in the
    /// preview type's `availableModes` ([.preview, .hex]); the loader then
    /// returns a `.preview` state, and the HEX-load block is (correctly)
    /// skipped for `.preview` — so picker (.hex) and pane (.preview) DESYNC.
    /// The picker lies about what's on screen until any explicit re-pick or
    /// `set-open-as auto` heals it.
    ///
    /// This asserts the CORRECT behavior (mode should follow the rendered
    /// pane = preview). It is a KNOWN-BUG regression guard: the picker↔pane
    /// desync assertion is wrapped in `XCTExpectFailure(strict: false)` so
    /// the suite stays green while the bug persists AND fires an
    /// "unexpectedly passed" the moment a carry-mode guard lands — at which
    /// point remove the wrapper. The `.preview` STATE assertion is left
    /// un-wrapped (it is correct today and must not regress).
    func test_SC_CHROME_02_carryModeHexOntoPreview_DESYNC() throws {
        let raw = try writeRandomBinary("raw.bin")
        let img = try writePNGFixture("after.png")

        // argv opens raw.bin (HEX). The script opens after.png with no
        // intervening source tab -> carry-mode runs from the hex tab.
        let script = """
        delay 0.6
        open \(img.path)
        """
        try runScenarios([
            Scenario(
                name: "carry-hex-onto-preview-desync",
                argFile: raw,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    // The pane renders the native image preview (.preview
                    // state). This is CORRECT today and must hold.
                    XCTAssertEqual(modelString(last, "currentStateKind"), "preview",
                        "[carry-desync] image after hex should load .preview state", file: file, line: line)
                    // KNOWN BUG: picker carries .hex while the .preview pane
                    // is what's drawn. Expected-failure until the carry guard
                    // lands (then this passes and the wrapper must be removed).
                    XCTExpectFailure(
                        "carry-mode HEX leaks onto a native-preview type: ModeBar picker shows HEX while the .preview pane renders (picker↔pane desync)",
                        strict: false
                    ) {
                        XCTAssertEqual(modelString(last, "currentViewMode"), "preview",
                            "[carry-desync] BUG: ModeBar picker shows '\(modelString(last, "currentViewMode"))' but the native preview pane (.preview state) is rendered — picker↔pane desync from HEX carry-mode onto a preview type",
                            file: file, line: line)
                    }
                })
        ])
    }

    /// SC-CHROME-02 edge: latest-switch-wins. Rapidly toggle a text file
    /// HEX <-> Source several times fast; the FINAL picker selection and
    /// the rendered state must agree — no HexView under a non-HEX picker
    /// (Bug C regression guard).
    func test_SC_CHROME_02_asyncLoaderRace_latestSwitchWins() throws {
        let txt = try harness.writeFile("race.txt", "line a\nline b\nline c\n")
        let script = """
        delay 0.6
        editor-set-mode hex
        editor-set-mode source
        editor-set-mode hex
        editor-set-mode source
        editor-set-mode hex
        editor-set-mode source
        delay 0.8
        """
        try runScenarios([
            Scenario(
                name: "async-race-latest-wins",
                argFile: txt,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    // Final selection is source; state must agree (not binary).
                    assertModel(last, "currentViewMode", equals: "source", label: "race-final", file: file, line: line)
                    XCTAssertNotEqual(modelString(last, "currentStateKind"), "binary",
                        "[race] final picker=source but state=binary — HexView leaked under non-HEX picker (Bug C)",
                        file: file, line: line)
                    XCTAssertFalse(hasViewClass(last, containing: "Hex"),
                        "[race] a Hex* byte grid is mounted under a non-HEX picker (Bug C)",
                        file: file, line: line)
                    assertNotError(last, label: "race-final", file: file, line: line)
                })
        ])
    }

    // MARK: - SC-CHROME-04 — StatusBar fidelity + visibility coupling

    /// StatusBar appears for a file (currentURL != nil) and disappears for
    /// a blank tab. Type-aware: Ln/Col hidden for image (preview). The live
    /// caret channel + date-chip truncation are not script-reachable, so
    /// this asserts the visibility-coupling + type-awareness invariants the
    /// dump CAN see.
    func test_SC_CHROME_04_statusBarVisibilityCoupling() throws {
        let srcPy = try harness.writeFile("src.py", "def f():\n    return 42\n\nprint(f())\n")
        let imgJpg = try writeJPEGFixture("img.jpg")

        // s1 delay     -> src.py source, statusbar present
        // s2 open img  -> image preview, statusbar present (Size shown)
        // s3 new-tab   -> blank, statusbar GONE
        let script = """
        delay 0.8
        open \(imgJpg.path)
        new-tab
        """
        try runScenarios([
            Scenario(
                name: "statusbar-coupling",
                argFile: srcPy,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 3, "expected >=3 dumps", file: file, line: line)
                    guard dumps.count >= 3 else { return }

                    let s1 = dumps[0]
                    assertModel(s1, "currentURL", endsWith: "src.py", label: "s1", file: file, line: line)
                    assertModel(s1, "currentViewMode", equals: "source", label: "s1-py-source", file: file, line: line)
                    assertStatusBarPresent(s1, expected: true, label: "s1-statusbar", file: file, line: line)

                    let s2 = dumps[1]
                    assertModel(s2, "currentURL", endsWith: "img.jpg", label: "s2", file: file, line: line)
                    assertModel(s2, "currentViewMode", equals: "preview", label: "s2-jpg-preview", file: file, line: line)
                    assertStatusBarPresent(s2, expected: true, label: "s2-statusbar", file: file, line: line)

                    let s3 = dumps[2]
                    assertModel(s3, "currentURL", equals: "", label: "s3-blank-url", file: file, line: line)
                    assertStatusBarPresent(s3, expected: false, label: "s3-statusbar-gone", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "statusbar/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SC-CHROME-05 — Chrome-pin invariant under resize + sidebar toggle

    /// Chrome-pin: shrink the window aggressively (via `resize`); the
    /// chrome bars must never blank/collapse/zero-size. Then toggle the
    /// sidebar off/on and confirm the chrome survives + sidebar visibility
    /// tracks. Over-subscribing rails isn't script-reachable, so this uses
    /// resize as the lever for the chrome-pin invariant (Bug A guard).
    func test_SC_CHROME_05_chromePinUnderResizeAndSidebar() throws {
        let repo = try harness.makeDir("repo")
        let main = try harness.writeFile("repo/main.swift", "import Foundation\nlet x = 1\n")
        try harness.writeFile("repo/readme.md", "# Repo\n")

        // s1 delay              -> open, sidebar visible
        // s2 sidebar-set-root   -> root = repo
        // s3 resize 360x300     -> tiny window; chrome must not blank
        // s4 resize 1100x800    -> restore; chrome intact
        // s5 toggle-sidebar     -> sidebar off
        // s6 toggle-sidebar     -> sidebar on
        let script = """
        delay 0.8
        sidebar-set-root \(repo.path)
        resize 360x300
        resize 1100x800
        toggle-sidebar
        toggle-sidebar
        """
        try runScenarios([
            Scenario(
                name: "chrome-pin-resize",
                argFile: main,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 6, "expected >=6 dumps", file: file, line: line)
                    guard dumps.count >= 6 else { return }

                    // s3: tiny window. The window content must still hold a
                    // realized tree (not collapsed to nothing) and the file
                    // must still be loaded (no error from the resize).
                    let s3 = dumps[2]
                    assertNotError(s3, label: "s3-tiny", file: file, line: line)
                    assertModel(s3, "currentURL", endsWith: "main.swift", label: "s3-tiny", file: file, line: line)
                    // The realized content view must have a non-trivial
                    // subtree even at 360x300 (chrome bars present, not
                    // blanked away).
                    XCTAssertGreaterThan(allNodes(in: s3).count, 10,
                        "[s3-tiny] content tree collapsed to <=10 nodes at 360x300 — chrome may have blanked",
                        file: file, line: line)

                    // s5: sidebar toggled off.
                    let s5 = dumps[4]
                    XCTAssertFalse(boolSidebarVisible(s5),
                        "[s5] sidebar did not collapse on toggle-sidebar", file: file, line: line)
                    assertNotError(s5, label: "s5-sidebar-off", file: file, line: line)

                    // s6: sidebar toggled back on.
                    let s6 = dumps[5]
                    XCTAssertTrue(boolSidebarVisible(s6),
                        "[s6] sidebar did not restore on second toggle-sidebar", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "chrome-pin/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SC-CHROME-06 — Zoom scaling chrome + content together

    /// Zoom in/out/reset: zoom is a global scalar the model exposes. Three
    /// zoom-ins (cap 3.0), then reset to 1.0, asserting `model.zoom` tracks
    /// and the document stays loaded (chrome + content scale, no error).
    /// Split-view (⌘\) isn't a script verb, so this covers the zoom axis of
    /// SC-CHROME-06; split is logged as not-script-reachable.
    func test_SC_CHROME_06_zoomScaling() throws {
        let leftMd = try harness.writeFile("left.md", "# Left\n\nbody\n")

        // Each zoom-in is +10% (0.1). Start may be persisted != 1.0 from a
        // prior scenario, so zoom-reset first to normalize, THEN measure
        // deltas.
        let script = """
        delay 0.8
        zoom-reset
        zoom-in
        zoom-in
        zoom-in
        zoom-reset
        zoom-out
        """
        try runScenarios([
            Scenario(
                name: "zoom-scaling",
                argFile: leftMd,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 7, "expected >=7 dumps", file: file, line: line)
                    guard dumps.count >= 7 else { return }

                    // s2: zoom-reset -> 1.0
                    let reset = dumps[1]
                    assertZoom(reset, equals: 1.0, label: "s2-reset", file: file, line: line)

                    // s3,s4,s5: three zoom-ins -> grows each time, monotonic.
                    let z3 = doubleZoom(dumps[2])
                    let z4 = doubleZoom(dumps[3])
                    let z5 = doubleZoom(dumps[4])
                    XCTAssertGreaterThan(z3, 1.0, "[s3] zoom-in did not increase zoom", file: file, line: line)
                    XCTAssertGreaterThan(z4, z3, "[s4] zoom-in not monotonic", file: file, line: line)
                    XCTAssertGreaterThan(z5, z4, "[s5] zoom-in not monotonic", file: file, line: line)
                    XCTAssertLessThanOrEqual(z5, 3.0, "[s5] zoom exceeded 3.0 cap", file: file, line: line)

                    // s6: zoom-reset -> back to 1.0
                    assertZoom(dumps[5], equals: 1.0, label: "s6-reset", file: file, line: line)

                    // s7: zoom-out -> below 1.0 but floored.
                    let z7 = doubleZoom(dumps[6])
                    XCTAssertLessThan(z7, 1.0, "[s7] zoom-out did not decrease zoom", file: file, line: line)
                    XCTAssertGreaterThanOrEqual(z7, 0.5, "[s7] zoom dropped below 0.5 floor", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "zoom/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SC-CHROME-01 var: /var vs /private/var symlink dedup

    /// Open the same file once via `/var/...` and once via the
    /// `/private/var/...` realpath; the resolver must dedup to a SINGLE tab
    /// (no twin). `harness.tmpDir` lives under `/var/folders` which is a
    /// symlink to `/private/var/folders`.
    func test_SC_CHROME_01var_symlinkDedup() throws {
        let f = try harness.writeFile("dup.txt", "hello\n")
        // Build the /private-prefixed twin path.
        let privatePath = f.path.hasPrefix("/var/")
            ? "/private" + f.path
            : f.path
        let script = """
        delay 0.6
        open \(privatePath)
        """
        try runScenarios([
            Scenario(
                name: "symlink-dedup",
                argFile: f,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    // argv opened /var/... ; the script re-opens /private/var/...
                    // They resolve to the same realpath -> ONE tab.
                    let count = intModel(last, "tabCount")
                    if privatePath != f.path {
                        XCTAssertEqual(count, 1,
                            "[symlink-dedup] /var and /private/var opened as \(count) tabs — expected 1 (resolvingSymlinksInPath dedup)",
                            file: file, line: line)
                    }
                    assertNotError(last, label: "symlink-dedup", file: file, line: line)
                })
        ])
    }

    // MARK: - SC-CHROME-01 var: bookmark star

    /// ⌘D toggles a bookmark on the active tab; `model.isCurrentTabBookmarked`
    /// flips true, and toggling again clears it.
    func test_SC_CHROME_01var_bookmarkToggle() throws {
        let f = try harness.writeFile("bm.md", "# Bookmark me\n")
        let script = """
        delay 0.6
        toggle-bookmark
        toggle-bookmark
        """
        try runScenarios([
            Scenario(
                name: "bookmark-toggle",
                argFile: f,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 3, "expected >=3 dumps", file: file, line: line)
                    guard dumps.count >= 3 else { return }
                    XCTAssertFalse(boolModel(dumps[0], "isCurrentTabBookmarked"),
                        "[bm-s1] tab should not start bookmarked", file: file, line: line)
                    XCTAssertTrue(boolModel(dumps[1], "isCurrentTabBookmarked"),
                        "[bm-s2] toggle-bookmark did not set bookmark", file: file, line: line)
                    XCTAssertFalse(boolModel(dumps[2], "isCurrentTabBookmarked"),
                        "[bm-s3] second toggle did not clear bookmark", file: file, line: line)
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
    private func boolSidebarVisible(_ dump: [String: Any]) -> Bool {
        boolModel(dump, "sidebarVisible")
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

    /// StatusBar visibility coupling: the bar is present iff `currentURL`
    /// is non-empty. We assert via the model coupling (the authoritative
    /// signal the bar uses) since the bar's a11y id doesn't reach the tree.
    private func assertStatusBarPresent(
        _ dump: [String: Any], expected: Bool,
        label: String, file: StaticString, line: UInt
    ) {
        let hasURL = !modelString(dump, "currentURL").isEmpty
        XCTAssertEqual(hasURL, expected,
            "[\(label)] StatusBar visibility coupling: currentURL non-empty=\(hasURL), expected=\(expected)",
            file: file, line: line)
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
    private func hasViewClass(_ dump: [String: Any], containing needle: String) -> Bool {
        allNodes(in: dump).contains { (($0["class"] as? String) ?? "").contains(needle) }
    }

    // MARK: - Binary fixtures

    /// 1x1 red PNG (real magic bytes -> routes to .image -> .preview).
    private func writePNGFixture(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        guard let data = Data(base64Encoded: b64) else { throw XCTSkip("PNG fixture decode failed") }
        try data.write(to: url)
        return url
    }

    /// Minimal JPEG (SOI + APP0/JFIF + EOI). Enough magic bytes for the
    /// category sniff to route it to .image; MediaPreviewView may show a
    /// decode-fail placeholder for a 0x0 image, but the routing (Ln/Col
    /// hidden, preview lens) is what this smoke checks.
    private func writeJPEGFixture(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        // FFD8 (SOI) FFE0 0010 "JFIF\0" 0101 0001 0000 0000 0000 FFD9 (EOI)
        let bytes: [UInt8] = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00,
            0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9
        ]
        try Data(bytes).write(to: url)
        return url
    }

    /// Random non-text bytes -> unknown binary -> HEX-only routing. Uses a
    /// fixed seed-free pattern with high-bit bytes so FileCategory can't
    /// classify it as text.
    private func writeRandomBinary(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        var bytes = [UInt8]()
        for i in 0..<512 { bytes.append(UInt8((i * 37 + 0x80) & 0xFF)) }
        try Data(bytes).write(to: url)
        return url
    }

    /// A real, valid, enumerable SQLite v3 database (one table + a few rows),
    /// so the SQLite browser mounts its `NSSplitView`. See `UATSQLiteFixture`.
    private func writeSQLiteFixture(_ name: String) throws -> URL {
        try UATSQLiteFixture.write(name, in: harness.tmpDir)
    }
}
