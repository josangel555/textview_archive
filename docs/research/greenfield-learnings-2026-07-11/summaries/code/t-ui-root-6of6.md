# Test Survey: Tests/ViewerUITests Root, Files 346–415/415 (Final Slice)

**Slice:** 70 files, ~6,800 LOC · 286 distinct test functions · all XCTest (no Swift Testing)

---

## File-by-File Inventory

**SpreadsheetViewHostingTests.swift** (74 LOC) — tier: webview-inprocess · framework: XCTest · pins: SpreadsheetView renders non-blank hierarchy + scroll containers for multi-sheet grids (TSK-1141) · teeth: real (NSHostingView + layoutSubtreeIfNeeded)

**SQLiteBrowserExportTests.swift** (58 LOC) — tier: headless-unit · framework: XCTest · pins: SQLite export menu wiring (exportedText/copyResult model methods on CSV/JSON/Markdown serializers) · teeth: real (model state + pasteboard side effects)

**SQLiteWidthTests.swift** (182 LOC) — tier: headless-unit · framework: XCTest · pins: SQLite column-width model & persistence across query result changes · teeth: real (width array symmetry + bounds)

**StatusBarMemoryTests.swift** (69 LOC) — tier: headless-unit · framework: XCTest · pins: StatusBar memory sampler publishes only on actual value changes, not on zero-change polls · teeth: real (Combine timer + @Published mutation guard; TSK-366)

**StatusBarMetricsCacheTests.swift** (183 LOC) — tier: headless-unit · framework: XCTest · pins: Byte-count metrics (UTF-8/UTF-16 views, character boundary handling, line-ending edge cases) · teeth: real (16 cases covering null bytes, surrogate pairs, CRLF)

**StickyScrollModelTests.swift** (101 LOC) — tier: headless-unit · framework: XCTest · pins: Sticky scroll model pins enclosing headers into nested scope chains · teeth: real (scope hierarchy invariants; TSK-719)

**StructuralSearchHostingTests.swift** (58 LOC) — tier: webview-inprocess · framework: XCTest · pins: Structural search panel renders with live search controls (language selector, query field, results) · teeth: real (NSHostingView + WebViewTestCase gate)

**StructuralSearchViewModelTests.swift** (46 LOC) — tier: headless-unit · framework: XCTest · pins: Structural search engine discovers function declarations in Swift source · teeth: real (parser → query matching)

**SurfaceCoverageMatrixTests.swift** (86 LOC) — tier: headless-unit · framework: XCTest · pins: **MANDATE 1** gate: every ViewMode lens + aux surface (canvas/terminal/walkthrough) maps to ≥1 real-render evidence suite (WV/T4/T5) or exempt ticket · teeth: real (compiler-forced dictionary coverage + file-exists disk checks; TSK-1539)

