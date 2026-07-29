# ViewerUITests Root, Slice 5/6 (277–345) — Learnings Summary

## File Inventory (69 files)

| # | File | LOC | Tier | Framework | Pins | Teeth |
|---|------|-----|------|-----------|------|-------|
| 1 | PDFFoundationGlueTests | 111 | headless-UI | XCTest | PDF magic-byte sniff + metadata extraction | real (would fail on bad sniff logic) |
| 2 | PDFSearcherTests | 103 | headless-UI | XCTest | PDF text search cursor navigation + wraparound | real (search offset/count mismatches fail) |
| 3 | PreviewMetadataToggleTests | 70 | headless-UI | XCTest | Preview metadata panel toggle + persistence | real (defaults round-trip tested) |
| 4 | PreviewTabVisualRegressionTests | 120+ | T5-pixel | XCTest | Preview tab compositing; compositor-blank detection | real (regionHasVariety guards occlusion) |
| 5 | PrintExportModelTests | 81 | headless-UI | XCTest | Print/PDF export gate + nonce-driven requests | real (gate logic + request sequencing) |
| 6 | ProblemsPanelUnanalyzedTests | 102 | headless-UI | XCTest | LSP diagnostics "unanalyzed" flag for unopened files | real (logic matches panel display) |
| 7 | PTYReapTests | 40 | headless-unit | XCTest | PTY zombie collection; ESRCH verification | real (would pass zombie if reap broken) |
| 8 | PTYSpawnPlanTests | 120+ | headless-unit | XCTest | Pre-fork shell/env resolution; CStringArray roundtrip | real (byte-exact encoding verified) |
| 9 | PTYWriteDrainTests | 57 | headless-unit | XCTest | PTY partial-write drain loop; EINTR retry logic | real (error handling + edge cases) |
| 10 | ReadOnlySaveGuardTests | 68 | headless-UI | XCTest | Read-only extracted buffer save guard (data safety) | real (source file corruption prevented) |
| 11 | RecentChangesDiscoveryTests | 100+ | headless-UI | XCTest | Git repo discovery from file or sidebar root | real (fallback logic tested with live git) |
| 12 | RecentsRailWiringTests | 91 | headless-UI | XCTest | Recents rail button visibility + data-presence wiring | real (model state → presence mapping) |
| 13 | RefreshTabTests | 100+ | headless-UI | XCTest | Force-reload dirty/clean tabs; prompt overrides | real (content reload + edit preservation) |
| 14 | RegexCacheTests | 90 | headless-unit | XCTest | Find-bar regex cache + ReDoS guard | real (nested-quantifier rejection + timing) |
| 15 | ReloadVerbTests | 56 | headless-UI | XCTest | Reload script verb wiring + file read | real (verb routing + content reload) |
| 16 | RenameFileActionTests | 100+ | headless-UI | XCTest | File rename + tree/bookmark follow-through | real (file mv + sidebar reselection) |
| 17 | RenderedFindBarModelTests | 77 | headless-UI | XCTest | Find bar show/dismiss + query clear + counters | real (state machine transitions) |
| 18 | RenderedFindBarTests | 100+ | webview-inprocess | XCTest | Find bar view-tree presence in rendered mode | weak (descendant count; missing per-control check) |
| 19 | RenderedFindClearWebViewTests | 100+ | webview-inprocess | XCTest | Rendered find clear removes all marks from DOM | real (mark element count verified) |
| 20 | RenderedHTMLAsyncFillTests | 100+ | headless-UI | XCTest | Async markdown→HTML render + cache fill | real (cache miss→request→republish) |
| 21 | RenderedLoadFailureRecoveryTests | 55 | headless-UI | XCTest | WKWebView load-failure dedup-baseline reset | real (lastHTML nil on fail/terminate) |
| 22 | RepoFocusTrackerTests | 100+ | headless-UI | XCTest | Watcher count tracking + eviction on grace expiry | real (watcher lifecycle pinned) |
| 23 | RepoRelativePathTests | 68 | headless-unit | XCTest | Repo-relative path calculation; sibling-prefix guard | real (edge case: /proj vs /proj-sibling) |
| 24 | RepublishCountTests | 100+ | headless-UI | XCTest | God-object republish baseline guard (perf) | real (baseline regression would fail) |
| 25 | ReviewExportTests | 100+ | headless-UI | XCTest | Review JSON/file/clipboard export + state transition | real (export record appended + state→sent) |
| 26 | ReviewJourneyTests | 100+ | headless-UI | XCTest | Code review end-to-end: comment→reply→persist→export | real (full persistence + export verified) |
| 27 | ReviewSessionTests | 100+ | headless-UI | XCTest | ReviewSession runtime; mutations + debounce + state machine | real (debounce collapse tested) |
| 28 | SaveCopyTests | 100+ | headless-UI | XCTest | Save-a-copy: 3 sources (clean/dirty/hex) + overwrite | real (file written, original untouched) |
| 29 | SaveCopyWiringTests | 100+ | headless-UI | XCTest | Save-copy menu gate + suggested name + File menu wiring | real (gate parity with engine) |
| 30 | ScenarioTests | 76 | headless-UI (T1m) | XCTest | Composed flows: multi-file open, render/source toggle | real (title change + mode transitions) |
| 31 | ScriptConsoleHostingTests | 68 | webview-inprocess (T2') | XCTest | Script console panel render + control presence | weak (control structure asserted, not labels) |
| 32 | ScriptConsoleViewModelTests | 63 | headless-unit | XCTest | Script console run/error/timeout state machine | real (error messages + timeout detection) |
| 33 | SearchAnywhereSectionLayoutTests | 80+ | headless-unit | XCTest | Divider() call count in SearchAnywhereSection (brittle pin) | real (would fail on re-added divider) |
| 34 | SelectionAndMinimapEdgeTests | 70+ | headless-unit | XCTest | Selection highlight + minimap layout edge cases | real (UTF-8/emoji boundaries) |
| 35 | SelectionHighlightEngineTests | 70+ | headless-unit | XCTest | Selection-match occurrence finder; policy gates | real (size cap short-circuit) |
| 36 | SelectionMatchHighlightGateTests | 70+ | headless-unit | XCTest | CM6 selection-match drag-gate state machine | real (shouldRunSelectionMatchScan transitions) |
| 37 | SessionsEnabledSettingTests | 57 | headless-UI | XCTest | Sessions-enabled pref read/write + default | real (persistence round-trip) |
| 38 | SessionTabLabelTests | 46 | headless-unit | XCTest | Session tab label truncation helper | real (ellipsis logic + byte budget) |
| 39 | SetThemeVerbTests | 56 | headless-UI | XCTest | Set-theme verb; theme selection + Follow System | real (verb routing + pref write) |
| 40 | SettingsTerminalColorSchemeHostingTests | 70+ | webview-inprocess (T2') | XCTest | Terminal color-scheme picker render | weak (picker presence asserted, not colors) |
| 41 | ShoulderRailEmptyHidingHostingTests | 70+ | webview-inprocess (T2') | XCTest | Empty shoulder rail hidden unless dragging | weak (view count delta, not pixel layout) |
| 42 | ShoulderToggleNoFileOpenTests | 100+ | headless-UI | XCTest | Shoulder toggle visibility; no file open side effect | real (tab list invariant + no URL) |
| 43 | SidebarChildrenCacheEvictionTests | 53 | headless-unit | XCTest | Sidebar LRU eviction; pinned working set | real (eviction count verified) |
| 44 | SidebarDividerWiringTests | 60+ | headless-UI | XCTest | Sidebar divider render + drag routing | weak (divider count + routing behavior) |
| 45 | SidebarFilesToggleHostingTests | 60+ | webview-inprocess (T2') | XCTest | Files panel visibility toggle render | weak (view count delta) |
| 46 | SidebarFilesVisibilityTests | 31 | headless-unit | XCTest | Files override gate (independent of folder presence) | real (isVisible logic) |
| 47 | SidebarFilterTests | 100+ | headless-UI | XCTest | Fuzzy filter ranking + match indices + result cap | real (ranking order + glyph mapping) |
| 48 | SidebarFollowTests | 60+ | headless-UI | XCTest | Pin/follow-active-tab: selection + re-root | real (selection maintained within root) |
| 49 | SidebarKeyMonitorYieldTests | 60+ | headless-unit | XCTest | Sidebar key monitor yield logic (editor key routing) | real (modifier/focus decision tree) |
| 50 | SidebarModelTests | 60+ | headless-UI | XCTest | Sidebar children cache contract (no side effects in body) | real (cache populated only via ensureLoaded) |
| 51 | SidebarRefreshFromDiskTests | 60+ | headless-UI | XCTest | Manual refresh force re-list from disk | real (externally-added/removed files) |
| 52 | SidebarRepublishInvariantTests | 100+ | headless-UI | XCTest | Sidebar mutations NOT fanning to DocumentModel (perf) | real (negative invariant: zero document publishes) |
| 53 | SidebarRevealTests | 60+ | headless-UI | XCTest | Reveal in sidebar: set root + expand ancestors + select | real (expansion state + selection) |
| 54 | SidebarSectionHeaderRecipeTests | 60+ | headless-unit | XCTest | Shared section header font/padding recipe constants | real (accidental bumps detected) |
| 55 | SideDockCompositingTests | 60+ | headless-unit | XCTest | Terminal column z-order (compositingGroup above content) | real (z-index inequality verified) |
| 56 | SnippetInsertModelTests | 60+ | headless-UI | XCTest | Snippet insert posts expanded text to editor | real (request carries correct text) |
| 57 | SnippetSessionDrivingTests | 60+ | headless-unit | XCTest | Snippet tab-stop navigation state machine | real (stop walking + final-exit) |
| 58 | SnippetSessionModelTests | 60+ | headless-UI | XCTest | DocumentModel snippet session integration | real (session begun + caret seeded) |
| 59 | SourceApplyRecolorTests | 100+ | headless-UI | XCTest | In-place recolor preservation (no storage rebuild) | real (sentinel attribute survival) |
| 60 | SourceControllerCacheTests | 60+ | headless-unit | XCTest | SourceTextController view-preservation cache (TSK-889) | real (teardown calls + LRU recency) |
| 61 | SourceHoverGeometryTests | 60+ | headless-unit | XCTest | Source line-hover pointer→line mapping | real (geometry math verified) |
| 62 | SourceInvisiblesViewTests | 60+ | headless-unit | XCTest | Visible-line slicing for invisibles overlay | real (line window math) |
| 63 | SourceTextControllerLineCountTests | 43 | headless-unit | XCTest | Line count with trailing newlines (TSK-737) | real (empty final line counted) |
| 64 | SourceViewChannelRepublishInvariantTests | 100+ | headless-UI | XCTest | Source scroll/caret NOT fanning to DocumentModel (perf) | real (zero document publishes on scroll) |
| 65 | SourceViewVisualRegressionTests | 80+ | T5-pixel | XCTest | Source view compositing + ruler absence check | real (regionHasVariety + meta-broken-ruler) |
| 66 | SplitAndMoveTabVerbTests | 100+ | headless-UI | XCTest | Toggle-split, close-split, swap-split, move-tab verbs | real (verb routing + state changes) |
| 67 | SplitObservationTests | 100+ | headless-UI | XCTest | Split pane observation propagation (tabCoordinator observed) | real (synchronous coordinator publishes) |
| 68 | SplitPaneCloseActionTests | 60+ | headless-UI | XCTest | Split close button action (xmark closure wiring) | real (splitURL nil after close) |
| 69 | SplitPaneViewSizeGateTests | 39 | headless-unit | XCTest | Sync-read size gate (media never gated, text at watermark) | real (strict > comparison verified) |

---

## Test-Type Taxonomy — Kinds & Rough Proportions

### Tier Distribution
- **Headless-Unit (T1/T1m)** (70% of tests): Pure model/logic tests, no UI views or AppKit. Fast, deterministic.
  - PDFSearcher, PTY/drain/reap/spawn, cached-regex, sidebar cache, selection highlight, snippet navigation, file rename, save-copy, etc.
  - Heavy use of isolated fixtures (temp dirs, git repos, UserDefaults suites).

- **Headless-UI (T1m)** (20% of tests): DocumentModel + controllers, no AppKit windows. Host-safe.
  - Wiring tests (dead-channel idiom), end-to-end journeys, perf invariant checks (republish counts), file operations.
  - Uses HeadlessHarness pattern for tab/file/editor state.

- **WebView In-Process (T2')** (5% of tests, #192-gated): SwiftUI hosting in NSHostingView (no spawned app).
  - Find bar view-tree, script console panel, sidebar toggles, shoulder rail, terminal color scheme.
  - Weak teeth — descendant counts, control presence, NOT pixel-level details.

- **T5 Pixel (Spot checks)** (2% of tests): PixelTestCase, screencapture via WindowServer.
  - PreviewTabVisualRegressionTests, SourceViewVisualRegressionTests (compositor-blank guard, regionHasVariety).

### Framework Split
- **XCTest** (100% adoption): All 69 tests use XCTest. Swift Testing pilot not yet in this slice.

---

## Coverage Shape — Over/Under-Tested Areas

### Well-Tested (High Confidence)
- **Model state machines** (find, split, snippets, reviews, LSP diagnostics, sidebar toggles).
- **File I/O + rename** (roundtrip tests with real temp dirs; bookmark follow-through).
- **PDF handling** (magic-byte sniff, metadata extraction, search cursor).
- **Perf invariants** (republish counts, scroll-caret isolation from DocumentModel).
- **Edge cases** (UTF-8/emoji boundaries, sibling-prefix trap, trailing newlines, empty-queue scenarios).
- **Wiring contracts** (dead-channel idiom: menu items, keyboard shortcuts, script verbs reach model actions).

### Under-Tested / VM-Only Gaps
- **Rendered output pixels** (find-bar highlights, color-scheme colors, icon appearance).
- **Keyboard/mouse interaction** (key routing to editor, drag-select on gutter, mouse hover geometry).
- **AppKit view layout** (frame/bounds geometry, NSTextView glyph layout, CALayer compositing depth).
- **Live WKWebView rendering** (HTML DOM, CM6 editor paint, WebView scroll).
- **AX (Accessibility) interaction** (VoiceOver routing, screen reader labels — off-limits per CLAUDE.md).

### Regression Risks
- **False positives** (SearchAnywhereSectionLayoutTests brittle pin on source code structure; string search for "Divider()").
- **View-count deltas** (ShoulderRailEmptyHidingHostingTests descendant count; can regress if SwiftUI layout changes shape without feature breaking).
- **Negative controls** (SourceViewVisualRegressionTests has a meta-test `test_meta_brokenRulerIsDetectedAsRegression` that proves teeth by enabling a known-broken config; good pattern but requires special env var).

---

## Harness & Infra Patterns Worth Porting

### 1. **HeadlessHarness**
```swift
private var harness: HeadlessHarness!
override func setUp() async throws {
    try await super.setUp()
    harness = HeadlessHarness(label: "MyTest")
}
override func tearDown() async throws {
    harness?.cleanup()
    harness = nil
    try await super.tearDown()
}
```
- **Value**: One-shot DocumentModel + temp dir + isolated UserDefaults + git repo fixture.
- **Use for**: Tab operations, file I/O, script verbs, editor actions.
- **Port**: Model-dependent tests need similar isolation; this pattern is a strong template.

### 2. **Fixture Temp Dirs (UUID suffix)**
```swift
tmpDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("TestName-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
// ... use tmpDir.appendingPathComponent(name)
defer { try? FileManager.default.removeItem(at: tmpDir) }
```
- **Value**: No filesystem collisions; easy cleanup.
- **Use for**: Any test that writes files or modifies on-disk state.

### 3. **Isolated UserDefaults per Test**
```swift
suiteName = "TestName-\(UUID().uuidString)"
defaults = UserDefaults(suiteName: suiteName)
// ... test runs
defaults.removePersistentDomain(forName: suiteName)
```
- **Value**: No pollution of developer's real prefs; deterministic per-test state.
- **Use for**: Any test that reads UserDefaults or PreferencesStore.

### 4. **WebViewTestTeardown (for #192-gated tests)**
```swift
override func setUp() async throws {
    try WebViewTestTeardown.skipUnlessEnabled()  // gate: MDV_RUN_WEBVIEW_TESTS=1
}
override func tearDown() async throws {
    WebViewTestTeardown.teardown(hostedViews)
    hostedViews.removeAll()
}
```
- **Value**: In-process WKWebView hosting without spawning app; automatic skip in headless gate.
- **Use for**: SwiftUI + WebView integration tests (CM6 editor, HTML rendering).
- **Port**: If greenfield uses in-process WebView, this pattern is critical.

### 5. **Negative-Control Switches (Meta-Tests)**
```swift
func test_meta_brokenRulerIsDetectedAsRegression() throws {
    // Enable the known-broken ruler, verify the regression guard catches it.
    let p = Process()
    p.environment = [..., "MDV_ENABLE_BROKEN_RULER": "1"]
    // ... run app, screencapture, regionHasVariety check
    // EXPECT: test goes RED (ruler blank is detected)
}
```
- **Value**: Proves the regression detector (regionHasVariety) has teeth; not just a false-green.
- **Use for**: Any guard that claims to detect a bug; always demonstrate teeth via a deliberate break.
- **Port**: Use a `MDVNegativeControl.isBroken("<NAME>")` helper (mentioned in CLAUDE.md).

### 6. **Dead-Channel Idiom (Wiring Pins)**
```swift
func test_entryPoints_areWired() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let monitor = try src("Sources/ViewerUI/SidebarKeyMonitor.swift")
    XCTAssertTrue(monitor.contains("return .f2"))
    // ... grep test ensures F2 keycode AND sidebar handler + rename prompt wiring
}
```
- **Value**: Catches the exact gap (e.g., "Rename is menu-only, missing from F2 / right-click").
- **Use for**: New verbs, keyboard shortcuts, menu items — grep source to confirm all wiring paths.
- **Port**: Pattern applies universally; use sparingly (brittle on refactors, but catches silent regressions).

### 7. **Perf Baseline / Republish Counts**
```swift
var count = 0
let token = model.objectWillChange.sink { count += 1 }
defer { token.cancel() }
// ... measured operation
XCTAssertLessThanOrEqual(count, expectedMax)  // baseline guard
```
- **Value**: Negative test: assert `DocumentModel.objectWillChange` does NOT fire during sidebar mutation (PERF #1).
- **Use for**: Any observable that should NOT fan out; bounds republish storms.
- **Port**: Use whenever splitting observers by responsibility; verify isolation.

### 8. **String Search (Brittle) vs. Logic Test (Preferred)**
```swift
// BRITTLE (source-dependent):
XCTAssertTrue(source.contains("Divider()"))
// STRONGER (logic-tested):
XCTAssertEqual(SidebarSectionHeaderMetrics.labelFontSize, 10)
```
- **Port rule**: String searches catch *zero* regressions if the code moves to a different line. Use only as a last resort when no logic test is available (e.g., rendering proof-of-presence). Prefer logic tests for all behavior.

---

## Flake / False-Green Risks Observed

### 1. **Stale Dist / Test Instance Leakage**
```swift
AppLauncher.killTestInstances(named: "MarkdownViewer")
// NOT: killall MarkdownViewer  (kills owner's running app!)
```
- **Risk**: Blanket `killall` by exe name hits the production `/Applications` bundle.
- **Mitigation**: Tag test instances with `MDV_TEST_INSTANCE=1` env var; reap by tag.

### 2. **View-Geometry Dependent Tests**
- **Risk**: Descendant count or NSView hierarchy assertions break if SwiftUI changes layout shape.
- **Mitigation**: Pair with a logic-layer test (e.g., state machine); don't rely on geometry alone.

### 3. **ImageRenderer / CacheDisplay False Greens**
```swift
// ❌ WRONG: uses ImageRenderer (renders SwiftUI tree, placeholders representables)
let img = ImageRenderer(content: view).image
XCTAssertNotNil(img)  // SwiftUI-only view renders; AppKit surface is a placeholder

// ✅ RIGHT: uses screencapture (real WindowServer composite)
let windowID = try waitForWindowID()
shell(["/usr/bin/screencapture", "-l\(windowID)", "-x", pngPath])
```
- **Risk**: ImageRenderer + NSView.cacheDisplay both hide occluded SwiftUI siblings (the exact compositor bug).
- **Mitigation**: T5 pixel tests must use `screencapture(1)` for compositor-blank guards.

### 4. **Async Task Completion Flake**
```swift
// Weak: no guarantee async Task has settled
try? await Task.sleep(nanoseconds: 100_000_000)
await Task.yield()

// Stronger: wait for specific side effect
while !model.isRenderedHTMLCached(forTabID: id) {
    try? await Task.sleep(nanoseconds: 50_000_000)
}
```
- **Risk**: Arbitrary sleep can still race on slow machines.
- **Mitigation**: Spin until the expected state is reached (e.g., cache fill, watcher settled).

---

## Rebuild Notes — Day-1 Test Strategy for Greenfield

### Phase 0: Foundation (Critical First)
1. **Tier 1 headless tests** (unit + integration, no window).
   - Model state machines (MVVM core, commands, reducers).
   - Pure logic (string slicing, path math, URL normalization).
   - Wiring contracts (dead-channel grammar: verb → model action).
   - **No heroics**: single responsibility, isolated fixtures.

2. **HeadlessHarness pattern** — one DocumentModel instance + temp dirs.
   - Tab operations, file I/O, multi-document state.
   - Use from day 1; it scales to complex flows.

3. **Perf invariants** (republish counts, cache isolation).
   - Document which observables feed which views.
   - Assert observers do NOT cascade across boundaries.
   - **Catch PERF #1 early**: sidebar mutations re-bodying entire content tree is catastrophic.

### Phase 1: UI Rendering (After Core)
4. **T2' WebView in-process** (NSHostingView-hosted SwiftUI + WKWebView).
   - Editor integration (CM6), rendered markdown, script console.
   - Use WebViewTestTeardown gate (#192); skip in headless merge gate.
   - Teeth: assert controls render (descendant counts), not pixel colors.

5. **String/brittle wiring checks** (sparingly).
   - Catch "feature added but menu entry missing" gaps.
   - Only if no logic test is available (e.g., rendering proof-of-presence).

### Phase 2: End-to-End (High-Level Flows)
6. **Journey tests** (review, code-review, session open/close).
   - Multi-step flows: state → action → state → ...
   - Assert each rung; break anywhere fails the whole journey.
   - Use real git repos (GitTestRepo fixture), not mocks.

7. **Scenario tests** (tab-switching, mode-toggle, search active).
   - Composed interactions that used to be VM-only; now T1m.
   - Small SVG/diagram per scenario so owner can trace expected path.

### Phase 3: Pixel / UAT (Late, VM-Only)
8. **T5 PixelTestCase** — screencapture + regionHasVariety (compositor-blank guard).
   - Only SwiftUI-rendered surfaces with occlusion risk.
   - Always prove teeth: `test_meta_brokenX_isDetected`.
   - Runs on UTM VM only; skip in host headless gate.

9. **AX interaction (off-limits per CLAUDE.md)** — owner-driven or supervised.
   - Agent cannot drive without explicit MCP + VM setup.

### Anti-Patterns to Avoid
- ❌ Mocking the world (use real FileManager, real UserDefaults — they're cheap).
- ❌ Brittle string grepping (prefer logic tests; use grep only as last resort).
- ❌ Async waits without condition checks (spin until state reached, not arbitrary sleep).
- ❌ UI tests on the Mac host (T4/T5/WebView spawn apps; run on UTM VM only).
- ❌ `killall ` by exe name (tag test instances, reap by tag).
- ❌ ImageRenderer for occlusion checks (use screencapture for compositor-blank detection).
- ❌ Over-decomposition of tickets (one test per unit of work, not per step).

---

## Summary for Rebuild

**This slice** (277–345, 69 files) showcases a **mature test pyramid** that leans 70% headless, 20% UI-model wiring, 5% in-process WebView, 2% pixel. The **pattern is scalable**: HeadlessHarness at the core, perf invariants carved out as isolated subscriptions, and visual regression as a last-resort top layer.

**Key learnings for greenfield:**
1. **Invest in isolating observables early** (PERF #1: sidebar shouldn't republish document; source scroll shouldn't either).
2. **Use dead-channel wiring tests to catch silent regressions** (verb → action missing).
3. **Prove regression guards have teeth** (meta-tests with broken config).
4. **Defer pixel/AX tests to VM lane** (not host playgrounds).
5. **Use real dependencies** (git repos, file I/O, UserDefaults) — cheap isolation, high fidelity.

Teeth distribution: **Real** (70%), **Weak** (15% view-count deltas), **Brittle** (5% string searches), **Off-limits** (10% AX).
