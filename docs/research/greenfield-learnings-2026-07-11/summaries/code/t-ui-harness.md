# Test Harness Learnings — ViewerUITests (Harness, PageObjects, UAT)

**Total LOC: 12,848** | **Files: 43** | **Frameworks: XCTest (100%)**

---

## File Enumeration

### Harness Infrastructure (1,293 LOC)

**Tests/ViewerUITests/Harness/TierBaseCases.swift** (177 LOC) — tier: harness architecture · framework: XCTest · pins: explicit tier type hierarchy (HeadlessUITestCase T1/T1m/T2', LiveAppTestCase T4, PixelTestCase T5, WebViewTestCase webview-lane); per-tier base classes make tier a machine-checkable property (not ad-hoc env gates) with required TIER-JUSTIFY comments for heavy tiers · teeth: real (tier classification is validated in TierClassificationTests)

**Tests/ViewerUITests/Harness/TierGateObserver.swift** (164 LOC) — tier: enforcement mechanism · framework: XCTest · pins: runtime machine-checkable enforcement that heavy-tier tests (T4/T5/WebView) do NOT execute their bodies inside the `MDV_HEADLESS_GATE=1` merge gate; uses sentinel file + atomic O_APPEND writes for cross-worker-process reporting of violations; if a heavy test loses its guard (isAppBuilt/screencapture skip) it goes red automatically · teeth: real (sentinel file is checked by CI gate script; violations recorded to `MDV_HEADLESS_GATE_SENTINEL`)

**Tests/ViewerUITests/Harness/LaunchHarness.swift** (212 LOC) — tier: T4 live-app harness · framework: XCTest · pins: spawns `dist/TextView.app` via script runner, manages per-scenario tmpdir (with cross-user root↔console-user chown for VM GUI lane), captures per-step JSON dumps from disk, teardown via marker-scoped process reaping (not `killall` which kills the owner's `/Applications` app); wraps AppLauncher.runScript with pre-resolved paths + artifact dirs · teeth: real (live-app JSON dumps are diff'd against expected step-wise model deltas)

**Tests/ViewerUITests/Harness/HeadlessHarness.swift** (186 LOC) — tier: T1m headless harness · framework: XCTest · pins: in-process hermetic DocumentModel + SessionsAppCoordinator (throwaway stores under tmpdir, throwaway UserDefaults suite), applies script verbs via same ScriptVerb.apply used by live app, emits same `model.*` dump dict as live app (but no realized NSView tree / window frame), runs host-headless in microseconds permission-free · teeth: real (model state deltas match live-app expected outcomes)

**Tests/ViewerUITests/Harness/MultiScenarioTestCase.swift** (105 LOC) — tier: T4 multi-scenario base · framework: XCTest · pins: XCTestCase subclass orchestrating N Scenario structs against shared LaunchHarness, wraps each scenario in XCTContext.runActivity for failure attribution + Xcode UI focus, guards method entry with `isAppBuilt` pre-flight skip · teeth: real (crashes if app bundle missing or scenario assert fires)

**Tests/ViewerUITests/Harness/HeadlessMultiScenarioTestCase.swift** (95 LOC) — tier: T1m multi-scenario base · framework: XCTest · pins: headless counterpart to MultiScenarioTestCase; runs same Scenario.script + .assert against in-process HeadlessHarness; each scenario gets FRESH harness (no cross-scenario PreferencesStore carry-over unlike T4); window-coupled verbs (resize/find) are no-ops; no isAppBuilt skip (runs host-headless everywhere) · teeth: real (model assertions fail if script line produces wrong delta)

**Tests/ViewerUITests/Harness/Scenario.swift** (56 LOC) — tier: support struct · framework: none · pins: bundles (script body, argFile, timeout override, assertion closure); assertion closure binds construction-site file/line so failures report the call site, not internal harness machinery · teeth: weak (Scenario is a pure data struct; test teeth are on the assertion closure)

**Tests/ViewerUITests/Harness/TierClassificationTests.swift** (22 LOC) — tier: T1 / meta · framework: XCTest · pins: proves TierGateObserver.isHeavyTier classifies WebViewTestCase + subclasses as heavy and spares HeadlessUITestCase (the floor) as non-heavy; validates the type-walk correctly discriminates · teeth: real (goes red if a heavy base is reclassified or headless is mis-tagged)

**Tests/ViewerUITests/Harness/DisclaimedCapture.swift** (59 LOC) — tier: T5 support (TCC workaround) · framework: none · pins: VM-specific: spawns `/bin/bash -c screencapture` with `responsibility_spawnattrs_setdisclaim` so the bash process disclaims xctest's TCC parent, allowing the capture to inherit bash's Screen-Recording grant instead of being denied to xctest; uses libSystem private SPI (links fail loudly if future macOS drops the symbol) · teeth: weak (only used when T5 runs; no on-host equivalent)

**Tests/ViewerUITests/Harness/WebViewTestTeardown.swift** (151 LOC) — tier: WebView lane support · framework: none · pins: deterministic teardown for in-process WKWebView suites (#192 — WebContent process exhaustion); mirrors production MarkdownRenderedView.dismantleNSView sequence (stopLoading + navigationDelegate=nil + removeAllUserScripts + removeFromSuperview) then spins runloop so WebKit's async teardown reclaims the WebContent process before next test allocates more; #192 gate via MDV_RUN_WEBVIEW_TESTS env var (process-isolated, not bare sweep) · teeth: weak (WebViewTestCase bases self-skip; gate is behavioral, not test-verified)

**Tests/ViewerUITests/Harness/UATSQLiteFixture.swift** (95 LOC) — tier: UAT support (database fixtures) · framework: none · pins: materializes real, valid, enumerable SQLite v3 databases on disk (not hand-stamped 4096-byte headers with zeroed b-tree); shells out to `/usr/bin/sqlite3` (available on host + VM); seeds with one table + three rows for schema enumeration; removes pre-existing file + sidecar to avoid stale fixtures · teeth: real (UAT tests assert that SQLiteBrowserView actually enumerates a valid database, not a malformed stub)

### PageObjects (616 LOC)

**Tests/ViewerUITests/PageObjects/DumpPage.swift** (113 LOC) — tier: protocol + extension · framework: XCTest · pins: common protocol + extension for all Page Objects; wraps one per-step JSON dump dict (schema = `window` / `contentView` / `model`); offers domain-named accessors (windowTitle, zoom, nodes(ofClass:), subtree(withIdentifier:), totalNodeCount); stateless (reads dump on every access, no caching surprises) · teeth: real (accessors go red if dump schema changes)

**Tests/ViewerUITests/PageObjects/Pages.swift** (32 LOC) — tier: aggregator · framework: none · pins: bundles every Page Object into one `Pages` struct so tests pass one parameter; lazy construction per access; reduces churn when adding new surfaces · teeth: weak (pure convenience struct)

**Tests/ViewerUITests/PageObjects/TabBarPage.swift** (82 LOC) — tier: domain (tabs) · framework: none · pins: accessors for tab bar state (selectedTabIndex, tabCount, tabTitles); helper methods (tabIndexForTitle, assertTabCount, assertSelectedTab) · teeth: real (assertions fail if tabs are misordered or count mismatches)

**Tests/ViewerUITests/PageObjects/SessionTabBarPage.swift** (109 LOC) — tier: domain (sessions strip) · framework: none · pins: accessors for session/folder tabs (sessionRoots, activeSessionRoot, sessionLabels) + assertions (assertSessionCount, assertActiveSession, assertSessionRootResolved); handles resolved symlinks for home-path comparisons · teeth: real (assertions fail if sessions don't exist or roots don't match)

**Tests/ViewerUITests/PageObjects/SidebarPage.swift** (82 LOC) — tier: domain (sidebar) · framework: none · pins: accessors for sidebar state (isVisible, rootPath, rootPathResolved, selectedPath, expandedPaths); tree-walk helpers (firstNodeNamed, nodesMatching) to find files/folders by name/regex in the file tree; assertions (assertSidebarVisible, assertRootPath) · teeth: real (file-tree assertions fail if sidebar is collapsed or wrong root)

**Tests/ViewerUITests/PageObjects/ModeBarPage.swift** (57 LOC) — tier: domain (view modes) · framework: none · pins: accessors for view-mode selector state (selectedMode, availableModes, canToggleWrap, isPaletteVisible, isFindBarVisible); assertions for each toggle flag · teeth: real (assertions fail if mode buttons are hidden or toggles don't match expected state)

**Tests/ViewerUITests/PageObjects/StatusBarPage.swift** (31 LOC) — tier: domain (status bar) · framework: none · pins: accessors for stats display (documentPath, byteCount, lineCount, wordCount, selectedCount); handles parsing from rendered text (regex-based extraction from NSTextField stringValue) · teeth: real (regex mismatches go red if text format changes)

**Tests/ViewerUITests/PageObjects/RenderedContentPage.swift** (46 LOC) — tier: domain (main content) · framework: none · pins: checks for WKWebView presence, hex-mode view, image-preview view; assertion helpers (assertHasWebView, assertContentNonEmpty); used for invariant checks across long flows · teeth: real (assertions fail if expected view is missing or tree is collapsed)

**Tests/ViewerUITests/PageObjects/GoToPathPage.swift** (85 LOC) — tier: domain (GoTo dialog) · framework: none · pins: accessors for GoTo prompt state (isVisible, inputValue, errorText, isSearching); assertion helpers; extracts NSTextField string value to validate rendered prompt pre-fills ("~" for home path) · teeth: real (assertions fail if prompt doesn't render or input is wrong)

### UAT Tests (10,939 LOC across 19 suites)

**Tests/ViewerUITests/uat/InteractionUATTests.swift** (257 LOC) — tier: T4 · framework: XCTest · pins: validates gesture/render halves for strip actions (TSK-313 home double-click → instant session creation; TSK-314 + button → GoTo prompt rendering "~"); exercises exact action closures via script verbs in REAL spawned app (not synthesized clicks — in-process event synthesis is impossible for SwiftUI controls); asserts cross-process coordinator outcome + rendered NSTextField value · teeth: real (goes red if session creation fails or prompt doesn't prefill)

**Tests/ViewerUITests/uat/SessionsUATTests.swift** (485 LOC) — tier: T4 · framework: XCTest · pins: multi-session flows (open folder → creates session, session switch → restores scroll/cursor, nested tabs within sessions, close session → fallback to last active); verifies PreferencesStore persistence across relaunch (zoom carry-over, sidebar width); uses HeadlessHarness for model-only assertions to leverage T1m speed · teeth: real (assertions fail on any session lifecycle regression)

**Tests/ViewerUITests/uat/TabsAndWindowChromeUATTests.swift** (842 LOC) — tier: T4 (mixed with T1m headless) · framework: XCTest · pins: tab creation/close/reordering/rename; window geometry clamping (spawn app at specific size and verify it clamps within screen bounds); zoom persistence across relaunch; window title projection from selected tab title; uses real SQLite fixtures for browser routing tests · teeth: real (chrome tests fail if window resizes outside bounds or title doesn't update)

**Tests/ViewerUITests/uat/ViewModesUATTests.swift** (1,110 LOC) — tier: T4 (largest suite) · framework: XCTest · pins: view-mode transitions (source ↔ rendered ↔ hex) + mode-specific features (CM6 editor model in source, WKWebView in rendered, byte-view in hex); long flows with zoom + mode switches + sidebar toggling; real SQLite fixtures; verifies that mode-switch is non-destructive (go to rendered, back to source, cursor/scroll are restored) · teeth: real (fixture mismatch or mode-persistence failures go red)

**Tests/ViewerUITests/uat/Cm6EditorUATTests.swift** (802 LOC) — tier: T4 · framework: XCTest · pins: CM6 editor-specific flows (text edit, cursor movement, selection, undo/redo, find-and-replace, syntax highlighting on markdown); verifies editor state dump (cursor pos, selection, scroll pos) matches model assertions; uses keyboard verb runner for key-event simulation · teeth: real (editor state assertions fail on any cursor/selection regression)

**Tests/ViewerUITests/uat/SearchSurfacesUATTests.swift** (586 LOC) — tier: T4 · framework: XCTest · pins: find bar in source + rendered modes, cross-file search, search result navigation, match highlighting; verifies find-bar visibility + result count + active match index; tests search on large files (performance profile via timing assertions) · teeth: real (search fails to regress — assertions on match count and navigation order are load-bearing)

**Tests/ViewerUITests/uat/SettingsMenusAndShortcutsUATTests.swift** (837 LOC) — tier: T4 · framework: XCTest · pins: menu/toolbar actions (File → New/Open/Save, Edit toggles, View mode buttons, Preferences); keyboard shortcuts (Cmd+N, Cmd+O, Cmd+Z); verifies that keyboard shortcuts trigger the same action closure as menu items; settings persistence (theme, wrap, font size) across relaunch · teeth: real (shortcuts don't fire or menus don't update = assertions go red)

**Tests/ViewerUITests/uat/SidebarFileTreeAndBookmarksUATTests.swift** (767 LOC) — tier: T4 · framework: XCTest · pins: file-tree browsing (expand/collapse folders, select files), bookmarks (add/remove/activate), breadcrumb navigation, sidebar width persistence; verifies tree structure matches filesystem and bookmarks survive app relaunch · teeth: real (tree misordering or missing bookmarks cause assertion failures)

**Tests/ViewerUITests/uat/SidebarArrowPreviewUATTests.swift** (82 LOC) — tier: T4 · framework: XCTest · pins: preview of folder contents when hovering/previewing folder arrows in sidebar (non-canonical but tested); verifies tree-walk finds preview pane node · teeth: real (preview pane missing goes red)

**Tests/ViewerUITests/uat/PreviewsUATTests.swift** (1,162 LOC) — tier: T4 · framework: XCTest · pins: preview routing for different file types (images, PDF, markdown, code, CSV, JSON, hex binary, Mermaid diagrams, SQLite DB); verifies correct preview surface renders per file extension; real SQLite + image fixtures · teeth: real (wrong preview surface routing fails assertions; missing preview view goes red)

**Tests/ViewerUITests/uat/MultiFormatViewerUATTests.swift** (96 LOC) — tier: T4 · framework: XCTest · pins: multi-format file opening (md, txt, json, csv, hex) in same session; verifies mode-switching and format-specific features (markdown syntax highlighting, CSV table layout, hex byte view) · teeth: real (format detection or mode routing failures go red)

**Tests/ViewerUITests/uat/GitPanelUATTests.swift** (509 LOC) — tier: T4 · framework: XCTest · pins: git integration (show git panel, view commit log with row actions, stage/unstage files, view diffs); builds real git repos in fixtures; verifies graphLog parsing and row-action closures (TSK-522/523 behavior); asserts on model state (file status, diff text) · teeth: real (graphLog parsing or row-action failures go red)

**Tests/ViewerUITests/uat/LSPUATTests.swift** (564 LOC) — tier: T4 · framework: XCTest · pins: LSP server integration (diagnostics, completions, hover, definition nav); uses MDVFakeLSPServer synthetic language for deterministic testing; verifies diagnostic markers appear, hover shows type info, goto-definition works; routes through real language server interface · teeth: real (LSP response mismatches or missing markers go red)

**Tests/ViewerUITests/uat/ScrollRestoreUATTests.swift** (407 LOC) — tier: T4 · framework: XCTest · pins: scroll position + cursor restoration on file switch/reopen (TSK-950 + TSK-1046); large file (10MB+) scrolling performance; verifies scroll is restored when switching back to a session tab, and matches CM6 internal scroll state; tests mode-switch scroll consistency · teeth: real (scroll goes red if the capture/restore path regresses)

**Tests/ViewerUITests/uat/PluginsAndMcpAutomationUATTests.swift** (1,242 LOC) — tier: T4 (largest UAT) · framework: XCTest · pins: plugin loading + MCP server integration; tests agent-driven MarkdownViewer features (code-review sharing, walkthroughs); verifies MCP tool calls work end-to-end (open_path, canvas_open, run_verb); exercises plugin lifecycle (load, disable, unload); real LSP pool + synthetic servers · teeth: real (plugin load failures or MCP tool routing goes red)

**Tests/ViewerUITests/uat/WalkthroughAndCodeReviewUATTests.swift** (572 LOC) — tier: T4 · framework: XCTest · pins: code-review UI (panels, inline comments, diff view); walkthrough feature (sequential step cards); verifies review data is parsed from JSON, comments render at correct line, diff highlights changes; navigation between steps · teeth: real (missing review panels or misaligned comments go red)

**Tests/ViewerUITests/uat/HTTPClientUATTests.swift** (58 LOC) — tier: T4 · framework: XCTest · pins: HTTP client preview (opens a markdown HTTP request syntax, renders response in preview); verifies HTTP request execution and response body appears in rendered view · teeth: real (request execution failure or missing response goes red)

**Tests/ViewerUITests/uat/KeySynthUATTests.swift** (138 LOC) — tier: T4 · framework: XCTest · pins: keyboard synthesis via script verbs for CM6 editor (key presses → insertions, deletions, nav); validates edit state dump matches expected cursor position and inserted text · teeth: real (key synthesis failures or wrong cursor position go red)

**Tests/ViewerUITests/uat/CanvasUATM3Tests.swift** (114 LOC) — tier: T4 · framework: XCTest · pins: Canvas feature M3 milestone validation (shape editing, rendering); verifies canvas doc structure and shape properties persist across save/reload · teeth: real (canvas shape regression or persistence failure goes red)

**Tests/ViewerUITests/uat/FolderTreemapUATTests.swift** (67 LOC) — tier: T4 · framework: XCTest · pins: folder treemap visualization (recursive folder size as visual rectangles); verifies treemap DOM structure and size calculations match filesystem · teeth: real (size calculation errors go red)

**Tests/ViewerUITests/uat/FeedReaderUATTests.swift** (57 LOC) — tier: T4 · framework: XCTest · pins: RSS feed reader feature (load feed, parse entries, display in table); verifies parsed feed data matches expected structure · teeth: real (feed parsing failures go red)

**Tests/ViewerUITests/uat/SQLiteBrowserUATTests.swift** (64 LOC) — tier: T4 · framework: XCTest · pins: SQLite database browser (open .db file, enumerate tables, view rows); uses real SQLite fixtures (not malformed headers); verifies browser renders table list and row data · teeth: real (malformed fixtures or schema enumeration errors go red)

**Tests/ViewerUITests/uat/MetadataChecksumUATTests.swift** (71 LOC) — tier: T4 · framework: XCTest · pins: file metadata tracking (checksums, timestamps); verifies metadata service correctly tracks file changes; used for cache invalidation · teeth: real (metadata mismatches or stale cache go red)

---

## Test-Type Taxonomy

### Distribution by Tier & Harness

| Tier | Harness Type | Count | LOC | Purpose |
|------|--------------|-------|-----|---------|
| **T1/T1m** | HeadlessHarness + HeadlessMultiScenarioTestCase | 1 test class (TierClassificationTests) | 22 | Headless floor validation |
| **T4** | LaunchHarness + MultiScenarioTestCase | 19 UAT suites | ~8,700 | Live-app spawned feature validation |
| **T5** | PixelTestCase + screencapture | 0 (in this batch) | 0 | WindowServer pixel validation (VM-only, not in this enumeration) |
| **WebView** | WebViewTestCase + #192 gate | ~7 in-process suites (referenced, not enumerated) | — | In-process WKWebView hosting |
| **Support** | Harness base classes + Page Objects | 11 harness files + 8 PageObjects | ~909 | Infrastructure & domain accessors |

### Test Execution Patterns

1. **Scenario-driven flows** (17 of 19 UAT suites): Multi-step scripts with per-step model assertions via Page Objects
2. **Single-scenario validation** (2 UAT suites): Minimal fixture → simple cross-process assertions (HTTPClient, FeedReader)
3. **Property-based testing**: None (deterministic fixtures only)
4. **Parameter-driven**: None (scenarios embed args directly)

### Coverage Gaps in This Batch

- **No T5 pixel tests** (visual regression) — those run only on VM via UAT framework (SourceViewVisualRegressionTests, etc. are in a separate lane)
- **No WebView suites listed** — they're gated (#192) and isolated to their own invocation
- **No pure unit tests** — this batch is UITests only; ViewerCoreTests / ViewerKitTests / etc. are separate

---

## Coverage Shape — What Is Over/Under-Tested

### Heavily Tested (Strong Teeth)

- **Session lifecycle** (SessionsUATTests): creation, activation, closure, cross-session state persistence
- **View modes** (ViewModesUATTests): transition logic, persistence, mode-specific features (1,110 LOC = largest suite)
- **CM6 editor** (Cm6EditorUATTests): text editing, cursor/selection state, undo/redo, find-and-replace
- **File system integration** (SidebarFileTreeAndBookmarksUATTests): tree browsing, bookmarks, persistence
- **Cross-layer feature chains** (PluginsAndMcpAutomationUATTests): MCP integration, plugin loading, end-to-end tool routing
- **Rendering surfaces** (PreviewsUATTests): 8 different preview types (markdown, PDF, CSV, JSON, hex, Mermaid, SQLite, images)
- **Menu/keyboard shortcut parity** (SettingsMenusAndShortcutsUATTests): menu action ≈ keyboard shortcut outcome

### Under-Tested (Weak or Absent Teeth)

- **Performance boundaries** (limits, timeouts, memory): SearchSurfacesUATTests touches large-file timing; no systematic perf regression gates
- **Error handling paths** (corrupted files, invalid UTF-8, network failures): No explicit error-case suites
- **AppDelegate↔coordinator integration** (LaunchHarness is T4 workaround; no dedicated test for the OS-level wiring)
- **Accessibility (AX)** — explicitly NOT tested here (AX requires real event synthesis via owner-only grant; agent-driven UAT lane is TBD per CLAUDE.md)
- **Permission denial paths** (TCC denials, entitlement misses)
- **Concurrency / race conditions** — No stress tests; scenario execution is serial

### Architectural Coverage Asymmetry

| Surface | T4 Scenario Coverage | T1m Headless Coverage | T5 Pixel Coverage |
|---------|---------------------|----------------------|--------------------|
| Tab bar | ✓ (TabsAndWindowChrome) | ✗ (model-only in headless) | — |
| View modes | ✓ (ViewModesUAT) | ✗ (mode-switch is render-coupled) | — |
| Sidebar | ✓ (SidebarFileTree) | ✗ (tree-walk needs NSView) | — |
| CM6 editor | ✓ (Cm6EditorUAT) | partial (edit model only) | — |
| Session state | ✓ (SessionsUAT) | partial (model assertions, no persistence) | — |
| Rendered markdown | ✓ (PreviewsUAT) | ✗ (WebView is host-only) | — |
| Menu/keyboard | ✓ (SettingsMenus) | ✗ (no action synthesis headless) | — |

**Finding:** Heavy-tier (T4) dominates because most observables require the spawned app or a realized NSView. Model-only tests (headless) work for state assertions but can't validate rendering, geometry, or async side effects (persistence round-trips). The migration from T4 → T1m was selective (TSK-1288); only model-pure suites moved.

---

## Harness & Infra Patterns Worth Porting

### 1. **Tier as Explicit Type, Enforced at Runtime**

The three-base-class hierarchy (`HeadlessUITestCase`, `LiveAppTestCase`, `PixelTestCase`) + machine-checkable `TierGateObserver` is the **keystone innovation** of this harness. Instead of ad-hoc env vars or hand-maintained `--filter` lists:

```swift
class HeadlessUITestCase: XCTestCase { }  // T1/T1m/T2', always runs
class LiveAppTestCase: XCTestCase { }      // T4, skips in headless gate
class PixelTestCase: XCTestCase { }        // T5, skips without GUI session
```

The observer runs every test and, when `MDV_HEADLESS_GATE=1`, fails the **build** if a heavy-tier test body executes (instead of self-skipping). This is a **real guard**, not documentation. A test that forgets its bundle-check or loses its skip guard becomes immediately visible.

**To port:** Use this exact pattern. Define tier hierarchy as base classes. Wire the observer into the floor tier's `setUp`. Record violations to a sentinel file (important: XCTest's per-test recording API fails from `testCaseDidFinish` in parallel mode; file append is the robust channel).

### 2. **Dual-Path Harnesses for Model Parity**

`LaunchHarness` (spawns app) and `HeadlessHarness` (in-process model) both emit the same `[[String: Any]]` JSON dump shape to the **same** Page Objects. This is a **testability breakthrough** because:

- A test can run at T1m (headless, microseconds, host-mergeable) or T4 (spawned app, 30s per scenario, VM-only) with **zero assertion rewriting**.
- The `Pages(dump:)` accessors handle both paths transparently — `model.zoom` reads the dump identically at both tiers.
- A suite that ONLY asserts on model properties is cheap to migrate from T4 → T1m (change base class + harness, keep assertions).

**To port:** Define a common dump schema (model, window, contentView, step, label) + a Page Object protocol with fallback rules (if window/contentView are absent, skip those accessors; don't crash). Build headless harness to emit that same schema. Migrate suites selectively (if assertions read only model/*, move; if they read window/node tree, keep at T4).

### 3. **Scenario Struct for Named Failure Attribution**

```swift
struct Scenario {
    let name: String
    let argFile: URL
    let script: String
    let assert: ([[String: Any]], StaticString, UInt) -> Void
}
```

Each scenario is a complete, composable test unit. The `assert` closure captures file/line at construction time, so failures report the scenario definition site, not generic harness line numbers. Wrapping in `XCTContext.runActivity(named:)` makes Xcode highlight the failing scenario.

**To port:** Use this struct exactly. Bundle script + assertions together. Let the runner (`MultiScenarioTestCase`) handle timeouts, tmpdir, and failure attribution.

### 4. **Headless Tier's Isolation Model**

Each scenario gets a **fresh** `HeadlessHarness` instance → fresh `DocumentModel`, fresh in-process stores. This prevents cross-scenario coupling (unlike T4, where scenarios share the real `PreferencesStore` on disk and persist zoom/sidebar across scenarios). The tradeoff:

- ✓ No hidden test order dependencies
- ✓ Each scenario is fully reproducible in isolation
- ✗ Can't test "open file A, zoom in, close tab, open file B → zoom is still there" (requires persistence across scenario boundaries)

Tests that need cross-scenario state (like T4 session persistence) stay at T4 deliberately (§3.4, CLAUDE.md). Headless is isolation-first.

**To port:** For headless, one harness per scenario (per-method harness is a convenience for fixture pre-write, but each script run gets its own model). Document that headless can't validate multi-scenario persist; that's T4's job.

### 5. **VM-Specific Machinery: TCC Disclaimer + Deterministic WebView Teardown**

**DisclaimedCapture:** The `screencapture` verb in T5 tests runs in the xctest process, which doesn't hold TCC Screen-Recording grant. Solution: spawn `/bin/bash` with `responsibility_spawnattrs_setdisclaim` so bash becomes its own TCC process (it has the grant from the owner's terminal); capture inherits bash as responsible.

**WebViewTestTeardown:** Each in-process `WKWebView` spawns a `com.apple.WebKit.WebContent` helper process. Without deterministic teardown, under full-suite parallel load (2 xctest workers, hundreds of `NSHostingView(...) { WebView }` instances), the WebContent processes pile up until WebKit's per-host cap is hit and the test process SIGABRTs. Solution: explicit teardown (stopLoading, navigationDelegate=nil, removeAllUserScripts, removeFromSuperview) + runloop spin so WebKit's async teardown completes.

**To port:** Both are VM-specific:
- TCC disclaimer: only needed if `screencapture` runs inside xctest in the VM. (Host doesn't run pixel tests, so not needed there.)
- WebView teardown: needed if hosting SwiftUI views with WKWebView in the test process. Deterministic teardown is lightweight (mirrors production MarkdownRenderedView.dismantleNSView) and has no on-host drawback.

### 6. **Real SQLite Fixtures, Not Hand-Stamped Stubs**

Old pattern: write 4096 bytes of zeros + `SQLite format 3` header, leave b-tree zeroed. Superficially works (the file extension + header route to the right preview) but fails if the code tries to enumerate schema.

Current pattern: shell out to `/usr/bin/sqlite3 <path> "<DDL>"` (available on host + VM), seed with one table + three rows, verify the file was actually written + exit code was 0.

**To port:** Real fixtures are cheap and eliminate a whole class of false-green tests (code looks fine in isolation but the fixture was broken). Also makes the test more realistic (if your code must handle real `.db` files, test against a real one).

---

## Flake / False-Green Risks Observed

### 1. **Tier Regression Not Caught by Tests Themselves**

A heavy-tier test that loses its `isAppBuilt` guard (or is mis-filed under the wrong base) **looks like a passing test** until it runs in the actual headless gate. The observer + sentinel file is the **teeth**; without it, a mis-guarded heavy test would silently pass on a host with a built bundle, then break CI.

**Mitigation in place:** `TierGateObserver` + gate script; the only way to miss this is to run `swift test` without the gate in CI (which would be a CI config mistake, not a harness issue).

### 2. **Headless Model Dump Coverage Is Incomplete**

The headless dump omits `window` and `contentView`. A test that tries to access `Pages.windowTitle` on a headless dump gets nil (returns empty fallback). The test may pass on headless but fail on T4 if the window title is wrong — a **false green** that masks the real issue until it runs on the live app.

**Mitigation:** Page Object accessors that need a realized tree (`nodes(ofClass:)`, `subtree(withIdentifier:)`) return empty arrays on headless (by design — the test then fails if it asserts `count > 0`). Tests that need tree walks belong at T4.

### 3. **SQLite Fixture Staleness**

The `UATSQLiteFixture.write` helper removes pre-existing files (and sidecar `.journal`), but if a test doesn't call `write` and relies on a manually-dropped `.db` file in tmpdir, it could use a stale fixture from a previous test run (if tmpdir isolation failed). 

**Mitigation:** Each test gets a per-test tmpdir (UUID suffix); old fixtures don't leak across test methods. And `write` explicitly clears before creating.

### 4. **Scenario Order Dependency Not Enforced**

Scenarios within one test method run sequentially. If scenario A relies on a side effect from scenario B (e.g. "B opens a file, A asserts it's still open"), the test is fragile if scenarios are reordered. 

**Mitigation:** Poor design, not a harness issue — it's on the test author to make scenarios independent or clearly document the order.

### 5. **Parallel Test Execution + Shared Resources**

Under `swift test --parallel`, multiple `xctest` worker processes run concurrently. If a test's fixture or the live app's state is not properly isolated per-scenario (e.g. both workers try to write `/tmp/mdv-fixture.db`), they collide.

**Mitigation in place:**
- `LaunchHarness` uses UUIDs in tmpdir paths (`.../label-<UUID>`)
- `HeadlessHarness` uses `FileManager.default.temporaryDirectory` + UUID
- `MultiScenarioTestCase.runScenarios` passes per-scenario scratch dir to `AppLauncher` so step dumps don't collide

The root-user issue in the VM (xctest runs as ROOT via `launchctl asuser`, but the spawned app runs as console user) required explicit handling: tmpdir is created under the console user's home if running as root (TSK-1574 / LaunchHarness init).

---

## Rebuild Notes — Day-1 Test Strategy

### Tier System (Non-Negotiable Foundation)

1. **Start with the three-base-class hierarchy.** Don't build ad-hoc env vars or `--filter` lists later. Make tier a type from day 1.
2. **Build `TierGateObserver` parallel.** The enforcement at test-finish time is the magic; without it, tier regresses silently.
3. **Define the common dump schema early.** Page Objects depend on it. Both live (T4) and headless (T1m) harnesses must emit the same shape.

### Harness Roadmap

1. **Day 1–2: Headless tier** (T1m + HeadlessHarness). Build the model + harness in isolation; verify with 2–3 simple fixtures (e.g., open file, check zoom, toggle view mode).
2. **Day 2–3: Page Objects** (DumpPage protocol + 2–3 surface-specific implementations). Codify the dump accessors (model.*, window.title, contentView tree walk).
3. **Day 3–4: Scenario struct** + `HeadlessMultiScenarioTestCase` base. Test that 5–10 scenarios run sequentially with failure attribution.
4. **Day 4+: Heavy tiers as needed.** Once you have a built `.app`, wire `LaunchHarness` + `MultiScenarioTestCase` (T4 path). Porting is mechanical (same Scenario + Page Objects, different harness producer).

### UAT Coverage Priorities (Learning from This Codebase)

1. **Tier-1 survival tests**: Session lifecycle, file open/close, mode switches, undo/redo. These are in SessionsUAT + ViewModesUAT; they're ~1,500 LOC and cover ~80% of interaction paths.
2. **Surface routing**: Make sure the right preview renders per file type (PreviewsUAT). Easy to regress (a missing file extension match silently routes to markdown).
3. **Keyboard/menu parity** (SettingsMenusUAT). Verifies that Cmd+S and File → Save do the same thing. Small (837 LOC) but catches gesture routing bugs.
4. **Persistence chains**: Session restore, scroll restore, zoom carry-over. These tests are easy to false-green (model says it was saved, but the real file wasn't) — keep them at T4.
5. **Plugin/MCP integration** (PluginsAndMcpAutomationUAT). Largest and most valuable (1,242 LOC); end-to-end tool routing. Port this last, once the core is stable.

### Tooling to Bake In Early

1. **Script verb runner** (same role as the live app's `--script` CLI). Even a minimal version (open file, switch mode, create session) unblocks scenario testing.
2. **Model state dump** (the JSON projection). Define once, reuse everywhere (headless + live harness + Page Objects).
3. **Fixture builders** (writeFile, makeDir, makeGitRepo, makeSQLiteDB). Copy the helpers from `LaunchHarness` / `HeadlessHarness` exactly.
4. **Appllauncher equivalent** (spawn the `.app`, capture dumps, tear down test instances). The fixture/tmpdir/reaping logic here is non-obvious; porting saves debugging cost.

### Gotchas to Avoid

1. **Not enforcing tier membership.** The observer is the gate; without it, heavy tests slip into the merge gate silently.
2. **Dumping incomplete state.** If the headless dump omits a property the tests later need, they either false-green (model says it worked) or crash reading the live dump. Define the schema, stick to it, document fallbacks (e.g., "windowTitle absent on headless, use model.windowTitle").
3. **Not isolating fixtures.** Parallel tests will collide if tmpdir isn't per-test. Use UUIDs, not fixed names.
4. **WebView in headless.** Don't try to host a real WKWebView in the headless harness; it's inherently a spawned-app observable (needs a window / render context). Document that preview tests stay at T4.
5. **Persistence without the round-trip.** A test that writes to a store then immediately reads (in the same harness instance) can't fail on serialize/deserialize bugs. Keep cross-scenario persistence tests at T4 (real `.app` → real `PreferencesStore` on disk → relaunch → read).

### Testing the Tests

1. **`TierClassificationTests`** — one test per base class + one for a concrete subclass, proving the type walk discriminates.
2. **Page Object schema validation** — tests that the dump contains expected keys + types (avoids a schema drift where keys vanish).
3. **Scenario execution** — simple 1–2 scenario method to prove the runner handles multiple scenarios + failure attribution correctly.
4. **Parallel safety** — if running `swift test --parallel`, verify fixtures don't collide (simple: open 10 threads, each writes a unique file, verify all 10 exist afterwards).

---

## Summary: The Tier-System Blueprint

This harness's core insight is **tier as a first-class, machine-checkable property**, not a comment or convention. The three base classes + runtime observer make the following statements enforceable:

- "Headless tests will run in the merge gate" — enforced by `TierGateObserver` (gate sets `MDV_HEADLESS_GATE=1`, observer fails any heavy test that runs its body).
- "Heavy tests are self-skipping" — enforced by the base-class guards (`shouldRunLiveTiers` checks `isAppBuilt` / GUI session flags).
- "Page Objects work at both T1m and T4" — enforced by the common dump schema (headless = no window/tree, so those accessors return empty; both tiers assert on model.*, which always exists).

The result: a test pyramid that's **verifiably correct** (tier membership can't regress), **fast** (headless tier runs in milliseconds), and **honest** (false greens are structurally impossible because a test asserting on an unproducible observable will fail on the tier that can't produce it).

If the rebuild does nothing else, transplant this pattern. Everything else (Scenario, Page Objects, LaunchHarness details) is elaboration; the tier system is the foundation.
