import XCTest
import ViewerKit
@testable import ViewerUI

/// Pure-logic tests that don't need a window or WKWebView. Cover:
///
/// 1. The CM6 bundle's three files (HTML host, JS, CSS) ship inside
///    `Bundle.module` so a future rebuild that drops one of them
///    surfaces here instead of as a blank webview at runtime.
/// 2. The JS→Swift bridge `CodeMirrorBridge.decode` correctly maps
///    every payload shape we care about to its action enum, and
///    rejects unknown / malformed payloads instead of crashing.
final class CodeMirrorBundleTests: XCTestCase {

    func testHostHTMLResourceExists() {
        let url = CodeMirrorResources.hostHTMLURL
        XCTAssertNotNil(url, "codemirror.html missing from ViewerUI resources")
        if let url = url {
            let size = (try? Data(contentsOf: url).count) ?? 0
            XCTAssertGreaterThan(size, 1000, "codemirror.html shrunk suspiciously to \(size) bytes")
        }
    }

    func testJSBundleResourceExists() {
        let url = CodeMirrorResources.jsBundleURL
        XCTAssertNotNil(url, "codemirror.js bundle missing — re-run scripts/codemirror-build/npm run build")
        if let url = url {
            let size = (try? Data(contentsOf: url).count) ?? 0
            // Sanity: minified CM6 bundle is ~570 KB. Floor at 100 KB
            // catches an empty / esbuild-failed output without locking
            // us to a specific byte count on every rebuild.
            XCTAssertGreaterThan(size, 100_000, "codemirror.js suspiciously small: \(size) bytes")
            XCTAssertLessThan(size, 5_000_000, "codemirror.js suspiciously large: \(size) bytes — added too many languages?")
        }
    }

    func testHostCSSResourceExists() {
        let url = CodeMirrorResources.hostCSSURL
        XCTAssertNotNil(url, "codemirror.css missing from ViewerUI resources")
    }

    // MARK: - Phase 2: bundle contract for new dispatch surface
    //
    // We can't execute the JS here, but we can grep the HTML host's
    // dispatch switch and the JS bundle's exports to confirm Phase 2
    // wiring made it through the build.

