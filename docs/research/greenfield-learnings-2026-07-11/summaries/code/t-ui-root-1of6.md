# TextView/MarkdownViewer — Test Inventory: ViewerUITests Root (Slice 1/6, files 1-69)

**Cohort:** XCTest + SwiftTesting hybrid; 69 files, ~10.5 KLOC in this slice.

---

## File Inventory

### Headless-Unit Tests (XCTestCase) — Pure logic/model, host-safe

**ActionHistoryRowModelTests.swift** (64 LOC) — tier: headless-unit · framework: XCTest · pins: label passthrough, category→glyph mapping, coalesced badge label, timestamp formatting · teeth: real (mapping exhaustiveness, format regression).

**AppLauncherPipeSafetyTests.swift** (35 LOC) — tier: headless-unit · framework: XCTest · pins: Pipe.readToEnd() surfaces errors on dead FD (vs ObjC uncatchable exception) · teeth: real (swap to `readDataToEndOfFile()` crashes the test).

**AppMenuActionsTests.swift** (48 LOC) — tier: headless-unit · framework: XCTest · pins: app-menu action dispatch wiring (File, Edit, View, Tools menus) · teeth: real (action not wired = nil).

**AudioConvertViewModelTests.swift** (41 LOC) — tier: headless-unit · framework: XCTest · pins: audio format conversion ViewModel state machine · teeth: real (model mutations).

**AudioEditorViewModelLoadGuardTests.swift** (17 LOC) — tier: headless-unit · framework: XCTest · pins: load-guard prevents re-mounting already-loaded editor · teeth: real (race condition regression).

**AudioEditorViewModelSpectrumTests.swift** (56 LOC) — tier: headless-unit · framework: XCTest · pins: spectrum peak reduction algorithm correctness · teeth: real (peak math).

**AudioEditorViewModelTrimFadeTests.swift** (82 LOC) — tier: headless-unit · framework: XCTest · pins: trim/fade envelope DSL and sample application · teeth: real (boundary conditions, offset/duration math).

**AudioPlaybackControllerTests.swift** (33 LOC) — tier: headless-unit · framework: XCTest · pins: playback state machine (play/pause/stop), time updates · teeth: real (state transitions).

**BinaryFileAffordanceTests.swift** (127 LOC) — tier: headless-unit · framework: XCTest · pins: binary file detection heuristics, mime type fallback, hex-mode availability · teeth: real (detection edge cases).

**BookmarkIntegrationTests.swift** (117 LOC) — tier: headless-unit · framework: XCTest · pins: bookmark create/delete/restore via DocumentModel wiring · teeth: real (store round-trip, undo/redo state).

**BookmarkLineCacheTests.swift** (105 LOC) — tier: headless-unit · framework: XCTest · pins: line-number caching for bookmarks under file edits · teeth: real (line-number invalidation, stale cache).

**BookmarkOpenTocTouTests.swift** (123 LOC) — tier: headless-unit · framework: XCTest · pins: bookmark + TOC entry open routing, touch-up via URI · teeth: real (path routing, line number match).

**BookmarksSectionEmptyTests.swift** (75 LOC) — tier: headless-unit · framework: XCTest · pins: bookmarks sidebar section hides when empty, shows when populated · teeth: real (visibility toggle on add/remove).

**ByteFormatTests.swift** (54 LOC) — tier: headless-unit · framework: XCTest · pins: byte-size formatting (B/KB/MB/GB) with precision · teeth: real (boundary thresholds, decimal places).

**CanvasTabControllerTests.swift** (288 LOC) — tier: headless-unit · framework: XCTest · pins: Canvas tab state (open/close/focus), undo wiring, dirty tracking · teeth: real (state machine, dirty flag).

**CanvasVerbTests.swift** (60 LOC) — tier: headless-unit · framework: XCTest · pins: Canvas verb routing (create/edit/delete/select), intent dispatch · teeth: real (verb handler binding).

**ClaudeMonitorEmptyMessageTests.swift** (39 LOC) — tier: headless-unit · framework: XCTest · pins: Claude Monitor empty-message sentinel rendering · teeth: real (sentinel marker visibility).

**ClaudeMonitorModelTests.swift** (329 LOC) — tier: headless-unit · framework: XCTest · pins: Claude Monitor message stream parsing (protocol, user/assistant roles, code blocks, error handling) · teeth: real (SSE parsing, line-continuation, error recovery).

