<!-- CLAUDE-HANDOFF v1 -->
# Handoff — 2026-08-22 full day: UX batch + dead band + split-cycling fixes (23:00)

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · main @ `55df2e66`
(ALL CI-green; tree clean but for the 4 protected untracked: OwnerWishlist.md[.bak],
Untitled.txt, archive/Untitled.txt — NEVER touch). /Applications = `1fa35538`-era
build (22:34). CI loop = background Monitor per commit; NEVER wait.
tasked board OFFLINE — BACKLOG + commits are the record. **VM is RUNNING again**
(restarted 22:20; AX suites 6/6 green on the final build).

## Mission
Owner-driven interactive push. 2026-08-22 arcs: the 5-item UX batch (ghosts,
swallowed clicks, pointer flicker, stale previews, pill separator), then the
tab-strip DEAD BAND root-cause, then the split-view tab-cycling repro fixes.
(Earlier: startup 5.6s→0.53s, 2026-08-16.)

## Current state — all DONE & CI-green
- **Dead band** (`0dafe31a`): the empty-NSToolbar traffic-light spacer laid a
  66pt invisible titlebar hit container over the 46pt session band — ~20px of
  the tab strip swallowed clicks ("dead spots right above the text"). Toolbar
  gone; `TrafficLightCenterer` (new file) repositions the standard buttons
  (~3px above perfect center due to the hit-test clamp — owner may comment).
- **Split-view cycling** (`1fa35538`): ⌃Tab/⌘] now cycle within the FOCUSED
  pane's strip order while split (was flat store order — hopped panes, yanked
  focus, first responder fell to a session pill = the focus-ring screenshot).
  Chrome (chips+pills) `.focusable(false)` + `.focusEffectDisabled()`.
- **Stuck-drag WATCHDOG** (`1fa35538`): heavy re-renders cancel DragGestures
  silently IN PLACE (no onEnded, no disappear, ids unchanged) — a 250ms
  physical-button poll now reaps any dead drag (state + pill highlight +
  click suppression). Kills the screenshot ghost from ANY cause.
- **5-item batch** (`f95651ed`): drag-ghost guards, micro-drag click disarm,
  ALL NSCursor sites → `.pointerStyle` (CM6 flicker, I-07 ph2 done), stale
  previews (unfocused-pane watchers `syncPaneFileWatchers` + Split diskStamp;
  selected-tab chain PROVEN by `RenderedPreviewStalenessTests`), pill
  separator removed.
- **Chrome-pin family migration COMPLETE** (`bae242bd`, `55df2e66`): under
  the 18-worker gate, starved async stragglers + measurement-coupled pane
  chrome land benign bodies in retry windows — pins now hard-zero ONLY on
  model-only observers (StatusBar, BottomAttributesBar), ≤1 storm bounds on
  ContentToolbar/PaneTabStrip/SidebarView. Three incidents, all migrated.

## Key decisions & rationale
- Never NSCursor.push() in hover sites; never titlebar-inflating chrome
  (toolbars/accessories) taller than the band our UI draws — probe the
  container (`standardWindowButton(.closeButton).superview…` headless).
- Every sticky gesture gets a liveness watchdog (physical-button poll), not
  just disappear/identity guards.
- "The current X" singletons must be audited when visibility multiplies:
  watcher ✓, cycling ✓, focus loop ✓ — find/diagnostics unchecked.
- Publish gating: textview_dist HOLDS for the owner's hands-on verdict
  (last published 2026-08-12-v2; head is ~17 commits ahead).

## Gotchas (full text in LESSONS.md 2026-08-22 tail)
- os_log `.info` not persisted; DragGesture no-cancel; micro-drag suppression
  revoke; visible ≠ selected singletons; toolbar-spacer hit container;
  silent in-place gesture cancellation → watchdog pattern.

## Files that matter
- `Sources/MarkdownViewer/TrafficLightCenterer.swift` — the no-toolbar centering.
- `Sources/ViewerUI/DocumentModel+TabNavigation.swift:25` — pane-scoped cycleTab.
- `Sources/ViewerUI/StripDragReorder.swift` — guards + watchdog + disarm.
- `Sources/ViewerUI/DocumentModel+Panes.swift` — syncPaneFileWatchers.
- `Sources/ViewerUI/HoverCursorBalance.swift` — pointerStyle bridge.
- `Sources/ViewerCore/StartupTrace.swift` + App Support/startup-trace.log.
- `Tests/ViewerUITests/RenderedPreviewStalenessTests.swift` + the cycling pins
  in `TabCoordinatorPaneTests`.

## Open questions / blockers
- **AWAITING owner verdict**: does the screenshot ghost / dead-spot / cycling
  behavior feel fixed on the installed build? Traffic lights sit ~3px high —
  acceptable? If the ghost EVER recurs: get the exact gesture sequence; the
  watchdog should make it impossible, so a recurrence means a NEW renderer.
- **textview_dist publish** on verdict ⇒ `TextView-2026-08-22.zip` (ditto+sha+
  README recipe, key-in-place GIT_SSH).
- BACKLOG queue: focused-tab WebView staleness (only if owner still sees it —
  model chain proven; needs VM webview repro), diagnostic-artifact subdir,
  safe-save `.sb-*` litter, LocalHistory global cap + save re-reads, MCP
  fall-through twin, gutter AX materialization, dead `TabBar` deletion
  (rehome computedTabWidth/tabsAreCrowded first — PaneTabStrip calls them).

## How to resume
1. `git log --oneline -10` · `git status --short` (only the 4 protected).
2. Owner feedback drives: ghost recurrence → new renderer hunt (VM is UP:
   rsync → `ssh macOS15 'cd markdown_viewer && touch rust-core/link/*.a &&
   bash scripts/build-app.sh debug'` → scenes/AX per scripts/vm-uitest.sh).
   Verdict good → dist publish. Otherwise: I-20 gap-matrix audit, mermaid
   zoom clip, AutoSave, BACKLOG residues.
3. Startup regressions: read App Support/MarkdownViewer/startup-trace.log.
4. Mirror per round: CloudDocs clone `fetch <repo> main` + `merge --ff-only
   FETCH_HEAD` (post-amend: `reset --hard`). Install-on-ask = NOW; say
   "⌘Q + relaunch". Commits carry the Claude-Session trailer.