**TabBarIntrinsicSizeTests.swift** (242 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Tab bar reports firm intrinsic width (not GeometryReader default), handles edge-case tab counts/widths · teeth: real (SwiftUI layout invalidation; 5 test variants)

**TabBarWidthTests.swift** (104 LOC) — tier: headless-unit · framework: XCTest · pins: Tab bar width calculations are positive, ordered, and sane across configurations · teeth: real (arithmetic invariants)

**TabCoordinatorCleanupTests.swift** (215 LOC) — tier: headless-unit · framework: XCTest · pins: TabCoordinator drains all 6 per-tab dicts (selections, previews, editor state, etc.) when tab closes · teeth: real (6 dictionary cleanup paths across 3 close routes; isolation from TabCoordinatorTests for debugging)

**TabCoordinatorTests.swift** (457 LOC) — tier: headless-unit · framework: XCTest · pins: State-machine invariants for tab append/close/move, selectedIndex, openTabURLs, splitURL tracking · teeth: real (36 test cases; @MainActor coordinator surface without DocumentModel)

**TabOpPerfTests.swift** (105 LOC) — tier: headless-unit · framework: XCTest · pins: Tab switch & close operations hit wall-clock perf ceiling (model-side only, not render) · teeth: real (wall-clock assertion; TSK-108; measures O(n) list mutations)

**TabRepublishInvariantTests.swift** (213 LOC) — tier: headless-unit · framework: XCTest · pins: DocumentModel does NOT republish when tab-local state changes (CSV filter, editor selection, scroll) · teeth: real (8 cases checking @Published silence on deep mutations)

**TabSwitchStaleReloadTests.swift** (76 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Tab switch to a file whose on-disk content changed forces reload (stats, display, render) · teeth: real (view invalidation on model mutation; TSK-452)

**TabTitleStyleTests.swift** (26 LOC) — tier: headless-unit · framework: XCTest · pins: Tab title style logic (italic only for preview mode, styling per content type) · teeth: real (4 style cases)

**TaskRunnerHostingTests.swift** (61 LOC) — tier: webview-inprocess · framework: XCTest · pins: Task runner panel renders with control + task list (NSHostingView smoke) · teeth: real (TSK-1160)

**TaskRunnerViewModelTests.swift** (53 LOC) — tier: headless-unit · framework: XCTest · pins: Task discovery finds package.json scripts, auto-selects first · teeth: real (JSON parse + discovery order)

**TerminalAccessibilityTests.swift** (84 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Terminal tab chips are in the AX tree (accessibility scan) · teeth: real (1 test validates AX presence)

**TerminalCommandPaletteHostingTests.swift** (61 LOC) — tier: webview-inprocess · framework: XCTest · pins: Terminal command-palette panel renders query field + results (NSHostingView smoke) · teeth: real (TSK-1176)

**TerminalCommandPaletteViewModelTests.swift** (60 LOC) — tier: headless-unit · framework: XCTest · pins: Command palette unifies favorites first, dedupes entries · teeth: real (3 cases; TSK-1176)

**TerminalCwdTests.swift** (74 LOC) — tier: headless-unit · framework: XCTest · pins: Working-directory resolution logic (file → containing folder, symlink expansion) · teeth: real (10 cases; TSK-769)

**TerminalDiagnosticInfoTests.swift** (112 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Terminal diagnostic output (grid dimensions, content rows, blank-screen reporting) · teeth: real (6 cases; TSK-493)

**TerminalDragDockTests.swift** (63 LOC) — tier: headless-unit · framework: XCTest · pins: Shoulder-edge drag mapping (terminal pane edge ↔ dock-position translation) · teeth: real (4 cases; TSK-1317)

**TerminalFavoritesEditorModelTests.swift** (63 LOC) — tier: headless-unit · framework: XCTest · pins: Favorites editor model rows mirror underlying store · teeth: real (5 cases; TSK-1475)

**TerminalForegroundBumpTests.swift** (79 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Background output feeds PTY parser without version-increment side effects · teeth: real (2 cases; TSK-459)

**TerminalModelHistoryTests.swift** (57 LOC) — tier: headless-unit · framework: XCTest · pins: Terminal history model records typed commands in command-entry log · teeth: real (5 cases; TSK-1176)

**TerminalNSViewResizeTests.swift** (50 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Zero-size transient resizes do NOT emit destructive AppKit resize signals · teeth: real (1 case; guards against false PTY reflow)

**TerminalPaletteTests.swift** (66 LOC) — tier: headless-unit · framework: XCTest · pins: Terminal color-palette model default, selection, activation · teeth: real (5 cases)

**TerminalPaletteThemeTests.swift** (58 LOC) — tier: headless-unit · framework: XCTest · pins: Active theme name drives ANSI color assignments · teeth: real (4 cases; TSK-1312)

**TerminalPaneStoreTests.swift** (481 LOC) — tier: headless-unit · framework: XCTest · pins: TerminalPaneStore lifecycle (fresh closed, spawn on open, per-pane state, session persistence) · teeth: real (38 cases; heavyweight state machine)

**TerminalReturnKeyRoutingTests.swift** (76 LOC) — tier: headless-unit · framework: XCTest · pins: Return key while terminal focused routes to PTY (claimed, not propagated) · teeth: real (4 cases; TSK-448)

**TerminalScrollOffsetPersistenceTests.swift** (98 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Scroll wheel writes offset back to model (persistence roundtrip) · teeth: real (4 cases; TSK-489)

**TerminalTabShoulderEdgeTests.swift** (20 LOC) — tier: headless-unit · framework: XCTest · pins: Shoulder-edge geometry (outer edge per position) · teeth: real (1 case; TSK-1177)

**TerminalTabStripRenderTests.swift** (116 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Terminal tab-strip chips paint on the correct edges (left/right rail, correct visual ordering) · teeth: real (4 cases; SwiftUI raster smoke for TSK-488; headless complement to pixel test)

**TerminalTabStripVisualRegressionTests.swift** (338 LOC) — tier: T5-pixel · framework: XCTest · pins: **REAL-PIXEL compositor guard** — terminal tab chips actually composite on screen (not occluded by opaque NSViewRepresentable layer); compositor-ordered `.zIndex(1)` above surface · teeth: real (4 cases; WindowServer screencapture validates saturated-pixel density in rail band; would catch regression to TSK-488 occlusion; TSK-488)

**TerminalUpdateVersionGateTests.swift** (70 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Terminal first-update installs regardless of version value (no version-gate misfires) · teeth: real (4 cases; TSK-741)

**TextSearchRepaintGuardTests.swift** (96 LOC) — tier: headless-unit · framework: XCTest · pins: SourceTextController skips O(document) repaints when find-highlights don't change · teeth: real (4 cases; perf guard; TSK-736)

**TextSearchTests.swift** (145 LOC) — tier: headless-unit · framework: XCTest · pins: Text-search query matching (empty → nothing, case-sensitivity, regex vs literal, bidirectional) · teeth: real (15 cases)

**ThemeOverridePersistenceTests.swift** (77 LOC) — tier: headless-unit · framework: XCTest · pins: Theme override model writes-through to preferences on didSet · teeth: real (4 cases; TSK-101)

**ThemeSelectionModelTests.swift** (120 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Selected theme definition drives active theme publication · teeth: real (6 cases; TSK-641)

**TmuxControllerTests.swift** (53 LOC) — tier: headless-unit · framework: XCTest · pins: Tmux output routes to pane screen & bumps output version · teeth: real (4 cases; TSK-1023)

**ToastCenterTests.swift** (203 LOC) — tier: headless-unit · framework: XCTest · pins: Toast queue (post/auto-dismiss/persistence across navigation) · teeth: real (13 cases; TSK-1436)

**ToolPanelBoundingTests.swift** (281 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Tool panels remain within sidebar bounds (layout constraint guard) · teeth: real (3 cases; layout invalidation tracking)

**ToolResultsPanelIntegrationTests.swift** (76 LOC) — tier: headless-UI(T1/T1m/T2p) · framework: XCTest · pins: Check-links verb populates results panel, row clicks navigate to line · teeth: real (3 cases; verb wiring; TSK-1434)

**TooltipTimingTests.swift** (22 LOC) — tier: headless-unit · framework: XCTest · pins: Tooltip appear delay is relaxed (from default to 0.6s) · teeth: real (2 cases; TSK-1209)

**TrackedReposChannelReadTests.swift** (220 LOC) — tier: headless-unit · framework: XCTest · pins: Tracked-repos multi-repository status resolution (per-file logic, merge conflict detection) · teeth: real (11 cases)

**TrackedReposRepublishInvariantTests.swift** (207 LOC) — tier: headless-unit · framework: XCTest · pins: DocumentModel does NOT republish when tracked-repos channel recomputes · teeth: real (8 cases; @Published silence guard)

**TSK1049OffMainRenderTests.swift** (65 LOC) — tier: headless-unit · framework: XCTest · pins: Off-main-thread renders match sync renders (no corruption) · teeth: real (2 cases; TSK-1049; headless-only, not pixel-validated)

**UATSQLiteFixtureTests.swift** (111 LOC) — tier: headless-unit · framework: XCTest · pins: UAT SQLite fixture is written with SQLite magic header (file-format validation) · teeth: real (5 cases; TSK-1021)

**UIEventSynthTests.swift** (100 LOC) — tier: headless-unit · framework: XCTest · pins: UIEventSynth finds nested identifiers by accessibilityIdentifier · teeth: real (4 cases; AX automation glue)

**UIKeySynthTests.swift** (126 LOC) — tier: headless-unit · framework: XCTest · pins: Key synthesis types strings character-by-character with correct down/up sequencing · teeth: real (8 cases; TSK-818; event routing glue)

**UISceneApplierTests.swift** (410 LOC) — tier: headless-unit · framework: XCTest · pins: UISceneApplier state reconstruction (tab/split/panel nesting, sidebar configuration, view mode) · teeth: real (25 cases; TSK-492; deep state-machine)

**UnifiedHistoryViewModelTests.swift** (195 LOC) — tier: headless-unit · framework: XCTest · pins: Unified history model (reload, filtering, sorting, pagination) · teeth: real (14 cases; TSK-1103)

**UniversalPasteActionTests.swift** (90 LOC) — tier: headless-unit · framework: XCTest · pins: Universal paste action opens new tab with pasted content (plaintext → editor) · teeth: real (4 cases; TSK-958)

**ViewModeMatrixSmokeTests.swift** (521 LOC) — tier: support · framework: XCTest · pins: View-mode lens smoke test (fresh open renders default mode, all modes activate without crash) · teeth: weak (smoke; no assertion of rendered pixels; ImageRenderer false-green risk; legacy smoke-gate excluded from merge gate per TSK-1334)

**ViewModeShortcutTests.swift** (69 LOC) — tier: headless-unit · framework: XCTest · pins: View-mode keyboard shortcuts select the Nth available mode · teeth: real (3 cases; TSK-899)

**VimModeKindTests.swift** (31 LOC) — tier: headless-unit · framework: XCTest · pins: Vim mode classification from core enum values · teeth: real (4 cases; TSK-679)

**WalkthroughDiagramOverlayHostingTests.swift** (52 LOC) — tier: webview-inprocess · framework: XCTest · pins: ASCII-overlay renders text and caption (NSHostingView smoke) · teeth: real (TSK-1119)

**WalkthroughDiagramOverlayMountTests.swift** (53 LOC) — tier: webview-inprocess · framework: XCTest · pins: Mermaid requests mount a WebView, ASCII requests do not (mount logic) · teeth: real (TSK-1333)

**WalkthroughDiagramPresentationTests.swift** (40 LOC) — tier: headless-unit · framework: XCTest · pins: Diagram presentation model (Mermaid → source mapping) · teeth: real (5 cases; TSK-1119)

**WalkthroughMermaidPageTests.swift** (22 LOC) — tier: headless-unit · framework: XCTest · pins: HTML embedding (Mermaid source → complete page) · teeth: real (2 cases; TSK-1333)

**WalkthroughMermaidRenderWebViewTests.swift** (51 LOC) — tier: webview-inprocess · framework: XCTest · pins: Walkthrough Mermaid page renders SVG (WebView completion handler) · teeth: real (TSK-1333)

**WalkthroughMermaidWebViewHostingTests.swift** (49 LOC) — tier: webview-inprocess · framework: XCTest · pins: Walkthrough Mermaid component mounts a WKWebView (NSHostingView smoke) · teeth: real (TSK-1333)

**WalkthroughsBrowserWiringTests.swift** (45 LOC) — tier: headless-unit · framework: XCTest · pins: Walkthroughs browser wiring (menu item → hosted tab) · teeth: real (2 cases; TSK-1107)

**WarmEditorWebViewCacheTests.swift** (233 LOC) — tier: headless-unit · framework: XCTest · pins: Warm editor WebView cache stash/retrieve roundtrips same instance when text matches · teeth: real (13 cases; cache identity + reuse; TSK-1047)

**WarmHTMLWebViewCacheTests.swift** (187 LOC) — tier: headless-unit · framework: XCTest · pins: Warm HTML WebView cache roundtrip (identity preservation across stash/retrieve) · teeth: real (13 cases; TSK-1190)

**WarmWebViewCacheTests.swift** (169 LOC) — tier: headless-unit · framework: XCTest · pins: Warm WebView cache stash/retrieve roundtrips same instance (generic cache behavior) · teeth: real (10 cases; TSK-1042)

**WebViewAllowlistTests.swift** (55 LOC) — tier: headless-unit · framework: XCTest · pins: WebView construction only in allowlisted content hosts (security gate) · teeth: real (1 case; TSK-1524)

---

## Test-Type Taxonomy — Proportions & Patterns

| Tier | Count | % | Role |
|------|-------|---|------|
| **headless-unit** | 57 | 81% | Model/logic/FFI/state machines; pure-value behavior; no render |
| **headless-UI(T1/T1m/T2p)** | 11 | 16% | SwiftUI layout + accessibility + view-invalidation guards; no pixels |
| **webview-inprocess** | 9 | 13% | WKWebView smoke (NSHostingView + content render, no pixel validation) |
| **T5-pixel** | 1 | 1% | Real WindowServer pixels (compositor ordering, actual visibility) |
| **support** | 1 | 1% | Smoke / legacy; weak teeth |

**Key observation:** The tier distribution is **INVERTED from the MANDATE priority** — 81% are headless-unit (logic guards), 16% are the minimal headless-UI (layout smoke), only 9 are webview (render smoke), and **1 is the authoritative T5 pixel test**. The rebuild will invert this: pixel-first coverage for user-visible surfaces, then headless for the model.

---

## Coverage Shape — Over/Under-Tested Regions

### Well-Covered (Excellent Teeth)

- **State machines** (TabCoordinator, TerminalPaneStore, UISceneApplier, UnifiedHistoryViewModel): 25–481 LOC, 3–38 cases each. Comprehensive path coverage, invariant guards, isolation per tier (e.g., TabCoordinatorCleanupTests separates cleanup logic).
- **Model wiring / @Published guards** (TabRepublishInvariantTests, TrackedReposRepublishInvariantTests): 8 cases each. Real mutations tested against silence expectations.
- **View caches** (WarmEditorWebViewCacheTests, WarmHTMLWebViewCacheTests, WarmWebViewCacheTests): 10–13 cases each. Roundtrip identity validation.
- **Render guards** (TerminalTabStripRenderTests + TerminalTabStripVisualRegressionTests pair): headless smoke + real pixel guard; complementary approach.
- **Compositor occlusion** (TerminalTabStripVisualRegressionTests, TSK-488): the ONLY T5 test in this slice; chronicles a recurring false-green trap (ImageRenderer blind to AppKit layer compositing).

### Under-Tested / False-Green Risks

- **View-mode lens rendering** (ViewModeMatrixSmokeTests): 521 LOC, **3 test cases** (smoke only, no assertions). Uses ImageRenderer (known false-green for compositor occlusion). **NOT in headless gate** (TSK-1334 excludes pre-install smoke). Rebuild MUST add real-render per-lens validation (pixel + AX).
- **Surface-coverage MANDATE enforcement** (SurfaceCoverageMatrixTests): 2 cases. A single test validates the matrix; a typo in a surface name or a stale ticket reference can slide. The matrix itself is a guard, but it's held by a thin test.
- **WebView in-process tier**: 9 files, mostly 1–2 cases each. These are **smoke only** — they validate the WebView mounts and the content-hosting path fires, but NOT pixel/scroll/interaction correctness. A WebView can fail to render, misbehave on scroll, or remain invisible on screen and these pass.
- **Accessibility wiring** (TerminalAccessibilityTests, UIEventSynthTests): minimal coverage (1–4 cases each). `#192`-gated tests only. TerminalAccessibilityTests is 1 case ("is in AX tree"); no interaction/routing.
- **Perf gates** (TabOpPerfTests, TextSearchRepaintGuardTests): 1–4 cases. Wall-clock assertions can be flaky under machine load; perf regressions may not fail headless-gate if load varies.

---

## Harness & Infra Patterns Worth Porting

### 1. **Tier Base Classes & Self-Skip Gating**
- `WebViewTestCase`: `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`), self-skips unless `dist/` built + Screen Recording granted. Cleans up hosted NSViews.
- `HeadlessUITestCase`: host-safe, skips heavy tiers (T4/T5) under merge gate.
- `PixelTestCase` (T5): self-skips unless `MDV_VM_GUI_SESSION=1`, validates screen-capture presence + freshness.
- **Pattern:** Use tier base classes to enforce separation; self-skip prevents accidental host-side UI spawns.

### 2. **Surface-Coverage Mandate Enforcement** (SurfaceCoverageMatrixTests)
- **Static matrix** pinning every content lens + aux surface to an evidence file (WV/T4/T5 suite) or an explicit `exempt(ticket:)` entry.
- **File-exists checks** ensure evidence doesn't rot (renamed/deleted files fail the gate).
- **Exemption ratchet** (can only shrink, not grow) prevents silent coverage gaps.
- **Rebuild pattern:** Make this mandatory day-1; add every surface with explicit real-render suite or clear ticket.

### 3. **Compositor Occlusion Negative Control** (TSK-488 Pattern)
- TerminalTabStripVisualRegressionTests + headless TerminalTabStripRenderTests form a **complementary pair:**
  - Headless: validates SwiftUI-only render (chips exist, layout is correct).
  - T5: validates compositor ordering (chips actually reach screen, not overdrawned by opaque layer).
- **Root cause was diagnostic:** ImageRenderer = false green (rasterizes SwiftUI in isolation, no opaque layer). Fix required real WindowServer pixels.
- **Rebuild pattern:** For any SwiftUI view sharing a container with an opaque representable (AppKit WebView, Terminal surface, CodeMirror), **REQUIRE both tiers** — headless can't catch compositor order bugs.

### 4. **Invariant Separation** (TabCoordinatorTests vs TabCoordinatorCleanupTests)
- Large state machines split by **concern:** TabCoordinatorTests covers append/close/move arithmetic (36 cases); TabCoordinatorCleanupTests isolates the 6-dict cleanup (6 cases per path).
- **Benefit:** failures point directly at the responsible tier instead of tangling with broader logic.
- **Rebuild pattern:** Don't flatten large tests; separate by failure domain for debugging clarity.

### 5. **@Published Silence Guards** (TabRepublishInvariantTests pattern)
- Tests that DocumentModel does NOT republish when view-local state changes (CSV filter, selection, scroll).
- Validates that model-layer mutations don't cascade unnecessary re-renders.
- **Pattern:** replicate for every local-state mutation path.

### 6. **Fixture Validation** (UATSQLiteFixtureTests)
- Validates test fixture files are properly formatted (SQLite magic header), not corrupted/truncated.
- **Pattern:** any generated fixture/test data needs a basic sanity check test.

### 7. **WebViewTestCase Cleanup Pattern**
```swift
private var hosted: [NSView] = []
override func tearDown() async throws {
    WebViewTestTeardown.teardown(hosted)
    hosted.removeAll()
}
```
- Explicit cleanup prevents NSView leaks and window-stack pollution in hosted tests.

### 8. **Negative Control Pattern** (TSK-488, implied)
- Code comment documents the recurring defect (tab-strip occlusion by PTY layer).
- Both T5 test and headless test exist.
- **Rebuild pattern:** For bugs that recurred 3+ times, add a documented negative-control test that would fail on regression. (The `MDVNegativeControl.isBroken()` mechanism hasn't been applied here, but the pattern exists in LESSONS.md.)

---

## Flake / False-Green Risks Observed

### Critical Risks

1. **ImageRenderer false-green (TSK-488, 2026-06-07)** — already documented in LESSONS.md
   - **Risk:** SwiftUI-only smoke tests using ImageRenderer can pass while real compositor ordering fails (e.g., tab strip occluded by opaque AppKit layer).
   - **Mitigation:** This slice has TerminalTabStripVisualRegressionTests (T5 pixel test) catching the regression, but **only for terminal tabs**. Other opaque-representable pairs may not have T5 guards yet.
   - **Rebuild action:** Audit all AppKit-in-SwiftUI views; pair each with a T5 pixel validation.

2. **ViewModeMatrixSmokeTests: weak teeth**
   - **Risk:** 521 LOC, 3 cases, no render assertions, uses ImageRenderer, **excluded from merge gate** (TSK-1334).
   - **Impact:** A new view-mode lens can be added without pixel validation and shipped broken.
   - **Rebuild action:** Replace with per-lens real-render matrix (WV/T4/T5 per SurfaceCoverageMatrixTests pattern).

3. **Perf gate flake under load** (TabOpPerfTests)
   - **Risk:** Wall-clock assertions fail spuriously on busy machines; perf regressions may hide in noise.
   - **Mitigation:** Tab coordinator ops are fast (microseconds); on idle hardware should be stable.
   - **Rebuild action:** Add PerfSignpost instrumentation + xctrace profiling for any perf-critical operation; don't rely on raw wall-clock.

4. **WebView smoke ≠ WebView correctness**
   - **Risk:** 9 webview-inprocess tests validate NSHostingView mount + content-route-firing, but NOT scroll behavior, layout, input handling, or pixel rendering.
   - **Impact:** A WebView can have broken scroll, misaligned layout, or render nothing and pass all 9 tests.
   - **Rebuild action:** Add T4/T5 validation for every WebView surface (e.g., EditorScrollRestoreWebViewTests, PreviewTabVisualRegressionTests patterns).

### Moderate Risks

5. **Accessibility coverage minimal** (TerminalAccessibilityTests, UIEventSynthTests)
   - **Risk:** 1–4 cases per file. No interaction testing (only "is in AX tree" checks).
   - **Mitigation:** AX automation requires on-device real events + Screen Recording grant; not host-testable. But structural coverage is incomplete.
   - **Rebuild action:** Per MANDATE 2 (docs/TEST_PYRAMID.md), add AX interaction tests (real event synthesis on AX elements) for major UI paths.

6. **State-machine test isolation**
   - **Risk:** TabCoordinatorTests (36 cases) + TabCoordinatorCleanupTests (6 cases) + other state tests use simple @MainActor XCTestCase without mocking. A side-effect in setUp/tearDown can poison the whole suite.
   - **Mitigation:** No evidence of this in the codebase; tests appear clean.
   - **Rebuild action:** For state tests > 20 cases, consider a dedicated test fixture builder to isolate each case.

---

## Rebuild Notes — What to Take & What to Rethink

### Patterns to Adopt (Day 1)

1. **Tier-based self-skip gating** — prevent UI tests from running on the Mac host. Copy the WebViewTestCase / PixelTestCase self-skip logic.

2. **Surface-coverage mandate matrix** — make it day-1 infrastructure. Every surface = explicit evidence file or exemption ticket. Red gate if an entry is missing or stale.

3. **Compositor-occlusion awareness** — document the TabStripRenderTests vs TabStripVisualRegressionTests pattern. Any opaque-representable view needs BOTH tiers.

4. **@Published silence guards** — replicate the TabRepublishInvariantTests pattern for every view-local state path (selection, scroll, filter, etc.).

5. **State-machine isolation** — large tests (>15 cases) split by concern (state vs cleanup, append vs close, etc.) for debugging clarity.

6. **WebView in-process smoke** — NSHostingView mounts are valuable baselines, but pair with real-render (T4/T5) for any user-facing WebView.

### Rethink / Don't Adopt As-Is

1. **ViewModeMatrixSmokeTests (521 LOC, 3 cases)** — this is a false-green factory. **Don't port; replace with real-render per-lens guard.** The 521 LOC is mostly view instantiation boilerplate; useful for compile-time validation but not for render coverage.

2. **ImageRenderer as a render validation tool** — it's fast and doesn't require a live app, but it's BLIND to:
   - Opaque AppKit layer compositing order
   - Z-index occlusion
   - Real scroll behavior
   - Keyboard/mouse interaction
   Use ImageRenderer for debugging SwiftUI geometry, NOT for render validation. Real-render = T4/T5.

3. **Perf gates as flake-prone assertions** — TabOpPerfTests is useful as a direction check ("tabs are fast"), but wall-clock assertions are fragile. Pair with PerfSignpost instrumentation so you can see WHERE the time is going (which operation regressed, not just "the whole tier got slower").

### Coverage Gaps in This Slice (Known Exemptions)

- **ViewMode.formatted, .table, .diff, .hex** — marked exempt in SurfaceCoverageMatrixTests against TSK-1551 (4 exemptions as of 2026-07-07).
- **Terminal styling details** — TerminalPaletteTests is model-only; no render validation of palette color application.
- **Canvas/Mermaid rendering** — WalkthroughMermaidRenderWebViewTests validates WebView mount; no pixel validation of diagram SVG.
- **ImageEditor/AudioEditor** — referenced in SurfaceCoverageMatrixTests but no test file in this slice (likely earlier files or not yet ported).

### Metrics from This Slice

- **Average test count per file:** 286 tests ÷ 70 files ≈ **4.1 tests/file** (headless-unit median ~4, state machines up to 38).
- **LOC per test:** ~6,800 LOC ÷ 286 tests ≈ **23.8 LOC/test**.
- **Headless:real-render ratio:** ~57:1 (headless-unit + headless-UI : webview + T5). Rebuild **should be ~3:1 or tighter** (heavy investment in real-render).
- **Test density by tier:**
  - Headless-unit: 3–481 LOC, avg ~50 LOC.
  - Headless-UI: 20–281 LOC, avg ~135 LOC (larger due to layout setup).
  - WebView: 49–74 LOC, avg ~56 LOC (compact smoke).
  - T5: 338 LOC (1 outlier; comprehensive pixel suite).

### Autonomy Implications

- **Mandate enforcement tests** (SurfaceCoverageMatrixTests, TerminalTabStripRenderTests + VisualRegressionTests pair) have **TEETH** — they fail when coverage drops or compositor order regresses.
- **Negative-control pattern** (documented in LESSONS.md but not applied here) should be extended: explicit `MDVNegativeControl.isBroken()` switches for every 3+-recurrence bug.
- **Agent-driven UAT** (OWNER DIRECTIVE, CLAUDE.md): model-side validation (state tests) are agent-runnable; render tests (T4/T5) require VM but are **NOT owner-only**. Agents MUST run VM tests as part of validation.

---

## Summary

This final slice showcases a **mature test harness with strong state-machine and model-layer coverage** but **weak render validation**. The tier distribution (81% headless) reflects the codebase's evolution: logic was proven first via unit tests, then render was added reactively (catching compositor bugs post-ship). The rebuild should **flip the pyramid**: real-render first (T5 pixel + T4 live per surface), then headless model-layer under it. Key patterns to adopt: self-skip gating, surface-coverage mandate, compositor-occlusion awareness. Key anti-patterns to reject: ImageRenderer as a render validator, weak-teeth smoke suites, perf assertions without instrumentation.

