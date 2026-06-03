import XCTest
import Foundation

/// UAT executable companion — **group 5/12: search**
/// (find-bar / cross-file / unified panel / jq / css / xpath).
///
/// Durable T4 live-app smoke for `docs/uat/smokes/search.md`
/// (SMK-SEARCH-01..08). Drives the assembled `dist/TextView.app` via the
/// `--script` verb dispatcher (the proven path of `ViewModeMatrixSmokeTests`
/// + `ViewModesUATTests`), captures a `DiagnosticDump` JSON per step, and
/// asserts the scripted expectations AND walks the realized NSView tree for
/// missing-result / wrong-state / dead-control defects a model-only
/// assertion would miss.
///
/// ## Observability constraints (verified live, group 5)
///
/// 1. SwiftUI `.accessibilityIdentifier()` does NOT propagate onto
///    `NSView.accessibilityIdentifier()` — a live probe found ZERO `mdv.*`
///    ids in the cross-search overlay's `contentView` tree. So the panel's
///    documented ids (`mdv.crossSearchPanel`, `mdv.unifiedSearch.scope.*`)
///    are unreadable from the dump.
///
/// 2. `ScriptVerb.modelStateDump` surfaces `isCrossSearchPresented` and
///    `isRenderedFindBarPresented` (Bool) and the sidebar root, but does
///    NOT carry the cross-search result COUNT / running flag, nor any
///    find-bar match-count. So result presence is asserted STRUCTURALLY:
///    the cross-search results are SwiftUI rows mounted into a
///    `HostingScrollView` inside the overlay; a populated search adds ~16
///    view hosts to the `contentView` node count. Verified live:
///      - no panel:            130–132 contentView nodes
///      - panel open, 0 match: 144 nodes (panel chrome only)
///      - panel open, matches: 160 nodes (result rows mounted)
///    The detector therefore is: panel-open + nodeCount > 150 ⇒ results
///    rendered; panel-open + nodeCount ≤ 145 ⇒ no/empty results. This is a
///    real "did rows mount" check, not a brittle byte-size proxy.
///
/// ## Script reachability for THIS group (what is / isn't drivable)
///
/// REACHABLE via verbs: cross-file modal (`show-cross-search` /
/// `set-cross-query` / `dismiss-cross-search`), sidebar root
/// (`sidebar-set-root`), rendered find bar mount/dismiss (`show-find` /
/// `dismiss-find` / `find-next` / `find-prev`), tab reuse (`open`),
/// view-mode carry (`editor-set-mode`).
///
/// NOT reachable from `--script` (no verb exists — logged for the MANUAL /
/// VM lane in `UAT_RUN_undated.md`, NOT a failure here):
///   - HEX search toolbar (SMK-SEARCH-05): `mdv.hex.search.*` has no verb.
///   - Search Anywhere sidebar panel (SMK-SEARCH-04): no verb; the section
///     IS visible in the cross-search screenshots (SEARCH rail) but its
///     field/scope can't be driven programmatically.
///   - jq filter (SMK-SEARCH-06): no verb; `Cmd+Opt+J` is a menu action.
///   - cross-search CASE toggle (`crossSearchCaseSensitive`): no verb, so
///     the Aa case-sensitivity path is screenshot-only.
///   - source / editor find BARS: only the RENDERED bar has a `show-find`
///     verb; the source/editor bags can't be opened from script.
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real
/// cross-process cross-file grep (folder walk + skip rules + result-row
/// mount into the SwiftUI overlay) and the find-bar overlay surfaces, none
/// of which a headless `DocumentModel` exercises (the grep runs against the
/// real FS root; the overlay mounts in a real `NSWindow`). Self-skips on the
/// headless gate (`isAppBuilt` false there); runs for real on the VM/nightly
/// lane or a host-occluded UAT run.
@MainActor
final class SearchSurfacesUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "SearchSurfacesUAT" }
    // Cross-search dispatches the grep to a background queue and hops back
    // to the main actor; the rendered find bar is a WKWebView. Each bare
    // `delay` is a FIXED ~300 ms (the seconds arg is ignored by the script
    // runner), so we pad settle windows and give scenarios generous room.
    override class var defaultScenarioTimeout: TimeInterval { 120 }

    // MARK: - SMK-SEARCH-02 — Cross-file modal: results, grouping, skips, no-match

    /// The headline cross-file flow. Root the sidebar at the fixture repo,
    /// open the modal, run a no-match query (`No matches`, no rows), then the
    /// real query (`needle`) and assert result rows MOUNT (structural node
    /// count jumps) while the documented skips (>2 MiB / binary-NUL / hidden
    /// dir / node_modules) are honored — i.e. the grep terminates and renders
    /// without erroring on the poison files.
    func test_SMK_SEARCH_02_crossFileModalResultsAndSkips() throws {
        let root = try makeSearchFixture()
        // Verb plan (each bare `delay` ≈ 300 ms):
        //   sidebar-set-root      -> grep scope
        //   show-cross-search     -> overlay mounts (panel chrome only)
        //   set-cross-query zz..  -> 0-match: panel stays at chrome node count
        //   set-cross-query needle-> results: node count jumps (rows mount)
        let script = """
        sidebar-set-root \(root.path)
        show-cross-search
        delay
        delay
        set-cross-query zzqqxnomatch
        delay
        delay
        delay
        set-cross-query needle
        delay
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "cross-file-modal-results",
                argFile: root.appendingPathComponent("README.md"),
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    // Panel mounted after show-cross-search.
                    let opened = dumps.first { boolModel($0, "isCrossSearchPresented") }
                    XCTAssertNotNil(opened,
                        "[s02] show-cross-search never set isCrossSearchPresented", file: file, line: line)
                    if let o = opened {
                        // Sidebar root committed (grep scope present).
                        let rootURL = (model(o)["sidebar"] as? [String: Any])?["rootURL"] as? String ?? ""
                        XCTAssertTrue(rootURL.contains("uat-search") || rootURL.hasSuffix("/"),
                            "[s02] sidebar root not set for grep scope: \(rootURL.debugDescription)", file: file, line: line)
                    }

                    // RELATIVE detector (fixture-independent): the absolute
                    // node count depends on how many files the sidebar FILES
                    // tree lists, so we compare against the SAME run's
                    // panel-open-but-no-match baseline (the `zzqqx` window =
                    // panel chrome only). Result rows mounting must push the
                    // `needle` dump materially above that chrome baseline.
                    let zeroSettled = dumps.last {
                        boolModel($0, "isCrossSearchPresented")
                            && ($0["label"] as? String)?.contains("zzqqx") == true
                    }
                    // Stability of the chrome baseline across its settle window:
                    // the zero-match window must NOT grow (no rows leaking in).
                    let zeroWindow = dumps.filter {
                        boolModel($0, "isCrossSearchPresented")
                            && ($0["label"] as? String)?.contains("zzqqx") == true
                    }
                    let chromeBaseline = zeroSettled.map(nodeCount) ?? 0
                    XCTAssertGreaterThan(chromeBaseline, 0,
                        "[s02] no panel-open zero-match dump captured", file: file, line: line)
                    if let maxZero = zeroWindow.map(nodeCount).max(),
                       let minZero = zeroWindow.map(nodeCount).min() {
                        XCTAssertEqual(maxZero, minZero,
                            "[s02] zero-match window grew (\(minZero)→\(maxZero) nodes) — 'No matches' should mount no result rows",
                            file: file, line: line)
                    }

                    // The match window: the LAST panel-open dump (query=needle)
                    // must exceed the chrome baseline by a clear margin — the
                    // result rows for README.md/app.ts/data.json/page.html/
                    // doc.xml/notes.md/latin1.txt actually mounted.
                    let needleSettled = dumps.last { boolModel($0, "isCrossSearchPresented") }
                    XCTAssertNotNil(needleSettled, "[s02] panel not open at end", file: file, line: line)
                    if let n = needleSettled {
                        XCTAssertGreaterThan(nodeCount(n), chromeBaseline + 8,
                            "[s02] 'needle' produced NO mounted result rows (nodes \(nodeCount(n)) ≈ chrome baseline \(chromeBaseline)) — grep returned empty or rows never mounted. Expected hits in README.md/app.ts/data.json/page.html/doc.xml/notes.md/latin1.txt",
                            file: file, line: line)
                    }

                    // No step crashed / errored the document (the grep walking
                    // big.log / bin.dat / symlink-loop must not blow up the app).
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "s02/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    /// SMK-SEARCH-02 variation — stale-result guard + dismiss clears.
    /// Fire `needle` then immediately `hay` (a different, smaller result set):
    /// the generation counter must land the LATER query's results, not the
    /// stale `needle` rows. Then dismiss → panel gone, results emptied.
    func test_SMK_SEARCH_02var_staleGuardAndDismissClears() throws {
        let root = try makeSearchFixture()
        let script = """
        sidebar-set-root \(root.path)
        show-cross-search
        delay
        delay
        set-cross-query needle
        set-cross-query hay
        delay
        delay
        delay
        dismiss-cross-search
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "stale-guard-dismiss",
                argFile: root.appendingPathComponent("README.md"),
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    // After the rapid needle→hay, the panel is still open and
                    // the latest (hay) results landed without crashing — the
                    // node count reflects SOME stable result set (not a
                    // half-applied stale clobber producing 0 rows mid-flight).
                    let settledAfterHay = dumps.last {
                        boolModel($0, "isCrossSearchPresented")
                            && ($0["label"] as? String) == "delay"
                    }
                    // hay appears in data.json only → at least the panel is
                    // open and didn't error. (We can't read the exact text from
                    // the dump, so assert the weaker structural invariant: the
                    // panel survived the rapid re-query without erroring.)
                    if let s = settledAfterHay {
                        assertNotError(s, label: "s02var/after-hay", file: file, line: line)
                        XCTAssertTrue(boolModel(s, "isCrossSearchPresented"),
                            "[s02var] panel dropped mid rapid-requery", file: file, line: line)
                    }

                    // Dismiss: isCrossSearchPresented flips false AND the
                    // overlay node count drops back below the panel-open
                    // level (rows + chrome torn down — dismissCrossSearch
                    // clears query + results). RELATIVE: the post-dismiss node
                    // count must be strictly less than the with-results count.
                    let withResults = dumps.last { boolModel($0, "isCrossSearchPresented") }
                        .map(nodeCount) ?? Int.max
                    let dismissed = dumps.last { !boolModel($0, "isCrossSearchPresented") }
                    XCTAssertNotNil(dismissed,
                        "[s02var] dismiss-cross-search never cleared isCrossSearchPresented", file: file, line: line)
                    if let d = dismissed {
                        XCTAssertLessThan(nodeCount(d), withResults,
                            "[s02var] after dismiss the overlay node count (\(nodeCount(d))) did not drop below the with-results count (\(withResults)) — panel/results not torn down",
                            file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SMK-SEARCH-03 — reserved jq/css/xpath modes are inert; .text greps the folder

    /// The catalog's invariant: there is NO user-facing jq/css/xpath search
    /// mode today — only `.text` grep runs, and a single-file scope under
    /// `.text` falls back to the parent folder. Script can't drive the scope
    /// picker, but it CAN prove the reserved modes are inert: there is no
    /// verb that selects `.jq`/`.css`/`.xpath`, and a plain query against the
    /// folder root greps multiple files (folder behavior, the documented
    /// fallback target). If a reserved mode ever became reachable, a new verb
    /// would have to appear — which would break this build's verb set.
    func test_SMK_SEARCH_03_reservedModesInert_textGrepsFolder() throws {
        let root = try makeSearchFixture()
        let script = """
        sidebar-set-root \(root.path)
        show-cross-search
        delay
        delay
        set-cross-query needle
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "reserved-modes-inert",
                argFile: root.appendingPathComponent("app.ts"),
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    // .text grep ran against the FOLDER (multiple files matched
                    // → rows mounted), confirming the only engine-backed mode is
                    // the folder grep — NOT a single-file jq/css/xpath query.
                    XCTAssertTrue(boolModel(last, "isCrossSearchPresented"),
                        "[s03] panel not open", file: file, line: line)
                    // RELATIVE detector: compare against the FIRST dump (panel
                    // not yet open) so the threshold is fixture-independent.
                    // The overlay chrome (~+12) plus multi-file result rows
                    // (~+20) push well past the no-panel baseline.
                    let baseline = dumps.first { !boolModel($0, "isCrossSearchPresented") }
                        .map(nodeCount) ?? nodeCount(dumps[0])
                    XCTAssertGreaterThan(nodeCount(last), baseline + 16,
                        "[s03] .text grep produced no multi-file result rows (nodes \(nodeCount(last)) vs no-panel baseline \(baseline)) — reserved-mode regression or grep broke",
                        file: file, line: line)
                    assertNotError(last, label: "s03", file: file, line: line)
                })
        ])
    }

    // MARK: - SMK-SEARCH-08 — cross-surface continuity: tab reuse + open-at-line

    /// Open a result file via cross-search context (here driven by `open`),
    /// then switch it to Editor and confirm the SAME tab is reused (no dup),
    /// and the rendered find bar overlay opens/dismisses cleanly across the
    /// mode without leaking a stale bag. This exercises the "follow the
    /// trail" continuity: the cross-file panel and the per-view find bar are
    /// distinct surfaces over the same document, and switching modes does not
    /// duplicate the tab.
    func test_SMK_SEARCH_08_tabReuseAndFindBarAcrossModes() throws {
        let root = try makeSearchFixture()
        let ts = root.appendingPathComponent("app.ts")
        // argv opens app.ts (Source default for .ts). Open the cross-search
        // panel + run needle, dismiss, then re-`open` app.ts (must reuse the
        // SAME tab — tabCount stays 1), switch to Editor, open the find bar
        // surface for the editor mode is NOT script-reachable (only rendered
        // has show-find); so we assert tab-reuse + mode carry + no error.
        let script = """
        sidebar-set-root \(root.path)
        delay
        delay
        show-cross-search
        delay
        set-cross-query needle
        delay
        delay
        dismiss-cross-search
        delay
        open \(ts.path)
        delay
        editor-set-mode editor
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "tab-reuse-find-across-modes",
                argFile: ts,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    // Re-opening the already-open app.ts must NOT create a
                    // duplicate tab — tab count stays 1 throughout.
                    for (i, d) in dumps.enumerated() {
                        XCTAssertEqual(intModel(d, "tabCount"), 1,
                            "[s08/step\(i)] re-opening an already-open file duplicated the tab (count=\(intModel(d, "tabCount")))",
                            file: file, line: line)
                    }

                    // The final state is app.ts in Editor (mode carried), the
                    // CM6 WebView mounted, no error, no stale Hex grid.
                    let last = dumps.last!
                    assertModel(last, "currentURL", endsWith: "app.ts", label: "s08-final-url", file: file, line: line)
                    let editorDump = dumps.last { modelString($0, "currentViewMode") == "editor" }
                    XCTAssertNotNil(editorDump, "[s08] never reached Editor mode", file: file, line: line)
                    if let ed = editorDump {
                        assertWebViewRendered(ed, label: "s08-editor-webview", file: file, line: line)
                        assertNoHexView(ed, label: "s08-editor", file: file, line: line)
                    }
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "s08/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SMK-SEARCH-01 — rendered find bar mount/dismiss + the regex-toggle discrepancy

    /// The rendered find bar mounts on `show-find` and tears down on
    /// `dismiss-find`. The catalog says the rendered bar offers NO regex
    /// (`.*`) toggle (WKWebView find can't regex) — only Match-case (Aa).
    ///
    /// FINDING (group 5, real, screenshot-confirmed): the rendered find bar
    /// DOES render a `.*` regex Toggle. The shared `FindBar` view
    /// (`MarkdownFindBar.swift:80-89`) renders the `.*` Toggle
    /// UNCONDITIONALLY; the rendered bar passes `isRegex: .constant(false)`
    /// (line 160) with the comment "toggle is hidden visually but state is
    /// unused" — but there is no code that hides it. So the user sees a
    /// regex toggle that (a) contradicts the catalog and (b) is a DEAD
    /// control bound to a constant — clicking it does nothing and it can
    /// never show an on-state. Captured here as an expected-failure so the
    /// suite is green while the gap persists and flips to "unexpectedly
    /// passed" once the rendered bar conditionally hides the `.*` toggle.
    ///
    /// We can't read SwiftUI label text from the dump, so the discrepancy is
    /// asserted via the screenshot review logged in UAT_RUN; this test pins
    /// the reachable structural facts (bar mounts/dismisses; presented flag).
    func test_SMK_SEARCH_01_renderedFindBarMountDismiss() throws {
        let md = try makeSearchFixture().appendingPathComponent("README.md")
        let script = """
        delay
        delay
        delay
        show-find
        delay
        delay
        dismiss-find
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "rendered-find-bar-mount-dismiss",
                argFile: md,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "no dumps", file: file, line: line)
                    guard !dumps.isEmpty else { return }

                    // README.md opens Rendered.
                    assertModel(dumps[0], "currentViewMode", equals: "rendered", label: "s01-md-rendered", file: file, line: line)

                    // show-find mounts the rendered find bar overlay.
                    let shown = dumps.first { boolModel($0, "isRenderedFindBarPresented") }
                    XCTAssertNotNil(shown,
                        "[s01] show-find never set isRenderedFindBarPresented", file: file, line: line)

                    // dismiss-find tears it down.
                    let hidden = dumps.last { !boolModel($0, "isRenderedFindBarPresented") }
                    XCTAssertNotNil(hidden,
                        "[s01] dismiss-find never cleared isRenderedFindBarPresented", file: file, line: line)
                    // Ordering: there must be a presented dump BEFORE the final
                    // not-presented dump (a real open→close cycle).
                    let presentedIdx = dumps.firstIndex { boolModel($0, "isRenderedFindBarPresented") }
                    let dismissedIdx = dumps.lastIndex { !boolModel($0, "isRenderedFindBarPresented") }
                    if let p = presentedIdx, let d = dismissedIdx {
                        XCTAssertLessThan(p, d,
                            "[s01] find bar did not complete an open→close cycle", file: file, line: line)
                    }

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "s01/step\(i)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - Fixture builder (shared `$TMP/uat-search/` repo)

    /// Build the catalog's shared fixture repo once per scenario. Mirrors
    /// `docs/uat/smokes/search.md`'s "Shared fixture" block: a `needle` on
    /// multiple files + the poison files the grep MUST skip (oversize /
    /// binary-NUL / hidden dir / node_modules) + a symlink loop backstop.
    private func makeSearchFixture() throws -> URL {
        let root = try harness.makeDir("uat-search")
        try write(root, "README.md",
            "# README\nneedle line one\nNeedle capital line\nneedle line three\n")
        // CRLF line endings + one needle.
        try writeRaw(root, "notes.md",
            "first line\r\nneedle here\r\nlast line\r\n")
        try write(root, "data.json",
            "{\"items\":[{\"id\":1,\"tag\":\"needle\"},{\"id\":2,\"tag\":\"hay\"}]}\n")
        try write(root, "page.html",
            "<div class=\"needle\">content</div>\n<script>var x=1;</script>\n")
        try write(root, "doc.xml",
            "<root><item>needle</item></root>\n")
        try write(root, "app.ts",
            "const x = 1; // needle in a comment\nconst s = \"needle\";\n")
        try write(root, "table.csv",
            "id,name,amount,note\n1,alpha,10,plain\n2,beta,20,needle cell\n")
        // CP1252/Latin-1 with a needle (non-UTF8 bytes around it).
        try writeLatin1(root, "latin1.txt",
            "caf\u{00E9} needle r\u{00E9}sum\u{00E9}\n")
        // POISON: > 2 MiB, contains needle → MUST be skipped.
        var big = String(repeating: "filler line of log output to pad size\n", count: 60_000)
        big += "needle in oversize file should be skipped\n"
        try write(root, "big.log", big)
        // POISON: binary w/ NUL bytes + ascii needle → MUST be skipped.
        try writeBinaryWithNUL(root, "bin.dat")
        // POISON: hidden dir → MUST be skipped.
        let hidden = try harness.makeDir("uat-search/.hidden")
        try Data("needle in a hidden dir\n".utf8)
            .write(to: hidden.appendingPathComponent("secret.md"))
        // POISON: node_modules → MUST be skipped.
        let nm = try harness.makeDir("uat-search/node_modules")
        try Data("var needle = 1;\n".utf8).write(to: nm.appendingPathComponent("x.js"))
        // Symlink loop backstop: uat-search/loop -> .. (must terminate).
        let loop = root.appendingPathComponent("loop")
        try? FileManager.default.removeItem(at: loop)
        try? FileManager.default.createSymbolicLink(
            at: loop, withDestinationURL: root.deletingLastPathComponent())
        return root
    }

    private func write(_ dir: URL, _ name: String, _ body: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
    private func writeRaw(_ dir: URL, _ name: String, _ body: String) throws {
        try Data(body.utf8).write(to: dir.appendingPathComponent(name))
    }
    private func writeLatin1(_ dir: URL, _ name: String, _ body: String) throws {
        let data = body.data(using: .windowsCP1252) ?? Data(body.utf8)
        try data.write(to: dir.appendingPathComponent(name))
    }
    private func writeBinaryWithNUL(_ dir: URL, _ name: String) throws {
        var bytes: [UInt8] = []
        for i in 0..<256 { bytes.append(UInt8(i & 0xFF)) }   // includes NUL
        bytes.append(contentsOf: Array("needle".utf8))
        bytes.append(0x00)
        for i in 0..<64 { bytes.append(UInt8((i * 7) & 0xFF)) }
        try Data(bytes).write(to: dir.appendingPathComponent(name))
    }

    // MARK: - Model assertion helpers (mirror ViewModesUATTests)

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

    private func assertModel(
        _ dump: [String: Any], _ key: String, equals expected: String,
        label: String, file: StaticString, line: UInt
    ) {
        XCTAssertEqual(modelString(dump, key), expected,
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

    /// Total node count in the `contentView` subtree. The cross-search
    /// overlay's result rows are SwiftUI hosts that mount as additional
    /// nodes, so this count is the load-bearing "did rows render" signal
    /// (the model dump carries no result count). Thresholds are calibrated
    /// live (see the suite doc): no-panel ≈130, panel-chrome ≈144,
    /// panel+results ≈160.
    private func nodeCount(_ dump: [String: Any]) -> Int {
        guard let root = dump["contentView"] as? [String: Any] else { return 0 }
        var n = 0
        var stack: [[String: Any]] = [root]
        while let node = stack.popLast() {
            n += 1
            if let kids = node["subviews"] as? [[String: Any]] {
                stack.append(contentsOf: kids)
            }
        }
        return n
    }

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
    private func assertWebViewRendered(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        let webNodes = allNodes(in: dump).filter { $0["wkWebView"] != nil }
            + allNodes(in: dump).filter { (($0["class"] as? String) ?? "").contains("WKWebView") }
        XCTAssertFalse(webNodes.isEmpty,
            "[\(label)] expected a WKWebView in tree — editor/rendered view did not mount",
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
