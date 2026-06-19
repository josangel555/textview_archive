import XCTest
import Foundation

/// LOADBUG pre-install live-app smoke gate.
///
/// Drives the *assembled* `dist/TextView.app` through the (file type ×
/// view mode) matrix and asserts that the **realized NSView tree** —
/// not just the model — renders the correct content in the correct view
/// for every mode, and never lands in an `.error` / blank / wrong-mode
/// state.
///
/// ## Why this suite exists (the fd11e61 gap)
///
/// fd11e61 shipped two regressions that every existing gate missed:
///   1. "main.swift cannot be loaded" / blank content on open.
///   2. View-mode scramble: pick Editor → blank, pick HEX → blank, pick
///      Editor again → shows the HEX byte grid.
///
/// Root cause (both): the three async file-load completions
/// (`materializeIfNeeded`, `loadBinaryAsync`, `loadTextAsync`) committed
/// the new tab state via `tabCoordinator.replace(...)` only. PERF #1
/// severed `TabCoordinator.objectWillChange` → `DocumentModel.
/// objectWillChange` forwarding, so the deferred state landed correct on
/// the *model* but the realized SwiftUI/NSView subtree never re-bodied —
/// it stayed frozen on the prior render until some unrelated model
/// republish.
///
/// Because the MODEL stays self-consistent, every headless tier
/// (`ModeSwitchRaceTests`, `ModeSwitchRaceLiveTimingTests`,
/// `InteractionProfileHarness`) is structurally blind to it: they assert
/// on `model.*` scalars, which are correct. The bug is purely in the
/// render layer, which only a live mounted `NSWindow` exercises. The
/// WKWebView-backed modes (Editor, Rendered) are additionally `#192`-
/// excluded from the bare headless sweep. Hence: a dedicated T4 smoke
/// that walks the realized `DiagnosticDump` tree.
///
/// TIER-JUSTIFY: T4 — the observable is "the assembled dist/ bundle, when
/// the real AppDelegate mounts ContentView in a real NSWindow with real
/// WKWebView WebContent processes, renders the correct content for each
/// (file type × view mode) and keeps currentViewMode ↔ currentState ↔
/// realized-subtree consistent." The desync is in the render layer (not
/// model state, which ModeSwitchRaceTests already pins headless), and the
/// WKWebView-backed modes (Editor, Rendered) are #192-excluded from the
/// headless gate. Only a live process exercises this. Run for real on the
/// VM/nightly lane or as the `scripts/build-app.sh` pre-install gate;
/// self-skips on the headless host gate (`isAppBuilt` is false there).
@MainActor
final class ViewModeMatrixSmokeTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "ViewModeMatrix" }
    // WKWebView-backed modes (Editor, Rendered) need WebContent settle
    // time, and we cycle several modes per file; give each scenario room.
    override class var defaultScenarioTimeout: TimeInterval { 90 }

    // MARK: - The matrix

    /// Fresh-open default-mode coverage: launch with each file type and
    /// assert the realized content pane shows the right view for that
    /// file's DEFAULT mode (Source for code/log, Rendered for markdown,
    /// Preview for image/sqlite). Each scenario is its own launch, so the
    /// view is observed on the synchronous open path right after launch.
    func test_freshOpen_defaultMode_rendersCorrectView() throws {
        let swiftFile = try harness.writeFile(
            "main.swift",
            "import Foundation\nstruct Main { static func main() { print(\"hi\") } }\n")
        let logFile = try harness.writeFile(
            "app.log",
            String(repeating: "INFO 2026-06-01 line of log output\n", count: 60))
        let mdFile = try harness.writeFile(
            "readme.md",
            "# Title\n\nSome **bold** body text and a [link](https://example.com).\n")
        let pngFile = try writePNGFixture("pixel.png")
        let dbFile = try writeSQLiteFixture("data.db")

        try runScenarios([
            openOnlyScenario(name: "swift-source", file: swiftFile, expectMode: "source"),
            openOnlyScenario(name: "log-source", file: logFile, expectMode: "source"),
            openOnlyScenario(name: "md-rendered", file: mdFile, expectMode: "rendered"),
            openOnlyScenario(name: "png-preview", file: pngFile, expectMode: "preview"),
            openOnlyScenario(name: "db-preview", file: dbFile, expectMode: "preview"),
        ])
    }

    /// View-mode transition coverage — THE deterministic bug-2 catch.
    ///
    /// Each scenario is a fresh launch that performs exactly ONE mode
    /// switch from the file's freshly-opened default, captured immediately
    /// (no trailing `delay` step) so the dump is taken ~300 ms after the
    /// switch — long enough for the async `loadBinaryAsync`/`loadTextAsync`
    /// completion to land on the MODEL, but before any incidental sibling
    /// republish (file-watcher tick, WebView teardown callback, etc.) can
    /// mask a missing republish by re-bodying ContentView for us.
    ///
    /// Pre-fix, `source → hex` deterministically renders the STALE source
    /// NSTextView under a `hex`/`binary` model (verified 3/3). Post-fix the
    /// `updateDerived()` republish makes the byte grid mount immediately.
    /// A single switch with no prior WebView/select noise is the ONLY
    /// reliably-unmasked window — hence one switch per launch, not a long
    /// cycle (a cycle's later switches get masked by the churn).
    func test_singleModeSwitch_rendersTargetView() throws {
        let swiftFile = try harness.writeFile(
            "main.swift",
            "import Foundation\nstruct Main { static func main() { print(\"hi\") } }\n")
        let mdFile = try harness.writeFile(
            "readme.md",
            "# Title\n\nSome **bold** body text and a [link](https://example.com).\n")
        let pngFile = try writePNGFixture("pixel.png")

        try runScenarios([
            // source -> hex (loadBinaryAsync completion): the rock-solid
            // deterministic catch for the missing-republish defect.
            switchScenario(name: "swift_source-to-hex", file: swiftFile,
                           from: "source", to: "hex"),
            switchScenario(name: "log_source-to-hex",
                           file: try harness.writeFile("a.log", "INFO one\nINFO two\n"),
                           from: "source", to: "hex"),
            // source -> editor (WKWebView mounts; proves the #192-excluded
            // editor surface renders on the real artifact).
            switchScenario(name: "swift_source-to-editor", file: swiftFile,
                           from: "source", to: "editor"),
            // markdown rendered -> source -> hex covered by single switches:
            switchScenario(name: "md_rendered-to-source", file: mdFile,
                           from: "rendered", to: "source"),
            switchScenario(name: "md_rendered-to-hex", file: mdFile,
                           from: "rendered", to: "hex"),
            // image preview -> hex -> (back) preview is the native-preview
            // round trip through loadBinaryAsync + controller.open restore.
            switchScenario(name: "png_preview-to-hex", file: pngFile,
                           from: "preview", to: "hex"),
        ])
    }

    /// Lazy-materialize path (bug 1): append a file as a lazy `.empty` tab,
    /// then `select-tab` it so it materializes through `materializeIfNeeded`'s
    /// async completion — the exact path that produced "main.swift cannot be
    /// loaded" in the live app (workspace restore / multi-file drop). The
    /// argv-open of a single small file takes the SYNCHRONOUS path (which
    /// always republished), so it cannot reproduce bug 1; this scenario
    /// must use the lazy path.
    func test_lazyMaterializedTab_rendersContentNotBlank() throws {
        let first = try harness.writeFile(
            "first.swift", "let first = 1\n// argv-opened, eager\n")
        let second = try harness.writeFile(
            "second.swift",
            "let second = 2\nstruct LazyMaterialized { let marker = \"second-file\" }\n")

        // argv opens `first` eagerly (tab 1, focused). `open-lazy second`
        // appends `second` as a `.empty` tab 2 WITHOUT selecting it.
        // `select-tab 2` then runs `materializeIfNeeded(at:)`, whose async
        // completion (DocumentModel.swift) commits `.loaded` via
        // `tabCoordinator.replace` — the site that, pre-fix, never
        // republished the model so the content pane stayed on the
        // `.loading` placeholder ("cannot be loaded" / blank).
        let script = """
        open-lazy \(second.path)
        delay 0.4
        select-tab 2
        delay 0.9
        """
        try runScenarios([
            Scenario(
                name: "lazy-materialize",
                argFile: first,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty,
                                   "no step dumps produced — app may not have launched",
                                   file: file, line: line)
                    // Final dump: tab 2 (second.swift) selected + materialized.
                    guard let last = dumps.last else { return }
                    XCTAssertEqual(modelString(last, "currentStateKind"), "loaded",
                                   "lazy tab did not reach .loaded after select",
                                   file: file, line: line)
                    XCTAssertTrue(modelString(last, "currentURL").hasSuffix("second.swift"),
                                  "selected tab is not the lazily-materialized file",
                                  file: file, line: line)
                    assertModelNotError(in: last, label: "lazy-materialize/final",
                                        file: file, line: line)
                    assertSourceTextRendered(in: last, label: "lazy-materialize/final",
                                             file: file, line: line)
                })
        ])
    }

    // MARK: - Scenario builders

    /// Open the file and assert ONLY the default view renders correctly.
    /// A `delay` step gives the launch open + (for markdown/preview) the
    /// WKWebView / native preview a beat to mount. The default-mode open
    /// goes through the synchronous path, so this is a steady-state check
    /// (no race), confirming each file type's natural view actually draws.
    private func openOnlyScenario(
        name: String, file: URL, expectMode: String
    ) -> Scenario {
        let script = "delay 1.0\n"
        return Scenario(
            name: name,
            argFile: file,
            script: script,
            assert: { [self] dumps, file, line in
                XCTAssertFalse(dumps.isEmpty,
                               "[\(name)] no step dumps — app may not have launched",
                               file: file, line: line)
                guard let dump = dumps.last else { return }
                assertMode(expectMode, file: file, label: "\(name)/open",
                           dump: dump, sourceLine: line)
            })
    }

    /// Fresh launch → exactly ONE mode switch → capture immediately (no
    /// trailing `delay`). Asserts the target mode's realized view mounted.
    /// This is the deterministic, unmasked window for the missing-republish
    /// defect (see the doc on `test_singleModeSwitch_rendersTargetView`).
    /// The `from` mode is the file's default and is asserted on the
    /// pre-switch dump as a sanity anchor.
    private func switchScenario(
        name: String, file: URL, from: String, to: String
    ) -> Scenario {
        // One short delay to let the launch open settle into `from`, then
        // the single switch verb. NO delay after the switch — the switch's
        // own 300 ms post-step capture is the unmasked observation point.
        let script = """
        delay 0.8
        editor-set-mode \(to)
        """
        return Scenario(
            name: name,
            argFile: file,
            script: script,
            assert: { [self] dumps, file, line in
                XCTAssertFalse(dumps.isEmpty,
                               "[\(name)] no step dumps — app may not have launched",
                               file: file, line: line)
                // dumps[0] = the `delay 0.8` step (file open settled in
                //            `from` mode).
                // dumps[1] = the `editor-set-mode <to>` step, captured
                //            ~300 ms later — the unmasked window.
                if let pre = dumps.first {
                    assertMode(from, file: file, label: "\(name)/from-\(from)",
                               dump: pre, sourceLine: line)
                }
                guard dumps.count >= 2 else {
                    XCTFail("[\(name)] missing the post-switch dump", file: file, line: line)
                    return
                }
                assertMode(to, file: file, label: "\(name)/to-\(to)",
                           dump: dumps[1], sourceLine: line)
            })
    }

    // MARK: - Per-mode assertions (realized tree + model consistency)

    private func assertMode(
        _ mode: String, file: StaticString, label: String,
        dump: [String: Any], sourceLine line: UInt
    ) {
        // (0) Never an error state — catches "main.swift cannot be loaded".
        assertModelNotError(in: dump, label: label, file: file, line: line)
        // (1) The picker reflects the requested mode (model layer).
        let vm = modelString(dump, "currentViewMode")
        XCTAssertEqual(vm, mode, "[\(label)] currentViewMode mismatch", file: file, line: line)
        // (2) Mode ↔ state consistency (catches the "Editor shows HEX"
        //     desync at the model layer).
        let stateKind = modelString(dump, "currentStateKind")
        switch mode {
        case "hex":
            XCTAssertEqual(stateKind, "binary",
                           "[\(label)] HEX picker but state != binary", file: file, line: line)
        case "preview":
            XCTAssertEqual(stateKind, "preview",
                           "[\(label)] Preview picker but state != preview", file: file, line: line)
        case "source", "editor", "rendered":
            XCTAssertNotEqual(stateKind, "binary",
                              "[\(label)] non-HEX picker but state == binary (HexView under \(mode))",
                              file: file, line: line)
        default:
            break
        }
        // (3) The realized tree shows the right content for the mode —
        //     this is the load-bearing check that the headless tiers cannot
        //     make. It catches a stale/blank/wrong view even when the model
        //     is internally consistent.
        //
        //     NOTE: SwiftUI's `.accessibilityIdentifier()` sets the AX-tree
        //     identifier, which is NOT propagated onto `NSView.
        //     accessibilityIdentifier()` that `DiagnosticDump` reads — so the
        //     dump carries no a11y ids. We therefore detect the mounted view
        //     by NSView CLASS (same approach as ContentViewHostingTests),
        //     which IS in the dump.
        switch mode {
        case "source":
            // Source view: a plain NSTextView (NOT the HexNSTextView
            // subclass) with generated, contrasting glyphs.
            assertSourceTextRendered(in: dump, label: label, file: file, line: line)
        case "editor":
            // CM6 editor is a WKWebView. Must be present AND the document
            // must NOT still be showing source/hex text (the desync).
            assertWebViewRendered(in: dump, label: label, file: file, line: line)
            assertNoBareSourceTextView(in: dump, label: label, file: file, line: line)
            assertNoHexView(in: dump, label: label, file: file, line: line)
        case "rendered":
            // Markdown rendered is a WKWebView (MarkdownRenderedView).
            assertWebViewRendered(in: dump, label: label, file: file, line: line)
            assertNoHexView(in: dump, label: label, file: file, line: line)
        case "hex":
            // HEX shows a HexNSTextView byte grid with visible bytes.
            assertHexRendered(in: dump, label: label, file: file, line: line)
        case "preview":
            // Native preview lens. The byte grid (HexNSTextView) must be
            // gone, and the pane must carry a real preview subtree — for
            // images the ZoomableImageScrollView / image view; for the
            // SQLite browser an NSSplitView with content (no dedicated
            // a11y id / distinctive class exists for the latter).
            assertNoHexView(in: dump, label: label, file: file, line: line)
            assertPreviewRendered(in: dump, label: label, file: file, line: line)
        default:
            break
        }
    }

    // MARK: - Tree-walk helpers (operate on the serialized DiagnosticDump)

    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        (dump["model"] as? [String: Any])?[key] as? String ?? ""
    }

    private func assertModelNotError(
        in dump: [String: Any], label: String,
        file: StaticString, line: UInt
    ) {
        let kind = modelString(dump, "currentStateKind")
        XCTAssertNotEqual(
            kind, "error",
            "[\(label)] document landed in .error state (\"cannot be loaded\")",
            file: file, line: line)
        XCTAssertNotEqual(
            kind, "loading",
            "[\(label)] document stuck in .loading (async completion never committed?)",
            file: file, line: line)
    }

    /// Walk the `contentView` subtree depth-first, returning every node
    /// dict. The dump nests children under the `subviews` key.
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

    /// True if any node's class name contains `needle`.
    private func hasViewClass(_ dump: [String: Any], containing needle: String) -> Bool {
        allNodes(in: dump).contains {
            (($0["class"] as? String) ?? "").contains(needle)
        }
    }

    /// True if any NSTextView node (incl. the HexNSTextView subclass) has
    /// generated, contrasting glyphs.
    private func anyTextViewWithGlyphs(_ dump: [String: Any]) -> Bool {
        allNodes(in: dump).contains { node in
            guard let tv = node["nsTextView"] as? [String: Any] else { return false }
            let glyphs = (tv["numberOfGlyphs"] as? Int) ?? 0
            let contrasts = (tv["contrastsWithBackground"] as? Bool) ?? false
            return glyphs > 0 && contrasts
        }
    }

    /// Source mode: a *non-hex* NSTextView with visible glyphs, and the
    /// HEX byte grid must be absent.
    private func assertSourceTextRendered(
        in dump: [String: Any], label: String,
        file: StaticString, line: UInt
    ) {
        assertNoHexView(in: dump, label: label, file: file, line: line)
        XCTAssertTrue(
            anyTextViewWithGlyphs(dump),
            "[\(label)] Source mode: no NSTextView with visible glyphs — content blank/stale",
            file: file, line: line)
        // And it must not be a WebView-only view (that would mean Editor/
        // Rendered mounted instead of Source).
        XCTAssertFalse(
            hasViewClass(dump, containing: "WKWebView"),
            "[\(label)] Source mode: a WKWebView is mounted — wrong view (editor/rendered) under Source picker",
            file: file, line: line)
    }

    /// Editor / Rendered: a real WKWebView must be mounted and not zero-sized.
    private func assertWebViewRendered(
        in dump: [String: Any], label: String,
        file: StaticString, line: UInt
    ) {
        let webNodes = allNodes(in: dump).filter { $0["wkWebView"] != nil }
        XCTAssertFalse(
            webNodes.isEmpty,
            "[\(label)] expected a WKWebView in tree — editor/rendered view did not mount",
            file: file, line: line)
        let anyVisible = webNodes.contains { $0["zeroSize"] == nil }
        XCTAssertTrue(
            anyVisible,
            "[\(label)] WKWebView present but zero-sized — content pane blank",
            file: file, line: line)
    }

    /// HEX: a HexNSTextView (the byte-grid text view subclass) with visible
    /// glyphs must be present.
    private func assertHexRendered(
        in dump: [String: Any], label: String,
        file: StaticString, line: UInt
    ) {
        XCTAssertTrue(
            hasViewClass(dump, containing: "Hex"),
            "[\(label)] HEX mode: no Hex* view in tree — byte grid did not mount",
            file: file, line: line)
        XCTAssertTrue(
            anyTextViewWithGlyphs(dump),
            "[\(label)] HEX mode: byte grid has no visible glyphs — blank",
            file: file, line: line)
    }

    /// The HEX byte grid must be ABSENT (used to catch HexView leaking under
    /// a non-HEX picker — the "Editor shows HEX" desync).
    private func assertNoHexView(
        in dump: [String: Any], label: String,
        file: StaticString, line: UInt
    ) {
        XCTAssertFalse(
            hasViewClass(dump, containing: "Hex"),
            "[\(label)] a Hex* byte-grid view is mounted under a non-HEX picker — stale/desynced view",
            file: file, line: line)
    }

    /// The editor/rendered web view must NOT leave a bare source NSTextView
    /// mounted (would indicate a stale Source view under the Editor picker).
    private func assertNoBareSourceTextView(
        in dump: [String: Any], label: String,
        file: StaticString, line: UInt
    ) {
        // The CM6 editor is a WebView, so a *non-hex* NSTextView in the
        // content pane while in editor mode means the source view is stale.
        let bareSourceTextView = allNodes(in: dump).contains { node in
            let cls = (node["class"] as? String) ?? ""
            // PlatformTextView / SelectionTextField etc. are chrome (status
            // bar, find fields); only the source NSTextView document view is
            // the tell. The source document view is class "NSTextView"
            // exactly (Hex is "HexNSTextView"); chrome text fields are
            // NSTextField subclasses, not NSTextView. So match the dump's
            // `nsTextView` payload on a node whose class is NOT a Hex view.
            guard node["nsTextView"] != nil, !cls.contains("Hex") else { return false }
            let tv = node["nsTextView"] as? [String: Any]
            let glyphs = (tv?["numberOfGlyphs"] as? Int) ?? 0
            // A meaningful amount of source text drawn (the document), not a
            // tiny status-bar label.
            return glyphs > 0 && (tv?["isEditable"] as? Bool) == false
        }
        XCTAssertFalse(
            bareSourceTextView,
            "[\(label)] a read-only source NSTextView is mounted under the Editor picker — stale Source view",
            file: file, line: line)
    }

    /// Preview mode: a real native preview subtree is mounted. Images use
    /// ZoomableImageScrollView / an NSImageView; the SQLite browser uses an
    /// NSSplitView with content. Either satisfies "preview rendered".
    private func assertPreviewRendered(
        in dump: [String: Any], label: String,
        file: StaticString, line: UInt
    ) {
        let hasImagePreview = hasViewClass(dump, containing: "ZoomableImageScrollView")
            || hasViewClass(dump, containing: "ImageScrollHost")
            || hasViewClass(dump, containing: "ImageView")
        let hasSplitBrowser = hasViewClass(dump, containing: "NSSplitView")
        XCTAssertTrue(
            hasImagePreview || hasSplitBrowser,
            "[\(label)] Preview mode: no image-preview or split-browser subtree — preview did not mount",
            file: file, line: line)
    }

    // MARK: - Binary fixtures

    /// A minimal valid 1×1 opaque-red PNG. Real magic bytes so
    /// `FileCategory` routes it to `.image` → `.preview` and
    /// `MediaPreviewView` can actually decode + draw it (a text file with a
    /// `.png` name would misroute / fail to decode and false-pass).
    private func writePNGFixture(_ name: String) throws -> URL {
        let url = harness.tmpDir.appendingPathComponent(name)
        // 1×1 red PNG (standard reference bytes).
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        guard let data = Data(base64Encoded: b64) else {
            throw XCTSkip("could not decode PNG fixture")
        }
        try data.write(to: url)
        return url
    }

    /// A real, valid, enumerable SQLite v3 database (one table + a few rows),
    /// so the SQLite browser mounts its `NSSplitView`. See `UATSQLiteFixture`.
    private func writeSQLiteFixture(_ name: String) throws -> URL {
        try UATSQLiteFixture.write(name, in: harness.tmpDir)
    }
}
