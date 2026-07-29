# Test Slice 4/6: ViewerUITests Root (files 208–276) — Analysis & Rebuild Guidance

**Batch scope:** 69 test files, ~7,580 LOC total  
**Slice range:** ImageEditorTonePaintGateTests.swift through PDFFindDriverTests.swift

---

## File Inventory

**`ImageEditorTonePaintGateTests.swift`** (49 LOC) — tier: headless-unit · framework: XCTest · pins: tone-controls disabled during paint mode; `isToneEditable` contract · teeth: real (asserts state flips on beginStroke/revertAll)

**`ImageEditorUndoOrderingTests.swift`** (58 LOC) — tier: headless-unit · framework: XCTest · pins: unified paint+geometry undo timeline; peels ops in order (paint then resize, not vice-versa) · teeth: real (asserts pixel counts + frame dimensions post-undo/redo)

**`ImageEditorVectorEditTests.swift`** (73 LOC) — tier: headless-unit · framework: XCTest · pins: vector shape hit-test pick (front-most), resize-by-handle frame mutation, undo-ability of resize · teeth: real (normalized frame coords ±1e-6 tolerance; undo restores exact pre-resize state)

**`ImageEditorViewModelTests.swift`** (482 LOC) — tier: headless-unit · framework: XCTest · pins: debounced slider render (no per-delta sync render), coalesced burst → one render, brightness/saturation pixel mutations, geometry ops, undo/redo, reset tonal, revert all · teeth: real (pixel samples via CoreImage decode + raster; render count assertions; undo-stack depth)

**`ImageEditorVisualRegressionTests.swift`** (161 LOC) — tier: T5-pixel · framework: XCTest · pins: compositor occlusion regression guard; preview + controls panels composite (≥3 color variety in WindowServer pixels) · teeth: real (fails if opaque representable occludes SwiftUI siblings; quad-color fixture guarantees non-uniform rendered preview; T5 screenshot + region-variety assertions)

**`ImageEditStateTests.swift`** (83 LOC) — tier: headless-unit · framework: XCTest · pins: edit-state Codable round-trip (capture → JSON encode/decode → restore on fresh VM); init-with-seed at construction (first-render paints edits) · teeth: real (asserts all tonal sliders + geometry ops + overlay shapes survive JSON cycle)

**`ImageElementPropertiesPanelRenderTests.swift`** (93 LOC) — tier: webview-inprocess · framework: XCTest · pins: inspector shape-gated (ColorWell renders only when shape selected; nil selection → no controls) · teeth: real (recurses view tree for NSColorWell + NSTextField presence; `#192`-gated)

