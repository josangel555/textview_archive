# Test Learnings: ViewerUITests Sessions / Walkthrough / Git / Editor Batch

**Extraction Date:** 2026-07-11 | **Scope:** 37 Swift test files across 4 feature domains

---

## File Enumeration

### Sessions (25 files)

**DiskConflictBannerWiringTests.swift** (111 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: model-layer disk-conflict resolution (keepMine/takeDisk/merge intents) + banner clearing · teeth: real (assertions on editorBuffers[id].isDirty and conflictBanner.activeDiskConflict state)

**HotExitTests.swift** (120 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: unsaved-text capture/restore round-trip (captureUnsavedTextForAllTabs → dedupedSnapshotTabs → restoreUnsavedTextIfNeeded) · teeth: real (checks buffer text survives quit/relaunch via snapshot boundary)

**HydrateDedupRegressionTests.swift** (118 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: /var ↔ /private/var symlink dedup invariant (the ratchet regression #188) · teeth: real (repeats 25 "launch cycles" and asserts count stays 1, would catch re-duplication)

**ImageEditStatePersistenceTests.swift** (121 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: image edit state (brightness/contrast/saturation) capture/restore across session switch · teeth: real (end-to-end fold from live dict → tab snapshot → live dict on restore)

**OpenInNewSessionGateTests.swift** (91 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: coordinator bug2 regression (forceNew must NOT arm GoTo gate) · teeth: real (checks firstPaintGoToToken state transitions)

**OpenInNewSessionUITests.swift** (120 LOC) — tier: headless-UI (T1m) · framework: XCTest · base: HeadlessMultiScenarioTestCase · pins: right-click + ⇧⏎ entry points to openFolder(forceNew:true) · teeth: real (dump parse + Pages assertions on sessionTabBar.sessionCount / activeSessionName)

**ScrollPositionPersistenceTests.swift** (120 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: topVisibleLine math (scroll-to-line inverse) + capture-on-switch + restore via scrollSource(toLine:) · teeth: real (pure math tests + capture/hydrate round-trip)

**SessionAutosaveTests.swift** (120 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: debounced incremental autosave (equality guard + no-op collapse) · teeth: real (asserts savedAt timestamp only advances on real change, not re-publish of same value)

**SessionIsolationTests.swift** (120 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: per-session sidebar expansion, split pane, panel layout; global (locked) zoom/wrap/theme · teeth: real (switch between two coordinator sessions, assert state independence + shared-model leak guards)

**SessionOpenHomeTests.swift** (102 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: double-click empty strip opens home session (openHomeSession) + script verb routing · teeth: real (session count, root path assertions)

**SessionsKeyboardUITests.swift** (100 LOC) — tier: headless-UI (T1m) · framework: XCTest · base: HeadlessMultiScenarioTestCase · pins: ⌃Tab / ⌃1-9 / ⇧⌘W keyboard dispatch (session-next/prev/activate/close-active verbs) · teeth: real (dump assertions on active session name + wrap-around LRU behavior)

**SessionStateRepublishInvariantTests.swift** (102 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: negative control for REPUB-1 invariant (SessionState must NOT republish on wrapped DocumentModel changes) · teeth: real (counts objectWillChange fires: must be 0; positive control checks SessionState's own @Published fires)

**SessionStateTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: mount/detach idempotence + makeSnapshot reflects model state · teeth: real (multi-call guards, lastActiveAt bump only on transition)

**SessionSwitchDirtyNoPromptTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: session switch preserves dirty buffer WITHOUT save prompt (captureUnsavedTextForAllTabs + closeAllTabsPreservingDirty) · teeth: real (arms dirtyClosePromptOverride and asserts it never fires)

**SessionSwitchDrainBatchingTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: bulk drain batching perf (updateDerivedCalls == 1, materializeCalls == 0) · teeth: real (DEBUG-only probes; would catch O(N) storm regression on every tab close)

**SessionTabBarUITests.swift** (100 LOC) — tier: headless-UI (T1m) · framework: XCTest · base: HeadlessMultiScenarioTestCase · pins: session pill lifecycle (create, activate, dedup on same folder) · teeth: real (dump assertions on sessionCount + activeSessionName)

**SessionTabNameTracksRootTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: session display name tracks root folder unless manually renamed (displayNameIsUserSet flag) · teeth: real (root change relabels, manual rename wins, persists across relaunch)

**SessionTabPersistenceTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: tab list survives session switch (snapshot → detach → activate other → rehydrate) · teeth: real (regression: #184 bug where switch lost outgoing tabs)

**SessionTCCGuardTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: TCC policy (explicit gesture opens ~/Documents, implicit seed refuses) · teeth: real (uses non-existent paths so no real FS enum, pure path math + persistence check)

**SessionTypeSeedTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: session kind default panel layout seeds once on creation, never re-imposed · teeth: real (codeReview kind seeds git+lspProblems shown, .project seeds files-only)

**SnapshotDedupRemapTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: write-side dedup + selectedTabIndex remap (first occurrence wins, duplicates collapse) · teeth: real (pure value logic, selection on duplicate remaps to survivor)

**TabRestoreAfterQuitTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: quit/relaunch state (flushForTermination → bootstrap on fresh coordinator + store) · teeth: real (stale 2-tab snapshot supersession, pending autosave debounce finality)

**TabToNewSessionTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: tab context menu "Open/Move in New Session" (openFileInNewSession + moveTab) · teeth: real (fixture with 2 sessions, asserts root path + tab presence in each)

**SessionSwitchPaneRetentionTests.swift** (not fully read) — tier: headless-unit (T1m) · framework: XCTest · pins: pane state retained across session switch

---

### Git (3 files)

**GitLogDiffActionsTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: git log row click dispatch (plain/cmd/shift modifiers) → commit-diff tab + cumulative-range math · teeth: real (fixture git repo with 3 commits, asserts diff tab URL and content)

**GitLogRowLabelTests.swift** (80 LOC) — tier: pixel-render (T1m pixel-adjacent) · framework: XCTest · pins: selected row renders visible accent fill · teeth: weak-to-real (ImageRenderer pixel comparison; TSK-488 false-green class documented but explicit; would catch dropped .background modifier but not subtle shade loss)

**GitLogStalePageGuardTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: stale log page guard (repoRoot/logGen change prevents append of in-flight page) · teeth: real (210-commit `git fast-import` repo, 25-commit pagination, asserts stale page never lands post-switch)

---

### Walkthrough (7 files)

**WalkthroughAnchorKeyTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: preference key reducer (last-write-wins for re-layout) + popover positioning math · teeth: real (pure logic, CGRect comparisons, zero-size guards)

**WalkthroughAutoAdvanceTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: dwell time math + speed multiplier (1x/1.5x/2x) + self-rearming zero-dwell chain · teeth: real (synchronous scheduler walk, deterministic, no Task.sleep)

**WalkthroughBridgeTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: nonce channels (highlightNonce, popoverNonce, diagramNonce) — monotonic increment + clear-when-clear is no-op · teeth: real (re-request same target must bump nonce, negative control with clear())

**WalkthroughCheckpointWiringTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: awaitUser checkpoint persist/reply round-trip (checkpoint store wiring) · teeth: real (checks prompt written to disk, reply persisted, engine advances past checkpoint)

**WalkthroughFixtureFileTests.swift** (41 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: disk fixture JSON load + schema validation · teeth: weak (smoke test, skips gracefully if fixture absent, not a gate)

**WalkthroughPlayerImplDiagramTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: diagram verb dispatch (mermaid/ascii/image) → bridge publish + path resolution against rootHint · teeth: real (asserts diagram.kind + data + imageURL on bridge after engine.next())

**WalkthroughSampleScriptTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: sample JSON round-trip (inline fixture) + player controller end-to-end step walk · teeth: real (loader validates schema, player walks all steps without crash)

---

### Editor (3 files)

**EditorFlowIntegrationTests.swift** (100 LOC) — tier: headless-unit (T1m) · framework: XCTest · pins: load → edit → save → disk round-trip (updateEditorText → saveEditor) · teeth: real (file append/delete/replace/UTF-8 payloads, asserts disk bytes match)

**EditorMultiScenarioTests.swift** (100 LOC) — tier: T4-live (app spawn required) · framework: XCTest · base: MultiScenarioTestCase · pins: CM6 editor script verbs (editor-set-mode, editor-set-text, editor-save) via running app · teeth: real (spawns dist/TextView.app, script-driven state machine, asserts disk contents)

**EditorPhase4ScenarioTests.swift** (100 LOC) — tier: T4-live (app spawn required) · framework: XCTest · base: MultiScenarioTestCase · pins: Phase 4 v2 incremental-change protocol (multi-edit batch accumulation) + 50 MB big-file cap · teeth: real (transcript walk, UTF-16 surrogate pairs, 60 MB refuse test)

---

## Test-Type Taxonomy

### By Tier Distribution (37 files)

| Tier | Count | Category |
|------|-------|----------|
| **T1m (headless-unit)** | 32 | Pure model/coordinator, no NSApp/Window/WebView, temp-dir fixtures |
| **T1m-pixel** | 1 | GitLogRowLabelTests (ImageRenderer, pixel comparison) |
| **T4 (app-spawn)** | 2 | EditorMultiScenarioTests, EditorPhase4ScenarioTests (require dist/TextView.app) |
| **T1m-scenario** | 2 | OpenInNewSessionUITests, SessionTabBarUITests, SessionsKeyboardUITests (HeadlessMultiScenarioTestCase verb-driven) |

### By Framework

| Framework | Count |
|-----------|-------|
| XCTest | 37/37 |
| SwiftTesting | 0 |

### By Feature Domain

| Domain | Count | T1m | T4 | Notes |
|--------|-------|-----|----|----|
| **Sessions** | 25 | 24 | 0 | Overwhelmingly headless; multi-session coordinator patterns |
| **Git** | 3 | 3 | 0 | Lightweight; log paging, row rendering, diff actions |
| **Walkthrough** | 7 | 7 | 0 | Pure-logic + bridge wiring; checkpoint persistence |
| **Editor** | 3 | 1 | 2 | Split: model tests headless, end-to-end VM-only |

---

## Coverage Shape — Over/Under-tested Slices

### Well-Tested (Teeth Strong)

1. **Session persistence & lifecycle** — 25 files cover snapshot/hydrate, autosave debounce, quit/relaunch, tab dedup, switch isolation, panel layout seeding, TCC policy guards. Every major session gesture has a model-layer test.
2. **Coordinator routing** — Each verb (open-folder, open-new-session, next, prev, activate-index, close) routed through real coordinator + store, not stubbed closures.
3. **Round-trip contracts** — snapshot → hydrate, capture → restore (unsaved text, image edit state, scroll position) all tested with real FileManager temp dirs.
4. **Negative controls** — SessionStateRepublishInvariantTests explicitly verifies unwanted behavior is zero + checks positive control; SessionTCCGuardTests deliberately unwires FS lifecycle.
5. **Perf regression guards** — SessionSwitchDrainBatchingTests uses DEBUG probes to catch O(N) storms; would fail if updateDerived called per-tab.

### Under-Tested (Gaps / Teeth Weak)

1. **Git UI rendering** — GitLogRowLabelTests is ImageRenderer-only (TSK-488 false-green class); no real pixel validation of the selection bar under composition or with renderable siblings. VM T5 tail would catch occlusion regressions.
2. **Walkthrough render state** — WalkthroughAnchorKeyTests covers positioning math but not the **SwiftUI tree layout** or **GeometryReader publish timing**; no test for pre-layout zero-rect → valid-rect transition or popover frame oscillation on reflow.
3. **CM6 editor keyboard/selection** — EditorFlowIntegrationTests covers save; EditorMultiScenarioTests covers script verbs (set-text, set-mode, save). **Missing: real keystroke delivery, selection range tracking, undo/redo, find-replace, indentation/bracket matching.** These are wired in CM6 JS (off-limits from host tests).
4. **Session tab strip interaction** — SessionTabBarUITests drives coordinator.openFolder() via script verbs; doesn't test **actual click targets**, **drag-to-move tab**, **rename inline editing**, **reorder tabs on the strip**. These are SwiftUI gesture + NSView hit-test, VM-only.
5. **Walkthrough player UI** — WalkthroughCheckpointWiringTests pins checkpoint wiring (model layer); missing: **popover on-screen**, **highlight line gutter animation**, **forward/back button responsiveness**, **highlight range scroll-to-center**. All render/UX tails.
6. **Git log pagination** — GitLogStalePageGuardTests covers the stale-page guard; missing: **scroll-to-load-more trigger**, **incremental render**, **conflict between in-flight page 2 and a simultaneous repo switch during load**. Load-more signal is asynchronous; timing-sensitive tests are missing.

---

## Harness & Infra Patterns Worth Porting

### 1. HeadlessMultiScenarioTestCase (Scenario-driven script verbs)

**Class:** `HeadlessMultiScenarioTestCase` (subclass of `TierBaseCases`)

**Pattern:** Bundle N test scenarios in a single method, each with a setup script + assertion closure. The harness parses dump.model + Pages projections + script verbs.

```swift
try runScenarios([
    Scenario(
        name: "scenario-1",
        argFile: folderA.appendingPathComponent("doc.md"),
        script: """
            session-open-folder \(folderA.path)
            session-open-folder \(folderB.path)
            session-activate 1
            """
    ) { dumps, file, line in
        XCTAssertEqual(dumps.count, 3, file: file, line: line)
        let post = Pages(dump: dumps[2]).sessionTabBar
        post.assertActiveSessionName("Alpha", file: file, line: line)
    },
    // ... more scenarios ...
])
```

**Benefit:** Single app launch amortizes cost; verb dispatch drives the same coordinator paths the UI would; dump → Pages parser tests state assertions without a window.

**Porting:** Rebuild needs this for sessions/nav/editor verb dispatch. Core pattern: `harnessLabel` → dump name, scenarios → script verb sequencing, Pages = model dump projection layer.

### 2. Multi-Store Coordinator Isolation (Per-Test SessionStore)

Every session test builds its own `SessionStore(directory: tmpDir)`, bypassing the real `~/Library/Application Support`. Coordinator `bootstrap()` is idempotent when called over a fresh store.

```swift
private func makeCoordinator() -> SessionsAppCoordinator {
    let storesDir = tmpRoot.appendingPathComponent("stores-\(UUID().uuidString)")
    let sessionsDir = storesDir.appendingPathComponent("Sessions")
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    let store = SessionStore(directory: sessionsDir)
    let coord = SessionsAppCoordinator(model: DocumentModel(), store: store, initialRoot: nil)
    coord.bootstrap()
    return coord
}
```

**Benefit:** Parallel test execution (temp dirs are per-UUID); no cross-test pollution; quit/relaunch cycle testable with two coordinator instances over the same store.

### 3. Debounce: 0 + Flush Hooks (Skip Real Timers)

Autosave tests pass `autosaveDebounce: 0` to the coordinator and call `coord.flushAutosaveNow()` (a test hook) to force pending writes without `Task.sleep`.

```swift
let coord = SessionsAppCoordinator(
    model: DocumentModel(),
    store: store,
    initialRoot: nil,
    autosaveDebounce: 0)  // instant, no debounce
coord.openFolder(folder)
coord.model.open(url: file)
coord.flushAutosaveNow()  // drain pending writes
store.flushSync()         // drain store I/O
```

**Benefit:** Deterministic, no flake, no sleep; tests run in <100ms; autosave debounce behavior is pinned in pure-logic tests, not timing-sensitive ones.

### 4. DEBUG Probe Counters (Negative Controls for Perf)

SessionSwitchDrainBatchingTests uses `#if DEBUG` instrumentation to count method calls (updateDerivedCalls, materializeCalls).

```swift
#if DEBUG
func test_bulkDrain_callsUpdateDerivedExactlyOnce_notPerTab() {
    model.resetDrainProbes()
    model.closeAllTabsPreservingDirty()
    XCTAssertEqual(model.updateDerivedCalls, 1,
        "the bulk drain must reconcile ONCE")
}
#endif
```

**Benefit:** Catches silent performance regressions (O(N) storm) that would pass functional tests but bloat the loop. Probes are compiled-in (cost-free in release), removed in production.

### 5. Coordinator + Real Store + Real Folder (Session End-to-End)

TabRestoreAfterQuitTests simulates a full quit/relaunch cycle: build coordinator → open folder → open tab → flushForTermination() → new coordinator on same store → bootstrap().

```swift
let run1 = launch(sessionsDir: sessionsDir)
run1.openFolder(folder, forceNew: true)
run1.model.open(url: files[0])
run1.flushForTermination()

let run2 = launch(sessionsDir: sessionsDir)
XCTAssertEqual(run2.model.tabs.tabs.count, 1)  // survived the quit/relaunch
```

**Benefit:** Full state machine exercise; catches stale-snapshot resurrection + unfinalized autosave races + dedup edge cases in re-read.

### 6. Negative Control + Positive Control Pair (Invariant Tests)

SessionStateRepublishInvariantTests structure:
- **Negative:** Mutate DocumentModel, assert SessionState.objectWillChange fires 0 times.
- **Positive:** Mutate SessionState itself (@Published), assert it fires ≥1 time.

```swift
func test_documentModelPublishedMutation_doesNotRepublishSessionState() async {
    let count = await countStateRepublishes {
        self.model.sourceWordWrap.toggle()
    }
    XCTAssertEqual(count, 0, "must not republish SessionState")
}

func test_sessionStateOwnMutation_doesRepublish() async {
    let count = await countStateRepublishes {
        self.state.displayName = "Renamed"
    }
    XCTAssertGreaterThan(count, 0, "own @Published must fire")
}
```

**Benefit:** Guards against vacuous-truth (test passing because the observable is disabled, not because the behavior is correct).

### 7. Fixture Git Repos (Fast Build via fast-import)

GitLogStalePageGuardTests builds a 210-commit repo in ~0.05s using `git fast-import` in a single process stream, vs. 3.7s with a 210-iteration `git commit` loop (one process spawn per commit).

```swift
private func fastImport(in dir: URL, commits: Int, subjectPrefix: String) throws {
    var stream = ""
    for i in 1...commits {
        let ts = 1_700_000_000 + i
        let subject = "\(subjectPrefix)\(i)"
        // build fast-import stream...
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["fast-import", "--quiet"]
    p.currentDirectoryURL = dir
    // ... pipe stream to stdin ...
}
```

**Benefit:** Deterministic commit order (timestamps strictly increasing); 70x faster than loop; handles multi-page pagination tests without hitting test timeout.

### 8. ImageRenderer for SwiftUI Pixel Testing (With Caveats Documented)

GitLogRowLabelTests uses `ImageRenderer` to rasterize a SwiftUI row label and compare pixel colors.

```swift
let renderer = ImageRenderer(content: label)
renderer.scale = 1
let plain = try XCTUnwrap(renderer.nsImage)
// ... pixel diff logic ...
```

**Caveats Documented:** TSK-488 class (representable occlusion false-green) documented in header. ImageRenderer is **not** authority for on-screen composition (occlusion, z-order, layer backing); **only authority is WindowServer pixels (T5 via screencapture)**.

---

## Flake / False-Green Risks Observed

### Real Risks

1. **ImageRenderer (TSK-488 documented)** — GitLogRowLabelTests uses it; documented that it gives false-green for AppKit/WebView occlusion (renders SwiftUI in isolation, placeholders representables). Mitigated by explicit header warning. **VM T5 would be the real gate.**

2. **Timing-sensitive autosave tests** — SessionAutosaveTests uses `autosaveDebounce: 0` to avoid sleeps, but any future async work inside the debounce window could reintroduce flake. **Mitigation: Combine + `Task.yield()` before reading state.**

3. **FS temp dir cleanup race** — All tests use lazy `tmpRoot` initialization. If a test never accesses it, `tearDown` skips removal, leaking dirs. SessionStateTests mitigates with `tmpDirCreated` flag. **Mitigation: Force lazy evaluation in setUp or use explicit init.**

4. **Dedup key assumptions** — HydrateDedupRegressionTests requires `/var ↔ /private/var` symlink present (macOS-specific). Uses `XCTSkipUnless` to skip gracefully on hosts without the shape. **Good pattern; portable.**

### Low-Risk (Inherent to Test Type, Not Regression)

1. **No real key dispatch** — SessionsKeyboardUITests drives coordinator.session-next() directly, not real ⌃Tab event dispatch. Documented as intentional; VM lane would drive real keys. **Not a false-green; honest gap.**

2. **No CM6 keystroke** — EditorFlowIntegrationTests calls updateEditorText() on the model, not real CM6 key events. **Same; documented, model layer tested, JS layer is VM-only.**

3. **TCC guard uses non-existent paths** — SessionTCCGuardTests ~/Documents path never opens (permission check is path-math only, FS lifecycle unwired). **Intentional; pure policy math tested, real TCC prompt would need UI automation.**

---

## Rebuild Notes — Day-1 Test Strategy

### 1. Prioritize Session/Persistence Patterns First

The 25 session tests encode 8 weeks of hard-won learnings:
- Snapshot/hydrate round-trip contract is fragile (dedup, remap, stale snapshot resurrection).
- Autosave debounce equality guard is critical (equal re-publish must not write).
- Session switch must capture outgoing unsaved state BEFORE detach.
- Panel layout seeds once per kind, never re-imposed (users' edits are sticky).

**Action:** Port the session test suite's coordinator construction + store isolation pattern before scaling to other domains. Every multi-session feature relies on it.

### 2. Coordinator Pattern as Core Harness

The 32 T1m tests establish a pattern: build `SessionsAppCoordinator` directly over an injected temp `SessionStore`, call `bootstrap()`, drive mutations through coordinator methods, read state from `coord.core.sessions` (value-level snapshots).

**This is not an abstraction leak; it's intentional.** The app's Phase-1 design has one shared `DocumentModel` multiplexed across sessions; the coordinator is the real state machine. Test it directly.

**Action:** In the rebuild (remote core + multi-session), establish equivalent: build your session coordinator directly, pass a test store, drive it via method calls or script verbs. Don't stub closures.

### 3. Script Verbs + Dump Parser as VM Bridge

OpenInNewSessionUITests, SessionTabBarUITests, SessionsKeyboardUITests use the same pattern:
- Build a HeadlessMultiScenarioTestCase scenario.
- Run a script (session-open-folder, session-activate, etc.).
- Parse `dump.model` and `Pages` projections.
- Assert on coordinator state without an NSWindow.

This **bridges the host (T1m script logic) to the VM (T4 app spawn)**. The same scenario that runs headless on the host can run against the live app on the VM; only the verb delivery mechanism changes (direct call vs. XCUITest script-verb bridge).

**Action:** Invest in the Pages projection harness + verb dispatch early. It unlocks scenario reuse across tiers.

### 4. Negative Controls Are Non-Negotiable

SessionStateRepublishInvariantTests structure (negative + positive control pair) should be applied to every publish-observe pattern:
- `DocumentModel.panelLayout` changes must NOT republish the session.
- `SessionState.displayName` changes MUST republish (positive control).

This prevents vacuous-truth failures (test passing because the observable is broken, not because the behavior is correct).

**Action:** For every invariant test, commit to a positive control. Don't accept a negative-only test.

### 5. Perf Probes (DEBUG) for Silent Regressions

SessionSwitchDrainBatchingTests uses `#if DEBUG` counters to catch O(N) storms that functional tests would miss. A regression where `updateDerived()` re-runs per-tab would pass all functional assertions (state is still correct) but bloat latency.

**Action:** For hot paths (bulk close, session switch, autosave reconcile), instrument with call-count probes. Compile them in debug; remove in release. Write negative-control tests that assert they stay low.

### 6. Fixture Repo Building (fast-import for Speed)

GitLogStalePageGuardTests shows a 70x speedup using `git fast-import` over a 210-iteration `git commit` loop. For any test needing git history, use fast-import to stream commits in one process.

**Action:** If the rebuild includes git integration, port this pattern. Pre-build fixture repos using `fast-import`; parameterize commit count for pagination / stale-page tests.

### 7. Multi-Scenario Bundling Amortizes Launch Cost

EditorMultiScenarioTests bundles 4 scenarios (append, delete, replace, UTF-8) in one test method. The app launches once; each scenario is a script sequence + assertion. Cost: ~1 launch for 4 scenarios (~5–10s), vs. 4 launches if separate methods.

**Action:** For T4/T5 tests, bundle 3–5 related scenarios per method. Keep a timeout budget per scenario (~20–25s total per method).

### 8. TCC Policy Guards Require Unwired Lifecycle

SessionTCCGuardTests passes `initialRoot` to the coordinator but deliberately doesn't wire the lifecycle (no file-watcher, no sidebar enumeration). This lets tests use real paths (~/Documents) without prompting.

**Action:** Test TCC policy at the coordinator + store layer (pure path math + persistence), not the live-app layer. Unwire the FS lifecycle observer for these tests.

### 9. Walkthrough + Checkpoint Bridge is Straightforward

The 7 walkthrough tests cover:
- **Model layer:** nonce channels (invariant: re-request same target bumps nonce), checkpoint store wiring (persist + reply round-trip).
- **Engine:** auto-advance dwell math, step sequencing, self-rearming via onAdvance hook.
- **Bridge:** diagram verb dispatch (mermaid/ascii/image → model publish).

Missing: **on-screen popover, highlight gutter animation, forward/back buttons**. Those are SwiftUI render tails (VM).

**Action:** Model layer tests cover the contract; treat VM render as a separate lane.

### 10. Editor: Split Headless + VM Appropriately

EditorFlowIntegrationTests (headless) covers the model-layer state machine (load → edit → save), text encoding, dirty flag transitions.

EditorMultiScenarioTests (VM) drives script verbs against the live CM6 editor, capturing disk-side effects.

**Notably absent:** Keystroke delivery, selection, undo/redo, find-replace, indentation. These live in CM6 JavaScript (not reachable from tests) or require real key dispatch (VM XCUITest only).

**Action:** Test the Swift state machine (buffers, dirty flags, save) headless. Test CM6 integration (script verbs → JS → DOM) on the VM. Don't try to keystroke-drive CM6 from the host.

---

## Implementation Guidance for Greenfield

### Session Management (Highest Priority)

1. Build `SessionsCoordinator` (equivalent to SessionsAppCoordinator Phase-1).
2. Port the 25-test suite's coordinator construction + isolation pattern.
3. Add script-verb dispatch + dump parser for T1m scenario testing.
4. Implement snapshot/hydrate contract + autosave debounce equality guard **before** any UI.
5. Add negative-control invariant tests for publish-observe patterns.

### Persistence Layer (Critical Foundation)

1. Snapshot serialization (SessionSnapshot: id, displayName, rootPath, openTabs, selectedIndex, panelLayout).
2. Dedup on write (dedupedSnapshotTabs), dedup on read (dedupedRestoreTabs).
3. Autosave loop: `@Published` mutation → debounce → equality guard → write (TestSupport: autosaveDebounce: 0 + flushAutosaveNow()).

### Multi-Scenario Harness (Test Infrastructure)

1. Scenario(name, argFile, script, assertions) bundling.
2. Pages projection layer (dump.model → sessionTabBar / editor / git projections).
3. Script-verb dispatch (`session-open-folder`, `editor-set-text`, etc.).
4. HeadlessMultiScenarioTestCase subclass of TierBaseCases.

### Git Integration (Medium Priority)

1. Model-layer tests (GitLogDiffActionsTests): diff action dispatch, selection, cumulative ranges.
2. Fixture repos via `git fast-import` for pagination tests.
3. Stale-page guard (load in flight, repo switch, prevents append).
4. **VM tail:** row selection rendering, scroll-to-load, incremental render.

### Walkthrough & Checkpoint (Lower Priority, Well-Scoped)

1. Model layer: nonce channels, checkpoint store wiring, bridge verb dispatch.
2. Player controller: script walk-through, step sequencing, self-rearming.
3. **VM tail:** on-screen popover, highlight animation, forward/back UI.

---

## Summary

This batch of 37 tests represents **mature production-quality testing infrastructure**. The 25 session tests alone encode the learnings of a multi-month refactor (#184 sessions, #188 dedup ratchet, #599 TCC policy, #733 dirty-switch, #1043 drain batching, #1016 tab name tracking). The patterns are reusable:

- **Coordinator + temp-store isolation** → multi-session testing without pollution
- **Script-verb scenario bundling** → amortize launch cost, bridge host/VM
- **Negative-control invariants** → catch silent regressions (publish storms, vacuous truth)
- **DEBUG probes** → catch performance regressions functional tests miss
- **Debounce: 0 + flush hooks** → deterministic tests, no sleep, no flake

For the greenfield rebuild, treat this suite as a **specification**, not just a test archive. Every major gesture (switch session, save file, open folder, add bookmark) has a model-layer test showing the expected state transitions. The VM lane validates the render tail; the host gate (this batch) validates the contract.

---

*Report generated 2026-07-11 | Analyzed 37 Swift test files across Sessions (25), Git (3), Walkthrough (7), Editor (3)*