**ClaudeTimelineRedactionTests.swift** (81 LOC) — tier: headless-unit · framework: XCTest · pins: Claude Monitor timeline redaction (removing Anthropic-sensitive metadata) · teeth: real (redaction rules).

**ClickTargetRegistryTests.swift** (146 LOC) — tier: headless-unit · framework: XCTest · pins: click target deduplication + z-order ranking in overlapping geometries · teeth: real (priority collision resolution).

**CloseTabMaterializeTests.swift** (108 LOC) — tier: headless-unit · framework: XCTest · pins: closing a tab materializes its state before removal · teeth: real (state persistence on close).

**CMIndentationTests.swift** (48 LOC) — tier: headless-unit · framework: XCTest · pins: CodeMirror indentation-detection (spaces vs tabs, level inference) · teeth: real (indent inference edge cases).

**CodeMirrorBridgeExtendedTests.swift** (167 LOC) — tier: headless-unit · framework: XCTest · pins: CodeMirror bridge query API (selection, scroll, position) · teeth: real (JS-query round-trip consistency).

**CodeMirrorBundleTests.swift** (651 LOC) — tier: headless-unit · framework: XCTest · pins: CodeMirror bundle JavaScript extraction, asset integrity · teeth: real (bundle structure, asset checksums).

**CodeMirrorEditorRegistryTests.swift** (39 LOC) — tier: headless-unit · framework: XCTest · pins: CodeMirror editor instance registration + recovery · teeth: real (registry state).

**CommandPaletteRegistryTests.swift** (261 LOC) — tier: headless-unit · framework: XCTest · pins: command palette registration (action binding, fuzzy-search index, group hierarchy) · teeth: real (command wiring, search results).

**ConflictResolutionModelTests.swift** (68 LOC) — tier: headless-unit · framework: XCTest · pins: 3-way merge conflict model (ours/theirs/base selection) · teeth: real (merge choice tracking).

**ContentToolbarMappingTests.swift** (376 LOC) — tier: headless-unit · framework: XCTest · pins: content-type→toolbar-action mapping (file type determines available tools) · teeth: real (toolbar availability matrix).

**ContentToolbarPaletteButtonTests.swift** (22 LOC) — tier: headless-unit · framework: XCTest · pins: palette button state (enabled/disabled) · teeth: real (state visibility).

**ContentViewMetadataGateTests.swift** (23 LOC) — tier: headless-unit · framework: XCTest · pins: ContentView metadata access gate (guards against missing model) · teeth: real (guard enforcement).

**ConvertEncodingPaletteCommandTests.swift** (50 LOC) — tier: headless-unit · framework: XCTest · pins: encoding-conversion command execution · teeth: real (encoding round-trip).

**ConvertImageViewModelTests.swift** (71 LOC) — tier: headless-unit · framework: XCTest · pins: image format conversion ViewModel state machine · teeth: real (format detection, conversion logic).

**CrossFileReplaceModelTests.swift** (228 LOC) — tier: headless-unit · framework: XCTest · pins: cross-file find/replace model (regex parsing, scope, replace rules) · teeth: real (regex validation, replacement text).

---

### Headless-UI Tests (HeadlessUITestCase) — SwiftUI/AppKit model wiring, host-safe, in-process view tree

