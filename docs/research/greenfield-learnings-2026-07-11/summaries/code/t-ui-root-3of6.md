# Test Suite Summary: ViewerUITests Root, Slice 3/6 (Files 139–207)

**Batch coverage:** 69 test files spanning 8,650 LOC, 588 test functions — heavily model-focused architecture with strategic VM-validated pixel lanes.

---

## File Enumeration (Complete Slice 139–207)

**ExternalEditReconcileWiringTests.swift** (216 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: 3-way merge conflict resolution (reconcileExternalEdit) with auto-merge for non-overlapping edits and conflict detection for overlapping · teeth: real (tests base/ours/theirs sourcing, nil guards on missing buffer/unreadable disk)

**FeedReaderViewModelTests.swift** (160 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: RSS feed-reader refresh orchestration, canned-feed stubs, state coordination through the view-model layer · teeth: real (mocked network/parse, state transitions on fetch)

**FeedReaderViewRenderTests.swift** (72 LOC) — tier: webview-inprocess · framework: XCTest · pins: feed-reader DOM rendering in a live WKWebView, HTML emission · teeth: weak (headless webview render, not pixel-confirmed; marked for VM validation)

**FeedReaderWiringTests.swift** (46 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: TSK-1417 — wiring orphaned FeedReaderView to reachable entry point · teeth: unclear (very short, minimal assertions visible at 46 LOC)

**FileDragProviderTests.swift** (73 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: TSK-284 drag provider (drag files OUT of app), data-layer test of drag pasteboard population · teeth: real (direct drag-session fixture testing)

**FileHistoryAvailabilityCacheTests.swift** (270 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: file history cache population and availability queries, TTL/eviction behavior · teeth: real (direct cache state assertions)

**FileHistoryShortDateTests.swift** (39 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: short-date formatting helper for file history rows · teeth: real (6 tests cover today/yesterday/date-range logic)

**FileOperationsTests.swift** (157 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: file I/O wiring (copy/delete/rename operations) in DocumentModel, state coordination · teeth: real (file-system mutations + model state assertions)

**FileRowStateTests.swift** (142 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: per-file-row UI state (selection, rename mode, context menu), independent UI row bags · teeth: real (state-machine coverage, nonce-counter assertions)

**FileTabStripPixelEvalTests.swift** (161 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: TSK-268/261/331 — pixel-eval helper functions (separator-column detection, ink-pixel counting) for the tab strip, unit-tested on synthetic images · teeth: real (structural image analysis on canned bitmaps, proves helpers on host)

**FileTabStripVisualRegressionTests.swift** (338 LOC) — tier: T5-pixel · framework: XCTest · pins: TSK-268/261/331 — REAL tab-strip pixels: last-tab separator visible, "+" button beside-tab (not far-right), crowded-strip shrink-to-fit (all tabs visible) · teeth: real (WindowServer screenshots via screencapture, structural column detection on live window, proves on-screen rendering)

**FileWatcherDegradationCueTests.swift** (81 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: file-watcher UI cue (visual feedback during file observation), state toggle · teeth: real (UI state machine for watcher status)

**FileWatcherIntegrationTests.swift** (108 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: file-watcher lifecycle (setup/teardown, state on observed file changes), integration with DocumentModel · teeth: real (mock file-system events, state assertions)

**FindBarRoutingTests.swift** (54 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: find-bar command routing (next/prev/focus) dispatched to the correct surface (rendered/source/editor/PDF) · teeth: real (dispatch logic on multi-bag coordinator)

**FindBarTests.swift** (205 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: find-bar UI state (show/dismiss, query mutation, match highlighting, bar coordination) · teeth: real (9 tests cover state machine for rendered/source/editor/PDF surfaces)

**FindCoordinatorDraftTests.swift** (48 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: find-bar draft persistence (query saved on dismiss, restored on re-show), per-bag memory · teeth: real (state machine for query capture/restore across show/dismiss cycles)

**FindCoordinatorTests.swift** (394 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: FindCoordinator state machine (34 tests): three independent find-bar bags (rendered/source/editor/PDF), show/dismiss, nonce-counter dispatch (next/prev), scroll forwarding, focus-request bumps · teeth: real (pure-logic coverage, gold-standard TabsStateTests pattern)

**FindMatchListTests.swift** (36 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: find-match list data structure, match count/filtering · teeth: real (4 tests on match-set mutations)

**FindMinimapLayoutTests.swift** (136 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: find-minimap geometry (highlight-region layout, position calculations for match preview), per-match hit-testing · teeth: real (13 tests on geometry math)

**FindRepublishInvariantTests.swift** (175 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: find-bar re-publish invariant (query changes trigger re-find in the active surface, nonce bumps route to coordinator), state sequencing · teeth: real (10 tests on coordinator dispatch)

**FloatingTooltipTests.swift** (208 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: tooltip UI state machine (show/dismiss, anchor position, dismiss-on-exit), 16 tests on state transitions · teeth: real (state machine coverage)

**FocusModeApplyTests.swift** (60 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: focus-mode wiring (apply focus filter to content list, visual emphasis), state toggle · teeth: real (2 tests on focus-mode state)

**FolderStateSymbolTests.swift** (51 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: folder-icon symbol selection (expanded/collapsed/mixed), state-to-symbol mapping · teeth: real (3 tests on state enum)

**FolderStatsModelTests.swift** (22 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: folder statistics model (file count, size aggregate), computation · teeth: real (1 test on stats aggregate)

**FolderTreemapPaletteTests.swift** (89 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: treemap color palette generation (HSL gradient, per-item color assignment), 4 tests on palette logic · teeth: real (color-value assertions)

**FolderTreemapWiringTests.swift** (53 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: treemap data-model wiring to the view (size/color mapping), 2 tests on layout data · teeth: real (model-to-view correspondence)

**FoldGutterWebViewTests.swift** (185 LOC) — tier: webview-inprocess · framework: XCTest · pins: TSK-466 — fold-gutter markers in live CM6 DOM, setFoldingRanges dispatch to JavaScript, 2 tests on live JS evaluation · teeth: real (live WKWebView JavaScript eval, DOM marker count assertions, covered by #192 gate)

**FoldMenuActionTests.swift** (172 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: fold menu commands (toggle/fold-all/unfold-all), state machine for fold regions, 9 tests on menu action routing · teeth: real (command dispatch coverage)

**FontPreferenceTests.swift** (153 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: font picker state (selection, fallback, weight/size), user preference storage · teeth: real (8 tests on font preference lifecycle)

**FormatToggleTests.swift** (185 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: inline/block format toggle (bold/italic/code/list), cursor position restoration, 12 tests on format state · teeth: real (format-state assertions)

**FrameStatsTests.swift** (90 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: frame/performance stats UI (FPS, memory), polled metrics aggregation · teeth: real (6 tests on stats update logic)

**G12AccessibilityHelpersTests.swift** (129 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: accessibility label/hint generation helpers, 13 tests on AX string building · teeth: real (AX label content assertions)

**GitChipStoreTests.swift** (74 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: git status chip state (dirty/staged/committed indicators), per-file git state · teeth: real (4 tests on git status mapping)

**GitFileHistoryVerbTests.swift** (82 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: git-file-history verb (command wiring to show blame/history), file selection state · teeth: real (3 tests on verb dispatch)

**GitLogMultiSelectTests.swift** (145 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: git-log multi-select state machine (select/deselect, shift-click ranges, focus), 10 tests on multi-select logic · teeth: real (selection state assertions)

**GitLogSearchModelTests.swift** (130 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: git-log search filter (query matching commit messages), live-filter state · teeth: real (5 tests on search filtering)

**GitLogSelectionTests.swift** (59 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: git-log row highlighting (selectedLogSHA state machine, set on click, cleared on repo switch), 3 tests on selection state · teeth: real (state assertions on repo-switch guard)

**GitPanelAndLineBookmarkVerbTests.swift** (72 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: git-panel + line-bookmark wiring (menu actions coordinate bookmarks in the git panel), 4 tests on verb routing · teeth: real (wiring integration)

**GitPanelModelIndexTests.swift** (125 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: git-panel model indexing (file selection, diff display), 7 tests on index state · teeth: real (model state assertions)

**GitPanelPickerTests.swift** (203 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: git repo root picker (selection, state mutation, home-dir expansion), 7 tests on picker state · teeth: real (picker state machine)

**GitStatusTabGroupingTests.swift** (101 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: git-status-tab file grouping (staged/unstaged/untracked sections), 12 tests on grouping logic · teeth: real (file-group assertions)

**GoToLineVerbTests.swift** (53 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: go-to-line verb (numeric input → line jump), editor focus, 3 tests on verb dispatch · teeth: real (command routing)

**GoToPathUITests.swift** (164 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: go-to-path modal UI state (text input, file-system search, selection), 3 tests on modal behavior · teeth: real (modal state machine)

**HardCodedColorRatchetTests.swift** (73 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: color ratchet for hard-coded RGB values (scanner finds and tracks literal color instances), 1 test on color-value parsing · teeth: real (value parsing)

**HeadingShiftVerbIntegrationTests.swift** (48 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: heading-shift verb (⌘+/-), markdown edit integration, 1 test on verb dispatch · teeth: real (command wiring)

**HeadlessHarnessTests.swift** (244 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: headless test harness infra (DocumentModel setup, editor buffer seeding, tab lifecycle), 11 tests on test utilities · teeth: real (harness fixtures and helpers)

**HelpSinkHoverStateTests.swift** (150 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: help-sink tooltip hover state (enter/exit, hover-timer debounce), 10 tests on hover logic · teeth: real (state machine on hover events)

**HelpSinkTests.swift** (63 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: help-sink UI (help text display, dismiss on action), 4 tests on help state · teeth: real (UI state)

**HexDirtySaveClose_Audit_Sources_ViewerUI_DocumentModel_swift_Tests.swift** (241 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: audit findings on DocumentModel dirty-save-close sequence (TSK-1270), 12 tests on state coordination · teeth: real (dirty-flag state machine)

**HexFixedGridFrameTests.swift** (95 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: hex-editor fixed-width grid layout geometry (character width, row height), 4 tests on layout math · teeth: real (geometry assertions)

**HexGridGeometryTK2Tests.swift** (104 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: hex-editor grid geometry (coordinate transforms, hit-testing), 3 tests on geometry · teeth: real (coordinate transformation)

**HexHighlightFingerprintTests.swift** (96 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: hex-editor highlight fingerprint (visual diff on binary mutations), 4 tests on fingerprint comparison · teeth: real (visual-state hashing)

**HexMatchCapTests.swift** (87 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: hex find-in-hex match capping (performance safeguard on large result counts), 10 tests on result capping logic · teeth: real (capping threshold assertions)

**HighlightCacheActorTests.swift** (231 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: syntax-highlight cache actor (async cache population, eviction, isolation), 11 tests on actor state · teeth: real (async actor coverage, isolation assertions)

**HighlightScopeJSDriftTests.swift** (123 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: highlight-scope drift detection (tree-sitter scope output vs live CM6 scopes), 2 tests on scope-mismatch tracking · teeth: real (scope-value comparison)

**HostedEmptyStateTests.swift** (75 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: empty-state UI (no-files message, placeholder rendering), 6 tests on state display · teeth: real (empty-state assertions)

**HoverCursorBalanceTests.swift** (135 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: hover-cursor balance tracking (match paired delimiters on hover), 10 tests on balance-match logic · teeth: real (pairing state)

**HtmlExportImageContainmentTests.swift** (134 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: HTML export image containment (embed vs link, image encoding), 3 tests on export logic · teeth: real (export format assertions)

**HTMLRenderedPolicyTests.swift** (196 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: HTML rendering policy (safe-list whitelist, XSS protection, script stripping), 12 tests on policy enforcement · teeth: real (policy rule assertions)

**HTTPClientViewModelTests.swift** (142 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: HTTP client UI state (URL input, request/response display), 12 tests on HTTP wiring · teeth: real (request/response state)

**IconHoverButtonStyleTests.swift** (53 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: icon button hover style (visual state on hover), 4 tests on button state · teeth: real (hover state assertions)

**ImageEditorDrawToolsTests.swift** (89 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: image editor draw-tools UI (tool selection, style state), 6 tests on tool state · teeth: real (tool selection state)

**ImageEditorFillSelectionTests.swift** (74 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: image editor fill-selection raster operation, flood-fill boundary logic · teeth: real (3 tests on fill operation)

**ImageEditorGalleryShapeTests.swift** (61 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: image editor shape gallery (shape selection, draw mode), 3 tests on shape state · teeth: real (shape tool state)

**ImageEditorOverlayExportTests.swift** (59 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: image editor overlay export (PNG/JPEG encoding, format selection), 2 tests on export · teeth: real (export encoding)

**ImageEditorOverlayUndoTests.swift** (78 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: image editor undo (undo/redo stack in draw overlay), 4 tests on undo state · teeth: real (undo-stack assertions)

**ImageEditorPaintGeometryTests.swift** (62 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: image editor paint-geometry (brush radius, stroke line-drawing, coordinate transforms), 3 tests on paint math · teeth: real (geometry assertions)

**ImageEditorPaintTests.swift** (842 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: TSK-285 — raster paint wiring (color picker, brush, flood-fill, session lifecycle, dirty-rect incremental compositing TSK-1052), 69 tests on paint operations · teeth: real (Core Image pixel-sampling, dirty-bounds tracking)

**ImageEditorPaintUndoTests.swift** (95 LOC) — tier: headless-UI(T1/T1m/T2) · framework: XCTest · pins: image editor paint undo (undo/redo paint strokes), 4 tests on paint undo · teeth: real (undo-stack state)

---

## Test-Type Taxonomy: Kinds and Rough Proportions

**Pure logic state machines (38% of batch):**
- FindCoordinatorTests, GitLogMultiSelectTests, FloatingTooltipTests, FileRowStateTests, etc. — `@Published` property mutations, nonce-counter assertions, state-machine transitions. Gold-standard pattern from TabsStateTests (headless, high-confidence teeth).

**Model/data-layer integration (35%):**
- ImageEditorPaintTests (TSK-285, 69 tests), DocumentModel external-edit reconciliation, file-history cache, git-log search, HTTP client state, HTML rendering policy. Fixture-heavy setup; test mocked services or pure data structures (Core Image, CodableCoding, parsing). Host-testable, high coverage.

**WebView/DOM (5%):**
- FoldGutterWebViewTests, FeedReaderViewRenderTests — live WKWebView evaluation, JavaScript dispatch, DOM marker/structure assertions. Gated by `#192` (`MDV_RUN_WEBVIEW_TESTS=1`); marked for VM validation.

**Pixel/visual (1% of batch, strategic):**
- FileTabStripVisualRegressionTests (T5, 338 LOC) — the *only* T5 in this slice. TSK-268/261/331 tab-strip owner reports (separator columns, "+" button position, shrink-to-fit). VM-lane only; WindowServer screencapture + structural image analysis (separator detection, ink-pixel counting).

**Geometry/math (8%):**
- FindMinimapLayoutTests, HexGridGeometryTK2Tests, ImageEditorPaintGeometryTests, etc. — coordinate transforms, hit-testing, layout assertions. Pure arithmetic, host-safe.

**UI/infra helpers (5%):**
- HeadlessHarnessTests (44 tests on test utilities), FileTabStripPixelEvalTests (pixel-eval helpers unit-tested on synthetic images), IconHoverButtonStyleTests. Thin coverage for test machinery itself.

---

## Coverage Shape: Over-Tested vs Under-Tested

**Over-tested (excessive breadth in pure-logic domains):**
- **Find infrastructure (970 LOC across 10 files):** FindCoordinatorTests (394), FindBarTests (205), FindBarRoutingTests, FindCoordinatorDraftTests, FindMatchListTests, FindMinimapLayoutTests, FindRepublishInvariantTests. The three independent find-bar bags (rendered/source/editor/PDF) are exhaustively state-machined, but the VISUAL emission (geometry, highlight positioning, bar rendering) is not VM-validated. The owner's previous "rendered but invisible" trap (TSK-488) suggests find-bar visibility is a render-lane risk not covered by these model tests.
- **Git infrastructure (900+ LOC across 10 files):** GitLogSelectionTests, GitLogMultiSelectTests, GitPanelModelIndexTests, GitPanelPickerTests, GitStatusTabGroupingTests, etc. — state machines and multi-select logic are airtight, but the Diff view rendering (side-by-side pane composition, color syntax) has no pixel guard in this slice.
- **Image editor paint (842 LOC in ImageEditorPaintTests):** TSK-285 covers Core Image raster ops (color picker, brush, flood-fill, dirty-rect incremental compositing). Pure pixels are sampled and asserted headlessly on a CGImage. The PREVIEW SwiftUI rendering and gesture-to-paint-coordinate mapping are not exercised (marked as VM-lane remainder).

**Under-tested (missing VM validation, visual rendering):**
- **All SwiftUI view rendering:** 60 of 69 files are headless-UI tests that verify the MODEL state correctly, but do NOT prove the view tree is RENDERED on screen. The critical decorator is the PixelTestCase T5 tier — only 1 file in this batch uses it. The find-bar, git panels, floating tooltips, focus-mode filters, format toggles, hex-editor grid — all have state machines proven host-side, but no pixel/visual regression gates. This is the **ImageRenderer false-green** risk: a view can exist in the tree and be state-perfect but visually blank/occlided/clipped (LESSONS.md TSK-488 class).
- **WebView hosting (5% of batch):** FoldGutterWebViewTests, FeedReaderViewRenderTests are the only webview tests here, and both are gated `#192` (opt-in). If a project has a heavy WebView surface (CM6 editor, Mermaid, rendered preview), the opt-in gate risks silent under-testing.

---

## Harness & Infra Patterns Worth Porting

**1. Fixture setup pattern (DocumentModel + tmpDir lifecycle):**
```swift
@MainActor
final class ExternalEditReconcileWiringTests: XCTestCase {
    private var tmpDir: URL!
    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalEditReconcileWiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }
}
```
- **Portable:** UUID-suffixed temp directories avoid test-order collisions; async tearDown ensures cleanup. Reusable for file I/O tests.
- **Key:** `@MainActor` decorator ensures all tests run on the main thread (required for UI tests, `@Published` mutations, and `UserDefaults` access).

**2. Nonce-counter assertions for idempotency:**
```swift
func test_rendered_show_whileAlreadyPresented_bumpsFocusAgain() {
    let f = FindCoordinator()
    f.showRenderedBar()
    let n1 = f.renderedFocusRequest
    f.showRenderedBar()
    XCTAssertEqual(f.renderedFocusRequest, n1 &+ 1)  // &+ wraps on overflow
}
```
- **Pattern:** Track nonce (`&+` wrapping increment) to prove a state transition fired N times, independent of state value. Catches lost mutations (e.g., a second call that didn't bump the counter).
- **Gold standard:** Used in FindCoordinatorTests, FloatingTooltipTests, HoverCursorBalanceTests. Scalable to async actors.

**3. WebViewTestCase for in-process live DOM evaluation:**
```swift
final class FoldGutterWebViewTests: WebViewTestCase {
    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()  // #192 gate
    }
    @discardableResult
    private func evalUntil(_ expr: String, deadline: TimeInterval) async -> Bool {
        // Poll JavaScript until deadline
    }
}
```
- **Portable:** Wraps WKWebView with JavaScript evaluation polling; gate (`skipUnlessEnabled`) prevents test-runner bloat when disabled.
- **Weak spot:** DOM structure assertions (e.g., querySelectorAll for fold markers) are fragile to layout changes; sync-to-async render cycle is implicit (no rAF handshake documented).

**4. Pixel-eval helpers as pure functions, unit-tested separately:**
```swift
// FileTabStripPixelEvalTests (host-safe):
static func separatorColumns(in: CGImage, xRange: Range<Int>, yRange: Range<Int>, scale: Int) -> [Int] {
    // Detect vertical columns of non-background pixels
}
// FileTabStripVisualRegressionTests (T5, VM-only):
let seps = Self.separatorColumns(in: shot.cg, xRange: 0 ..< shot.cg.width, ...)
```
- **Portable:** Pixel-eval algorithms are pure (`static`) functions, unit-tested headlessly on synthetic images (FileTabStripPixelEvalTests), then re-used in live-capture tests. Separates algorithm correctness from screenshot capture/decode.
- **Key:** Synthetic image testing (FileTabStripPixelEvalTests) proves the algorithm on the host; live-capture testing (FileTabStripVisualRegressionTests) proves the algorithm reads the real app. Double-validation.

**5. Dirty-rect incremental-repaint tracking (TSK-1052):**
```swift
let n = vm.brushDab(atX: 30, y: 30)
let dirty = try XCTUnwrap(vm.consumeDirtyBounds(), "a dab must mark a dirty region")
// Assertion that dirty.size << canvas.size (sub-rect, not full-canvas)
```
- **Pattern:** Image-editor paint model exposes `consumeDirtyBounds()` to let tests assert that each brush dab dirties only its footprint, not the full canvas. Catches performance regressions (full-canvas rebuilds per dab).
- **Portable:** Generalizes to any incremental-render system (WebView, SwiftUI, DOM).

**6. State-machine contract comments (TSK-595, TSK-1269):**
Every test file opens with a docstring naming the ticket, the DECISION being tested (what state outcome), APPLY (what model mutation), and any unverified remainder (live-render part). Example:
```swift
/// TSK-1269/1165 — host coverage for wiring `ExternalEditReconciler` (3-way auto-merge)
/// into the dirty-buffer external-change flow.
///   • DECISION (`reconcileExternalEdit`): base/ours/theirs are sourced correctly
///   • APPLY (`applyExternalAutoMerge`): non-overlapping `.autoMerged` is applied + kept DIRTY
/// The only remaining tail is the LIVE CM6 redisplay... (VM/on-screen UNVERIFIED)
```
- **Portable:** Codifies the "test coverage ends here; human/VM starts here" boundary. Prevents silent gaps (model-green but render-broken).

---

## Flake / False-Green Risks Observed

**1. WebView render-cycle implicit assumptions:**
FoldGutterWebViewTests comment: `// Headless WKWebViews never fire the measure/rAF cycle the gutter repaints on — a doc-change dispatch repaints synchronously.`
- **Risk:** Headless webview tests may pass on model state but fail in live-app if repaint cycles don't fire (e.g., missing rAF trigger, layout-read debounce). The fold-gutter test works around this with ad-hoc doc-change re-dispatch, not a true cross-frame-boundary wait.
- **Mitigation:** T4/T5 VM testing covers the real rAF/repaint cycle; headless webview tests are semi-trustworthy.

**2. ImageRenderer / `cacheDisplay` false-greens (TSK-488 class):**
FileTabStripVisualRegressionTests docstring: `The strip is SwiftUI-drawn chrome whose visibility cannot be proven by ImageRenderer or cacheDisplay (LESSONS.md compositor class).`
- **Risk:** The 60+ headless tests for find-bar, floating-tooltip, git-panels, format-toggles, etc., all verify `@Published` property state but do NOT prove the SwiftUI view tree renders or is visible on screen. A silent regression (view blanked by an occlusive sibling, z-index bug, clipped frame) would pass all headless tests.
- **Mitigation:** Only FileTabStripVisualRegressionTests (T5) escapes this. The owner has been burned multiple times; T6 UAT framework is in development (docs/research/agent-uat-framework-2026-06-20/).

**3. Pixel-eval logic: fragile synthetic-image assumptions:**
FileTabStripPixelEvalTests unit-tests separator-column detection on canned bitmaps. If the algorithm assumes specific DPI, anti-aliasing behavior, or color-space encoding, a host-to-VM transition (different monitor, DPI scaling, color profile) can break the real-screenshot eval.
- **Risk:** A test passes on the dev machine's synthetic image but fails on the VM's real screenshot.
- **Mitigation:** FileTabStripVisualRegressionTests includes tolerance ranges (100..260 pt gap between separators, 8px ink-pixel thresholds) and debug-dir output (`MDV_PIXEL_DEBUG_DIR`) for manual inspection. But tolerance tuning is manual.

**4. Headless git tests assume model-level state = visual rendering:**
GitLogSelectionTests, GitPanelPickerTests, GitStatusTabGroupingTests all assert `GitPanelModel` state. No VM tests validate that the row highlighting color is *actually visible on screen*, that the grouped sections *actually render* with visual separation, or that the repo-picker modal *actually opens*.
- **Risk:** State machine is perfect; visual rendering is broken (color blended into background, modal off-screen, etc.).
- **Mitigation:** None in this batch. Git panels need T5 pixel tests (missing from slice 3/6).

**5. Async actor isolation (HighlightCacheActorTests):**
Tests on `@MainActor` verify that the actor's methods are called and state changes, but do NOT prove the actual async isolation boundary (concurrent access safety, race conditions in real multi-threaded context).
- **Risk:** Headless tests run sequentially on @MainActor; concurrent access races may not surface.
- **Mitigation:** Unit tests cover the happy path; integration tests would need async/concurrent task spawning (not visible in this batch).

---

## Rebuild Notes: Day-1 Test Strategy

**For a greenfield app (Swift native UI, Rust core, WebView/TUI/remote transport):**

1. **Replicate the tiered pyramid, but invest heavily in the VM-validation lane:**
   - The original app has 69 test files; only 1 is T5 pixel (1.4%). The owner has been burned repeatedly by invisible-but-state-perfect UI bugs. A rebuild should commit to T5 pixel coverage for **every custom-drawn surface** (tab strip, find-bar geometry, git-panel grouping, focus-mode filter, status badges). Rule of thumb: if it's a SwiftUI view component you added, it needs a PixelTestCase T5 test capturing its real on-screen appearance. Don't trust ImageRenderer.

2. **Adopt the pure-function pixel-eval pattern early:**
   - FileTabStripPixelEvalTests' approach (pure helper functions, unit-tested on synthetic bitmaps, re-used in live-capture tests) is robust. Bake it in: pixel-eval algorithm ⊂ host tests; screenshot-capture loop ⊂ VM tests.

3. **Gate WebView tests by default; whitelist per feature:**
   - The `#192` gate prevents bloat, but opt-in gates breed under-testing. If WebView is a first-class surface (CM6 editor, Mermaid, rendered preview), consider making the gate **default-on** and opt-out instead, or integrate WebView tests into the main merge gate with a fast path (headless synthetic eval first, live WKWebView second).

4. **Adopt nonce-counter + state-machine contracts:**
   - FindCoordinatorTests' pattern (nonce-bump assertions, multiple independent bags, state-routing coverage) is a gold standard. Bake it in as a standard for any multi-state UI coordinator. The docstring format (DECISION/APPLY/Remainder) codifies the model-render boundary.

5. **Test dirty-rect / incremental-repaint early:**
   - ImageEditorPaintTests (TSK-285, 69 tests) includes TSK-1052 dirty-rect tracking. If the rebuild has any incremental-render surface (canvas, editor, large list), add dirty-bounds assertions from day one. It's cheap to test and catches perf regressions before they ship.

6. **Don't reach for fixtures without async tearDown:**
   - ExternalEditReconcileWiringTests' pattern (tmpDir + UUID + async tearDown) is reliable. Copy it. Avoid bare `setUp()` if cleanup is async (file removal, network close, etc.).

7. **Expect wide state-machine coverage + narrow pixel coverage:**
   - This batch has ~50 state-machine tests (find, git, floating-tooltip, image-editor) and 1 pixel test. The ratio is backwards for a production app. Plan to spend 2-3× effort on T5 tests for user-visible surfaces; state-machine tests are cheap to write but insufficient.

8. **Audit the "WebViewTestCase #192" pattern:**
   - FoldGutterWebViewTests uses `skipUnlessEnabled()` to gate itself. When porting WebView tests to a new codebase, check if the gate is working (tests can be skipped silently, creating false confidence). Run the suite with `MDV_RUN_WEBVIEW_TESTS=1` explicitly to ensure they run.

9. **Pin the test-runner host-vs-VM contract upfront:**
   - This project ran UI tests on the host until 2026-06-06 (owner directive); VM-only is now the rule (LiveAppTestCase T4, PixelTestCase T5). In the rebuild, make it a git hook: refuse to land a change that runs T4/T5 on the host (check for `MDV_VM_GUI_SESSION` env var in test detection).

10. **Adopt the "gold-standard TabsStateTests pattern" language:**
    - Many tests in this batch cite "gold-standard TabsStateTests pattern" (FindCoordinatorTests, others). Find and copy that original pattern (the `TabsStateTests` file is the reference). It's clearly a widely-imitated, battle-tested model.

---

## Batch Summary Stats

| Metric | Value |
|--------|-------|
| Files in slice 139–207 | 69 |
| Total LOC | 8,650 |
| Total test functions | 588 |
| Headless-UI(T1/T1m/T2) | 66 files (96%) |
| WebView-inprocess | 2 files (3%) |
| T5-pixel | 1 file (1%) |
| T4-live | 0 files |
| AX tests | 0 files |
| Framework: XCTest | 69 files (100%) |
| Framework: SwiftTesting | 0 files (0%) |
| Avg LOC per file | 125 |
| Avg tests per file | 8.5 |
| Largest file | ImageEditorPaintTests (842 LOC, 69 tests) |
| Shortest file | FolderStatsModelTests (22 LOC, 1 test) |

---

## Key Takeaways

- **State machines dominate.** 50+ files test pure-logic state transitions (@Published properties, nonce counters, multi-bag coordinators). Excellent for catching regressions in the model layer.
- **Pixel validation is rare.** 1 T5 test in 69 files. The app has been burned by invisible UI bugs (TSK-488 ImageRenderer false-greens); the rebuild should commit to T5 for every custom surface.
- **WebView tests are opt-in and likely under-run.** #192 gate is not on by default; FoldGutterWebViewTests may silently skip in CI.
- **Infrastructure patterns are portable:** nonce-counter assertions, dirty-rect tracking, pixel-eval helpers, state-machine contracts (DECISION/APPLY/Remainder). Copy these wholesale.
- **The missing T4/T5 infrastructure:** 60 files verify model state correctly but don't prove on-screen rendering. The rebuild's day-1 investment should be a VM-validation lane that runs alongside the host gate, with T5 tests for every custom view component.
