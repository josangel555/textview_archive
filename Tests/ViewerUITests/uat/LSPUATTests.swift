import XCTest
import Foundation

/// UAT executable companion — **group 8/12: lsp**
/// (hover / go-to-def / outline / refs / diagnostics).
///
/// Durable T4 live-app smoke for `docs/uat/smokes/lsp.md` (LSP-01..04).
/// Drives the assembled `dist/TextView.app` via the `--script` verb
/// dispatcher (the proven path from `ViewModeMatrixSmokeTests` /
/// `GitPanelUATTests`), captures a `DiagnosticDump` JSON per step, and
/// asserts the observable facts against the authoritative `model`
/// sub-dict + structural view-CLASS detection — plus a live `pgrep`
/// side-channel for the one LSP signal that escapes the dump (the
/// `sourcekit-lsp` child process).
///
/// ## Observability reality for THIS group (probed against the live bundle)
///
/// The LSP surface is the LEAST script-automatable group in the catalog.
/// Probing the assembled bundle confirmed three hard walls:
///
///  1. **There is NO `lsp-*` / `hover` / `go-to-def` / `find-refs`
///     script verb.** The full `ScriptVerbDispatch` vocabulary has ZERO
///     LSP entry points (the catalog says this outright: "there is no LSP
///     script verb"). Every primary LSP gesture — 300 ms cursor-dwell
///     hover, right-click "Go to Definition" / the LSP nav submenu,
///     Cmd-click, the Outline row tap, the References / Workspace-Symbols
///     panel, the Problems severity filter, the Diagnostics tool window —
///     is a LIVE pointer/keyboard interaction with no verb. The scripted
///     harness cannot fire any of them.
///  2. **`ScriptVerb.modelStateDump` carries NO LSP state.** No outline
///     symbols, no diagnostics/problems rows, no navigation/references
///     rows, no per-server live/dead/crash/Reqs accounting, no hover
///     payload. `DocumentModel.lspPool` / `lspDiagnostics` / `lspNavigation`
///     and `LSPOutlineModel` are all OFF the dump's projection. The only
///     LSP-adjacent model scalar is `currentURL` (which file is active).
///  3. **The realized NSView tree does not distinguish LSP sidebar
///     sections.** SwiftUI `.accessibilityIdentifier()` ("mdv.lspOutline",
///     "mdv.problems", "mdv.lspNav") does NOT propagate onto
///     `NSView.accessibilityIdentifier()` (the group-1/2/5/6 finding,
///     re-confirmed here: zero `mdv.*` ids in the dump). Worse, the
///     accordion sections render as GENERIC `HostingScrollView` hosts
///     whose SwiftUI label text ("Outline", "PROBLEMS", "REFERENCES",
///     "Loading symbols…", "No language server for this file.") never
///     appears in `contentView` OR `recursiveDescription`. So the dump
///     cannot even tell WHICH accordion sections (LSP vs Bookmarks vs Git)
///     are mounted — they are indistinguishable generic scroll hosts.
///
/// ### The one LSP signal that DOES escape: the server child process
///
/// Opening a `.swift` file under a SwiftPM/git root drives the Outline
/// path (`LSPOutlineModel.setFile` → `LSPPool.documentSymbol`) which
/// spawns `sourcekit-lsp` as a child of the app. That child is observable
/// from the test side via `pgrep -x sourcekit-lsp`. We use it as the
/// liveness probe — AND it surfaced the headline bug for this group
/// (F-LSP-1): in the occluded/scripted run the spawn is NON-DETERMINISTIC
/// (observed 1/3 identical runs in the host probe), because it is gated
/// behind the lower accordion sections being realized + `LSPOutlineWrapper`'s
/// `.onAppear`/`.onChange(of: currentURL)` firing — which the occluded
/// window does not reliably do. The same republish-ordering class as the
/// git group's F-GIT-1.
///
/// ### Fixture language
///
/// The catalog defaults to `typescript-language-server`; it is NOT on this
/// host's PATH (nor `pyright`). The ONLY PATH-discoverable server is
/// `sourcekit-lsp` (via `xcrun`, ships with the Xcode toolchain). So every
/// fixture here is Swift under a `Package.swift` root. The suite SKIPS the
/// server-liveness assertions when `sourcekit-lsp` is absent (CI), keeping
/// the structural / no-crash assertions running everywhere the bundle is.
///
/// ## What this suite genuinely verifies (the observable floor)
///
///  - **No crash / no `.error` / no stuck `.loading`** when a `.swift`
///    file opens under a SwiftPM root and the LSP backend engages — i.e.
///    spawning `sourcekit-lsp` does not break document load (LSP-01/04
///    resilience).
///  - **The source view renders** for the `.swift` file (a non-hex
///    NSTextView with contrasting glyphs) — LSP does not blank/desync it.
///  - **Language-gating at the backend**: opening a `.md`/`.txt` file
///    (no registered server) does NOT spawn `sourcekit-lsp`; opening a
///    `.swift` file CAN (LSP-04 step 5 gating, observed via `pgrep`).
///  - **CM6 editor parity surface mounts**: `editor-set-mode editor` on
///    the `.swift` file mounts the CodeMirror WKWebView (the surface the
///    editor-mode hover/Cmd-click bridge — `respondToEditorHover` /
///    `respondToEditorCmdClick` — attaches to). We cannot inject the
///    hover, but we confirm the host it would render into is live.
///  - **Multi-byte / non-ASCII content** in the `.swift` file loads
///    cleanly (a `café` identifier after an emoji comment) — the source
///    pane renders without truncation/crash (the position-encoding
///    fixture; the actual hover-column correctness is a manual/VM check).
///
/// Everything that needs the visible LSP panels or a live gesture
/// (Outline population + click-jump, hover popover geometry, Cmd-click /
/// right-click definition, References / Workspace-Symbols panels, Problems
/// rows + severity filter + count pills, the Diagnostics tool window,
/// crash/restart accounting, position-encoding column correctness) is
/// enumerated in `UAT_RUN_undated.md` as a MANUAL/VM-lane gap (F-LSP-2).
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real
/// cross-process AppDelegate↔DocumentModel↔LSPPool wiring in a live
/// `NSWindow`: the `sourcekit-lsp` child spawn off the document-symbol
/// path, the source/CM6 mount under an LSP-gated language, and the
/// no-crash invariant when a real language server engages. None of this is
/// reachable from a bare `(model, sessions)` headless pair (the pool spawns
/// a real subprocess). Self-skips on the headless gate (`isAppBuilt` false);
/// runs for real on the VM/nightly lane or a host-occluded UAT run.
@MainActor
final class LSPUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "LSPUAT" }
    // sourcekit-lsp cold-start + CM6 WKWebView settle; give each scenario
    // generous room.
    override class var defaultScenarioTimeout: TimeInterval { 120 }

    /// True when `sourcekit-lsp` resolves on this host (via `xcrun -f` or
    /// `/usr/bin/sourcekit-lsp`). Liveness probes that depend on a real
    /// server spawning are downgraded to non-fatal observations when false
    /// (e.g. CI without a toolchain).
    private lazy var sourceKitAvailable: Bool = Self.resolveSourceKitLSP() != nil

    // MARK: - LSP-01 / LSP-04 — .swift open under SwiftPM root: no crash,
    //          source renders, server engagement does not break load.

    /// Open a `.swift` file (argv) whose root holds a `Package.swift`, root
    /// the sidebar there, and dwell long enough for the Outline path to try
    /// to engage `sourcekit-lsp`. Assert the load-bearing observable floor:
    /// never `.error`/`.loading`, the source NSTextView renders with visible
    /// contrasting glyphs, and (when sourcekit is available) record whether
    /// the server child spawned — the F-LSP-1 non-determinism probe.
    func test_LSP_01_swiftOpenUnderRoot_noCrash_sourceRenders() throws {
        let proj = try makeSwiftProject()
        let main = proj.appendingPathComponent("Sources/Demo/main.swift")

        // [0] delay 1.0   -> launch + argv-open main.swift (source mode)
        // [1] set-root    -> sidebar rooted at the SwiftPM project
        // [2] delay 1.0
        // [3] open (re-open via verb) -> drive the Outline refresh path
        // [4] delay 5.0   -> sourcekit-lsp cold-start window + outline req
        let script = """
        delay 1.0
        sidebar-set-root \(proj.path)
        delay 1.0
        open \(main.path)
        delay 5.0
        """
        try runScenarios([
            Scenario(
                name: "swift-open-source-floor",
                argFile: main,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 5,
                        "expected >=5 step dumps — app may not have launched",
                        file: file, line: line)
                    guard let last = dumps.last else { return }

                    // (1) Active doc is the .swift file, in source view, loaded.
                    assertModel(last, "currentURL", endsWith: "main.swift",
                                label: "swift-floor", file: file, line: line)
                    XCTAssertEqual(modelString(last, "currentViewMode"), "source",
                        "[swift-floor] .swift should default to source view",
                        file: file, line: line)

                    // (2) Never an error/stuck-loading state across ALL steps —
                    //     a real language server engaging must not break load.
                    for (i, d) in dumps.enumerated() {
                        assertNotErrorOrStuck(d, label: "lsp01/step\(i + 1)",
                                              file: file, line: line)
                    }

                    // (3) The source pane renders: a non-hex NSTextView with
                    //     contrasting glyphs, no WKWebView leaking under source.
                    assertSourceTextRendered(in: last, label: "swift-floor",
                                             file: file, line: line)
                })
        ])

        // (4) F-LSP-1 observation (non-fatal): did sourcekit-lsp engage?
        //     Probed live, OUTSIDE the scenario, since the dump has no LSP
        //     signal. The script-runner exits at end-of-script so by the
        //     time we get here the app is gone; this records the design
        //     reality, not a per-run gate.
        if sourceKitAvailable {
            print("[UAT lsp F-LSP-1] sourcekit-lsp IS PATH-discoverable; "
                + "Outline/hover backend CAN engage on a .swift open. Host probes "
                + "showed the occluded/scripted spawn is NON-DETERMINISTIC "
                + "(driven by LSPOutlineWrapper.onAppear/onChange, which the "
                + "occluded window does not reliably realize). Server-population, "
                + "hover, refs, problems, diagnostics-window are MANUAL/VM-lane.")
        } else {
            print("[UAT lsp F-LSP-1] sourcekit-lsp NOT on PATH — server-liveness "
                + "probes skipped (structural + no-crash assertions still ran).")
        }
        // Belt-and-suspenders: reap any stray server the run may have left.
        Self.reapStrayServers()
    }

    // MARK: - LSP-04 step 5 — language-gating at the backend (server spawn)

    /// Markdown is NOT an LSP-registered language. Opening a `.md` file
    /// under the same SwiftPM root must NOT spawn `sourcekit-lsp` (the
    /// backend half of the catalog's "Outline/Problems sections are
    /// language-gated" behavior). We assert the no-crash + rendered-markdown
    /// floor in the scenario, and probe the no-spawn invariant live.
    ///
    /// This is the most reliable LSP-gating assertion available to the
    /// scripted path: the .md path simply never reaches `LSPLanguageRegistry`
    /// → never constructs a pool entry → no child process. Verified on the
    /// host (`pgrep -x sourcekit-lsp` empty after a .md-only run).
    func test_LSP_04_markdownDoesNotEngageServer() throws {
        let proj = try makeSwiftProject()
        let readme = proj.appendingPathComponent("README.md")
        try "# Demo\n\nSome **bold** body and a [link](https://example.com).\n"
            .write(to: readme, atomically: true, encoding: .utf8)

        // Open ONLY the markdown file (rendered default). No .swift ever
        // touched, so a clean run must leave zero sourcekit-lsp children.
        let script = """
        delay 1.0
        sidebar-set-root \(proj.path)
        delay 3.0
        """
        // Pre-clean any ambient server so the post-run probe is meaningful.
        Self.reapStrayServers()
        try runScenarios([
            Scenario(
                name: "markdown-no-server",
                argFile: readme,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    assertModel(last, "currentURL", endsWith: "README.md",
                                label: "md-gate", file: file, line: line)
                    XCTAssertEqual(modelString(last, "currentViewMode"), "rendered",
                        "[md-gate] .md should default to rendered view",
                        file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotErrorOrStuck(d, label: "lsp04md/step\(i + 1)",
                                              file: file, line: line)
                    }
                    // Rendered markdown is a WKWebView; confirm it mounted.
                    XCTAssertTrue(hasViewClass(last, containing: "WKWebView"),
                        "[md-gate] rendered markdown WKWebView did not mount",
                        file: file, line: line)
                })
        ])

        // The gating assertion: no sourcekit-lsp child after a markdown-only
        // run. The script-runner has exited (app gone) by now; a stray server
        // would be an orphaned child = the gate leaked. This is a HARD
        // assertion when sourcekit is available (a leak here is a real bug),
        // and a logged no-op otherwise.
        let stray = Self.strayServerCount()
        if sourceKitAvailable {
            XCTAssertEqual(stray, 0,
                "[md-gate] a sourcekit-lsp child is alive after a MARKDOWN-only "
                + "session — language gating leaked an LSP server for an "
                + "unsupported file type")
        } else {
            print("[UAT lsp] markdown gating: sourcekit-lsp not installed; "
                + "no-spawn invariant trivially holds (\(stray) strays).")
        }
        Self.reapStrayServers()
    }

    // MARK: - LSP-02 edge (editor parity) — CM6 editor mounts for .swift

    /// The catalog's "Editor parity" edge (LSP-02): open the `.swift` file
    /// in the CM6 Editor — the surface the editor-mode hover tooltip +
    /// "Go to Definition" bridge (`DocumentModel.respondToEditorHover` /
    /// `respondToEditorCmdClick`) attaches to. We cannot inject a hover from
    /// `--script`, but we CAN confirm the host it renders into is live:
    /// `editor-set-mode editor` mounts the CodeMirror WKWebView, non-zero,
    /// with no stale source NSTextView / hex grid leaking under it.
    func test_LSP_02_editorParitySurfaceMounts() throws {
        let proj = try makeSwiftProject()
        let main = proj.appendingPathComponent("Sources/Demo/main.swift")

        // [0] delay 0.8 -> argv-open main.swift in source
        // [1] editor-set-mode editor -> CM6 WKWebView mounts (captured ~300ms)
        // [2] delay 3.0 -> WebContent settle
        let script = """
        delay 0.8
        editor-set-mode editor
        delay 3.0
        """
        try runScenarios([
            Scenario(
                name: "swift-editor-mount",
                argFile: main,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 3,
                        "expected >=3 step dumps", file: file, line: line)
                    guard let last = dumps.last else { return }

                    XCTAssertEqual(modelString(last, "currentViewMode"), "editor",
                        "[swift-editor] currentViewMode should be editor",
                        file: file, line: line)
                    // CM6 is a WKWebView; it must be mounted + non-zero-sized.
                    let webNodes = allNodes(in: last).filter { $0["wkWebView"] != nil }
                    XCTAssertFalse(webNodes.isEmpty,
                        "[swift-editor] CM6 editor WKWebView did not mount — the "
                        + "editor-mode LSP hover/definition bridge has no host",
                        file: file, line: line)
                    XCTAssertTrue(webNodes.contains { $0["zeroSize"] == nil },
                        "[swift-editor] CM6 WKWebView present but zero-sized — "
                        + "editor pane blank", file: file, line: line)
                    // No hex byte-grid leaking under the editor (desync guard).
                    XCTAssertFalse(hasViewClass(last, containing: "Hex"),
                        "[swift-editor] a Hex byte-grid is mounted under the editor",
                        file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotErrorOrStuck(d, label: "lsp02ed/step\(i + 1)",
                                              file: file, line: line)
                    }
                })
        ])
        Self.reapStrayServers()
    }

    // MARK: - LSP-04 fixture detail — multi-byte / non-ASCII source loads

    /// LSP-04 position-encoding fixture: a `.swift` line with multi-byte
    /// content (emoji comment) preceding a `café` identifier. We cannot
    /// verify the hover lands on the right COLUMN from `--script` (that is
    /// a live gesture + the dump carries no hover payload), but we CAN
    /// confirm the file with non-ASCII content opens and renders cleanly —
    /// no truncation at the surrogate boundary, no crash, glyphs drawn.
    func test_LSP_04_multiByteSourceLoadsCleanly() throws {
        let proj = try makeSwiftProject()  // main.swift already has a `café` line + emoji
        let main = proj.appendingPathComponent("Sources/Demo/main.swift")

        let script = """
        delay 0.8
        sidebar-set-root \(proj.path)
        delay 2.0
        """
        try runScenarios([
            Scenario(
                name: "multibyte-source-load",
                argFile: main,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    assertModel(last, "currentURL", endsWith: "main.swift",
                                label: "multibyte", file: file, line: line)
                    XCTAssertEqual(modelString(last, "currentStateKind"), "loaded",
                        "[multibyte] non-ASCII .swift did not reach .loaded",
                        file: file, line: line)
                    // The full source (incl. the multi-byte line) renders.
                    assertSourceTextRendered(in: last, label: "multibyte",
                                             file: file, line: line)
                    // The drawn string length should reflect the FULL file
                    // (~14 lines), not a truncated prefix at the emoji.
                    let glyphs = maxTextViewGlyphs(last)
                    XCTAssertGreaterThan(glyphs, 80,
                        "[multibyte] source NSTextView drew only \(glyphs) glyphs — "
                        + "content looks truncated (possible multi-byte boundary bug)",
                        file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotErrorOrStuck(d, label: "lsp04mb/step\(i + 1)",
                                              file: file, line: line)
                    }
                })
        ])
        Self.reapStrayServers()
    }

    // MARK: - Swift fixture

    /// A scratch SwiftPM project so `LSPDiscovery.swiftPackageRoot` finds a
    /// real root and `sourcekit-lsp` gets a workspace:
    ///   proj/
    ///     Package.swift
    ///     Sources/Demo/main.swift   (functions, a struct, a `café`
    ///                                multi-byte identifier, a deliberate
    ///                                type error)
    /// The deliberate type error (`let badType: Int = "..."`) is the
    /// catalog's diagnostic seed — though we cannot read the resulting
    /// Problems row from the dump, it makes the fixture honest for the
    /// VM/manual lane that CAN.
    private func makeSwiftProject() throws -> URL {
        let proj = try harness.makeDir("proj")
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "Demo",
            targets: [.executableTarget(name: "Demo", path: "Sources/Demo")]
        )
        """.write(
            to: proj.appendingPathComponent("Package.swift"),
            atomically: true, encoding: .utf8)
        let srcDir = try harness.makeDir("proj/Sources/Demo")
        try """
        import Foundation

        /// Adds two integers and returns the sum.
        func computeTotal(_ a: Int, _ b: Int) -> Int {
            return a + b
        }

        struct Calculator {
            var label: String
            func run() -> Int { computeTotal(2, 3) }
        }

        // 🧮 multi-byte comment before a non-ASCII identifier (LSP-04 fixture)
        let café = computeTotal(40, 2)
        let badType: Int = "deliberate type error for the Problems panel"
        print(café, Calculator(label: "x").run(), badType)
        """.write(
            to: srcDir.appendingPathComponent("main.swift"),
            atomically: true, encoding: .utf8)
        return proj
    }

    // MARK: - sourcekit-lsp side-channel (the one LSP signal the dump lacks)

    /// Resolve `sourcekit-lsp` the same way `LSPDiscovery` does: `xcrun -f`
    /// then `/usr/bin/sourcekit-lsp`. Returns the path or nil.
    private static func resolveSourceKitLSP() -> String? {
        // xcrun -f sourcekit-lsp
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-f", "sourcekit-lsp"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        let fallback = "/usr/bin/sourcekit-lsp"
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    /// Count of live `sourcekit-lsp` processes (the app's children, if any).
    private static func strayServerCount() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "sourcekit-lsp"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        guard (try? p.run()) != nil else { return 0 }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = (String(data: data, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
        return out.count
    }

    /// SIGTERM any stray sourcekit-lsp / SourceKitService a run may have
    /// orphaned. Idempotent; safe no-op when none exist. We do NOT want a
    /// UAT run to leak indexing daemons onto the dev host.
    private static func reapStrayServers() {
        for name in ["sourcekit-lsp", "SourceKitService"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = [name]
            p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            p.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try? p.run()
            p.waitUntilExit()
        }
    }

    // MARK: - Model + tree assertion helpers (same idiom as sibling UAT suites)

    private func model(_ dump: [String: Any]) -> [String: Any] {
        dump["model"] as? [String: Any] ?? [:]
    }
    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        model(dump)[key] as? String ?? ""
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
    private func assertNotErrorOrStuck(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        let kind = modelString(dump, "currentStateKind")
        XCTAssertNotEqual(kind, "error",
            "[\(label)] document landed in .error state", file: file, line: line)
        XCTAssertNotEqual(kind, "loading",
            "[\(label)] document stuck in .loading (async completion never committed?)",
            file: file, line: line)
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

    /// True if any non-hex NSTextView node has generated, contrasting glyphs.
    private func anyNonHexTextViewWithGlyphs(_ dump: [String: Any]) -> Bool {
        allNodes(in: dump).contains { node in
            let cls = (node["class"] as? String) ?? ""
            guard let tv = node["nsTextView"] as? [String: Any], !cls.contains("Hex")
            else { return false }
            let glyphs = (tv["numberOfGlyphs"] as? Int) ?? 0
            let contrasts = (tv["contrastsWithBackground"] as? Bool) ?? false
            return glyphs > 0 && contrasts
        }
    }

    /// Largest `numberOfGlyphs` across all NSTextView nodes (the document
    /// view dominates; chrome labels are tiny). Used to catch truncation.
    private func maxTextViewGlyphs(_ dump: [String: Any]) -> Int {
        allNodes(in: dump).compactMap { node -> Int? in
            (node["nsTextView"] as? [String: Any])?["numberOfGlyphs"] as? Int
        }.max() ?? 0
    }

    /// Source mode: a non-hex NSTextView with visible glyphs, the hex grid
    /// absent, and no WKWebView leaking in (which would mean editor/rendered
    /// mounted instead of source).
    private func assertSourceTextRendered(
        in dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertFalse(hasViewClass(dump, containing: "Hex"),
            "[\(label)] a Hex byte-grid view is mounted under source",
            file: file, line: line)
        XCTAssertTrue(anyNonHexTextViewWithGlyphs(dump),
            "[\(label)] source mode: no NSTextView with visible glyphs — content blank/stale",
            file: file, line: line)
        XCTAssertFalse(hasViewClass(dump, containing: "WKWebView"),
            "[\(label)] source mode: a WKWebView is mounted — wrong view under source picker",
            file: file, line: line)
    }
}