**AnnotationsWiringTests.swift** (54 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: Annotations scanner wiring into DocumentModel, opens hosted tab with markers · teeth: real (tab count, marker discovery).

**ArchiveRoutingTests.swift** (74 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: archive file detection (zip/tar/tgz/tar.bz2 multi-part extension), view-mode routing, preview-mode default, controller state · teeth: real (category classification, mode matrix, wiring verification via source-code inspection).

**Audit_Sources_ViewerUI_Automation_DocumentModel_AutomationHost_swift_Tests.swift** (234 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: document automation (macOS Automation.plist scripting host, AppleScript record/replay) · teeth: real (automation roundtrip).

**Audit_Sources_ViewerUI_Terminal_PTYProcess_swift_LifecycleTests.swift** (200 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: PTY process lifecycle (spawn, signal, termination), shell environment wiring · teeth: real (exit code, signal delivery).

**CheckLinksCommandIntegrationTests.swift** (50 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: Check Links command integration (runs link validator, collects results) · teeth: real (result count, URL parsing).

**ChromeBodyEvalCountTests.swift** (324 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: SwiftUI chrome re-evaluation counts per interaction (via BodyProbe debug instrumentation) · teeth: real (regression = named view re-body count increase; pinned to zero for many views via explicit bounds).

**ChromeLayoutGateTests.swift** (241 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: chrome layout bounds (content area, sidebar, statusbar sizing and visibility) under various model states · teeth: real (geometry regressions).

**ChromeThemeTests.swift** (118 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: theme application to chrome (light/dark colors, accent color) · teeth: real (color assignment, appearance detection).

**ChromeZoomScalingTests.swift** (185 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: zoom scaling of chrome elements (font size, gutter width, tab bar spacing) · teeth: real (scaling factors).

**CommentCardStructureTests.swift** (148 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: code-review comment card layout (author, timestamp, reactions, reply threading) · teeth: real (card hierarchy, presence of fields).

**ComponentModelStateTests.swift** (133 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: component (hosted view) state machine integration with DocumentModel · teeth: real (state transitions).

---

### WebView In-Process Tests (WebViewTestCase) — Real WKWebView runtime, JS evaluation, #192-gated

**AudioConvertHostingTests.swift** (53 LOC) — tier: webview-inprocess · framework: XCTest · pins: audio conversion WebView hosting (form rendering, input binding) · teeth: real (form submission, input values).

**AudioPlayerHostIntegrationTests.swift** (63 LOC) — tier: webview-inprocess · framework: XCTest · pins: audio player WebView runtime integration (play controls, time sync) · teeth: real (control responsiveness, time display).

**BlameGutterWebViewTests.swift** (134 LOC) — tier: webview-inprocess · framework: XCTest · pins: git blame gutter WebView rendering (commit info, line highlighting, click routing) · teeth: real (gutter geometry, click hit-testing).

**BlockPatchAlignmentProbeTests.swift** (129 LOC) — tier: webview-inprocess · framework: XCTest · pins: code-review block patch alignment on canvas (line ranges, indentation) · teeth: real (alignment geometry).

**BlockPatchApplyWebViewTests.swift** (168 LOC) — tier: webview-inprocess · framework: XCTest · pins: patch apply workflow (fetch from server, apply to editor, undo/redo) · teeth: real (patch parsing, application correctness).

**CanvasDragReorderWebViewTests.swift** (171 LOC) — tier: webview-inprocess · framework: XCTest · pins: Canvas drag-reorder (mouse events, element repositioning, bounds update) · teeth: real (reorder state, geometry).

**CanvasInlineEditWebViewTests.swift** (159 LOC) — tier: webview-inprocess · framework: XCTest · pins: Canvas inline editing (text edit, commit, cancel) · teeth: real (edit state transitions).

**CanvasPatchLoopWebViewTests.swift** (301 LOC) — tier: webview-inprocess · framework: XCTest · pins: Canvas patch-loop (incremental updates, DSL parsing, render cycle) · teeth: real (content consistency, patch semantics).

**CanvasSelectionWebViewTests.swift** (443 LOC) — tier: webview-inprocess · framework: XCTest · pins: Canvas selection UI (click hit-testing, overlay positioning, geometry queries, reflow tracking) · teeth: real (selection state, overlay synchronization).

**CanvasTabMountWebViewTests.swift** (82 LOC) — tier: webview-inprocess · framework: XCTest · pins: Canvas tab mount/unmount cycle, lifecycle, readiness sync · teeth: real (mount state, ready signal).

**CM6PlainClickAfterScrollWebViewTests.swift** (132 LOC) — tier: webview-inprocess · framework: XCTest · pins: CodeMirror click-after-scroll behavior (scroll does not consume click) · teeth: real (click registration after scroll).

**ComponentVisualTests.swift** (314 LOC) — tier: webview-inprocess · framework: XCTest · pins: hosted component visual rendering (buttons, inputs, layouts in WebView) · teeth: real (component geometry, visibility).

**ContentViewHostingTests.swift** (214 LOC) — tier: webview-inprocess · framework: XCTest · pins: content view hosting lifecycle (mount, data flow, unmount) · teeth: real (lifecycle state).

**ConvertImageHostingTests.swift** (51 LOC) — tier: webview-inprocess · framework: XCTest · pins: image conversion WebView hosting · teeth: real (form state).

---

### T5 Pixel Tests (PixelTestCase) — VM-only, real app spawn, WindowServer pixel capture

**AudioEditorVisualRegressionTests.swift** (142 LOC) — tier: T5-pixel · framework: XCTest · pins: audio waveform visualization renders (SwiftUI Canvas with variety of colors/peaks) · teeth: real (pixel variety in central band; blank = no render).

**CanvasOverlayVisualRegressionTests.swift** (168 LOC) — tier: T5-pixel · framework: XCTest · pins: Canvas overlay compositing (selection box, resize handles visible on screen) · teeth: real (overlay pixels distinct from background).

**ClaudeMonitorVisualRegressionTests.swift** (151 LOC) — tier: T5-pixel · framework: XCTest · pins: Claude Monitor message list renders (avatar, timestamp, message text color contrast) · teeth: real (pixel variety, text visibility).

---

### Support Fixtures & Base Classes

**AppLauncher.swift** (403 LOC) — tier: support · framework: foundation (no test code) · pins: shared app-spawning harness for L4/L5 tests (LaunchServices-based spawn, AppKit foregrounding, root→console-user uid transition, temp dir setup) · teeth: N/A (infrastructure).

**AXUIElementNodeTests.swift** (56 LOC) — tier: support · framework: XCTest (but no `XCTestCase` subclass — test fixtures or utility) · pins: Accessibility element tree utilities · teeth: N/A (support code).

---

### Remaining Headless-Unit Files (audit/generated names with focused topics)

**Audit_Sources_ViewerUI_ClaudeMonitor_ClaudeMonitorView_swift_StreamingLoadTests.swift** (166 LOC) — tier: headless-unit · framework: XCTest · pins: Claude Monitor streaming load state machine (loading spinner, load completion, error states) · teeth: real (state transitions).

**Audit_Sources_ViewerUI_CodeMirrorEditorView_swift_LinkPolicyTests.swift** (204 LOC) — tier: headless-unit · framework: XCTest · pins: CodeMirror link-policy security (URI validation, mailto/http/https filtering) · teeth: real (policy enforcement).

**Audit_Sources_ViewerUI_SidebarModel_swift_ClearCacheFlatMemoTests.swift** (120 LOC) — tier: headless-unit · framework: XCTest · pins: sidebar model cache invalidation (flat-memo memoization re-evaluation under model mutations) · teeth: real (cache coherency).

**BookmarksRecentsPruneTests.swift** (99 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: bookmarks/recent-files pruning policy (retains N items, deletes stale) · teeth: real (prune count, age threshold).

**BookmarkUndoWiringTests.swift** (112 LOC) — tier: headless-UI(T1) · framework: XCTest · pins: bookmark create/delete undo/redo state (undo stack wiring via DocumentModel) · teeth: real (undo count, state restoration).

**CommitReviewLaunchTests.swift** (189 LOC) — tier: headless-unit · framework: XCTest · pins: commit-review launch routing (file→review, metadata routing, error handling) · teeth: real (routing state).

---

## Test-Type Taxonomy

**Headless-Unit (pure-logic/model):** ~45 files (~4.5 KLOC) — pure Swift logic, no view tree, no AppKit, host green gate.
- Category models (ActionHistoryRowModel, AudioConvert*, ByteFormat, etc.)
- Algorithm tests (peak reduction, trim/fade, indentation detection)
- Command & registry tests (CommandPaletteRegistry, CodeMirrorEditorRegistry, ClickTargetRegistry)
- Data-structure tests (SearchIndex, CrossFileReplaceModel, ConflictResolutionModel)
- Parser/stream tests (ClaudeMonitorModel SSE parsing, CodeMirror bridge queries)
- Wiring audits (Audit_Sources_* — generated by the audit harness to pin specific source-file behaviors)

**Headless-UI (SwiftUI/model integration, no WebView):** ~16 files (~2.0 KLOC) — in-process SwiftUI view trees, file I/O, user defaults, host-safe.
- Chrome perf profiling (ChromeBodyEvalCountTests, ChromeLayoutGateTests, ChromeThemeTests, ChromeZoomScalingTests)
- Document wiring (Annotations, Archive routing, Automation, PTY lifecycle, CheckLinks)
- Bookmarks (OpenToc, LineCache, UndoWiring, RecentsPrune)
- State machines (ComponentModelState, CommentCardStructure)

**WebView In-Process (#192-gated):** ~13 files (~2.0 KLOC) — real WKWebView runtime, JS evaluation, form/DOM interaction.
- Audio (convert, player, import)
- Code Review (blame gutter, block patch, conflict resolution)
- Canvas (drag/reorder, inline edit, patch loop, selection, mount, overlay)
- CM6 (indentation, link-click, scroll behavior)
- Component hosting (visual tests, lifecycle)

**T5 Pixel (VM-only, real app):** 3 files (~461 LOC) — spawns `/Applications/TextView.app`, captures WindowServer pixels.
- Audio waveform visualization
- Canvas overlay compositing
- Claude Monitor message list

**Support:** 2 files (~459 LOC) — AppLauncher (spawn harness), AXUIElementNodeTests (accessibility utilities).

---

## Coverage Shape

### Over-tested (depth-first, many tests per feature)

- **Canvas WebView runtime:** 8 dedicated tests (drag, inline edit, patch loop, selection, mount, click-after-scroll, visual, overlay) — the most battle-tested surface, justified by complexity.
- **Chrome perf:** 4 dedicated eval-count tests pinning re-render behavior per interaction type.
- **CodeMirror:** 6 dedicated tests (bundle integrity, registry, bridge API, indentation, link-policy, post-scroll behavior).
- **Bookmarks:** 5 dedicated tests (create/delete, line-cache, open/TOC, pruning, undo wiring).
- **Audio:** 9 dedicated tests across waveform modeling, editing, playback, conversion, visualization.

### Under-tested (breadth-first, single test or none)

- **Session persistence & restoration:** only `CloseTabMaterializeTests` (single test); missing tests for workspace save/load, tab history, fold state, scroll restoration.
- **Terminal/shell integration:** only `PTYProcess_LifecycleTests` (Automation host); missing tests for input/output piping, exit codes, signal handling edge cases.
- **Plugin system:** no dedicated tests visible in this slice (may exist in ViewerCoreTests).
- **Theme application:** `ChromeThemeTests` only; missing tests for accent-color changes, system-appearance detection, per-surface theme overrides.
- **Find/replace (cross-file):** `CrossFileReplaceModelTests` (model only); missing WebView-layer behavior tests.
- **Git integration:** no dedicated tests visible (likely in separate domain).

### Blind spots (no tests observed)

- **Undo/redo state machine edge cases** (partial coverage via `BookmarkUndoWiringTests` + model audit).
- **Multi-window support** (if exists).
- **Nested tab drag/drop** (if Canvas extends to native tabs).
- **Scroll position + layout restoration under theme/zoom changes.**
- **Error recovery & crash resilience** (e.g., WebView hang, process death, corrupted state files).

---

## Harness & Infra Patterns Worth Porting

### 1. **BodyProbe Debug Instrumentation** (ChromeBodyEvalCountTests)
   - Swift-side: lightweight `@Published` property mutator that counts body re-evals per view.
   - Test pattern: enable probe, interact, pump runloop, read per-view counts, assert zero for unaffected views.
   - **Value:** catches SwiftUI rendering regressions without wall-clock noise; named per-view so failures are actionable.
   - **Porting:** add a similar hooks-based introspection layer; consider generalizing to other imperative state (render passes, layout cycles).

### 2. **WebViewTestCase + JS Probe Harness** (Canvas*/Component tests)
   - Base class: in-process WKWebView, message-passing API, geometry query helpers.
   - Pattern: send DSL/commands, poll for async reply via message handler, geometry queries hit the SAME API the app uses.
   - **Value:** low-level enough to test JS behavior (click dispatch, DOM layout, animation) without UI automation; high-level enough to avoid brittle DOM crawling.
   - **Porting:** port the WebView hosting pattern; consider a unidirectional message protocol (app→test) vs bidirectional for simplicity.

### 3. **Geometry Helpers** (CanvasSelectionWebViewTests, BlockPatchAlignmentProbeTests)
   - Pattern: query element bounds through the same code path the app uses (e.g., `CVBox` struct, `queryGeometry` message).
   - **Value:** proves the geometry query is consistent app-side and test-side; fails if the query breaks.
   - **Porting:** reuse the same geometry-query protocol; avoid separate test-only geometry calculations.

### 4. **File/Temp Cleanup Fixtures** (Multiple tests)
   - Pattern: `setUp()` creates isolated temp dir per test, `tearDown()` cleans up. Suites use `UUID()` to prevent collisions.
   - **Value:** parallel test-safe, no global state pollution, fast.
   - **Porting:** adopt per-test temp dirs as the default; avoid `/tmp` for deliverables.

### 5. **Audit-Driven Test Generation** (Audit_Sources_* files)
   - Pattern: toolchain audits source code for uncovered behaviors (e.g., link policy in CodeMirrorEditorView.swift), generates test stubs.
   - **Value:** systematic coverage; ensures behavioral tests exist for every audit finding.
   - **Porting:** build an audit harness that walks the codebase and reports untested surfaces; generate test stubs from that.

### 6. **T5 Pixel Helpers** (SourceViewVisualRegressionTests pattern reused)
   - Pattern: spawn app with env vars, capture pixels via `screencapture`, analyze region for color variety.
   - **Value:** real app, real pixels; proves visual behavior on-screen (not just model-layer green).
   - **Porting:** port the pixel-capture / region-analysis utilities; consider ffmpeg-based capture for cross-platform builds.

### 7. **Runloop Pumping** (ChromeBodyEvalCountTests.pump())
   - Pattern: `RunLoop.current.run(until: deadline)` × N to let scheduled SwiftUI renders complete.
   - **Value:** decouples test execution from SwiftUI's coalesced re-evaluation; necessary for measuring side effects.
   - **Porting:** export a shared `pumpMainQueue()` helper; document the pattern so new tests use it consistently.

### 8. **AppLauncher Root→ConsoleUser Bridge** (AppLauncher.swift)
   - Pattern: when xctest runs as root (VM GUI lane), spawn the app as the console user so it becomes a key window.
   - **Value:** avoids gesture-swallowing (non-key window blocks clicks); enables real UI automation under sudo.
   - **Porting:** abstract the uid-switching logic; consider a shared launcher module for all VM tests.

---

## Flake / False-Green Risks Observed

### 1. **ChromeBodyEvalCountTests Quiescence Trap (TSK-1328)**
   - **Risk:** under 18-worker parallel gate, a stray async mutation lands just after a single empty pump, leaking into the measured window.
   - **Fix:** quiescence now requires TWO consecutive empty pumps (iteration bound doubled to 24).
   - **Lesson:** a "no activity detected" check alone is insufficient under load; require stability over TWO cycles.

### 2. **VM GUI-Lane XCTest-as-Root Symlink Poisoning**
   - **Risk:** spawned app reads stale `.build/` from a prior root-run (uid 0 artifacts, unreadable by console user).
   - **Mitigation:** AppLauncher cleans temp dirs; AppLauncher.chownRecursive() hands ownership to spawn user.
   - **Lesson:** uid transitions muddy ownership; explicit cleanup + hand-off are non-negotiable.

### 3. **PixelTestCase Window Focus Race**
   - **Risk:** macOS 14+ rate-limits programmatic app activation; spawned window stays occluded; screencapture returns blank.
   - **Mitigation:** AppLauncher.runScript() uses LaunchServices (permitted to foreground) + AppleScript activation + 1.5s sleep.
   - **Lesson:** pixel capture requires real focus; can't rush; AppleScript activation has documented rate limits.

### 4. **WebView Async Message Race (waitUntil pattern)**
   - **Risk:** test sends command, polls for reply, but reply hasn't arrived yet under load.
   - **Mitigation:** `waitUntil(timeout, condition)` polls with 20ms sleep + mainQueue drain; bounded timeout + skip on timeout.
   - **Lesson:** don't spin-lock; drain the message queue between polls.

### 5. **Headless-UI Layout Stabilization**
   - **Risk:** SwiftUI layout is asynchronous; test reads geometry immediately and finds zeros.
   - **Mitigation:** explicit `layoutSubtreeIfNeeded()` before assertions; pump runloop after mutations.
   - **Lesson:** force-layout after model mutations; don't assume layout happens synchronously.

---

## Rebuild Notes for Greenfield Project

### Day-1 Test Strategy Recommendations

1. **Start headless-unit immediately** (model, parsing, algorithms).
   - Port the BodyProbe pattern for perf regression detection.
   - Use the Audit-driven test-generation pattern (toolchain scans code, reports untested).

2. **Add headless-UI tests for SwiftUI/AppKit wiring** (no WebView, host-safe).
   - Host the real view tree offscreen (InteractionProfileHarness / NSHostingView pattern).
   - Test document model → view binding, layout bounds, state machine.
   - Use T2' (text-only, no WKWebView) as the safe default for host perf testing.

3. **Reserve WebView tests for real runtime behavior** (jump to VM tier early).
   - Don't test JS in headless isolation; spin up WKWebView.
   - Gate behind #192 (MDV_RUN_WEBVIEW_TESTS=1) so host gate stays window-free.
   - Use message-passing + geometry queries, not DOM crawling.

4. **Establish T5 pixel tests as part of render changes** (VM-only).
   - Pixel capture = the authority for "did it visually render."
   - Prove teeth: revert the fix, confirm test fails, restore.
   - Use the region-analysis helpers (color variety, bounding-box match) not pixel-perfect matching.

5. **File structure & naming:**
   - `<Feature>Tests.swift` for headless-unit (pure logic).
   - `<Feature>HostingTests.swift` for headless-UI (SwiftUI hosting).
   - `<Feature>WebViewTests.swift` for WebView in-process.
   - `<Feature>VisualRegressionTests.swift` for T5 pixel.
   - Avoid ambiguous "Integration" (too vague); name the tier or layer.

6. **Test-data fixtures:**
   - Small files only (< 1 KB); generate on-the-fly in setUp if possible.
   - Use temp dirs isolated per test (UUID-keyed).
   - Never commit large binary fixtures; generate or use reproducible procedures (e.g., modulated sine).

7. **Avoid false-green traps:**
   - Runloop pumping after mutations (don't assume SwiftUI is synchronous).
   - Layout stabilization after model changes (explicit `layoutSubtreeIfNeeded()`).
   - Quiescence detection for async settle (two consecutive empty pumps, not one).
   - Timeout + skip on pixel capture (screen recording is environment-dependent).

8. **Infra worth building Day 1:**
   - Shared AppLauncher (app spawn with root→user transition, temp handoff).
   - BodyProbe or equivalent (perf regression detection).
   - WebViewTestCase base (WKWebView hosting, message passing, geometry queries).
   - Headless-gate enforcement (self-skip T4/T5 when not in VM lane).
   - Runloop pump helper + documentation.

9. **Discipline:**
   - Every rendered surface gets ≥1 test across (headless-unit model + headless-UI wiring + WebView behavior + T5 pixel).
   - Pixel tests span the actual rendering chain, not isolated pieces.
   - Audit findings → test stubs (systematic coverage).
   - No commit without corresponding tests (model change → unit test, UI change → headless-UI + pixel).

10. **Parallel-gate & CI strategy:**
    - Host merge gate: headless-unit + headless-UI (T1/T2'). Window-free, ~seconds.
    - VM nightly: WebView + T5 pixel. Heavy-tier self-skip on host.
    - Quiescence detection under parallelism (TK-1328 fix → two-pump stability).
    - Opt-in smoke gate (MDV_RUN_SMOKE_GATE=1) to build + launch the app; disabled by default (no window opening during merge).

---

## Slice Cohort Summary

This slice (1/6, files 1-69) covers **foundational infrastructure + core features**: action history, annotations, archives, audio (full stack), bookmarks, Canvas, Chrome chrome, Claude Monitor, CM6, components, conflict resolution, content toolbar, cross-file replace.

**Strengths:**
- Comprehensive model/logic coverage (45 headless-unit tests).
- Real runtime behavior tested (Canvas WebView tests, audio visualization pixel capture).
- Perf regression pinning (BodyProbe, re-eval counts).
- Good tier separation (host-safe headless-UI isolated from VM-only pixel tests).

**Gaps:**
- Session persistence & restoration (minimal coverage).
- Terminal/shell robustness (single lifecycle test).
- Plugin system (if exists; not visible in this slice).
- Theme/appearance edge cases (minimal coverage).
- Error recovery (no visible crash-resilience tests).

**Key takeaway:** This codebase has a **tiered, discipline-heavy test strategy** — layer by layer (model → wiring → runtime → pixels), with infrastructure (BodyProbe, WebViewTestCase, pixel helpers) built to catch specific regression classes. Day-1 for greenfield should adopt this template: unit → hosting → webview → pixel, with named tiers and explicit teeth per layer.

