<!-- CLAUDE-HANDOFF v1 -->
# Handoff — owner UX marathon: left shoulder reworked; NEXT = bottom dock (2026-08-09 04:45)

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · **branch/SHA:** main @
`11967e90` (this handoff's doc edits uncommitted at write time — commit them with this
file). /Applications/TextView.app = RELEASE @ `11967e90` (installed 04:30; owner may still
need ⌘Q+relaunch). CI loop: GREEN through the `71769ff9` checkpoint (fix-forward on red).
tasked board UNREACHABLE all session — BACKLOG + commit messages are the state of record;
ticket debt keeps accruing for reconnect. A local SITE test server may still be running:
`python3 -m http.server 8931` in the CloudDocs josangel.com dir → http://localhost:8931/
(homepage + /textview/ + /blog/) — kill or reuse. Owner-mode memory:
`feedback_interactive_drive_mode` (mid-turn batches, install-on-ask, the ⌘Q-relaunch
trap, full-accent styling).

## Mission
Owner-driven interactive drain (owner active, sending batches). Two arcs this session:
(1) launch-site/marketing polish (done); (2) a large owner UX batch culminating in the
LEFT-SHOULDER STRUCTURAL REWORK (done). **Explicitly queued next arc: BOTTOM DOCK
REWORK** — BACKLOG "★ BOTTOM DOCK REWORK" (tabs, resizable height, terminal demoted to a
regular tool window).

## Current state
- **Done + VM-pixel-verified:** one-rule sidebar stack (`SidebarStackLayout` + rewritten
  `SidebarView.sidebarBody`): uniform panels incl. plugins, layout-flexible
  [26pt…stored] heights, flex fill (FILES or last panel), sum-preserving pair dividers
  (floors only — the 50% dual-split wall is GONE), floor-bounded flex-boundary divider,
  outer scroll engages ONLY at constant compressed minimums; visible 12px gutter bands
  with grabber pills (no white→line→white seam); distinct tinted headers; per-panel
  `.clipped()` (the "Nothing staged over the footer" bleed); no white gap above file nav;
  full-accent active rows (file nav / current bookmark / selected log commit,
  `Palette.selectedRowText`); accent bar atop the active tab; dark diff washes quieter;
  git log search padding.
- **Done + host-tested (owner eyeball still pending):** hex edit caret now PAINTED
  (was invisible — zero-length selection in a non-editable NSTextView draws no beam) +
  hex↔ascii tandem selection (`HexCaretTandemTests`, 4 tests); session-switch HUD
  (`activateWithHUD` gesture variants — the coordinator stays synchronous);
  empty-shoulder drag placeholder (`PanelDragMonitor` — TSK-1316's reveal was never
  wired); settings one-column alignment (pickers centered in maxWidth frames); preview
  files italic-not-bold in file nav; tooltip placement (converts through `.tooltipRoot`
  — bubbles drew a titlebar-height too high, covering the hovered control).
- **In flight:** nothing half-written. Tree = LESSONS/BACKLOG/HANDOFF edits only.
- **Next action:** commit the handoff docs; then start the BOTTOM DOCK REWORK
  (BACKLOG "★ BOTTOM DOCK REWORK" carries the full spec + surface list).

## Key decisions & rationale
- **Layout over arithmetic** for panel sizing: two arithmetic attempts (fillHeight with
  chrome estimates; resolve()-driven rigid frames) produced double scrollbars / dead
  bands / chrome push. Final: panels flexible `[compressedMin…stored]` by SwiftUI layout;
  the only remaining arithmetic uses constants (`stackTargetHeight`) so drift is
  impossible.
- **HUD deferral lives at the gesture site** (`activateWithHUD`), never in
  `SessionsAppCoordinator.activate` — the synchronous contract is load-bearing for
  tests, scenes, and the CLI verb (deferral-in-core broke the session suite instantly).
- **Semantic colors only in chrome** — HardCodedColorRatchet enforces;
  `Palette.selectedRowText` (alternateSelectedControlTextColor) = white-on-accent.
- **Marketing scenes pin their world**: `MDV_FORCE_APPEARANCE`/`MDV_FORCE_THEME_ID`,
  zoom 1.0, parked pointer, explicit full sidebar set, session dance + delayed re-assert
  (session activation RESTORES that session's panel layout).

## Gotchas (full text in LESSONS.md, all 2026-08-09)
- Full parallel `swift test` sweep on a loaded host → "Bad file descriptor" floods
  (7-10 fails); re-run failures TARGETED before believing any.
- `ToolPanelBoundingTests` = the chrome-push teeth; keep it green through any sidebar
  layout change (it caught two of my cuts).
- Ratchet tests grep raw source — comments containing banned tokens trip them.
- The VM repo has full git history now (packs synced once 2026-08-08; re-sync after a
  host `git gc`).

## Files that matter
- `Sources/ViewerCore/SidebarStackLayout.swift` — resolve()/boundaryMax pure logic.
- `Sources/ViewerUI/SidebarView.swift` — sidebarBody one-rule stack (~lines 150-215),
  `stackTargetHeight`, `resolvedStack`, `stackedPanel`.
- `Sources/ViewerUI/SidebarConstants.swift` — `SidebarSectionBodyFrame` (`.infinity`
  sentinel + `compressedMinHeight` 26), header tint, `headerRowHeight`.
- `Sources/ViewerUI/ResizableSectionDivider.swift` — gutter band + `bounded()` writes.
- `Sources/ViewerUI/HexView.swift` — caret paint + tandem mirror (~lines 1090-1210).
- `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift` — `activateWithHUD` family.
- `Sources/ViewerUI/DockedToolWindow.swift` — `PanelDragMonitor` + drop zones;
  `BottomDockContainer` + SettingsView terminal section = the Phase-2 targets.
- `scripts/vm-uitest/aqua-runner.sh` — per-scene env pins + `host-screen` mode
  (captures the LIVE VM screen for owner-window inspections).

## Open questions / blockers
- tasked board offline (all of 08-08 + 08-09) — many commits owe tickets on reconnect.
- Owner-eyeball tail (BACKLOG item): hex caret, session HUD, drag placeholder, settings
  grid — ten-second checks on the installed app.
- OSS-prep queue (BACKLOG O-1..O-6) untouched today; `git-filter-repo` still needs owner
  dep-approval when that resumes.

## How to resume
1. `git -C /Users/me/Documents/workspaces/claude/markdown_viewer log --oneline -14`
   (head ≈ `11967e90` + the handoff commit) · `git status --short` (only the 4 protected
   untracked files).
2. Confirm the CI-loop Monitor is alive (events `CI <sha> GATE rc=<n>`); if the session
   lost it, re-arm per memory `ci-background-loop`. Red → fix forward, then install.
3. Start the bottom-dock rework from BACKLOG "★ BOTTOM DOCK REWORK": read
   `BottomDockContainer`/`DockedToolWindow` + the terminal special-casing list; mirror
   the SidebarStackLayout pattern; tests + VM captures per change; commit per round;
   mirror-refresh (fetch + `merge --ff-only FETCH_HEAD` from the CloudDocs side) each
   round; release-install only after that commit's CI is green.
4. VM lane: rsync (excludes .build/dist) → `ssh macOS15 'cd markdown_viewer && touch
   rust-core/link/*.a && bash scripts/build-app.sh debug'` → `MDV_VM_SUDO_PASS=<vm-sudo-password> bash
   scripts/vm-uitest.sh run <scene>` → Read the PNG. Fill-check scenes = sidebar teeth.