**`InteractionDeepResizeTests.swift`** (54 LOC) — tier: T4-live · framework: XCTest · pins: window resize verb (`resize WxH`) mutates NSWindow.frame incl. OS clamping to screen geometry · teeth: real (reads back `dump["window"]["frame"]` post-resize; hermetic DocumentModel can't test this in-process; VM lane only)

**`InteractionDeepTests.swift`** (174 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: tab cycling (next-tab, prev-tab, select-by-index), close-middle-tab preserves neighbors, palette show/dismiss flag toggle, zoom persistence across tab open · teeth: real (window-title projections from model, model bool flags, no generic node-count flakes)

**`InteractionProfileHarness.swift`** (653 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: per-interaction main-thread latency (SwiftUI body re-eval + AppKit layout); opt-in `MDV_PROFILE=1` profiler for ranked interaction slowness · teeth: weak (timing is load-dependent; self-skips in merge gate; perf-bench flake exemption applies)

**`InteractionScriptTests.swift`** (127 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: `--script` verb application: toggle-view, next-tab, select-tab, close-tab, open, keyboard navigation (arrow-up/down) · teeth: real (reads model.windowTitle, model.zoom, tab array bounds, mode state from Codable dumps)

**`LandingRecentsTests.swift`** (37 LOC) — tier: headless-unit · framework: XCTest · pins: `DocumentModel.landingRecents` cap enforcement; empty/under-cap/over-cap pass-through · teeth: real (asserts array length == cap and order preserved)

**`LargeFileOpenTests.swift`** (170 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: large-file async load path; soft-warn threshold triggers off-main load; mode stays `.loading` until text completes; binary loads (hex view) faster path · teeth: real (asserts `model.currentTab.state` flow + byte counts + load timing deltas)

**`LaunchHarnessTierGateTests.swift`** (39 LOC) — tier: headless-unit · framework: XCTest · pins: T4/T5 launch gate decision logic (never spawns app off stray bundle on bare host; headless-gate always disables; VM GUI lane opts in) · teeth: real (pure boolean guards; prevents footgun that put windows on owner's screen)

**`LaunchSmokeTests.swift`** (53 LOC) — tier: T4-live · framework: XCTest · pins: one representative smoke scenario: launch → open file → dispatch verb (toggle-view) → exit(0) without crash; AppDelegate↔coordinator wiring · teeth: real (only test that exercises full boot path; fails if launch sequence crashes)

**`LineNumberRulerViewTests.swift`** (54 LOC) — tier: headless-unit · framework: XCTest · pins: newline UTF-16 offset scan (rewrite from per-char ObjC NSString message-send to single Swift utf16 pass); equivalence vs old implementation over mixed corpus (ASCII, CRLF, emoji, CJK) · teeth: real (binary-search line lookup depends on exact offsets; surrogate-pair handling)

**`LiveElementRefTargetTests.swift`** (72 LOC) — tier: headless-unit · framework: XCTest · pins: element ID → unique ref target; sidebar nav to ref (jump + highlight); out-of-order anchors; missing target (no-op) · teeth: unclear (model state asserts; no screen render validation)

**`LocalHistoryRestoreTests.swift`** (175 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: session snapshots restore (document text, scroll offset, selection, fold state, tab list); re-open old session; create new session · teeth: real (asserts DocumentModel state + rendered output matches snapshot archive)

**`LocalHistorySaveWiringTests.swift`** (142 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: on-close snapshot capture (text, scroll, selection, folds, tab state); timing of save (after close, before open); snapshot archive structure · teeth: real (reads JSON snapshots + validates keys; timing assertions)

**`LocalHistoryWiringTests.swift`** (55 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: local-history tab/session lifecycle wiring (trash, restore from trash, durable per-session metadata) · teeth: real (asserts file existence post-save + restore; state fidelity)

**`LogPatternsWiringTests.swift`** (53 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: log panel regex-match filtering; pattern field wiring to tab state · teeth: real (model state asserts; line count post-filter)

**`LogTimestampTests.swift`** (52 LOC) — tier: headless-unit · framework: XCTest · pins: log-line timestamp parsing (ISO 8601, milliseconds, wall-clock vs elapsed); format round-trip · teeth: real (asserts parsed components; Date equivalence)

**`LongFlowRelaunchTests.swift`** (57 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: multi-step workflow persistence (open → edit → close → relaunch); state survives the relaunch cycle · teeth: real (asserts document content + edits after relaunch)

**`LongFlowTests.swift`** (136 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: 15–20 step interaction flow; cumulative state transitions (tab open, mode switch, sidebar nav, palette toggle) · teeth: real (model state assertions; tab indices + modes stay consistent)

**`LSPDidSaveWiringTests.swift`** (93 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: on-file-save LSP `didSave` notification dispatch (text sync, diagnostics refresh) · teeth: real (asserts model.lspDiagnostics update post-save + timing)

**`LSPEditActionSafetyTests.swift`** (67 LOC) — tier: headless-unit · framework: XCTest · pins: LSP text-edit application safety (out-of-bounds edits no-op; version mismatch rejected; concurrent edits coalesce) · teeth: real (asserts document state unchanged on bad edit)

**`LSPFacadeConsolidationTests.swift`** (213 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: LSPFacade consolidation (multiple protocol requests → single RPC round-trip; response coalescence) · teeth: real (asserts request count, coalesce timing, result correctness)

**`LSPFormatEndToEndTests.swift`** (118 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: textDocument/formatting verb; Rust-core RPC round-trip; formatted text → model update · teeth: real (asserts pre/post text diffs; model.documentText consistency)

**`LSPGotoCommandTests.swift`** (258 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: goto-definition / goto-reference nav; symbol resolution + line jump; cross-file nav; LSP symbol hierarchy · teeth: real (asserts model.selection + window-title post-jump; multi-file scenarios)

**`LSPHoverTokenInvalidateTests.swift`** (119 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: hover popover invalidation (edit during hover; cursor move; mode switch; cancel hover) · teeth: real (asserts hover state bools; hover content cleared appropriately)

**`LSPMarkdownRendererTests.swift`** (130 LOC) — tier: headless-unit · framework: XCTest · pins: String → NSAttributedString markdown render (plain vs markdown branch, fenced-code-block toggle, inline bold/italic/code traits, trailing-newline trim) · teeth: real (samples font traits, colors, backgrounds via NSAttributedString introspection)

**`LSPNavigateActionSafetyTests.swift`** (68 LOC) — tier: headless-unit · framework: XCTest · pins: LSP navigate-action bounds safety (out-of-range line/char rejected; missing symbol no-op) · teeth: real (asserts current-tab state unchanged on bad nav)

**`LSPRenameEndToEndTests.swift`** (360 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: symbol rename (multi-occurrence replace, cross-file rename, undo after rename, live symbol highlight invalidation) · teeth: real (asserts text mutations, model state post-rename, undo/redo behavior)

**`MarkdownJSEscapeTests.swift`** (69 LOC) — tier: headless-unit · framework: XCTest · pins: JS-escape filter for markdown code-blocks (prevent XSS in `<pre><code>`; escapes `</script>`, `\`, backticks) · teeth: real (asserts output escapes match known-safe corpus)

**`MarkdownLinkPolicyTests.swift`** (345 LOC) — tier: headless-unit · framework: XCTest · pins: markdown link `href` sandbox policy (file://, http/https allowed; javascript: blocked; relative URL resolution; anchor fragments) · teeth: real (asserts allowed/blocked per test matrix; URL parse edge cases)

**`MarkdownOutlineModelTests.swift`** (94 LOC) — tier: headless-unit · framework: XCTest · pins: outline panel ObservableObject (rebuild heading extraction, clamp stale index, scroll-follow no-op guard, filter row indices, keyboard step) · teeth: real (asserts heading list, index bounds, objectWillChange fire count)

**`MarkdownOutlinePanelTests.swift`** (52 LOC) — tier: headless-unit · framework: XCTest · pins: outline panel UI state wiring (filter query, selection highlight) · teeth: weak (model assertions only; no view render validation)

**`MarkdownTableFormatModelTests.swift`** (87 LOC) — tier: headless-unit · framework: XCTest · pins: table-format verb model (parse markdown table, reformat on-column-change, row/column bounds) · teeth: real (asserts reformatted output; Markdown.Table AST mutations)

**`MarkdownTocVerbIntegrationTests.swift`** (69 LOC) — tier: headless-unit · framework: XCTest · pins: insert-TOC verb (parse headings, generate markdown link list, insert at cursor) · teeth: real (asserts generated TOC text, heading hierarchy levels)

**`MediaPreviewInfoZoomTests.swift`** (20 LOC) — tier: headless-unit · framework: XCTest · pins: media-preview info-panel zoom label (renders readable zoom %, wraps 100% display) · teeth: weak (single label format assertion; minimal coverage)

**`MemoryReclaimOnCloseTests.swift`** (138 LOC) — tier: headless-unit · framework: XCTest · pins: close-tab memory reclaim (LSP diagnostics cleared, per-tab caches emptied); WebKit/WebContent process residual is #191 owner-deferred · teeth: real (asserts model.lspDiagnostics.byURL emptied on close; multi-tab guards)

**`MermaidBundleLoadTests.swift`** (24 LOC) — tier: headless-unit · framework: XCTest · pins: bundled Mermaid library integrity (SHA pin, byte count, not-embedded-in-exec) · teeth: real (asserts bundle presence + digest match)

**`MermaidHostingTests.swift`** (126 LOC) — tier: webview-inprocess · framework: XCTest · pins: `.mmd` file routes to rendered pipeline (WKWebView host), not source view; open/close notebook scenarios · teeth: real (asserts ContentView branches correctly per file category; `#192`-gated; WebContent teardown)

**`MermaidRenderModelTests.swift`** (119 LOC) — tier: headless-unit · framework: XCTest · pins: `.mmd`→fence synthesis, HTMLRenderer mermaid host div, cache hit on second open, error-state render · teeth: real (asserts rendered HTML string structure; cache behavior)

**`MermaidRenderProbeTests.swift`** (77 LOC) — tier: headless-unit · framework: XCTest · pins: Mermaid syntax validation probe (detects parse errors, renders error message in fallback) · teeth: real (asserts probe output on valid/invalid diagrams)

**`MetadataChecksumModelTests.swift`** (253 LOC) — tier: headless-unit · framework: XCTest · pins: file metadata checksum (SHA256 of text + binary ops, detect external edits, stale-snapshot detection) · teeth: real (asserts checksum mutations on edit, external-change detection)

**`MetadataPanelTests.swift`** (285 LOC) — tier: headless-unit · framework: XCTest · pins: metadata panel display (file size, checksum, modified date, encoding, line count, word count stats) · teeth: real (asserts stat computations; encoding detection)

**`ModeSwitchRaceLiveTimingTests.swift`** (120 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: mode-switch async load race with live timing (hex↔source toggle sequences, late completions, state consistency under hammer load) · teeth: real (asserts tab state never stranded in `.loading` or `.binary` after source select; timeout-based timing)

**`ModeSwitchRaceTests.swift`** (232 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: Bug C — mode-switch race invariants (tab state consistent with viewMode, no stranded `.loading`, latest switch wins) · teeth: real (drives real async loaders via softWarnBytes; asserts end state post-race)

**`MountedPanesWiringTests.swift`** (148 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: split-pane mounting (sidebar + content split persistence, pane proportions, toggle sidebar collapse) · teeth: real (asserts model.sidebar.isVisible + frame proportions)

**`MultiCursorWebViewTests.swift`** (101 LOC) — tier: webview-inprocess · framework: XCTest · pins: CM6 multi-cursor editing (live WebView; add/remove cursors, move independent; each cursor tracks selection) · teeth: real (asserts cursor positions via CM6 state; `#192`-gated WebView teardown)

**`NavSweepTests.swift`** (86 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: keyboard navigation sweep (arrow-up/down line-by-line, page-up/down, home/end); selection follows cursor · teeth: real (asserts model.selection line bounds; tab state consistency)

**`NewBlankImageTests.swift`** (69 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: File → New → Image creates blank editor with default 256×256 RGBA buffer · teeth: real (asserts tab open, mode set to `.editor`, image dimensions)

**`NewFileActionTests.swift`** (91 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: File → New markdown; tab opens with pristine untitled content · teeth: real (asserts new tab + title generation + content state)

**`OneShotRoutingTests.swift`** (181 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: open-as routing (sniff file type, route to correct view — hex/rendered/source/image/raw); single-file-arg bootstrap · teeth: real (asserts mode inference from content + extension; tab state post-open)

**`OpenAsSniffAndHostedViewTests.swift`** (275 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: file-type sniff (binary/text, encoding detect, mode routing); hosted-view render (off-screen NSHostingView + ContentView in-process) · teeth: real (asserts sniff accuracy over mixed content; view-tree structure)

**`OpenDeferThresholdTests.swift`** (58 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: large-file open deferral (soft-warn threshold triggers async load, blocks UI spinner) · teeth: real (asserts softWarnBytes triggers off-main path; tab state flow)

**`OpenInNewSessionTests.swift`** (194 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: open-in-new-session action (creates fresh session, new window, file opens in tab); session isolation · teeth: real (asserts two separate DocumentModel instances, distinct histories)

**`PackageExplorerWiringTests.swift`** (56 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: sidebar package-explorer (folder nav, file list, expand/collapse tree) · teeth: real (asserts sidebar.rootURL + folder tree structure)

**`PaletteEditTransformVerbTests.swift`** (233 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: palette edit/transform verbs (case-change, whitespace-trim, sort lines, dedupe, rotate, reverse); hex/binary mode palette verbs · teeth: real (asserts text transformations; multi-selection handling)

**`PaneCompositingPolicyTests.swift`** (104 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: pane compositing (opaque surface z-order, sibling occlusion guard via layering) · teeth: unclear (model state only; compositor occlusion needs T5 pixels)

**`PanelDragWiringTests.swift`** (141 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: split-pane drag (draggable divider moves pane boundary; frame recalc; min/max bounds) · teeth: weak (model frame asserts; no gesture interaction validation)

**`PanelLayoutRepublishInvariantTests.swift`** (252 LOC) — tier: headless-unit · framework: XCTest · pins: panel-layout republish invariants (layout frame changes → republish to all consumers; observers don't miss updates) · teeth: real (asserts publisher fire counts; layout state consistency)

**`PanelLayoutResolutionTests.swift`** (247 LOC) — tier: headless-unit · framework: XCTest · pins: panel-layout frame resolution (split proportions → pixel frames; edge-case bounds; dynamic pane mount/unmount) · teeth: real (asserts frame pixel math; off-by-one guards)

**`PaneRetentionMountProbeTests.swift`** (140 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: pane mount retention (sidebar stays mounted during tab switch; no teardown/recreate thrash) · teeth: real (asserts pane identity via object address; mount count)

**`PaneScrollRestoreWebViewTests.swift`** (94 LOC) — tier: webview-inprocess · framework: XCTest · pins: rendered-markdown scroll persistence (capture `scrollY` before reload, restore via `scrollTo` JS); round-trip across reload · teeth: real (JS eval in live WKWebView; asserts restored offset matches captured; `#192`-gated)

**`PasteFeedbackToastTests.swift`** (148 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: paste-action toast feedback (shows transient toast on paste; auto-dismiss timeout) · teeth: real (asserts toast.isVisible bool + timeout state)

**`PDFExportWebViewTests.swift`** (70 LOC) — tier: webview-inprocess · framework: XCTest · pins: Export-as-PDF via WKWebView (load rendered page, `createPDF()`, write atomic bytes, PDF magic + size) · teeth: real (asserts PDF bytes have %PDF magic, > 1 KB body; atomic write round-trip; `#192`-gated)

**`PDFFindDriverTests.swift`** (88 LOC) — tier: headless-unit · framework: XCTest · pins: PDF text-search driver (parse embedded text, find query matches, result line numbers) · teeth: real (asserts match count, line bounds per query)

---

## Test-Type Taxonomy

| Category | Count | LOC | Notes |
|----------|-------|-----|-------|
| **Headless-unit** (pure logic, no view) | 34 | ~2,600 | Model/VM logic, string transforms, parsing, state machines; pure XCTest; fastest tier |
| **Headless-UI (T1m)** (in-process hosted view) | 27 | ~3,200 | ContentView + DI harness, script verb runner, DocumentModel state; no real window |
| **WebView in-process (#192-gated)** | 6 | ~650 | WKWebView + hosted NSHostingView; MDV_RUN_WEBVIEW_TESTS gate; `WebViewTestCase`; VM/nightly lane |
| **T4 (live-app spawn)** | 2 | ~200 | Real `dist/TextView.app` launch + verb; smoke scenario only; VM lane |
| **T5 (pixel/screencapture)** | 1 | ~160 | WindowServer pixels; compositor occlusion guard; quadrant-color fixture; VM lane |
| **Harness / support** | 1 | ~650 | InteractionProfileHarness — opt-in profiler; self-skips in gate |

---

## Coverage Shape

### Over-tested
- **Image editor (paint + vector + undo):** 8 files covering paint/tone gate, undo ordering, vector edit, VM tests, visual regression, state persistence, properties panel, element render. Heavy due to high-complexity editable domain.
- **LSP integration (goto, rename, format, hover, nav, diag):** 9 files covering RPC round-trips, multi-file nav, rename invariants, hover invalidation, formatting, edit safety. Host-heavy (T1m) because LSP wiring is critical + UI-coupled state machines.
- **Markdown (outline, table format, TOC, escape, link policy):** 8 files covering heading extraction, table reformat, link sandbox, JS escaping. Pure-logic dominance (headless-unit) appropriate for low-latency parsing.

### Under-tested
- **Pane compositing policy & layout math:** 3 files (PaneCompositingPolicyTests, PanelLayoutRepublishInvariantTests, PanelLayoutResolutionTests) use model-state assertions only; **compositor occlusion** (the recurring sibling-blank pathology) is covered only by one T5 pixel test (ImageEditorVisualRegressionTests). The layout-frame math is host-testable, but opaque AppKit surface + SwiftUI sibling layering *cannot* be validated headlessly — **if rebuild omits compositor-occlusion T5 gates, the pathology will recur silently.**
- **Modal/panel drag interaction:** PanelDragWiringTests (141 LOC) asserts frame deltas but does NOT simulate actual dragging. A real PointerEvent / `onChanged` drag is AX-only (off-limits in headless/T1m). **Recommend a VM-lane T5 pixel test that dragsplitter visually to verify responsiveness.**
- **Sidebar nav / package explorer:** Minimal coverage (PackageExplorerWiringTests 56 LOC, mostly model state). No T5 test for sidebar visual or click-to-open on tree items.
- **File type sniff edge cases:** OneShotRoutingTests / OpenAsSniffAndHostedViewTests cover sniff + hosted view, but *no fuzz tests* on binary boundary cases (JPEG header vs. plaintext, UTF-8 BOM, etc.). Pure-logic parsing is low-latency, so a proptest harness would suit it.

---

## Harness & Infra Patterns Worth Porting

### 1. **Tier-gated test self-skip (LaunchHarnessTierGateTests + TierGateObserver)**
   - **Pattern:** `if ProcessInfo.processInfo.environment["MDV_HEADLESS_GATE"] == "1" { throw XCTSkip(...) }`
   - **Lesson:** Prevents accidental T4/T5 spawns on host. Cleanly separates merge-gate (headless) from VM/nightly (heavy) lanes without `#if` clutter.
   - **Rebuild:** Codify the `LaunchHarness.shouldRunLiveTiers(env:bundleExists:)` decision; use it in all T4/T5 base classes.

### 2. **WebViewTestCase + #192 graph teardown (MultiCursorWebViewTests, PaneScrollRestoreWebViewTests, PDFExportWebViewTests, MermaidHostingTests)**
   - **Pattern:** Track hosted WKWebView + NSHostingView refs; call `WebViewTestTeardown.teardown(hostedViews)` in `tearDown()` to reclaim WebContent process *before* the host tree is released.
   - **Lesson:** Without explicit teardown, WebContent processes accumulate and starve resources (observed ~60 orphaned WebContent procs mid-session). The gate `WebViewTestTeardown.skipUnlessEnabled()` prevents runs in the headless lane where GUI/XPC is unavailable.
   - **Rebuild:** Bake this into every WebView test; track refs in an array; teardown in reverse-LIFO order (nested views first).

### 3. **HeadlessUITestCase + DocumentModel DI seam (InteractionDeepTests, ModeSwitchRaceTests, etc.)**
   - **Pattern:** Inject `DocumentController`, `TextFileLoader`, `HistoryStore`, `PreferencesStore` with hermetic temp directories (`FileManager.default.temporaryDirectory + UUID`). Construct a vanilla `DocumentModel(...)` and run verbs via the `--script` harness.
   - **Lesson:** Decouples tests from the real app's launch/AppDelegate path, so tests run in-process without spawning. The `ScriptVerb` enum routes every verb through the same path the live app uses, catching UI-coupling bugs that pure ViewModel tests miss.
   - **Rebuild:** Preserve this DI layer; make it the default for model-state tests. Only spawn the real app (T4) for the one smoke scenario that genuinely needs it.

### 4. **Scenario-based harness with step dumps (InteractionDeepTests, LaunchSmokeTests, InteractionDeepResizeTests)**
   - **Pattern:** `MultiScenarioTestCase` / `HeadlessMultiScenarioTestCase` accepts named scenarios with a script string + a closure that asserts on collected dumps (`[Codable]` snapshots at each step). Re-uses the same file across scenarios.
   - **Lesson:** Reduces boilerplate; scenarios share setup/teardown. The `Pages(dump:)` struct parses the Codable dump into typed accessors (`Pages.generic.windowTitle`, `Pages.modeBar.mode`, etc.), avoiding string-key fragility.
   - **Rebuild:** Generalize the scenario harness; it's a highly reusable pattern for step-by-step flows.

### 5. **Negative-control switch + teeth proof (MDVNegativeControl.isBroken)**
   - **Pattern:** Flag deliberate breaks behind `MDVNegativeControl.isBroken("<NAME>")` (reads `MDV_ENABLE_BROKEN_<NAME>=1`); gate a minimal code path to break the feature; run the test with the flag set to assert the test FAILS (teeth proof).
   - **Lesson:** A test that has never been shown to go red is a false green. The switch lets you prove the test catches a regression without hand-reverting or CI tricks.
   - **Rebuild:** Adopt this for every *regression-guarded* test (especially UI/render tests where false greens are the pathology). Codify the helpers in a base class.

### 6. **Headless pixel sampling (LineNumberRulerViewTests equivalence test)**
   - **Pattern:** The newline-offset perf rewrite provided an exact equivalence test against the old NSString scan over a mixed corpus (ASCII, CRLF, emoji, CJK). Pure Swift logic, no image rasterization.
   - **Lesson:** When a fast rewrite must preserve exact output, an equivalence test to the old code is a high-confidence guard. Works well for parsing, indexing, and string transforms.
   - **Rebuild:** Use it liberally for perf rewrites; it's zero-cost to run (pure Swift) but highly effective.

### 7. **ImageRenderer false-green awareness + T5 pixel sniff (ImageEditorVisualRegressionTests)**
   - **Pattern:** T5 spawns the real app on a vivid quadrant-color fixture image; captures WindowServer pixels; asserts ≥3 distinct colors in the preview + controls regions. If an opaque representable occludes a SwiftUI sibling, the region would read uniform → test fails.
   - **Lesson:** `ImageRenderer` rasterizes the SwiftUI tree in isolation and draws placeholders for representables, giving a false green. Only stage-④ WindowServer pixels reveal compositor occlusion. The quad-color fixture is small (256×256) but unambiguous; it's cheaper than a rich test image.
   - **Rebuild:** For any opaque AppKit surface (WebView, custom NSViewRepresentable, terminal, code-editor), add a T5 pixel sniff test with a color-variety fixture. This is THE guard against the recurring sibling-blank pathology.

---

## Flake / False-Green Risks Observed

### **Timing-dependent flakes**
1. **ModeSwitchRaceTests / ModeSwitchRaceLiveTimingTests:** The race is real, but on slow machines a stale async load might not land within the test's drain timeout. Mitigated by hammering (200+ yields) and a 0.5-second sleep buffer.
2. **InteractionProfileHarness:** Load-dependent latencies; self-skips in the merge gate (opt-in `MDV_PROFILE=1`). Perf-bench flake exemption applies (can re-run).

### **False greens (no regression teeth)**
1. **PanelDragWiringTests, PaneCompositingPolicyTests:** Assert frame math + model state but do NOT exercise the actual drag gesture or compositor. A refactor that breaks layout or z-order would be silent.
2. **MediaPreviewInfoZoomTests (20 LOC):** Minimal coverage; a label-format change could slip through.
3. **MetadataPanelTests:** Asserts stat display but does NOT verify the panel is actually *visible* on screen (no T5 sniff).

### **Flake-prone patterns to avoid in rebuild**
- **Headless tests that read generic node counts (render tree size):** InteractionDeepTests' early version used `totalNodeCount` deltas; any unrelated tree change (focus ring, tooltip) caused false positives. **Fixed by reading model bools directly** (e.g., `model.isPalettePresented`).
- **Timing asserts without yield/sleep:** `ModeSwitchRaceTests.drainAsyncLoads()` yields 200 times and sleeps 10ms to let async completions land. Without the drain loop, a stale load landing after the assertion would be missed.
- **No WebContent process teardown in WebView tests:** Orphaned XPC processes accumulate → machine runs out of fds/memory mid-run, causing flakes downstream.

---

## Rebuild Notes — Day-1 Test Strategy

### **Tier structure to replicate**
1. **Headless-unit** (XCTest, ~40–50% of suite): Pure logic, fast, catches parsing/VM bugs early. Lowest-friction gate. Aim for high *behavior* density (each test pins one invariant, multiple assertions per test).
2. **Headless-UI (T1m)** (in-process hosted view, ~35–40%): DocumentModel + DI seam; exercises verb wiring + state machines without spawning. Use the scenario harness for multi-step flows.
3. **WebView in-process** (#192-gated, ~7–10%): Live WKWebView + hosted NSHostingView; JS eval for dynamic content. Explicit process teardown in every tearDown().
4. **T4 (real-app spawn, ~1–2%):** One smoke scenario only. Launch → verb → exit. Guards the AppDelegate↔coordinator path.
5. **T5 (pixel/screenshot, ~1–2%):** Compositor occlusion + visual regression. Quadrant-color fixtures. WindowServer screencapture. MUST exist for any opaque surface or SwiftUI render.

### **High-impact patterns to adopt immediately**
- **Compositor-occlusion T5 tests:** For every opaque NSViewRepresentable or surface composited with SwiftUI, add a pixel sniff test. This is the single highest-ROI guard against silent visual regressions (the sibling-blank pathology recurss without it).
- **Negative-control switches:** Codify `MDVNegativeControl.isBroken("<NAME>")` helpers; prove every regression-guarded test goes red on a deliberate break.
- **WebViewTestCase + teardown discipline:** Every WKWebView test must track refs and call `WebViewTestTeardown.teardown(hostedViews)` before the host view is released. No exceptions.
- **Scenario harness for multi-step flows:** Use it for any test > ~15 steps. It halves boilerplate vs. sequential assertions.

### **Coverage gaps to fill on day 1**
1. **Sidebar nav visual (T5):** Pixel test that sidebar expands/collapses and items are clickable.
2. **Pane-drag responsiveness (T5):** Drag the splitter; assert frame moves.
3. **File-type sniff fuzz (headless-unit):** proptest harness over binary boundary cases (JPEG header, UTF-8 BOM, truncated gzip, etc.).
4. **Opaque surface z-order audit (T5):** For terminal pane, CodeMirror web view, image editor scroll host — add pixel tests verifying no occlusion of adjacent SwiftUI elements.
5. **LSP diagnostic clearing edge cases (headless-unit):** Multi-tab with same file open in 2+ tabs; close one; assert diagnostic persists. (Covered in MemoryReclaimOnCloseTests but could expand.)

### **Avoid on day 1**
- **Broad headless node-count assertions:** They're flake-prone (unrelated tree changes perturb the count). Read model bools instead.
- **Timeout-free async drains:** Always include explicit yield loops + sleep buffers (e.g., 10–20ms) to let completions land.
- **Hand-reverting for teeth proof:** Use negative-control switches instead; it's repeatable and committed.
- **"Test harness X is test-infrastructure; I'll skip it until later":** The harness IS the product; build it incrementally so tests are immediately usable. A bare `swift test` must not spawn windows or accumulate orphaned processes.

### **Metrics to track**
- **Test count by tier:** Aim for 45% headless-unit, 40% T1m, 10% WebView, 3% T4, 2% T5.
- **False-green rate:** Every T5 test must have been shown to go red (negative-control switch proof). Every T1m test must assert both model state *and* a downstream observable (not just "no crash").
- **VM resource health:** After a full suite run, orphaned WebContent processes should be ≤ 1 (test cleanup succeeded). Monitor `ps aux | grep -i webcontent | wc -l` after runs.

---

## Summary

This slice (69 files, ~7,580 LOC) represents a mature test pyramid with strong **LSP integration coverage** (9 files), **image-editor domain complexity** (8 files), and a **clear tier separation** (headless-unit base, T1m hosts, T5 pixel guards for surfaces). The **WebViewTestCase pattern** with explicit teardown and the **scenario harness** are highly reusable. The **compositor-occlusion T5 guard** is the single pattern most critical to replicate — omitting it guarantees a recurrence of the sibling-blank visual regression. Day-1 focus: tier structure, DI seam, scenario harness, WebView teardown, and compositor-occlusion sniff tests.
