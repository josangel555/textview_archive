<!-- CLAUDE-HANDOFF v1 -->
# Handoff — EDITOR PANES epic S1–S4b LANDED; S4c drag remains (2026-08-11 ~04:15)

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · main @ the S4a+S4b
commit ("Split Editor Down + pane layouts persist") — `git log --oneline -12` shows the
whole arc. CI loop gates each head in the background (NEVER wait on it / no inline full
gates — owner re-directive 2026-08-11, memory `ci-background-loop`); installs ride its
green notifications. /Applications = the S3 head (panes usable; the S4a/S4b head installs
on its green line). tasked board OFFLINE all week — BACKLOG + commits are the record.

## Mission
Owner-driven interactive feature push. This session: dist publish (TextView-2026-08-11
on textview_dist), O-6 flush-before-read data-loss fix, I-19 per-tab split preview,
I-20 links slice, and the ★ EDITOR PANES epic (I-21) — "panes which contain tabs".

## Current state — the panes epic (BACKLOG I-21 has full detail)
- **S1 model** ✓ `PaneAssignment` (ViewerCore, pure): panes[{id,tabIDs,selectedTabID}]
  + focusedPaneID + orientation; ops split/close-absorbs/move/select-focuses/didOpen/
  didClose; `normalized(against:)` = the reconciliation safety net. 15-test suite.
- **S2 coordinator** ✓ TabCoordinator publishes the assignment; `syncPaneAssignment()`
  reconciles after EVERY mutation primitive; single-pane mirrors the store byte-for-byte
  (`mirrorSinglePane`); verbs splitFocusedPane(movingSelected:direction:)/focusPane
  (drives app selection)/closePane/movePaneTab. `TabCoordinatorPaneTests`.
- **S3 render** ✓ split ⇒ AnyLayout H/V run of pane columns: `PaneTabStrip` (TabBarItem
  chips; actions resolve STORE indices at click time; Close Pane button) + the mounted
  ZStack filtered per pane, visibility on the PANE's selection, find/active gating on
  the FOCUSED pane; focused ring; window TabBar stands down while split. Menu: View ▸
  Split Editor Right / Split Editor Down / Close Pane.
- **S4a orientation** ✓ first split picks the axis; `normalized()` carries it (dropping
  it was a latent reset — LESSONS).
- **S4b persistence** ✓ `SessionSnapshot.PaneLayoutState` by FILE PATH (ids re-mint on
  restore); captured in makeSnapshot (nil un-split), applied LAST in hydrate; carried in
  `with()` + `hasSamePersistedContent`. "Split, quit, reopen ⇒ splits back."
- **VM-verified**: `panes-split` + `panes-down` scenes PASS on real AX ids
  (mdv.paneStrip[.focused], mdv.pane.close) and were eyeballed (side-by-side + stacked).
- **S4c REMAINING**: cross-strip tab DRAG (model op `movePaneTab` exists; wire the
  strip drag — the `StripExternalTarget` tab→session-pill pattern is the substrate),
  content-click focuses the pane (strip clicks focus today; WKWebView clicks don't),
  pane divider drag-resize (panes share space equally now), per-pane ContentToolbar
  decision, keyboard focus-next-pane command. Mixed-axis GRIDS = future split-tree.

## Also landed this session (earlier arcs, all CI-green + installed)
- O-6 flush-before-read: nonce'd flushChanges→flushAck + CMEditorTextSync bounded wait
  at ⌘W/⌘Q/switch/menu-save + page blur/hide self-flush. Webview ordering teeth.
- I-19: Split preview is PER-TAB state (Tab.isSplitEditing; window pane = two-file only).
- I-20 links slice: absolute file/folder paths pinned; `other.md#heading` scrolls to the
  heading (gotoLine selectLength end-to-end; markdown coerces rendered→editor).
- Dist publish: TextView-2026-08-11.zip on github.com/josangel555/textview_dist.
- Round-2 owner batch (sidebar divider snap+cascade, global dock placement, search
  grouping/jump, press feedback, concise footer, centered traffic lights).

## Key decisions
- Panes are an ORDER+SELECTION OVERLAY on the single flat tab store — no ownership
  migration; `normalized()` absorbs every store mutation. App "current tab" = focused
  pane's selection. Single-axis v1 (orientation), not a split tree.
- Pane persistence by PATH, never tab id (ids re-mint on restore).
- CI: background loop only; report at commit; install on green lines; NEVER block work.

## Gotchas (LESSONS.md 2026-08-11 tail)
- Rebuild-constructor paths drop new struct fields (orientation reset; with() family).
- New MDV_UI_SCENE ids MUST be in UISceneRegistry.staticScenes or the applier never
  runs (capture silently shows leftover state).
- A "fix didn't work on the VM" verdict is void until the fix is PROVEN in the walked
  binary (the right-side AX void was "unfixable" against a stale build).
- Don't pump the runloop inside a WKScriptMessageHandler callback (flush design).

## How to resume
1. `git log --oneline -12` · `git status --short` (only the 4 protected untracked).
2. Watch the CI line for the S4a+S4b head → green ⇒ `bash scripts/build-app.sh release
   --install` (owner: ⌘Q+relaunch). Red ⇒ fix forward (pin suites are the usual).
3. Next work: **S4c cross-strip drag** (see I-21 in BACKLOG) or the owner's next batch.
   Then: I-20 gap-matrix audit, mermaid zoom clip, AutoSave (unblocked).
4. VM lane: rsync → `ssh macOS15 'cd markdown_viewer && touch rust-core/link/*.a &&
   bash scripts/build-app.sh debug'` → `MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/vm-uitest.sh
   run <scene>`; scenes: panes-split, panes-down, mktg-split, terminal-dock-right.
5. Mirror after each round: from the CloudDocs clone, `fetch <repo> main` +
   `merge --ff-only FETCH_HEAD`. Board still offline — keep BACKLOG authoritative.