    func testHostHTMLExposesNewDispatchTypes() throws {
        let url = try XCTUnwrap(CodeMirrorResources.hostHTMLURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        for needle in [
            "case \"setDiagnostics\"",
            "case \"setShowInvisibles\"",
            "case \"setSearchQuery\"",
            // UX-G find-and-replace: the dispatch cases + the replace
            // field seeded into the SearchQuery must survive the build.
            "case \"replaceNext\"",
            "case \"replaceAll\"",
            "replace: String(msg.replace",
            "findResultChanged",
            "applySetDiagnostics",
            "applySetShowInvisibles",
            "applySetSearchQuery",
        ] {
            XCTAssertTrue(html.contains(needle),
                          "codemirror.html missing Phase 2 wiring: \(needle)")
        }
    }

    /// Vim mode (TSK-679, owner-approved 2026-06-15). The HTML host must wire
    /// the dispatch case + compartment, and the JS bundle must export `vim`.
    /// A rebuild from a stale entry.js (missing the @replit/codemirror-vim
    /// import) or an HTML edit that drops the wiring trips here — host-side
    /// guard; live keystroke behavior is the VM smoke.
    func testVimModeWiringSurvivesBuild() throws {
        let htmlURL = try XCTUnwrap(CodeMirrorResources.hostHTMLURL)
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        for needle in [
            "case \"setVimMode\"", "applySetVimMode", "vimCompartment",
            // :w → save + footer mode-indicator wiring (TSK-679 follow-up).
            "Vim.defineEx", "vim-mode-change", "vimModeChanged",
        ] {
            XCTAssertTrue(html.contains(needle),
                          "codemirror.html missing vim wiring: \(needle)")
        }
        let jsURL = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let js = try String(contentsOf: jsURL, encoding: .utf8)
        for sym in ["vim:", "Vim:", "getCM:"] {
            XCTAssertTrue(js.contains(sym),
                          "codemirror.js missing export \(sym) — re-run scripts/codemirror-build npm run build")
        }
    }

    /// TSK-917: the line-number gutter must be non-selectable + show the
    /// default (not I-beam) cursor. Pure-CSS appearance fix in the chrome
    /// theme; the rule must survive in the host HTML (live look = VM tail).
    func testGutterNonSelectableWiringSurvivesBuild() throws {
        let html = try String(contentsOf: try XCTUnwrap(CodeMirrorResources.hostHTMLURL), encoding: .utf8)
        for needle in ["userSelect: \"none\"", "cursor: \"default\""] {
            XCTAssertTrue(html.contains(needle),
                          "codemirror.html missing gutter non-select wiring: \(needle)")
        }
    }

    /// TSK-893: the CM6 editing surface (`.cm-content`) must force the I-beam
    /// cursor so it never flips to the default arrow over editable text. Pure-CSS
    /// chrome-theme rule; the rule must survive in the host HTML (live look = VM
    /// tail). Distinct from the gutter's `cursor: "default"` (TSK-917) above.
    func testEditorContentForcesIBeamCursorSurvivesBuild() throws {
        let html = try String(contentsOf: try XCTUnwrap(CodeMirrorResources.hostHTMLURL), encoding: .utf8)
        XCTAssertTrue(html.contains("cursor: \"text\""),
                      "codemirror.html missing .cm-content I-beam cursor wiring (TSK-893)")
    }

    /// TSK-602 ViewOnly↔Editor color parity: the HTML host must carry the
    /// palette→HighlightStyle builder, and the JS bundle must export the
    /// symbols it needs (`HighlightStyle`, `tags`). A bundle rebuilt from a
    /// stale entry.js, or an HTML edit that drops the wiring, trips here.
    func testThemePaletteParityWiringSurvivesBuild() throws {
        let htmlURL = try XCTUnwrap(CodeMirrorResources.hostHTMLURL)
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        for needle in ["paletteExtensions", "msg.palette", "HighlightStyle.define"] {
            XCTAssertTrue(html.contains(needle),
                          "codemirror.html missing TSK-602 palette wiring: \(needle)")
        }
        let jsURL = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let js = String(data: try Data(contentsOf: jsURL), encoding: .utf8) ?? ""
        for needle in ["HighlightStyle:", "tags:"] {
            XCTAssertTrue(js.contains(needle),
                          "codemirror.js missing TSK-602 export: \(needle)")
        }
    }

    func testJSBundleExportsLintAndSearchAPIs() throws {
        let url = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let data = try Data(contentsOf: url)
        let js = String(data: data, encoding: .utf8) ?? ""
        // The IIFE bundle attaches every re-exported symbol off `window.CM`.
        // Just confirm string presence — the bundle is minified so name-
        // mangling on locals is fine but the export names survive.
        for needle in ["lintGutter", "setDiagnostics", "setSearchQuery", "SearchQuery", "replaceNext", "replaceAll"] {
            XCTAssertTrue(js.contains(needle),
                          "codemirror.js missing expected export: \(needle)")
        }
    }

    func testJSBundleSizeWithinPhase2Budget() throws {
        let url = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let size = try Data(contentsOf: url).count
        // Phase 2 plan: bundle stays below ~1.5 MB through Phase 4 even
        // with vim + extra languages. Today (Phase 2 with lint added)
        // we're at ~650 KB. Lock the upper bound at 1.5 MB so a slip
        // (e.g. accidentally bundling a non-minified build) trips here.
        XCTAssertLessThan(size, 1_500_000,
                          "codemirror.js bundle exceeded 1.5 MB Phase-2 budget: \(size) bytes")
    }

    // MARK: - Bridge action decoding

    func testBridgeDecodesReady() {
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "ready"]),
            .ready
        )
    }

    func testBridgeDecodesChangeWithText() {
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "change", "text": "hello world"]),
            .change(text: "hello world")
        )
    }

    func testBridgeDecodesChangeWithEmptyText() {
        // JS always sends text but we don't trust the wire — missing
        // key must decode to empty string, not nil-crash.
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "change"]),
            .change(text: "")
        )
    }

    func testBridgeDecodesSaveRequested() {
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "saveRequested"]),
            .saveRequested
        )
    }

    func testBridgeRejectsUnknownType() {
        XCTAssertNil(CodeMirrorBridge.decode(["type": "totallyMadeUp"]))
    }

    func testBridgeRejectsNonDictionary() {
        XCTAssertNil(CodeMirrorBridge.decode("not a dictionary"))
        XCTAssertNil(CodeMirrorBridge.decode(42))
        XCTAssertNil(CodeMirrorBridge.decode(NSNull()))
    }

    func testBridgeRejectsMissingType() {
        XCTAssertNil(CodeMirrorBridge.decode(["text": "no type field"]))
    }

    // MARK: - Language mapping

    func testLanguageMappingCoversCommonCases() {
        XCTAssertEqual(jsLanguageName(for: .markdown),   "markdown")
        XCTAssertEqual(jsLanguageName(for: .javascript), "javascript")
        XCTAssertEqual(jsLanguageName(for: .typescript), "typescript")
        XCTAssertEqual(jsLanguageName(for: .python),     "python")
        XCTAssertEqual(jsLanguageName(for: .json),       "json")
    }

    func testLanguageMappingFallsBackToPlain() {
        // TSK-1135 expanded the CM6 bundle to all 22 languages, so only the
        // explicit no-highlight fallback (`.plainText`) maps to "plain" now.
        XCTAssertEqual(jsLanguageName(for: .plainText), "plain")
    }

    /// TSK-1135: the CM6 editor now ships language packs (official Lezer +
    /// @codemirror/legacy-modes) for the full set the native tree-sitter engine
    /// covers. Every detectable language EXCEPT `.plainText` MUST resolve to a
    /// non-"plain" token AND have a matching `case "<token>":` in the bundled
    /// `codemirror.html` `languageFor` switch — otherwise it silently renders
    /// plain in the editor. This is the host guard for the 22-language coverage;
    /// on-screen per-language highlighting is WebView/VM-validated separately.
    func testAllTwentyTwoLanguagesMapToANonPlainEditorToken() throws {
        let html = try String(contentsOf: try XCTUnwrap(CodeMirrorResources.hostHTMLURL), encoding: .utf8)
        // The 22-language set the feature targets (jsx is folded into the
        // `.javascript` enum case for file detection; it's exercised via the
        // host `languageFor` switch directly below).
        let targets: [HighlightLanguage] = [
            .json, .rust, .javascript, .typescript, .tsx, .java, .c, .cpp,
            .csharp, .swift, .kotlin, .lua, .python, .shell, .yaml, .html,
            .css, .go, .ruby, .markdown, .xml, .sql,
        ]
        XCTAssertEqual(targets.count, 22, "expected exactly 22 target languages")
        for lang in targets {
            let token = jsLanguageName(for: lang)
            XCTAssertNotEqual(token, "plain",
                "\(lang.displayName) must resolve to a non-plain CM6 editor token (TSK-1135 22-language coverage)")
            XCTAssertTrue(html.contains("case \"\(token)\":"),
                "codemirror.html `languageFor` has no `case \"\(token)\":` for \(lang.displayName) — editor would render plain")
        }
        // `jsx` has no dedicated enum case but the host must still route it
        // (file extension `.jsx` maps to `.javascript`, but a fenced ```jsx or
        // an explicit mode pick can send "jsx" directly).
        XCTAssertTrue(html.contains("case \"jsx\":"),
            "codemirror.html `languageFor` dropped the `jsx` case — JSX files would lose highlighting")
    }

    /// TSK-1135: the JS bundle must actually export each new language-pack
    /// factory (Lezer packs) + the legacy-mode stream parsers + StreamLanguage.
    /// A rebuild from a stale entry.js (missing an import) trips here instead of
    /// silently rendering plain at runtime. The IIFE bundle emits `Name:()=>…`
    /// per re-export, so `Name:` survives minification.
    func testJSBundleExportsAllLanguagePacks() throws {
        let url = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let js = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        for sym in [
            // Official Lezer packs.
            "rust:", "java:", "cpp:", "sql:", "html:", "css:", "xml:", "go:",
            // StreamLanguage wrapper + legacy-mode parsers.
            "StreamLanguage:",
            "swiftMode:", "luaMode:", "shellMode:", "yamlMode:",
            "rubyMode:", "kotlinMode:", "csharpMode:",
        ] {
            XCTAssertTrue(js.contains(sym),
                "codemirror.js missing export \(sym) — re-run scripts/codemirror-build npm run build (TSK-1135)")
        }
    }

    /// TSK-897: `jsLanguageName` (the CM6 Editor's lang token) MUST agree with
    /// `HighlightLanguage.editorHighlightable` for every case — a language that
    /// reports it colors in the editor must NOT map to "plain", and vice-versa.
    /// This is what catches the "highlights in View but plain in Edit" gap: when
    /// a new `@codemirror/lang-*` pack is bundled, both must flip together.
    func testJSLanguageNameAgreesWithEditorHighlightable() {
        for lang in HighlightLanguage.allCases {
            let token = jsLanguageName(for: lang)
            if lang.editorHighlightable {
                XCTAssertNotEqual(token, "plain",
                    "\(lang.displayName).editorHighlightable == true but jsLanguageName == \"plain\" — editor would render plain")
            } else {
                XCTAssertEqual(token, "plain",
                    "\(lang.displayName).editorHighlightable == false but jsLanguageName == \"\(token)\" — CM6 has no pack for it, must fall back to plain")
            }
        }
    }

    /// The CM6 host's `languageFor` switch must actually handle every non-"plain"
    /// token `jsLanguageName` can emit — otherwise a token reaches the editor that
    /// `languageFor` doesn't recognise and silently falls through to plain text.
    /// Pins the Swift→JS token contract against the bundled `codemirror.html`.
    func testEveryEmittedLanguageTokenIsHandledByHostHTML() throws {
        let html = try String(contentsOf: try XCTUnwrap(CodeMirrorResources.hostHTMLURL), encoding: .utf8)
        let tokens = Set(HighlightLanguage.allCases.map { jsLanguageName(for: $0) })
            .filter { $0 != "plain" }
        for token in tokens {
            XCTAssertTrue(html.contains("case \"\(token)\":"),
                "codemirror.html `languageFor` has no `case \"\(token)\":` — the editor emits this token but the host can't map it to a language")
        }
    }

    // MARK: - Phase 3: hover / Cmd-click / context-menu wiring

    func testHostHTMLExposesPhase3DispatchSurface() throws {
        let url = try XCTUnwrap(CodeMirrorResources.hostHTMLURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        for needle in [
            // JS → Swift outbound shapes
            "requestHover",
            "requestDefinition",
            "contextMenuRequested",
            // Swift → JS inbound dispatch handlers
            "case \"hoverResponse\"",
            "case \"setSaveOnBlur\"",
            // CM6 hoverTooltip + custom CSS class for our popover
            "cm-tooltip-hover-lsp",
            "buildHoverExtension",
        ] {
            XCTAssertTrue(html.contains(needle),
                          "codemirror.html missing Phase 3 wiring: \(needle)")
        }
    }

    func testJSBundleExportsHoverTooltip() throws {
        let url = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let data = try Data(contentsOf: url)
        let js = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(js.contains("hoverTooltip"),
                      "codemirror.js missing hoverTooltip export — re-run scripts/codemirror-build/npm run build")
    }

    // MARK: - Phase 4 (v2) bundle contract
    //
    // v2 introduced: incremental-change emitter, applyEdits inbound,
    // LSP-driven foldService, diff/blame gutter, indent guides. We
    // can't execute the JS here (CLAUDE.md), but grep-tests pin the
    // wiring so a future entry.js or codemirror.html slip surfaces
    // immediately. The actual behaviour is exercised by the VM-only
    // EditorMultiScenarioTests + Swift-side unit suites.

    func testHostHTMLExposesPhase4DispatchSurface() throws {
        let url = try XCTUnwrap(CodeMirrorResources.hostHTMLURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        for needle in [
            "PROTOCOL_VERSION = 2",
            "PROTOCOL_OLDEST_SUPPORTED",
            // v2 inbound emitter
            "incrementalChange",
            "accumulateChanges",
            "ChangeSet.compose|.compose(", // either form survives
            // v2 dispatcher entries
            "case \"applyEdits\"",
            "case \"setFoldingRanges\"",
            "case \"setGutterMarkers\"",
            "case \"setIndentGuides\"",
            // Wired plugins
            "buildFoldService",
            "buildDiffGutter",
            "buildIndentGuidesPlugin",
            "applyApplyEdits",
        ] {
            let alts = needle.split(separator: "|").map(String.init)
            let found = alts.contains(where: { html.contains($0) })
            XCTAssertTrue(found,
                          "codemirror.html missing Phase 4 wiring: \(needle)")
        }
    }

    func testJSBundleExportsPhase4Surface() throws {
        let url = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let data = try Data(contentsOf: url)
        let js = String(data: data, encoding: .utf8) ?? ""
        // foldService is the @codemirror/language facet driving the
        // LSP-fold extension; GutterMarker is the @codemirror/view base
        // class for our diff bar; StateField is the v2 base for the
        // marker-map field. All three must survive minification by
        // name (re-exported off `window.CM`).
        for needle in ["foldService", "GutterMarker", "StateField"] {
            XCTAssertTrue(js.contains(needle),
                          "codemirror.js missing Phase 4 export: \(needle)")
        }
    }

    func testJSBundleSizeWithinPhase4Budget() throws {
        let url = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let size = try Data(contentsOf: url).count
        // Phase 4 plan §19 (design doc): ≤ 1.5 MB even with vim mode
        // + extras layered in. Today (Phase 4 without vim) we're at
        // ~607 KB. Lock the upper bound + assert the post-phase-3
        // baseline (570 KB) wasn't catastrophically halved by a
        // misconfigured esbuild.
        XCTAssertLessThan(size, 1_500_000,
                          "codemirror.js bundle exceeded 1.5 MB Phase-4 budget: \(size) bytes")
        XCTAssertGreaterThan(size, 400_000,
                             "codemirror.js bundle shrank suspiciously below post-Phase-3 baseline: \(size) bytes")
    }

    func testHostCSSCarriesPhase4Markers() throws {
        let url = try XCTUnwrap(CodeMirrorResources.hostCSSURL)
        let css = try String(contentsOf: url, encoding: .utf8)
        for needle in [
            ".cm-diff-added", ".cm-diff-removed", ".cm-diff-modified",
            ".cm-blame-marker", ".cm-indent-guide",
        ] {
            XCTAssertTrue(css.contains(needle),
                          "codemirror.css missing Phase 4 marker class: \(needle)")
        }
    }

    // MARK: - Invisibles rendering contract (item I2)
    //
    // The show-invisibles cue is IntelliJ-style: middle-dot for space,
    // arrow for tab, pilcrow for line break — rendered in a subtle-but-
    // readable *secondary* tone (was a washed-out flat mid-grey, "too
    // grey"). Both halves live in the bundle (glyphs in the HTML plugin,
    // color in the CSS), so we pin them headlessly here. Behaviour is
    // exercised live by the MDV_RUN_WEBVIEW_TESTS / VM lane; this guards
    // a silent bundle-rebuild regression.

    func testInvisiblesPluginUsesIntelliJStyleGlyphs() throws {
        let url = try XCTUnwrap(CodeMirrorResources.hostHTMLURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        // The exact glyphs the show-invisibles ViewPlugin substitutes.
        // Asserting the source literals so a future glyph swap is a
        // deliberate, test-visible change.
        XCTAssertTrue(html.contains("InvWidget(\"·\")"),
                      "show-invisibles plugin no longer uses middle-dot (·) for space")
        XCTAssertTrue(html.contains("InvWidget(\"→\")"),
                      "show-invisibles plugin no longer uses arrow (→) for tab")
        XCTAssertTrue(html.contains("InvWidget(\"↵\")"),
                      "show-invisibles plugin no longer uses return-arrow (↵) for line break")
    }

    func testInvisiblesColorIsReadableSecondaryNotFlatGrey() throws {
        let url = try XCTUnwrap(CodeMirrorResources.hostCSSURL)
        let css = try String(contentsOf: url, encoding: .utf8)
        // The `.cm-invisible` rule must exist and be theme-scoped: a
        // light-mode default plus a `body.dark` override (the old flat
        // `rgba(127, 127, 127, 0.5)` applied to both themes and washed
        // out against each background).
        XCTAssertTrue(css.contains(".cm-invisible"),
                      "codemirror.css dropped the .cm-invisible rule")
        XCTAssertTrue(css.contains("body.dark .cm-invisible"),
                      "codemirror.css missing the dark-theme .cm-invisible override — " +
                      "invisibles would be illegible on the dark background")
        XCTAssertFalse(css.contains("rgba(127, 127, 127, 0.5)"),
                       "codemirror.css still uses the washed-out flat mid-grey for " +
                       "invisibles (item I2: should be a subtle-but-readable secondary)")
    }

    // MARK: - Bootstrap symbol-binding contract (regression: WidgetType)
    //
    // The CM6 Phase-4 bug (commit 4ab4c56) was a `class IndentGuideWidget
    // extends WidgetType` at the top level of the bootstrap IIFE while
    // `WidgetType` was never added to the top-level `const { … } = window.CM`
    // destructure. A class declaration's `extends` clause is evaluated when
    // the script runs, so the bootstrap threw `ReferenceError: Can't find
    // variable: WidgetType` BEFORE `new EditorView(...)`, `window.cmDispatch`,
    // or the `ready` post — every editor tab was a permanently blank
    // WKWebView since Phase 4. None of the existing grep tests caught it:
    // they assert the bundle EXPORTS a symbol and the HTML CONTAINS a
    // dispatch-case string, but never that an extended base class is
    // actually BOUND in scope, and they never execute the bootstrap in a
    // JS engine (the live-WKWebView suites are MDV_RUN_WEBVIEW_TESTS-gated
    // out of the host sweep — CLAUDE.md).
    //
    // These two tests close exactly that gap, headlessly:
    //   1. Every CM base class used in a top-level `class X extends Y` must
    //      appear in the top-level `window.CM` destructure (so the bootstrap
    //      can't throw a ReferenceError before mounting the editor).
    //   2. Every symbol the bootstrap destructures from `window.CM` AND uses
    //      as an `extends` base must actually be exported by the JS bundle
    //      (so the destructure binds a real value, not `undefined`).

    /// Extracts the single top-level `const { … } = window.CM;` destructure
    /// block (lines 21-37 of codemirror.html) and returns the set of names
    /// bound by it. Robust to whitespace / line comments inside the braces.
    private func topLevelCMDestructure(in html: String) throws -> Set<String> {
        // Grab text between `= {` of the destructure and `} = window.CM`.
        // The bootstrap's first `const {` opens the block; `} = window.CM`
        // closes it. (The nested re-destructure inside buildInvisiblesPlugin
        // is `const { … } = window.CM;` on a SINGLE line, so anchoring on the
        // multi-line `const {\n` opener selects the top-level one.)
        guard let openRange = html.range(of: "const {\n") else {
            XCTFail("codemirror.html: no top-level `const {` destructure found")
            return []
        }
        let after = html[openRange.upperBound...]
        guard let closeRange = after.range(of: "} = window.CM;") else {
            XCTFail("codemirror.html: top-level destructure not closed with `} = window.CM;`")
            return []
        }
        let body = after[..<closeRange.lowerBound]
        // Strip `// …` line comments, split on commas / newlines, keep
        // identifier-shaped tokens.
        var names: Set<String> = []
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.split(separator: "/").first.map(String.init) ?? String(rawLine)
            for token in line.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }) {
                let t = token.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty,
                      t.first.map({ $0.isLetter }) == true,
                      t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
                else { continue }
                names.insert(t)
            }
        }
        return names
    }

    /// All `class X extends Y` base classes (`Y`) referenced anywhere in the
    /// bootstrap, restricted to CapitalCase identifiers (CM exports are
    /// CapitalCase; `extends` of a lower-case local helper would be a
    /// different thing).
    private func extendedBaseClasses(in html: String) -> Set<String> {
        var bases: Set<String> = []
        // Simple scan for "extends <Identifier>" — sufficient for the
        // hand-written bootstrap (no minified soup here).
        var search = html.startIndex
        let marker = "extends "
        while let r = html.range(of: marker, range: search..<html.endIndex) {
            var idx = r.upperBound
            var ident = ""
            while idx < html.endIndex {
                let c = html[idx]
                if c.isLetter || c.isNumber || c == "_" { ident.append(c); idx = html.index(after: idx) }
                else { break }
            }
            if let first = ident.first, first.isUppercase { bases.insert(ident) }
            search = idx
        }
        return bases
    }

    func testBootstrapExtendedBaseClassesAreDestructured() throws {
        let url = try XCTUnwrap(CodeMirrorResources.hostHTMLURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        let destructured = try topLevelCMDestructure(in: html)
        let bases = extendedBaseClasses(in: html)
        XCTAssertFalse(bases.isEmpty,
                       "no `class … extends …` found — parser likely broken")
        // The exact regression: WidgetType (and GutterMarker) are used as
        // base classes in the bootstrap; both MUST be in the top-level
        // window.CM destructure or the IIFE throws ReferenceError before
        // mounting the editor.
        for base in bases {
            XCTAssertTrue(
                destructured.contains(base),
                "codemirror.html bootstrap extends `\(base)` but never " +
                "destructures it from window.CM — the IIFE will throw " +
                "ReferenceError: Can't find variable: \(base) before " +
                "new EditorView(...), leaving every editor tab a blank " +
                "WKWebView. Add `\(base)` to the top-level `const { … } = " +
                "window.CM;` block (this is the CM6 Phase-4 WidgetType bug, " +
                "commit 4ab4c56).")
        }
        // Belt-and-braces: pin the two we know are load-bearing today so a
        // future refactor that drops them from the destructure trips here
        // even if the `extends`-scan misses them.
        for required in ["WidgetType", "GutterMarker"] {
            XCTAssertTrue(destructured.contains(required),
                          "codemirror.html top-level destructure dropped `\(required)`")
        }
    }

    func testBundleExportsEveryExtendedBaseClass() throws {
        let htmlURL = try XCTUnwrap(CodeMirrorResources.hostHTMLURL)
        let jsURL = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let js = String(data: try Data(contentsOf: jsURL), encoding: .utf8) ?? ""
        // A destructured-but-undefined symbol binds `undefined`; `extends
        // undefined` throws at class-eval time. So every extended base must
        // also be present (as an export) in the bundle. The IIFE bundle
        // emits `Name:()=>local` for each re-export, so `Name:` survives
        // minification.
        for base in extendedBaseClasses(in: html) {
            XCTAssertTrue(
                js.contains("\(base):"),
                "codemirror.js does not export `\(base)` (no `\(base):` " +
                "re-export found) yet the host bootstrap extends it — the " +
                "destructure would bind undefined and `extends undefined` " +
                "throws. Re-run scripts/codemirror-build/npm run build.")
        }
    }
}
