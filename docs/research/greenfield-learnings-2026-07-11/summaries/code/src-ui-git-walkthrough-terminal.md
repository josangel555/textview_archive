# ViewerUI: Git, Walkthrough, Terminal — Code Summary & Learnings

**Scope:** 41 Swift files across 3 feature modules in `Sources/ViewerUI/` (Git, Terminal, Walkthrough); ~9,600 LOC total.

---

## File Inventory

### Git Panel (21 files, ~4,900 LOC)

| File | LOC | Role |
|------|-----|------|
| **CommandClickModifier.swift** | 55 | AppKit click-event overlay to distinguish Cmd-click from plain click for range selection (shared by FileHistory and UnifiedHistory). |
| **DiffView.swift** | 650 | Renders unified diffs with line numbers, hunks, file headers; hosts review affordances (comment threads, composer); find-in-diff with match nav. |
| **FileHistoryAvailabilityCache.swift** | 165 | Synchronous in-memory cache for "is this file tracked?" — gates menu enable-state without main-thread git forking. Off-main probe + main-actor store. |
| **FileHistoryModel.swift** | 203 | View-model for FileHistoryView; owns commit list + selection state machine (single / range mode + Cmd-click logic); off-main diff load with last-write-wins token. |
| **FileHistoryView.swift** | 210 | Master-detail file history: left commit list, right diff pane; toggle "this commit" vs "vs working tree" for single selection; Cmd-click range. |
| **FolderStatsView.swift** | 266 | Repo statistics card: commit count, author leaderboard, file-type histogram; lazy off-main fetch via RepoStatsCache (HEAD-invalidated). |
| **GitGraphColumn.swift** | 111 | Left graph column for Log tab: lanes + dot/line rendering via Core Graphics Canvas (no animation, stateless). |
| **GitLogDiffActions.swift** | 103 | Action closures for Git Log row clicks (mod-dispatch: cmd toggles multi-select, shift extends range, plain opens diff); diffs cached + opened as tabs. |
| **GitLogRowLabel.swift** | 80 | Extracted Log row label (pure inputs, no observation) for ImageRenderer testability; commit sha, branch refs, author line, selected-row accent. |
| **GitLogTab.swift** | 276+ | Flat commit list (v1; topological graph pending); search field; multi-selection bar; pagination; GraphLayout caching to avoid O(commits×lanes) re-calcs per body eval. |
| **GitPanelModel.swift** | 650+ | State container for multi-tab Git panel; per-tab cached data + 60s refresh timer; log pagination + multi-selection range; deinit safety for timer/tasks. |
| **GitPanelSection.swift** | 120 | Sidebar accordion wrapper for GitPanelView; repos pinned to override auto-focus; forced-shown-when-empty placeholder. |
| **GitPanelView.swift** | 202 | Position-agnostic panel (tab strip + body); repo picker (multi-repo); refresh button with spinning icon during refresh. |
| **GitRemotesTab.swift** | 88 | Remote list: URL, last-fetch timestamp; click to open in browser (translates ssh → https via ForgeRemote parser). |
| **GitStashTab.swift** | 109 | Stash list with per-row Apply / Pop / Show / Drop; confirm before drop; diffs via cached .diff files. |
| **GitStatusTab.swift** | 345+ | Status view: staged/unstaged/untracked groups; per-row stage/unstage; commit bar (message field + Commit button, disabled when empty/nothing staged); discard-confirm dialog. |
| **GitWorktreesTab.swift** | 320+ | Worktree manager: Add sheet, Prune button; per-row removal with force detection; lock/prunable/current state chips; delegates UX logic to WorktreeManagerModel (ViewerCore). |
| **RepoFocusTracker.swift** | 344+ | Demand-driven multi-repo registry: gathers tracked repos from open tabs + sidebar selection + pins; deduped recompute → store retain/release + FSEvents watchers; cheap focus resolution. |
| **TrackedReposChannel.swift** | 232 | THE observation surface for multi-repo registry (thin sync mirror of off-main TrackedReposStore); single @Published version tick; bounded normalizer + .git-existence caches. |
| **UnifiedHistoryView.swift** | 303 | UNIFIED version-history viewer (Local History + Git, backend-agnostic via VersionSource); list + detail; view/diff/own-change toggles; range diff; Restore confirmation. |
| **UnifiedHistoryViewModel.swift** | 266 | @MainActor view-model for UnifiedHistoryView; selection state machine (single + range + Cmd-click); off-main diff loads; size annotations (delta vs previous save). |

