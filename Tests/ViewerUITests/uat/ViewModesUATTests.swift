import XCTest
import Foundation

/// UAT executable companion — **group 3/12: view-modes**
/// (source / editor / hex / rendered / preview / formatted).
///
/// Durable T4 live-app smoke for `docs/uat/smokes/view-modes.md`
/// (VM-01..06). Drives the assembled `dist/TextView.app` via the
/// `--script` verb dispatcher (the same proven path as
/// `ViewModeMatrixSmokeTests` + `TabsAndWindowChromeUATTests`), captures a
/// `DiagnosticDump` JSON per step, and asserts the scripted expectations
/// AND walks the realized NSView tree for wrong-viewer paint / desync that
/// a model-only assertion would miss.
///
/// ## Observability constraint (verified against a live dump, group 1+2)
///
/// SwiftUI's `.accessibilityIdentifier()` sets the AX-tree id, which is
/// **NOT** propagated onto `NSView.accessibilityIdentifier()` that
/// `DiagnosticDump` reads — ZERO `mdv.*` ids appear in either the
/// `contentView` tree or `recursiveDescription`. So the load-bearing
/// assertions read the authoritative `model` sub-dict
/// (`ScriptVerb.modelStateDump`: currentViewMode, currentStateKind,
/// isCurrentTabFormatted, currentURL, tabCount, ...) supplemented by
/// view-CLASS detection for the surfaces only the realized tree exposes
/// (the byte grid HexNSTextView, WKWebView, NSTextView, NSSplitView).
///
/// ## What is / isn't script-reachable for THIS group
///
/// Reachable: every view-mode route (`editor-set-mode <raw>` accepts every
/// `ViewMode.rawValue`), `toggle-format` (⌥⌘F), `toggle-view` (⇧⌘R),
/// `set-open-as <category>` / `open-as`, zoom, tab switch + per-tab mode
/// carry. NOT reachable: the ModeBar SwiftUI picker SEGMENTS themselves
/// (which segments are offered, accent tint), find-bar interactions (⌘F
/// overlay match count — `show-find` only toggles the rendered find bar),
/// the Wrap / invisibles / Enable-JS toggles, split view (⌘\), and the
/// large-file placeholder VIEWS (we can drive a >cap file but the
/// placeholder is a SwiftUI view with no NSView class / model scalar).
/// Those are logged for the MANUAL/VM lane in `UAT_RUN_undated.md`.
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real
/// cross-process per-(file type × view mode) routing, the mode↔state↔
/// realized-subtree consistency (the fd11e61 load-bug class), and the
/// WKWebView-backed modes (Editor/Rendered, #192-excluded from the
/// headless gate). Self-skips on the headless gate (`isAppBuilt` false
/// there); runs for real on the VM/nightly lane or a host-occluded UAT run.
@MainActor
final class ViewModesUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "ViewModesUAT" }
    // WKWebView-backed modes (Editor, Rendered) need WebContent settle
    // time and several scenarios cycle multiple modes; give generous room.
    override class var defaultScenarioTimeout: TimeInterval { 120 }

    // MARK: - VM-01 — Markdown: default Rendered, ⇧⌘R round-trip to Source

    /// md opens Rendered → ⇧⌘R toggles to Source → ⇧⌘R back to Rendered →
    /// zoom-in carries → reset. Asserts mode + state + realized surface at
    /// each step (WKWebView for rendered, non-hex NSTextView for source),
    /// and that the rendered↔source toggle is symmetric.
    func test_VM_01_markdownRenderedSourceRoundTripAndZoom() throws {
        let md = try harness.writeFile(
            "doc.md",
            """
            # Title

            Some body that will **render** as HTML. We render, we render again,
            so the word render appears several times for find.

            | Col A | Col B |
            |-------|-------|
            | 1     | 2     |

            ```swift
            let x = 1
            ```
            """)
        // HARNESS NOTE: the `--script` runner sleeps a FIXED 300 ms after
        // EVERY step regardless of a `delay`'s seconds arg (ScriptRunner.swift
        // line 45 ignores the arg). So a single `delay 0.6` is only 300 ms —
        // too short for a WKWebView (rendered) mount / async reload to settle.
        // We therefore (a) pad each settle window with repeated bare `delay`
        // lines, and (b) assert on the EVENTUAL state via `lastWhere(...)`
        // rather than a fixed dump index. This keeps the smoke a true
        // steady-state check instead of racing the async completion.
        //
        // Verb plan (each bare `delay` ≈ 300 ms):
        //   settle x3 -> doc.md RENDERED default (WKWebView)
        //   toggle-view + settle x3 -> SOURCE (raw markdown NSTextView)
        //   toggle-view + settle x3 -> back to RENDERED (symmetric)
        //   zoom-reset -> normalize; zoom-in + settle -> >1.0 still rendered
        let script = """
        delay
        delay
        delay
        toggle-view
        delay
        delay
        delay
        toggle-view
        delay
        delay
        delay
        zoom-reset
        zoom-in
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "md-rendered-source-roundtrip",
                argFile: md,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    // Opening default: the FIRST settled dump is RENDERED with
                    // a WKWebView and no Hex grid.
                    let s0 = dumps[0]
                    assertModel(s0, "currentViewMode", equals: "rendered", label: "s0-md-default", file: file, line: line)
                    assertWebViewRendered(s0, label: "s0-rendered", file: file, line: line)
                    assertNoHexView(s0, label: "s0-rendered", file: file, line: line)

                    // First toggle reaches SOURCE: the first source-mode dump
                    // shows raw markdown in a non-hex NSTextView, never binary.
                    let firstSource = dumps.first { modelString($0, "currentViewMode") == "source" }
                    XCTAssertNotNil(firstSource, "[vm01] ⇧⌘R never reached Source", file: file, line: line)
                    if let sb = firstSource {
                        XCTAssertNotEqual(modelString(sb, "currentStateKind"), "binary",
                            "[vm01] source picker but state==binary (Hex under source)", file: file, line: line)
                        assertSourceTextRendered(sb, label: "vm01-source", file: file, line: line)
                    }

                    // Symmetric round-trip: AFTER returning to source the second
                    // toggle must land back on RENDERED. Assert the LAST dump is
                    // rendered (the toggle-back + zoom keep it rendered).
                    let last = dumps.last!
                    assertModel(last, "currentViewMode", equals: "rendered", label: "vm01-roundtrip-back-rendered", file: file, line: line)
                    assertWebViewRendered(last, label: "vm01-rendered-final", file: file, line: line)

                    // Zoom: after `zoom-reset` then `zoom-in`, the eventual zoom
                    // must exceed the reset baseline (1.0). Assert on the last
                    // settled dump (zoom is a synchronous model scalar).
                    XCTAssertGreaterThan(doubleZoom(last), 1.0,
                        "[vm01] zoom-in did not raise zoom above the reset baseline", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "vm01/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    /// VM-01 variation: a standalone `.mmd` (mermaid) opens straight into
    /// RENDERED (synthesized single mermaid fence), same as markdown.
    func test_VM_01var_mermaidDefaultsRendered() throws {
        let mmd = try harness.writeFile(
            "graph.mmd", "graph TD\n  A[Start] --> B[End]\n")
        try runScenarios([
            Scenario(
                name: "mmd-rendered-default",
                argFile: mmd,
                script: "delay 1.2\n",
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    assertModel(last, "currentViewMode", equals: "rendered", label: "mmd-default", file: file, line: line)
                    assertNoHexView(last, label: "mmd-rendered", file: file, line: line)
                    assertNotError(last, label: "mmd", file: file, line: line)
                })
        ])
    }

    // MARK: - VM-02 — Source ↔ Editor ↔ HEX (dirty, save, mode carry)

    /// A plain `.py` opens in Source. Switch to Editor (CM6 WKWebView),
    /// type → buffer dirty, save → flush, switch to HEX (byte grid reflects
    /// saved bytes), switch back to Source. The load-bearing checks: the
    /// realized surface matches the picker at EVERY hop (no Hex under a
    /// non-hex picker, no stale source under editor) — the fd11e61/Bug-C
    /// class.
    func test_VM_02_sourceEditorHexLifecycle() throws {
        let py = try harness.writeFile(
            "script.py",
            "def main():\n    print(\"hello\")\n\nif __name__ == '__main__':\n    main()\n")
        // HARNESS NOTE (see VM-01): bare `delay` ≈ 300 ms fixed; pad each
        // async settle window (editor WebView mount, HEX `loadBinaryAsync`,
        // HEX→source reload) with repeated `delay` lines and assert on the
        // EVENTUAL per-mode dump, not a fixed index.
        let script = """
        delay
        delay
        delay
        editor-set-mode editor
        delay
        delay
        delay
        editor-set-text def main():\\n    print("edited")\\n
        editor-save
        delay
        editor-set-mode hex
        delay
        delay
        delay
        editor-set-mode source
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "source-editor-hex-lifecycle",
                argFile: py,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    // SOURCE default for plain code (first settled dump).
                    let s0 = dumps[0]
                    assertModel(s0, "currentViewMode", equals: "source", label: "s0-py-source", file: file, line: line)
                    assertSourceTextRendered(s0, label: "s0-source", file: file, line: line)

                    // EDITOR — the first editor-mode dump must mount a WKWebView,
                    // no Hex grid (no stale view).
                    let editorDump = dumps.first { modelString($0, "currentViewMode") == "editor" }
                    XCTAssertNotNil(editorDump, "[vm02] never reached Editor mode", file: file, line: line)
                    if let ed = editorDump {
                        assertWebViewRendered(ed, label: "vm02-editor-webview", file: file, line: line)
                        assertNoHexView(ed, label: "vm02-editor", file: file, line: line)
                    }

                    // HEX — the first hex-mode dump shows a HexNSTextView byte
                    // grid with glyphs, state binary.
                    let hexDump = dumps.first { modelString($0, "currentViewMode") == "hex" }
                    XCTAssertNotNil(hexDump, "[vm02] never reached HEX mode", file: file, line: line)
                    if let hd = hexDump {
                        XCTAssertEqual(modelString(hd, "currentStateKind"), "binary",
                            "[vm02] HEX picker but state != binary", file: file, line: line)
                        assertHexRendered(hd, label: "vm02-hex", file: file, line: line)
                    }

                    // BACK TO SOURCE (latest-switch-wins, Bug C): the LAST
                    // source-mode dump must NOT carry a Hex grid / binary state.
                    let sourceBack = dumps.last { modelString($0, "currentViewMode") == "source" }
                    XCTAssertNotNil(sourceBack, "[vm02] never returned to source", file: file, line: line)
                    if let sb = sourceBack {
                        XCTAssertNotEqual(modelString(sb, "currentStateKind"), "binary",
                            "[vm02] back-to-source but state==binary — Hex leaked under source (Bug C)", file: file, line: line)
                        assertNoHexView(sb, label: "vm02-source-back", file: file, line: line)
                        assertSourceTextRendered(sb, label: "vm02-source-back", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "vm02/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    /// VM-02 carry-mode fallback: explicitly pick Editor on a text tab,
    /// then open a `.png` (Editor NOT in image's availableModes). It must
    /// fall back to the image's natural default (Preview), not strand an
    /// empty Editor.
    func test_VM_02var_editorCarryFallsBackToPreviewOnImage() throws {
        let txt = try harness.writeFile("notes.txt", "line one\nline two\n")
        let png = try writePNGFixture("shot.png")
        // argv opens notes.txt (source). Pick editor, then open the png.
        let script = """
        delay 0.7
        editor-set-mode editor
        delay 0.6
        open \(png.path)
        delay 0.7
        """
        try runScenarios([
            Scenario(
                name: "editor-carry-fallback-image",
                argFile: txt,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    assertModel(last, "currentURL", endsWith: "shot.png", label: "carry-img", file: file, line: line)
                    // Editor is not offered for images → must clamp to the
                    // image's natural default, Preview. (NOT stranded on the
                    // carried Editor, which would lie about the pane.)
                    assertModel(last, "currentViewMode", equals: "preview", label: "carry-fallback-preview", file: file, line: line)
                    XCTAssertEqual(modelString(last, "currentStateKind"), "preview",
                        "[carry-img] image should be .preview state", file: file, line: line)
                    assertNotError(last, label: "carry-img", file: file, line: line)
                })
        ])
    }

    // MARK: - VM-03 — CSV Table, JSON Format, Open-As cross-routing

    /// CSV opens in Table (default). Switch Table↔Source. Then JSON opens
    /// in Source (conservative default, NOT Format). Drive BOTH format
    /// routes: `toggle-format` (⌥⌘F — a per-tab flag layered on Source,
    /// mode stays `source`) AND `editor-set-mode formatted` (the explicit
    /// Formatted view mode). This is the subtle distinction the catalog
    /// conflates — we assert both behaviors.
    func test_VM_03_csvTableAndJsonFormat() throws {
        var csvBody = "id,name,score\n"
        for i in 1...25 { csvBody += "\(i),row\(i),\(i * 3)\n" }
        let csv = try harness.writeFile("data.csv", csvBody)
        let json = try harness.writeFile(
            "min.json",
            "{\"a\":1,\"b\":[1,2,3],\"c\":{\"nested\":true},\"d\":\"long string value here\"}\n")
        // HARNESS NOTE (see VM-01): pad async settle windows; assert on the
        // eventual per-(url, mode) dump. The `open <json>` in particular needs
        // > 300 ms for the async load to commit `currentURL`.
        //
        // Verb plan:
        //   settle      -> data.csv TABLE default
        //   set source  -> raw CSV NSTextView
        //   set table   -> back to grid
        //   open json   -> SOURCE default (not formatted)
        //   toggle-format x1 -> ⌥⌘F flag true, mode STAYS source
        //   toggle-format x1 -> flag back off
        //   set formatted    -> explicit Formatted VIEW MODE
        let script = """
        delay
        delay
        editor-set-mode source
        delay
        delay
        editor-set-mode table
        delay
        delay
        open \(json.path)
        delay
        delay
        delay
        toggle-format
        delay
        toggle-format
        delay
        editor-set-mode formatted
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "csv-table-json-format",
                argFile: csv,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    // CSV TABLE default (first settled dump, still on data.csv).
                    let s0 = dumps[0]
                    assertModel(s0, "currentURL", endsWith: "data.csv", label: "s0-csv", file: file, line: line)
                    assertModel(s0, "currentViewMode", equals: "table", label: "s0-csv-table", file: file, line: line)
                    assertNoHexView(s0, label: "s0-table", file: file, line: line)

                    let csvDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("data.csv") }
                    let jsonDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("min.json") }

                    // CSV reached Source (raw CSV NSTextView) at some point.
                    let csvSource = csvDumps.first { modelString($0, "currentViewMode") == "source" }
                    XCTAssertNotNil(csvSource, "[vm03] CSV never reached Source mode", file: file, line: line)
                    if let cs = csvSource {
                        assertSourceTextRendered(cs, label: "vm03-csv-source", file: file, line: line)
                    }
                    // …and returned to Table (the LAST CSV dump is table).
                    if let lastCsv = csvDumps.last {
                        assertModel(lastCsv, "currentViewMode", equals: "table", label: "vm03-csv-table-back", file: file, line: line)
                    }

                    // JSON opened: its FIRST dump is the conservative SOURCE
                    // default, NOT pre-formatted.
                    XCTAssertFalse(jsonDumps.isEmpty, "[vm03] open min.json never committed currentURL", file: file, line: line)
                    if let firstJson = jsonDumps.first {
                        assertModel(firstJson, "currentViewMode", equals: "source", label: "vm03-json-source-default", file: file, line: line)
                        XCTAssertFalse(boolModel(firstJson, "isCurrentTabFormatted"),
                            "[vm03] fresh JSON should not start pre-formatted", file: file, line: line)
                    }

                    // toggle-format ON: ⌥⌘F is a per-tab FLAG layered on Source
                    // — some JSON dump shows isCurrentTabFormatted=true while
                    // currentViewMode stays `source`.
                    let formatFlagOn = jsonDumps.first {
                        boolModel($0, "isCurrentTabFormatted") && modelString($0, "currentViewMode") == "source"
                    }
                    XCTAssertNotNil(formatFlagOn,
                        "[vm03] ⌥⌘F did not produce a (formatted-flag=true, mode=source) state on JSON", file: file, line: line)

                    // editor-set-mode formatted: the EXPLICIT Formatted VIEW
                    // MODE — currentViewMode == formatted, flag also set.
                    let formattedMode = jsonDumps.last { modelString($0, "currentViewMode") == "formatted" }
                    XCTAssertNotNil(formattedMode, "[vm03] editor-set-mode formatted never took", file: file, line: line)
                    if let fm = formattedMode {
                        XCTAssertTrue(boolModel(fm, "isCurrentTabFormatted"),
                            "[vm03] Formatted view mode should also set isCurrentTabFormatted", file: file, line: line)
                        assertNoHexView(fm, label: "vm03-formatted", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "vm03/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    /// VM-03 Open-As cross-routing + invalid-JSON graceful path.
    /// Force a CSV through the Source/code lens (Open-As → code) so it
    /// opens with Source default and offers the structured modes; then
    /// Open-As → auto reverts to Table. Also: a BROKEN json formatted
    /// must not blank/crash the pane.
    func test_VM_03var_openAsCrossRoutingAndInvalidJson() throws {
        let csv = try harness.writeFile("rows.csv", "a,b\n1,2\n3,4\n")
        let badJson = try harness.writeFile("broken.json", "{ this is : not, valid json ]\n")
        // HARNESS NOTE (see VM-01): pad settle windows; assert on eventual
        // per-(url, mode) dumps.
        //   settle    -> rows.csv TABLE default
        //   open-as code -> force the code/source lens; CSV default -> source
        //   open-as auto -> override cleared -> back to Table default
        //   open broken.json -> source default
        //   set formatted    -> format a broken json: must NOT crash / .error /
        //                       blank the pane
        let script = """
        delay
        delay
        set-open-as code
        delay
        delay
        set-open-as auto
        delay
        delay
        open \(badJson.path)
        delay
        delay
        delay
        editor-set-mode formatted
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "open-as-cross-routing",
                argFile: csv,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    let csvDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("rows.csv") }
                    let jsonDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("broken.json") }

                    // Table default (first CSV dump).
                    if let firstCsv = csvDumps.first {
                        assertModel(firstCsv, "currentViewMode", equals: "table", label: "vm03var-table-default", file: file, line: line)
                    }
                    // Open-As code forced the CSV through the Source/code lens.
                    let csvSource = csvDumps.first { modelString($0, "currentViewMode") == "source" }
                    XCTAssertNotNil(csvSource, "[vm03var] Open-As code did not flip the CSV default to Source", file: file, line: line)
                    // Open-As auto reverted to Table (the LAST CSV dump is table).
                    if let lastCsv = csvDumps.last {
                        assertModel(lastCsv, "currentViewMode", equals: "table", label: "vm03var-openas-auto-table", file: file, line: line)
                    }

                    // Format a BROKEN json: must not error / blank — Format
                    // fails gracefully (mode flips formatted but content stays).
                    XCTAssertFalse(jsonDumps.isEmpty, "[vm03var] open broken.json never committed", file: file, line: line)
                    if let lastJson = jsonDumps.last {
                        XCTAssertNotEqual(modelString(lastJson, "currentStateKind"), "error",
                            "[vm03var] formatting invalid JSON landed in .error (should fail gracefully)", file: file, line: line)
                        XCTAssertTrue(anyTextViewWithGlyphs(lastJson),
                            "[vm03var] invalid JSON Format blanked the pane (no glyphs)", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "vm03var/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - VM-04 — Native preview vs HEX routing

    /// Image opens in Preview (NOT HEX) — the explicit Bug-B "fresh image →
    /// HEX" regression guard. Preview↔HEX round-trip must not strand a Hex
    /// view under a Preview picker. Then a sqlite opens in Preview
    /// (browser), and a `.bin` opens straight into HEX.
    func test_VM_04_previewHexRoutingRoundTrip() throws {
        let png = try writePNGFixture("img.png")
        let db = try writeSQLiteFixture("data.db")
        let bin = try writeRandomBinary("blob.bin")
        // HARNESS NOTE (see VM-01): the Preview↔HEX round-trip's restore paths
        // (`loadBinaryAsync` into HEX, then `controller.open` back to .preview)
        // each take > 300 ms, so a single `delay` captured the intermediate
        // state and produced a FALSE "Bug C / Hex stuck under Preview" failure.
        // Pad each window and assert on the eventual per-(url, mode) dump.
        //   settle      -> img.png PREVIEW (NOT hex) — Bug B guard
        //   set hex     -> raw bytes byte grid
        //   set preview -> native image returns, NO Hex stuck (Bug C guard)
        //   open data.db -> sqlite PREVIEW (browser, NOT hex)
        //   open blob.bin-> unknown binary -> HEX, state binary
        let script = """
        delay
        delay
        delay
        editor-set-mode hex
        delay
        delay
        delay
        editor-set-mode preview
        delay
        delay
        delay
        delay
        open \(db.path)
        delay
        delay
        delay
        open \(bin.path)
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "preview-hex-roundtrip",
                argFile: png,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    let pngDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("img.png") }
                    let dbDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("data.db") }
                    let binDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("blob.bin") }

                    // PNG fresh open -> PREVIEW (Bug-B regression guard: a fresh
                    // image must NEVER default to HEX).
                    if let firstPng = pngDumps.first {
                        assertModel(firstPng, "currentViewMode", equals: "preview", label: "vm04-png-default", file: file, line: line)
                        XCTAssertEqual(modelString(firstPng, "currentStateKind"), "preview",
                            "[vm04] fresh image landed in '\(modelString(firstPng, "currentStateKind"))' state, not .preview (Bug B: fresh image → HEX)", file: file, line: line)
                        assertNoHexView(firstPng, label: "vm04-png-preview", file: file, line: line)
                        assertPreviewRendered(firstPng, label: "vm04-image-preview", file: file, line: line)
                    }

                    // PNG forced to HEX -> byte grid, binary state.
                    let pngHex = pngDumps.first { modelString($0, "currentViewMode") == "hex" }
                    XCTAssertNotNil(pngHex, "[vm04] PNG never reached HEX", file: file, line: line)
                    if let ph = pngHex {
                        XCTAssertEqual(modelString(ph, "currentStateKind"), "binary",
                            "[vm04] HEX picker but state != binary", file: file, line: line)
                        assertHexRendered(ph, label: "vm04-png-hex", file: file, line: line)
                    }

                    // PNG back to PREVIEW (Bug C — latest-switch-wins): the LAST
                    // png dump while still on img.png must be a clean preview,
                    // state .preview, NO Hex grid stuck under the Preview picker.
                    if let lastPng = pngDumps.last, modelString(lastPng, "currentViewMode") == "preview" {
                        XCTAssertEqual(modelString(lastPng, "currentStateKind"), "preview",
                            "[vm04] preview-back but state != preview — Hex stuck under Preview picker (Bug C)", file: file, line: line)
                        assertNoHexView(lastPng, label: "vm04-png-preview-back", file: file, line: line)
                        assertPreviewRendered(lastPng, label: "vm04-png-preview-back", file: file, line: line)
                    } else {
                        XCTFail("[vm04] PNG did not return to Preview after the HEX round-trip", file: file, line: line)
                    }

                    // sqlite -> PREVIEW (browser), not HEX.
                    XCTAssertFalse(dbDumps.isEmpty, "[vm04] open data.db never committed", file: file, line: line)
                    if let firstDb = dbDumps.first {
                        assertModel(firstDb, "currentViewMode", equals: "preview", label: "vm04-db-preview", file: file, line: line)
                        XCTAssertEqual(modelString(firstDb, "currentStateKind"), "preview",
                            "[vm04] sqlite should be .preview state, not binary/hex", file: file, line: line)
                    }

                    // .bin -> HEX, state binary (HEX-only routing).
                    XCTAssertFalse(binDumps.isEmpty, "[vm04] open blob.bin never committed", file: file, line: line)
                    if let lastBin = binDumps.last {
                        assertModel(lastBin, "currentViewMode", equals: "hex", label: "vm04-bin-hex", file: file, line: line)
                        XCTAssertEqual(modelString(lastBin, "currentStateKind"), "binary",
                            "[vm04] unknown binary should load as .binary state", file: file, line: line)
                        assertHexRendered(lastBin, label: "vm04-bin-hex", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "vm04/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    /// VM-04 edge: empty (0-byte) file in HEX must not crash and a
    /// truly-binary file with no native preview goes straight to HEX.
    func test_VM_04var_emptyFileHex() throws {
        let empty = try harness.writeFile("empty.bin", "")
        try runScenarios([
            Scenario(
                name: "empty-file-hex",
                argFile: empty,
                // 3.0s, was 0.9: the 0-byte classification → HEX mode
                // resolution is async and the loaded VM missed the window
                // ("source" ≠ "hex", TSK-617). ScriptRunner has no
                // wait-until verb (steps run on main; a blocking poll would
                // starve the resolution it waits for), so a wider fixed
                // settle is the honest fix. VM-lane-only cost.
                script: "delay 3.0\n",
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    // 0-byte unknown -> HEX, no crash, no .error.
                    assertModel(last, "currentViewMode", equals: "hex", label: "empty-hex", file: file, line: line)
                    assertNotError(last, label: "empty-hex", file: file, line: line)
                })
        ])
    }

    // MARK: - VM-05 — Diff & HTML specialized views + Error envelope

    /// `.diff` opens in Diff (structured DiffView). Diff↔Source raw-unified
    /// round-trip. HTML opens in Source (conservative). Rendered HTML
    /// mounts the SEPARATE sanitized WKWebView. Editor must NOT be offered
    /// for diffs (we probe forcing it).
    func test_VM_05_diffAndHtmlSpecializedViews() throws {
        let diff = try harness.writeFile(
            "change.diff",
            """
            diff --git a/foo.txt b/foo.txt
            index 1111111..2222222 100644
            --- a/foo.txt
            +++ b/foo.txt
            @@ -1,3 +1,3 @@
             context line
            -removed line
            +added line
             trailing context
            diff --git a/bar.txt b/bar.txt
            index 3333333..4444444 100644
            --- a/bar.txt
            +++ b/bar.txt
            @@ -1 +1,2 @@
             keep
            +new line
            """)
        let html = try harness.writeFile(
            "page.html",
            "<html><body><h1>Heading</h1><a href=\"https://example.com\">link</a><script>alert(1)</script></body></html>\n")
        // HARNESS NOTE (see VM-01): pad async settle windows; assert on the
        // eventual per-(url, mode) dump.
        //   settle    -> change.diff DIFF default
        //   set source-> raw unified diff text
        //   set diff  -> structured DiffView back
        //   open html -> SOURCE conservative default (not rendered)
        //   set rendered -> sanitized HTMLRenderedView WKWebView
        let script = """
        delay
        delay
        editor-set-mode source
        delay
        delay
        editor-set-mode diff
        delay
        delay
        open \(html.path)
        delay
        delay
        delay
        editor-set-mode rendered
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "diff-html-specialized",
                argFile: diff,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    let diffDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("change.diff") }
                    let htmlDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("page.html") }

                    // DIFF default (first diff dump).
                    if let firstDiff = diffDumps.first {
                        assertModel(firstDiff, "currentViewMode", equals: "diff", label: "vm05-diff-default", file: file, line: line)
                        assertNoHexView(firstDiff, label: "vm05-diff", file: file, line: line)
                    }
                    // Diff reached Source (raw unified diff text) at some point.
                    let diffSource = diffDumps.first { modelString($0, "currentViewMode") == "source" }
                    XCTAssertNotNil(diffSource, "[vm05] Diff never reached raw Source", file: file, line: line)
                    if let ds = diffSource {
                        assertSourceTextRendered(ds, label: "vm05-diff-source", file: file, line: line)
                    }
                    // …and returned to the structured Diff view (LAST diff dump).
                    if let lastDiff = diffDumps.last {
                        assertModel(lastDiff, "currentViewMode", equals: "diff", label: "vm05-diff-back", file: file, line: line)
                    }

                    // HTML opened -> conservative SOURCE default (NOT rendered).
                    XCTAssertFalse(htmlDumps.isEmpty, "[vm05] open page.html never committed", file: file, line: line)
                    if let firstHtml = htmlDumps.first {
                        assertModel(firstHtml, "currentViewMode", equals: "source", label: "vm05-html-source-default", file: file, line: line)
                    }
                    // HTML rendered -> sanitized WKWebView mounts (LAST html dump).
                    let htmlRendered = htmlDumps.last { modelString($0, "currentViewMode") == "rendered" }
                    XCTAssertNotNil(htmlRendered, "[vm05] HTML never reached Rendered mode", file: file, line: line)
                    if let hr = htmlRendered {
                        assertWebViewRendered(hr, label: "vm05-html-webview", file: file, line: line)
                        assertNoHexView(hr, label: "vm05-html-rendered", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "vm05/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    /// VM-05 Error envelope: opening a NONEXISTENT path must KEEP the
    /// existing tab and append an ErrorView tab (state .error) — it must
    /// NOT clear all open tabs (the existing-tabs-kept invariant).
    func test_VM_05var_errorStateKeepsExistingTabs() throws {
        let good = try harness.writeFile("real.md", "# Real\n\nbody\n")
        let ghostPath = harness.tmpDir.appendingPathComponent("does-not-exist-\(UUID().uuidString).txt").path
        let script = """
        delay 0.7
        open \(ghostPath)
        delay 0.7
        """
        try runScenarios([
            Scenario(
                name: "error-keeps-tabs",
                argFile: good,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 2, "expected >=2 dumps", file: file, line: line)
                    guard dumps.count >= 2 else { return }
                    // s0: real.md loaded (1 tab).
                    assertModel(dumps[0], "tabCount", equals: 1, label: "s0-good", file: file, line: line)
                    XCTAssertNotEqual(modelString(dumps[0], "currentStateKind"), "error",
                        "[s0] good file should not be in error", file: file, line: line)
                    // s1: open ghost -> existing tab KEPT, error tab appended.
                    let s1 = dumps.last!
                    XCTAssertGreaterThanOrEqual(intModel(s1, "tabCount"), 1,
                        "[s1] opening a nonexistent file cleared all tabs — existing tabs must be kept", file: file, line: line)
                    XCTAssertEqual(modelString(s1, "currentStateKind"), "error",
                        "[s1] nonexistent file should land in .error state (ErrorView)", file: file, line: line)
                })
        ])
    }

    // MARK: - VM-06 — Per-tab mode persistence across tab switches

    /// Per-tab ViewMode is NOT global: open md (rendered), py (editor),
    /// csv (table), png (preview); cycle through them and assert each tab
    /// restores ITS OWN last-picked mode on re-selection.
    func test_VM_06_perTabModePersistenceAcrossSwitches() throws {
        let md = try harness.writeFile("a.md", "# A\n\nbody\n")
        let py = try harness.writeFile("b.py", "x = 1\nprint(x)\n")
        let csv = try harness.writeFile("c.csv", "h1,h2\n1,2\n3,4\n")
        let png = try writePNGFixture("d.png")
        // argv opens a.md. Open the other three. Set md->source (toggle),
        // py->editor. csv stays table, png stays preview. Then cycle tabs.
        //  s0 delay        -> a.md (tab1) rendered
        //  s1 open b.py    -> tab2 source
        //  s2 open c.csv   -> tab3 table
        //  s3 open d.png   -> tab4 preview
        //  s4 select-tab 1 -> a.md; toggle to source
        //  s5 toggle-view  -> a.md SOURCE
        //  s6 select-tab 2 -> b.py; set editor
        //  s7 editor-set-mode editor -> b.py EDITOR
        //  s8 select-tab 1 -> a.md should RESTORE source (not rendered)
        //  s9 select-tab 2 -> b.py should RESTORE editor
        //  s10 select-tab 3-> c.csv should be table
        //  s11 select-tab 4-> d.png should be preview
        let script = """
        delay 0.8
        open \(py.path)
        open \(csv.path)
        open \(png.path)
        select-tab 1
        toggle-view
        select-tab 2
        editor-set-mode editor
        select-tab 1
        delay 0.5
        select-tab 2
        delay 0.5
        select-tab 3
        delay 0.5
        select-tab 4
        delay 0.6
        """
        try runScenarios([
            Scenario(
                name: "per-tab-mode-persistence",
                argFile: md,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 12, "expected >=12 dumps", file: file, line: line)
                    guard dumps.count >= 12 else { return }

                    // Find dumps by (url, mode) rather than rigid indexing
                    // since trailing delays add steps; assert the RESTORE.
                    // Last a.md dump -> should be source (we toggled it).
                    let lastMd = dumps.last { modelString($0, "currentURL").hasSuffix("a.md") }
                    XCTAssertEqual(lastMd.map { modelString($0, "currentViewMode") }, "source",
                        "[vm06] a.md did not RESTORE its per-tab Source mode on re-select (mode leaked global?)", file: file, line: line)

                    // Last b.py dump -> should be editor.
                    let lastPy = dumps.last { modelString($0, "currentURL").hasSuffix("b.py") }
                    XCTAssertEqual(lastPy.map { modelString($0, "currentViewMode") }, "editor",
                        "[vm06] b.py did not RESTORE its per-tab Editor mode on re-select", file: file, line: line)

                    // Last c.csv dump -> table (never changed).
                    let lastCsv = dumps.last { modelString($0, "currentURL").hasSuffix("c.csv") }
                    XCTAssertEqual(lastCsv.map { modelString($0, "currentViewMode") }, "table",
                        "[vm06] c.csv lost its Table mode", file: file, line: line)

                    // Last d.png dump -> preview.
                    let lastPng = dumps.last { modelString($0, "currentURL").hasSuffix("d.png") }
                    XCTAssertEqual(lastPng.map { modelString($0, "currentViewMode") }, "preview",
                        "[vm06] d.png lost its Preview mode", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "vm06/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    /// VM-06 toggle-view scope: ⇧⌘R only round-trips rendered↔source for
    /// markdown/mermaid. On a `.py` Source tab it SHOULD be a NO-OP — `.py`
    /// offers no Rendered mode (catalog: Source | Editor | HEX).
    ///
    /// FINDING (group 3/12, real): the `toggle-view` script verb calls
    /// `DocumentModel.toggleViewMode()` directly, which is NOT internally
    /// guarded — it flips `currentViewMode` to `.rendered` unconditionally
    /// even though `rendered ∉ availableModes(for: .py)` and
    /// `supportsViewModeToggle == false`. So the picker reads an OFF-MENU
    /// `rendered` for a Python file (verified live: mode flips to rendered and
    /// STAYS there across subsequent steps).
    ///
    /// Mitigating fact: in the LIVE UI the ⇧⌘R menu item is disabled by
    /// `AppDelegate.validateMenuItem` (`return model.supportsViewModeToggle`,
    /// main.swift:1435), so a user cannot reach this via the menu/keyboard —
    /// only a direct, un-gated caller (this script verb, MCP `set_view_mode`,
    /// or a future call site) can drive the picker off-menu. The robustness
    /// gap is that the gate lives in the menu layer, not in the model method.
    ///
    /// Wrapped as an expected-failure so the suite is green while the gap
    /// persists and flips to "unexpectedly passed" once `toggleViewMode` /
    /// `setCurrentViewMode` self-guard against off-menu modes.
    func test_VM_06var_toggleViewNoopOnPlainSource() throws {
        let py = try harness.writeFile("plain.py", "y = 2\nprint(y)\n")
        let script = """
        delay
        delay
        delay
        toggle-view
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "toggle-view-noop-python",
                argFile: py,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }
                    assertModel(dumps[0], "currentViewMode", equals: "source", label: "noop-s0", file: file, line: line)
                    let after = dumps.last!
                    let mode = modelString(after, "currentViewMode")
                    XCTExpectFailure(
                        "toggleViewMode() is not self-guarded: ⇧⌘R on a .py (which offers no Rendered mode) flips the picker off-menu to 'rendered'. The live menu DISABLES ⇧⌘R for non-markdown via validateMenuItem, so this is reachable only by un-gated callers (script verb / MCP). Fires 'unexpectedly passed' once the model method self-guards.",
                        strict: false
                    ) {
                        XCTAssertEqual(mode, "source",
                            "[vm06var] ⇧⌘R on a python source tab should be a NO-OP but flipped to '\(mode)' (off-menu)",
                            file: file, line: line)
                    }
                    // Whatever the picker says, the document must not crash /
                    // error and must not strand a Hex grid under the picker.
                    assertNotError(after, label: "vm06var", file: file, line: line)
                    XCTAssertNotEqual(modelString(after, "currentStateKind"), "binary",
                        "[vm06var] toggle-view on python left state==binary (Hex under non-hex picker)", file: file, line: line)
                })
        ])
    }

    // MARK: - PROBE — forcing an UNAVAILABLE mode via editor-set-mode
    //
    // `setCurrentViewMode` assigns `t.viewMode = mode` UNCONDITIONALLY
    // (DocumentModel.swift:3157), with the only guard being the >50MB
    // editor cap. So forcing e.g. `editor-set-mode rendered` on a `.py`
    // (which has NO .rendered in availableModes) sets the picker to a mode
    // that doesn't exist for the type. This probes whether the picker can
    // be driven into an off-menu state (picker↔pane desync surface).

    func test_PROBE_forceUnavailableModeRenderedOnPython() throws {
        let py = try harness.writeFile("force.py", "z = 3\nprint(z)\n")
        let script = """
        delay 0.8
        editor-set-mode rendered
        delay 0.7
        """
        try runScenarios([
            Scenario(
                name: "probe-force-unavailable-rendered",
                argFile: py,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    let mode = modelString(last, "currentViewMode")
                    let state = modelString(last, "currentStateKind")
                    // EXPECTED behavior: a robust app would clamp the force
                    // (rendered ∉ python availableModes) back to a valid mode.
                    // KNOWN GAP: setCurrentViewMode assigns unconditionally, so
                    // the picker may now read `rendered` for a python file while
                    // the pane shows source text (off-menu picker state).
                    // Wrap as expected-failure: green while the gap persists,
                    // fires "unexpectedly passed" once a clamp lands.
                    XCTExpectFailure(
                        "setCurrentViewMode accepts a mode not in availableModes (force editor-set-mode rendered on a .py): the picker reads a mode the file type does not offer",
                        strict: false
                    ) {
                        XCTAssertNotEqual(mode, "rendered",
                            "[probe] python forced to 'rendered' (not in its availableModes) — picker now reads an off-menu mode (mode=\(mode), state=\(state))",
                            file: file, line: line)
                    }
                    // Whatever the picker says, the document must NOT crash /
                    // error and the pane must not be a binary/Hex grid.
                    assertNotError(last, label: "probe-force", file: file, line: line)
                    XCTAssertNotEqual(state, "binary",
                        "[probe] forcing rendered on python left state==binary (Hex pane under non-hex picker)", file: file, line: line)
                })
        ])
    }

    // MARK: - Model assertion helpers (mirror TabsAndWindowChromeUATTests)

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
    private func assertNotError(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertNotEqual(modelString(dump, "currentStateKind"), "error",
            "[\(label)] document landed in .error state", file: file, line: line)
    }

    // MARK: - Tree-walk helpers (operate on the serialized DiagnosticDump)

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
            // TSK-1332: TK2-safe — numberOfGlyphs stays ~0 for a TextKit-2 view; textLength
            // (textStorage) is populated regardless, so a TK2 view isn't false-flagged as empty.
            let textLength = (tv["textLength"] as? Int) ?? 0
            let contrasts = (tv["contrastsWithBackground"] as? Bool) ?? false
            return (glyphs > 0 || textLength > 0) && contrasts
        }
    }

    /// Source mode: a *non-hex* NSTextView with visible glyphs, no Hex grid,
    /// no WebView-only view.
    private func assertSourceTextRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        assertNoHexView(dump, label: label, file: file, line: line)
        XCTAssertTrue(anyTextViewWithGlyphs(dump),
            "[\(label)] Source mode: no NSTextView with visible glyphs — content blank/stale",
            file: file, line: line)
    }

    /// Editor / Rendered: a real WKWebView must be mounted and not zero-sized.
    private func assertWebViewRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        let webNodes = allNodes(in: dump).filter { $0["wkWebView"] != nil }
            + allNodes(in: dump).filter { (($0["class"] as? String) ?? "").contains("WKWebView") }
        XCTAssertFalse(webNodes.isEmpty,
            "[\(label)] expected a WKWebView in tree — editor/rendered view did not mount",
            file: file, line: line)
    }

    /// HEX: a Hex* byte-grid view with visible glyphs.
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

    /// The HEX byte grid must be ABSENT (catches Hex leaking under a
    /// non-HEX picker — the stale/desynced view class).
    private func assertNoHexView(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertFalse(hasViewClass(dump, containing: "Hex"),
            "[\(label)] a Hex* byte-grid view is mounted under a non-HEX picker — stale/desynced view",
            file: file, line: line)
    }

    /// Preview mode: a native preview subtree (image scroll/host/view, or
    /// the SQLite browser NSSplitView).
    private func assertPreviewRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        let hasImagePreview = hasViewClass(dump, containing: "ZoomableImageScrollView")
            || hasViewClass(dump, containing: "ImageScrollHost")
            || hasViewClass(dump, containing: "ImageView")
        let hasSplitBrowser = hasViewClass(dump, containing: "NSSplitView")
        XCTAssertTrue(hasImagePreview || hasSplitBrowser,
            "[\(label)] Preview mode: no image-preview or split-browser subtree — preview did not mount",
            file: file, line: line)
    }

    // MARK: - Binary fixtures (mirror ViewModeMatrixSmokeTests)

    /// 1×1 red PNG (real magic bytes -> .image -> .preview).
    private func writePNGFixture(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        guard let data = Data(base64Encoded: b64) else { throw XCTSkip("PNG fixture decode failed") }
        try data.write(to: url)
        return url
    }

    /// Random high-bit bytes -> unknown binary -> HEX-only routing.
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
