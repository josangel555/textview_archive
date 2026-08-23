<!-- CLAUDE-HANDOFF v1 -->
# Handoff — startup 10× fix + 2026-08-22 UX batch + dead-band fix (2026-08-22 ~22:30)

**POST-CHECKPOINT ADDENDUM**: main @ `a3f7b51b` (CI-green, installed 22:09) —
the tab-strip DEAD BAND root cause: the empty-NSToolbar traffic-light spacer
laid out a 66pt invisible titlebar hit container over the 46pt session band,
swallowing clicks ~20px into the strip ("dead spots right above the text").
Toolbar removed; `TrafficLightCenterer` (new file) repositions the buttons
directly (~3px above perfect center due to the clamp — owner may comment).
Awaiting owner confirmation the dead spots are gone.

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · main @ `f95651ed`
(ALL CI-green; tree clean but for the 4 protected untracked: OwnerWishlist.md[.bak],
Untitled.txt, archive/Untitled.txt — NEVER touch). /Applications = f95651ed (21:51).
CI loop = background Monitor per commit; NEVER wait; installs ride green lines.
tasked board OFFLINE all month — BACKLOG + commit messages are the record.
**UTM VM is STOPPED** (since ~08-16 host reboot) — no VM lanes until restarted.

## Mission
Owner-driven interactive push. Since the last checkpoint: the startup-stall
investigation (5.6s → 0.53s to interactive, ROOT-CAUSED with a permanent
diagnosis kit) and a 5-item UX batch (drag ghosts, swallowed clicks, pointer
flicker, stale previews, pill separator).

## Current state — all DONE & CI-green
- **Startup**: `cleanStaleDiagnosticArtifacts()` enumerated the WHOLE per-user
  tmpdir (299k entries/638MB) on main in didFinishLaunching → detached utility
  task. Verified on the owner's machine: first runloop turn 5,627→531ms.
  Permanent kit: `StartupTrace` (unified-log `.notice` + App Support/
  startup-trace.log + signposts) brackets every launch.
- **2026-08-22 batch** (`f95651ed`): stuck mid-drag chip guards
  (stripReorderable onDisappear/ids-change clears state — DragGesture has no
  cancel callback); micro-drag (<10px) no-op drops DISARM click suppression
  ("clicks don't register" fix); ALL 7 NSCursor push/pop sites →
  `.pointerStyle` (`resizePointer(vertical:)` — the CM6 flicker fix, I-07
  phase 2 done); stale previews: unfocused-pane front files now WATCHED
  (`syncPaneFileWatchers`, DocumentModel+Panes; clean tabs auto-reload —
  live FSEvents test) + in-tab Split preview disk read keyed url+mtime
  (`SplitPaneView.diskStamp`); session pill separator removed.
- `RenderedPreviewStalenessTests` PROVES the selected-tab reload→cache-bust→
  re-render chain correct (incl. same-length mtime-only edits).
- Earlier (08-16): trace `.info`→`.notice` (info evaporates); StartupTrace
  routed through TestStateRedirect (drift guard caught it); chrome re-body
  pins re-scoped honest (hard-zero = StatusBar/BottomAttributesBar only;
  measurement-coupled ContentToolbar/PaneTabStrip ≤1).

## Key decisions & rationale
- Diagnosis pipeline for perf reports: StartupTrace milestones → rusage poll
  → `sample` armed on next launch. All host-safe, no windows. MEASURE first.
- Never `NSCursor.push()` in hover sites — `.pointerStyle` only (leak-by-
  missed-exit fights WKWebView). `hoverCursor` keeps an NSCursor param shim.
- Publish gating: textview_dist waits for the owner's hands-on verdict
  (HOLD stands — last published 2026-08-12-v2; head is ~12 commits ahead).

## Gotchas (full text in LESSONS.md 2026-08-16/22 tail)
- os_log `.info` is NOT persisted — `.notice` or a file.
- DragGesture: no cancellation callback — guard every sticky drag state.
- Suppression armed at drag-start must be revoked for micro-drag clicks.
- "The current X" singletons (watcher/find/diagnostics) break silently when
  panes make visible ≠ selected — audit on any visibility-multiplying feature.
- Never enumerate a shared system dir wholesale; app litter in app-owned subdirs.
- 9 `--mcp-connect` processes with LIVING parents = legitimate live Claude
  sessions, not orphans; 2 are permanent headless twins (fall-through bug,
  BACKLOG).

## Files that matter
- `Sources/ViewerCore/StartupTrace.swift` — the launch-timeline kit.
- `Sources/MarkdownViewer/Diagnostics.swift:56` — the off-main sweep.
- `Sources/ViewerUI/StripDragReorder.swift` — drag guards + suppression disarm.
- `Sources/ViewerUI/HoverCursorBalance.swift` — `.pointerStyle` bridge
  (`hoverCursor`/`resizePointer`).
- `Sources/ViewerUI/DocumentModel+Panes.swift` — `syncPaneFileWatchers()`
  (called from updateDerived + pane verbs + resumeFileWatcher).
- `Sources/ViewerUI/SplitPaneView.swift` — `diskStamp` cache-bust key.
- `Tests/ViewerUITests/RenderedPreviewStalenessTests.swift` — the staleness pins.

## Open questions / blockers
- **textview_dist publish HOLD** — owner verdict on the batch, then pack
  `TextView-2026-08-22.zip` (ditto+sha+README recipe, key-in-place GIT_SSH).
- **VM stopped** — owed when back: pixel pass on strip/pill changes; the
  focused-tab WebView staleness repro IF the owner still sees it; the
  fill/panes scene sweeps. Start via UTM app or `utmctl start "macOS 15"`.
- BACKLOG queue: bounded diagnostic-artifact subdir, safe-save `.sb-*` litter
  (315×history.json), LocalHistory global cap + save-path re-reads (~100MB
  per Kobol save — the owner's "526MB read"), 138KB session snapshot,
  MCP fall-through headless twin, gutter AX materialization, dead `TabBar`
  deletion (rehome computedTabWidth/tabsAreCrowded first).

## How to resume
1. `git log --oneline -10` · `git status --short` (only the 4 protected).
2. Owner reports stale previews on the FOCUSED tab? Model chain is proven —
   go straight to a VM webview repro (start the VM first). Otherwise next
   queue: I-20 gap-matrix audit, mermaid zoom clip, AutoSave, BACKLOG above.
3. Startup feels slow again? `cat ~/Library/Application Support/
   MarkdownViewer/startup-trace.log` — the timeline names the span.
4. VM lane (once started): rsync → `ssh macOS15 'cd markdown_viewer && touch
   rust-core/link/*.a && bash scripts/build-app.sh debug'` →
   `MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/vm-uitest.sh run <scene>`.
5. Mirror per round: CloudDocs clone `fetch <repo> main` + `merge --ff-only
   FETCH_HEAD` (post-amend: `reset --hard FETCH_HEAD`). Install-on-ask = NOW;
   say "⌘Q + relaunch". Commits carry the Claude-Session trailer.