**Notable Git patterns:**
- **Narrow @Published surfaces:** GitPanelModel doesn't forward objectWillChange wholesale; views bind to individual fields (REPUB-1 discipline).
- **Off-main + token-guarded loads:** FileHistoryModel / UnifiedHistoryViewModel use monotonic diffToken to guard against stale results landing after a newer load.
- **Cache lifecycle:** FileHistoryAvailabilityCache + RepoStatsCache use "unknown ⇒ enabled" for initial undefined state; probes run off-main, result written back via callback.
- **Multi-repo registry:** RepoFocusTracker + TrackedReposChannel are a coordinator/observer pair decoupled from DocumentModel.objectWillChange to avoid republish storms.
- **Compositor occlusion:** DiffView review affordances (comment threads, composer) require explicit z-order pinning (not yet fully deployed in the codebase).

---

### Terminal (10 files, ~2,100 LOC)

| File | LOC | Role |
|------|-----|------|
| **PTYProcess.swift** | 483 | Darwin forkpty wrapper: spawn shell, read async on background queue, write blocking on serial queue; lifecycle guard (double-fork prevention via claimStartSlot). Precompute C strings in parent (signal-safety, M4). |
| **SideDockCompositing.swift** | 45 | Named z-order constants for side-docked terminal vs center content (TSK-960 regression guard); host-testable ordering decision. |
| **TerminalCwd.swift** | 36 | Pure resolvers for "new terminal here" working directory: focused file → parent folder, sidebar folder → itself, nil → home. |
| **TerminalModel.swift** | 328+ | @MainActor bridge between live PTYProcess + pure ANSIParser; throttled snapshot publishes (coalesce input bursts on frame clock, not byte clock); OSC-7 cwd + child pid tracking. |
| **TerminalNSView.swift** | 667 | Direct-drawing NSView: monospaced grid rendering via Core Text glyph runs; mouse selection (click + drag, word, line); scrollbar + scrollback viewport; keyboard input via TerminalKeyEncoder. |
| **TerminalPalette.swift** | 64 | ANSI color resolver: 16-color theme + xterm 256 indexed + truecolor; precomputed shared NSColor palette (no alloc per draw frame — perf-critical for per-run churn). |
| **TerminalPaneStore.swift** | 327+ | Observable owner of terminal pane: open/close, height, docking edge (bottom/left/right), tab set + live model map. Lazy shell spawn; persists layout + cwd via OSC-7. |
| **TerminalView.swift** | 499+ | NSViewRepresentable bridge + TerminalPaneView: tab strip (horizontal/vertical position), tab rename alert, restart-after-exit overlay, shoulder border (TSK-1177). Compositor layering (TSK-488). |
| **TmuxController.swift** | 86 | Observable bridge for tmux -CC control-mode: ingests parsed events → applies to TmuxControllerCore (pure) → publishes on two channels (outputVersion / topologyVersion); encode outbound commands. |
| **TerminalCwd.swift** | (covered above) | |

**Notable Terminal patterns:**
- **PTY safety:** Signal-safe fork discipline (precompute C strings in parent, child only does chdir+execve); double-start guard via claimStartSlot; proper reaping with waitpid.
- **Off-main decode:** ANSIParser runs on serial dispatch queue; TerminalParserBox snapshot is lock-protected; UI bumps throttled to ~16ms frame clock (LESSONS "don't republish per byte").
- **Compositor layering:** Terminal column explicitly zIndex'd above content column (SideDockCompositing constants); tab strip in own compositingGroup above surface (TSK-488).
- **Scrollback UX:** Per-tab scroll offset persists on model (survives view recreation on tab switch via .id rebinding); scrollbar gutter hit-area, mouse selection via TerminalSelection geometry.
- **Live cwd tracking:** OSC-7 reports flow into TerminalModel → onWorkingDirectoryChange callback → TerminalPaneStore persists to tab descriptor for restore-on-relaunch.

