<!-- CLAUDE-HANDOFF v1 -->
# Handoff — panes epic COMPLETE + resize FINAL SPEC landed (2026-08-15)

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · main @ `f95a3f97`
(ALL CI-green; tree clean but for the 4 protected untracked: OwnerWishlist.md[.bak],
Untitled.txt, archive/Untitled.txt — NEVER touch). /Applications = f95a3f97 (02:45).
CI loop = background Monitor, per-commit lines; NEVER wait on it; installs on green.
tasked board OFFLINE all week — BACKLOG + commit messages are the record.

## Mission
Owner-driven interactive push. This stretch: the EDITOR PANES epic (I-21) end-to-end,
then an owner-driven sidebar-resize overhaul (4 rounds to the FINAL SPEC), plus chrome
polish batches. Dist publishes: TextView-2026-08-12{,-v2}.zip on textview_dist.

## Current state — all DONE & CI-green
- **Panes epic (I-21)**: model→coordinator→render→orientation→persistence→
  interactions→per-pane toolbar→GENERALIZATION (the window TabBar + window
  ContentToolbar are UNMOUNTED; un-split = one pane; `PaneTabStrip` is THE strip).
  Split Right/Down, cross-strip drag, click-to-focus (PaneFocusClickMonitor),
  divider resize (weights persist), Split Pane Right/Left context menu, ⌥⌘` cycles.
  Pane verbs route through `DocumentModel+Panes` (full selectTab pipeline — the
  stale-FileNav class).
- **Resize FINAL SPEC (owner, 4 rounds 2026-08-12)**: (1) `DividerDragSession`
  freezes bases AND budgets at drag origin (the live-budget halving loop = the
  "50% wall"); (2) NO auto-shrink → then refined to PROPORTIONAL refit on panel
  open/close (everything stays in view; scroll only below floors); (3) cascade
  DELETED — a pair drag moves THAT boundary only, stops at the floor;
  flex-adjacent dividers trade against origin slack; (4) floor = ZERO
  (`minExpandedHeight = 0`) — no minimum on ANY tool window, FILES' 200pt
  reserve dead, tripwire test pins 0.
- **Chrome batch**: pane strip shrink-to-fit + TSK-304 overflow menu (was silent
  h-scroll), top+bottom hairlines, session pills: grey hairline border (inactive) /
  accent edge (active) / accent-wash hover. Session header = flat windowBackground,
  96pt traffic-light inset.
- **Git panel session leak FIXED**: `resolveFocusedRoot` fallbacks filter to the
  CURRENT demand set (`previousDesired`) — never the app-global LRU/grace leftovers.
- **In-tab markdown split**: renders inside `tabContent` under the pane's toolbar,
  headerless (`SplitPaneView(showsHeader: false)`); the toolbar Split segment is the
  only lifecycle control. Window `splitURL` pane (two files) keeps its header.
- **Flake retired**: `test_sidebarRecencyTick` migrated to `evalsExpectingZero`.

## Key decisions & rationale
- Panes = order+selection OVERLAY on the flat tab store; per-tab display via
  `*(for tab:)` model variants; commands stay selected-tab-routed (mouse-down
  focus makes that correct). App-wide current tab = focused pane's selection.
- EVERY input to base-relative drag math is an ORIGIN snapshot (bases, budgets,
  ceilings) — live inputs feed back into the drag's own writes.
- No special cases for any panel; design constants get re-derived when the
  philosophy changes; one-symbol funnels + tripwire tests.
- Publish gating: after same-day re-fixes, textview_dist WAITS for the owner's
  hands-on verdict (current hold — see below).

## Gotchas (full text in LESSONS.md 2026-08-11/12 tail)
- Stuck VM crash dialogs EAT HID clicks (CGWindowList dump in the AX failure path);
  stray app bundles resurrect + crash-loop — shelve them. The sidebar resize-tooth
  "mystery" was exactly this — resolved, tooth passes 1:1.
- Shapes-only views NEVER materialize out-of-process AX elements (4 attempts).
- Scenes without a `scene_expect` entry fall through to the terminal pixel eval =
  false-pass generator. Register SceneSpec + scene_expect together.
- Tests beside a change encode the CHANGE, not the user's invariant — write the
  spec-level property test FIRST (fits-whenever-floors-fit is the exemplar).
- `PaneTabStrip` calls `TabBar.computedTabWidth/tabsAreCrowded` — rehome before
  deleting the dead `TabBar` struct.

## Files that matter
- `Sources/ViewerCore/PaneAssignment.swift` + `PaneResize.swift` — pane model/resize math.
- `Sources/ViewerUI/PaneTabStrip.swift` — THE tab strip (width-fit, overflow, drags).
- `Sources/ViewerUI/ContentView.swift` — paneAwareContent = the only content path.
- `Sources/ViewerCore/SidebarResize.swift` (`DividerDragSession`) +
  `SidebarStackLayout.swift` (proportional resolve) + `ResizableSectionDivider.swift`.
- `Sources/ViewerUI/Git/RepoFocusTracker.swift:254` — demand-filtered focus fallback.
- `scripts/vm-uitest.sh` — scene_expect table (fill-check-crowded = the 5-panel scene).

## Open questions / blockers
- **textview_dist publish ON HOLD** for the owner's hands-on verdict on the resize
  final spec + floor-zero + chrome batch (last published: 2026-08-12-v2 @ 845d90e1;
  head is 5 commits ahead). Owner says OK ⇒ pack `TextView-2026-08-12-v3.zip` (or
  next date) via the ditto+sha+README recipe, push with the key-in-place GIT_SSH.
- BACKLOG residues: crowded scene mounts 5/6 panels (`.recentlyOpened` override
  doesn't mount its section — its a11y id matched from elsewhere); frames-in-ax-reader;
  gutter AX materialization; dead `TabBar` deletion (rehome the two statics).
- tasked board reconnect ⇒ file the whole week's ticket debt from BACKLOG + git log.

## How to resume
1. `git log --oneline -15` · `git status --short` (only the 4 protected untracked).
2. If the owner verdicts the resize feel: publish the dist refresh (recipe above);
   if a complaint: the whole drag surface is `DividerDragSession` +
   `ResizableSectionDivider.apply` + `SidebarStackLayout.resolve` — instrument
   (delta, base, slack, written, rendered) per frame before theorizing.
3. Next queue: I-20 markdown gap-matrix audit, mermaid non-100%-zoom label clip
   (root-caused, BACKLOG), AutoSave (I-14, unblocked), BACKLOG residues above.
4. VM lane: rsync → `ssh macOS15 'cd markdown_viewer && touch rust-core/link/*.a &&
   bash scripts/build-app.sh debug'` → `MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/vm-uitest.sh
   run <scene>`; scenes: fill-check-crowded, panes-split/down/sessions, tab-session-drop.
5. Mirror after each round: from the CloudDocs clone `fetch <repo> main` +
   `merge --ff-only FETCH_HEAD` (post-amend: `reset --hard FETCH_HEAD`).
6. Install-on-ask = NOW; always say "⌘Q + relaunch". Commits carry the
   Claude-Session trailer. No inline full gates — the CI loop reports per commit.