---

### Walkthrough (10 files, ~2,600 LOC)

| File | LOC | Role |
|------|-----|------|
| **DocumentModel+Walkthrough.swift** | 299+ | Associated-object bridges: WalkthroughBridge (nonce channels for highlight/flash/popover/diagram) + WalkthroughController (owner of WalkthroughEngine + transport state). |
| **WalkthroughAnchorRegistration.swift** | 75 | PreferenceKey-based anchor registration: surfaces (sidebar, gitTab, editor) publish their frames via GeometryReader; overlay reads merged dict to position popovers. |
| **WalkthroughAutoAdvance.swift** | 160 | Auto-advance clock: pure dwell-math (stepped / speed-scaled) + async Task.sleep schedule; reschedule on speed change; onAdvance callback to re-arm for next step. |
| **WalkthroughDiagramOverlay.swift** | 100 | Illustration overlay for active step: ASCII callout, image, or Mermaid source; caption layered above surface (TSK-488 occlusion). Presentation enum (pure, host-testable). |
| **WalkthroughMermaidPage.swift** | 20 | Pure HTML page builder: fences Mermaid source in markdown, runs through HTMLRenderer with shimCSS (host-testable). |
| **WalkthroughMermaidWebView.swift** | 53 | WKWebView hosting Mermaid diagram: loads HTML from WalkthroughMermaidPage; injects runtime + shim as WKUserScript; guards via coordinator lastSource. |
| **WalkthroughOverlay.swift** | 357+ | Window-root overlay: highlight stripe (line-anchored, computed from SourceScrollState.lineHeight + offsetY), flash pulse (animated opacity), popover (container-aligned or frame-anchored), diagram. |
| **WalkthroughPlayerImpl.swift** | 290+ | WalkthroughEngineDelegate: translates engine actions (openFile, revealLine, highlightRange, flash, showPopover, diagram, awaitUser, …) to DocumentModel mutations + WalkthroughBridge nonce bumps; path resolution against rootHint. |
| **WalkthroughPlayerView.swift** | 500+ | Docked transport strip: narration display, scrub bar, prev/next/play-pause buttons (keyboard shortcuts ⌘[ / Space / ⌘]), speed pill, steps menu, note button; awaitUser checkpoint reply UI. |
| **WalkthroughsBrowserView.swift** | 116 | File ▸ Walkthroughs catalog browser: list saved scripts by title + mtime; Run / Resume / Rename / Delete; New Walkthrough seeds a starter template. |

**Notable Walkthrough patterns:**
- **Associated objects for late binding:** WalkthroughBridge + WalkthroughController attach to DocumentModel via objc_setAssociatedObject so app delegate can start tours before ContentView mounts (@StateObject).
- **Nonce channels:** Every visual request (highlight, flash, popover, diagram) bumps a separate nonce so the same target re-issues still animate (value doesn't change, nonce does).
- **Pure logic isolation:** WalkthroughEngine (ViewerCore) is a state machine with no UI / Timer; WalkthroughAutoAdvance owns the clock; WalkthroughPlayerImpl translates actions. Host-testable seams throughout.
- **Compositor layering:** Diagram overlay's Mermaid WebView is zIndex(0); caption is compositingGroup().zIndex(1) so it can't be occluded (TSK-488).
- **Line-anchored rendering:** Highlight + flash use SourceScrollState.lineHeight + topInset to compute doc coordinates, then subtract offsetY for viewport alignment (mirrors SourceGutterView math).
- **Coordinate space bridging:** Anchor surfaces register frames via PreferenceKey into named `.walkthroughOverlay` coordinate space; popover positioning reads merged dict for real rects instead of approximate Alignments.

---

## Module Summary

### What This Slice Does

**Git Panel** — A comprehensive in-app git UI replacing `git` CLI for common workflows:
- Status: staged/unstaged/untracked with per-file stage/unstage and bulk commit.
- Log: flat list with optional graph (v1), multi-selection for range diffs, search by message.
- File History: master-detail per-file view of commits; single or range diff; "vs working tree" toggle.
- Stash: per-entry apply/pop/show/drop with confirm.
- Worktrees: add/prune/remove with state badges (current/locked/prunable).
- Remotes: URL + last-fetch timestamp; click-to-open in browser.
- Multi-repo registry: discover + track repos from open tabs/sidebar; per-root FSEvents watchers; cheap focus resolution.

**Terminal** — A full-featured in-app shell replacing external terminal emulator:
- PTY via Darwin forkpty (no SwiftTerm dependency).
- Background ANSI parsing (off-main decode, throttled to frame clock).
- Multi-tab shell management with per-tab scroll, cwd, and title persistence.
- Monospaced grid rendering + text selection + scrollbar.
- Tmux -CC control-mode integration for nested splits (v1 foundation).
- OSC-7 cwd tracking for resume-on-relaunch.

**Walkthrough** — Interactive guided tours of the app (tutorials, onboarding, demos):
- Engine (pure logic in ViewerCore) + delegate (AppKit/SwiftUI actions in ViewerUI).
- Visual effects: line highlights, flash pulses, floating popovers, illustrations (ASCII/Mermaid/image).
- Auto-advance clock with speed control (1x / 1.5x / 2x).
- Checkpoints: awaitUser action to pause + collect user input before resuming.
- Catalog browser with new-from-template + run/rename/delete.

---

## Patterns Worth Porting

### 1. Off-Main Probe + Main-Actor Store (FileHistoryAvailabilityCache)
**Pattern:** Synchronous gate on main thread backed by async probe + callback.
```swift
public func availability(
    for url: URL, onResolved: @escaping @MainActor (URL, Bool) -> Void
) -> Bool {
    if let cached = entries[key(url)] { return cached }
    scheduleProbe(url: url, key: key(url), onResolved: onResolved)
    return true  // unknown ⇒ enabled (permit transient flicker forward)
}
private func scheduleProbe(url: URL, key: String, onResolved: ...) {
    guard !inFlight.contains(key) else { return }
    inFlight.insert(key)
    Task.detached(priority: .userInitiated) { [weak self] in
        let result = probe(url)
        await self?.store(key: key, url: url, value: result, onResolved: onResolved)
    }
}
```
**Why:** Menu enable-state gates (`NSMenuItem.isEnabled`) must be synchronous; forking git on the main thread is a non-starter. Cache hit is instant, miss schedules off-main, result flows back via callback.

**Rebuild:** Use this for any feature that needs synchronous UI gating backed by expensive async work (file-opened-in-another-tab? user-has-permission-for-X?).

---

### 2. Narrow @Published Surfaces (GitPanelModel)
**Pattern:** Don't forward child objectWillChange into parent; expose only what the view needs.
```swift
@Published public var selectedLogSHAs: Set<String> = []
@Published public var statusEntries: [GitClient.StatusEntry] = []
// NOT:
// @Published public var objectWillChange

// View binds to individual fields:
List(selection: Binding(
    get: { model.selectedLogSHAs },
    set: { model.selectedLogSHAs = $0 }
))
```
**Why:** PERF #1 — prevents a single-field mutation from republishing the entire tree. A panel refresh that changes statusEntries doesn't re-render unrelated parts of the layout.

**Rebuild:** In any coordinator / store that observes multiple upstream publishers (tabs, sidebar, repos), expose narrow @Published fields and never forward objectWillChange wholesale.

---

### 3. Monotonic Token for Last-Write-Wins (UnifiedHistoryViewModel)
**Pattern:** Guard async load results against races by checking a generation counter.
```swift
private var detailToken = 0

private func loadSingleDetail(_ version: VersionRef) {
    detailToken += 1
    let token = detailToken
    Task { @MainActor [weak self] in
        let result = await Task.detached { ... }.value
        guard let self, token == self.detailToken else { return }
        self.detail = result
    }
}
```
**Why:** If the user clicks version A, waits 100ms, then clicks version B, the slow load for A might land after B's result. The token makes A's result a no-op.

**Rebuild:** Use for any off-main load that can be superseded (search results, file history, remote fetch, …).

---

### 4. Compositor Layering via Named Constants (SideDockCompositing)
**Pattern:** Pin z-order decisions in an enum so a host test can guard the invariant.
```swift
enum SideDockCompositing {
    static let contentColumnZIndex: Double = 0
    static let terminalColumnZIndex: Double = 1
    static var terminalIsAboveContent: Bool {
        terminalColumnZIndex > contentColumnZIndex
    }
}
```
Then in the layout:
```swift
HStack {
    contentColumn.zIndex(SideDockCompositing.contentColumnZIndex)
    terminalColumn.zIndex(SideDockCompositing.terminalColumnZIndex)
}
```
And in the test:
```swift
func test_terminalAlwaysAboveContent() {
    XCTAssert(SideDockCompositing.terminalIsAboveContent)
}
```
**Why:** ImageRenderer false-greens occlusion bugs (doesn't instantiate AppKit layers). Pinning the ordering in a named constant lets a cheap host test fail if someone flips it, catching the logic regression even though pixel proof is VM-only.

**Rebuild:** For any layout with multiple opaque NSViewRepresentable surfaces, centralize z-order as named constants + an invariant guard.

---

### 5. PreferenceKey Anchor Registration (WalkthroughAnchorRegistration)
**Pattern:** Scatter frame-publishing GeometryReaders, gather with PreferenceKey reducer.
```swift
public extension View {
    func walkthroughAnchor(_ surface: WalkthroughAnchorSurface) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WalkthroughAnchorKey.self,
                    value: [surface.id: proxy.frame(in: .walkthroughOverlay)]
                )
            }
        )
    }
}
```
Window-root overlay consumes:
```swift
.onPreferenceChange(WalkthroughAnchorKey.self) { frames in
    anchorFrames = frames  // dict of [surfaceID → CGRect]
}
```
**Why:** Popover anchor targets (sidebar, git panel, editor) live at different depths. PreferenceKey bubbles frames up so the overlay sees them all in one coordinate space. No threading state through every leaf.

**Rebuild:** For any feature that needs to anchor UI at runtime-resolved positions (tooltips, callouts, selection highlights), use PreferenceKey to bubble frames up to the overlay.

---

### 6. Pure-Logic Dwell Math (WalkthroughAutoAdvance)
**Pattern:** Factor timing math into a nonisolated static function so tests don't need Task.sleep.
```swift
public static func effectiveDwell(
    forStepDwell stepDwellSec: Double?,
    speed: Speed,
    defaultStepMs: Double = WalkthroughAutoAdvance.defaultStepMs
) -> Double {
    let baseSec = stepDwellSec ?? (defaultStepMs / 1000.0)
    return max(0.0, baseSec / speed.rawValue)
}
```
**Why:** The scheduling task is async and can't be host-tested cleanly; the math is pure and can. Test suite covers the formula in isolation; the async Task.sleep path is validated on the VM (if needed at all).

**Rebuild:** For any controller with a complex calculation (dwell, throttle, rate-limit, backoff, …), hoist the pure logic into a nonisolated static function.

---

### 7. Nonce-Based Notification (WalkthroughBridge, TerminalModel)
**Pattern:** Publish a nonce counter so the same value can re-fire, and separate channels for independent concerns.
```swift
@Published private(set) var highlight: HighlightRange? = nil
@Published private(set) var highlightNonce: Int = 0

public func requestHighlight(_ range: HighlightRange) {
    highlight = range
    highlightNonce &+= 1  // bump even if range == oldRange
}
```
View animates on nonce change:
```swift
.onChange(of: bridge.highlightNonce) { _, nonce in
    triggerHighlight(nonce: nonce)
}
```
**Why:** Allows re-issuing the same target (e.g., highlight lines 10–20 of the same file again) and re-triggering animation without changing the value. Multiple independent channels (highlight / flash / popover / diagram) let one concern change without needlessly churning others.

**Rebuild:** Any time you need "the same action issued twice should run twice," use nonce counters. For throttled update channels, separate @Published for different concerns (terminal: outputVersion separate from topologyVersion).

---

## Anti-Patterns & Regrets

### 1. **Broad objectWillChange Forwarding** (avoided in Git, but a footgun elsewhere)
Do NOT do:
```swift
@ObservedObject var sidebar: SidebarModel
var objectWillChange: ObservedObjectPublisher { sidebar.objectWillChange }
```
**Cost:** One sidebar redraw republishes the entire DocumentModel tree. With FSEvents firing + a screen full of rows, this cascades.

**Lesson:** Observe narrow channels (TrackedReposChannel, not DocumentModel). If you need multiple upstream publishers, fold them into a coordinator that emits only when something observable changed.

---

### 2. **Stale Per-Frame Deep Comparisons** (TerminalNSView lesson)
Do NOT do:
```swift
if screen != newScreen { needsDisplay = true }  // O(rows × cols) on main thread
```
**Cost:** When a burst of PTY output fills scrollback, the deep compare of ~1000 cells runs on the main thread every frame and ANRs.

**Lesson:** Use version/generation counters as the "changed?" signal. TerminalNSView gates install on `version`, not `screen !=`.

---

### 3. **Naive SignalSafety in PTY Spawn**
Do NOT do:
```swift
if pid == 0 {
    let shellPath = resolveShell()  // String bridging — DEADLOCK
    execve(shellPath.utf8String, ...)
}
```
**Cost:** A malloc lock held elsewhere can cause the child to deadlock.

**Lesson:** Precompute all C strings in the parent BEFORE fork. Spend tokens pre-fork on building argv + envp + path, not on bridging in the child.

---

### 4. **Killing Processes by Executable Name**
Do NOT do:
```swift
system("killall MarkdownViewer")  // kills the owner's running app too
```
**Cost:** Accidental termination of the user's instance.

**Lesson:** Tag test instances (`MDV_TEST_INSTANCE=1`) and reap by tag (or PID). AppLauncher.killTestInstances() is the right pattern.

---

### 5. **Opaque Representable Occlusion (TSK-488)**
Do NOT do:
```swift
HStack {
    swiftUIView.opacity(0.5)        // Occluded!
    NSViewRepresentable()            // Opaque AppKit layer
}
```
**Cost:** The NSViewRepresentable's CALayer composites ON TOP of SwiftUI's paint, regardless of order. The SwiftUI view is invisible on screen but present in the tree (ImageRenderer false-greens).

**Lesson:** Give occluded siblings their own compositing group + explicit z-order: `swiftUIView.compositingGroup().zIndex(1)` vs `representable.zIndex(0)`. Host-test the ordering via named constants (SideDockCompositing pattern).

---

## Gotchas & Surprises

### 1. **Menu Enable-State Sync Trap**
Menu validation happens VERY frequently — every menu open, every mouse hover. Forking git per validation stalls the main thread. FileHistoryAvailabilityCache solves this with a cached answer + off-main probe.

### 2. **Sorted Sidebar Invalidates Root Cache**
RepoFocusTracker.rootCache maps `parentDir → repo root?`. If the sidebar changes (e.g., user navigates to a different folder in Finder), a stale root can surface. Solution: Invalidate on FSEvents `.git` create/delete.

### 3. **Tab Switch View Recreation (TSK-489)**
TerminalPaneView uses `.id(selectedTabID)` on TerminalRepresentable, which recreates the NSView on tab switch. Scroll offset MUST live on the model, not the view, or it resets to 0. Same issue for split panes.

### 4. **OSC-7 Async Report Race**
TerminalModel.currentWorkingDirectory updates when the shell emits OSC 7. If the shell doesn't report (a quiet tab, a non-compliant shell), it stays at initialWorkingDirectory. TerminalPaneStore.wireCwdPersistence guards the write only on actual change.

### 5. **Swift 6 Concurrency on VM**
Swift 6.1.2 (VM default) can't compile the test target due to `try await super.setUp()` sending non-Sendable self. Must use 6.3. The scripts/test-in-vm.sh auto-selects 6.3 via TOOLCHAINS env var.

### 6. **Walkthrough Engine is Modal**
The engine can only play one script at a time (no nested walkthroughs). Stopping one clears pendingAwaitUser + all bridge state. Multi-script queueing is a future feature.

### 7. **Diagram Illustration Occlusion (TSK-1334)**
WalkthroughMermaidWebView renders Mermaid in a WKWebView. The view is occlusion-class (TSK-488): without explicit zIndex, the caption sibling is invisible. Wiring this into WalkthroughDiagramOverlay + T5-pixel validation is a pending atomic unit.

---

## Rebuild Notes

### Approach

1. **Git Panel:** A mature feature with broad coverage. Can be ported nearly as-is, with simplifications:
   - Collapse FileHistoryView + UnifiedHistoryView into a single history view (both are master-detail + selection machine + diff rendering).
   - Unify the log-search path (git grep via ViewerCore).
   - The multi-repo registry (RepoFocusTracker + TrackedReposChannel) is production-grade and worth keeping.

2. **Terminal:** The core PTY + parser is reusable; the UI is AppKit-specific and would need rewriting for a new platform:
   - PTYProcess.forkpty + signal-safe spawn plan are portable.
   - ANSI parsing (off-main on serial queue, throttled publishes) is platform-free.
   - Direct-drawing NSView rendering is macOS-only; a web/TUI version would use different rendering.
   - Tmux -CC integration (TmuxController + core) is a strong foundation for nested-split support.

3. **Walkthrough:** Clean separation of concerns (pure engine + delegate + bridge + UI). Port as-is:
   - ViewerCore.WalkthroughEngine is transport / narrative engine (pure, testable).
   - WalkthroughPlayerImpl is the app-specific delegate (trivial to adapt to a new UI framework).
   - WalkthroughBridge is the nonce-channel hub (generalizable).
   - Visual overlays (highlight, popover, diagram) are SwiftUI-specific but the coordinate math (PreferenceKey anchors) is a clean pattern.

### What to Design Upfront

1. **Multi-repo concurrency:** RepoFocusTracker is a demand-driven coordinator. Design the file-system-watcher integration early (FSEvents or equivalent on the target platform).

2. **Off-main decode discipline:** Terminal performance depends on NOT parsing ANSI on the main thread. Architecture the parser as a separate actor / thread from the start.

3. **Compositor z-order and layering:** If the new platform uses a compositor (web/Electron/Qt/etc.), early design for explicit z-order and test it. Don't assume paint order.

4. **Persistent state lifecycle:** Git panel (cwd per tab) + Terminal (scroll offset, cwd, tabs) + Walkthrough (last-played script) all persist. Design the session persistence path upfront so restore-on-relaunch works.

5. **Async-sync boundary:** Git operations fork subprocesses; Terminal forks shells; both need careful boundaries (sync gates, async probes, callbacks). Early design of the concurrency model.

---

## Summary

This slice demonstrates **production-grade iOS/macOS UI patterns** applied to three high-complexity features:

- **Narrow observation channels** prevent republish storms (PERF #1).
- **Off-main work + token-guarded results** keep the main thread responsive.
- **Compositor layering via named constants** catches occlusion regressions with host tests.
- **Nonce-based notification** allows re-issuing the same action.
- **Pure-logic seams** (dwell math, diagram presentation, anchor registration) enable clean testing.
- **Signal-safe fork discipline** (PTY spawn) prevents deadlock.
- **PreferenceKey anchor registration** avoids threading state through the tree.

The code is mature, well-factored, and most patterns are **worth porting intact** to a greenfield app, especially the observation discipline, async patterns, and testing seams.
