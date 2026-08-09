<!-- CLAUDE-HANDOFF v1 -->
# Handoff — bottom-dock rework LANDED (tabs + terminal demotion) (2026-08-09 05:40)

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · **branch/SHA:** main @
`d0782617` + the fix-forward commit carrying this handoff (CI: `0c417c26` GREEN,
`d0782617` RED → fixed forward in that commit — two missed suites, see below).
/Applications/TextView.app = RELEASE @ `11967e90` (PRE-rework — install a fresh release
only after the fix-forward commit's CI line is rc=0). tasked board UNREACHABLE (3rd day)
— BACKLOG + commit messages are the state of record.

## Mission
Owner-driven interactive drain. This session (post-compaction) executed the owner's
explicitly queued Phase 2: **the BOTTOM DOCK REWORK — done end-to-end** (spec was
BACKLOG "★ BOTTOM DOCK REWORK", now marked LANDED with residue).

## Current state
- **Commit 1 (`0c417c26`, CI GREEN): bottom dock = TABS.** One panel visible behind a
  tab strip (`BottomDockTabs.resolve`, selection persisted, hidden-choice → first);
  ONE shared band height (`PanelLayoutStore.bottomBandHeight`) dragged from a 12px
  gutter+pill (sidebar divider idiom); chips = drag sources + move menu; strip carries
  move/hide for the selected panel. `DockedToolWindow` lost its bottom-band plumbing
  (right dock unchanged).
- **Commit 2 (`d0782617`, CI RED → fixed forward): terminal = REGULAR tool window.**
  `SidebarPanelKind.terminal` + `preferredDefaultEdge` (.bottom; a NEW per-panel
  default layered under the global default — every PanelEdgeAssignment normalization
  site resolves per-panel now); presence hard-false = user-summoned (`.auto` → hidden,
  toggle forces `.shown`); body = `TerminalPanelSection` via `SidebarPanelBody` (works
  in bottom tabs / right dock / left accordion); one-shot `TerminalPanelMigration`
  (legacy isOpen/paneEdge keys read literally + marker) keeps a previously-open pane
  open in the same dock. DELETED: TerminalToggleButton, TerminalPaneEdge + bridge +
  Settings placement rows, TerminalDragPayload/DropZone + its Info.plist UTI,
  sideTerminalColumn + both terminal resize handles, in-pane dock/close controls.
  ⌃` toggles the panel; last-shell-tab close hides the window (`onLastTabClosed`
  wired in DocumentModel). Scenes drive placement through PanelLayoutStore.
- **CI red on commit 2 — cause + fix (in the fix-forward commit):** two suites my
  targeted filter missed: `PanelEdgeTests` (5 "all panels on left" list pins — now
  exclude terminal / expect it on bottom) and `ResizeGestureSpaceAuditTests` (its
  manifest expected 2 DragGestures in TerminalView.swift — both handles deleted;
  entry removed, DockedToolWindow stays at 2 = right edge handle + dock gutter).
- **VM render rung DONE (partial T6, eyeballed):** `terminal` scene = tabbed band
  (gutter+pill, accent Terminal tab, move/hide, section header + "+", LIVE shell) —
  PASS + eyeballed; `terminal-dock-right` = right tool window + content BOTH
  compositing (TSK-960 recipe now on RightDockContainer) — eyeballed twice (first run
  had a blank content WebView = the known first-run capture flake, TSK-1247 class;
  re-run clean).
- **In flight:** nothing half-written.
- **Next action:** watch CI on the fix-forward commit → rc=0 → `bash
  scripts/build-app.sh release --install` + tell the owner ⌘Q+relaunch. Then the
  owner-eyeball tail (BACKLOG). Then OSS-prep O-1..O-6 or the next owner batch.

## Key decisions & rationale
- **Terminal presence ≡ false** ("user-summoned"): `.auto` must never auto-open a
  shell pane; the rail/menu toggle forces `.shown`/`.hidden`. The idiom for any future
  non-data panel.
- **Per-panel `preferredDefaultEdge`** rather than migrating an explicit edge entry:
  fresh installs get terminal-on-bottom with an EMPTY stored map (canonical encode);
  `edge()`, `setEdge()`, `setDefaultEdge()`, `init` all normalize per-panel.
- **Terminal visibility rides per-session panel layout now** — sessions saved
  pre-rework open with the terminal hidden (by design; surface to owner if it bites).
- **Right-of-content AX void is PRE-EXISTING** (never one id in any historical dump;
  `.contain` through the whole chain doesn't fix it) — filed in BACKLOG under the
  TSK-1577 family; right-dock scenes assert via the dense-chip PIXEL eval instead.

## Gotchas (full text in LESSONS.md, 2026-08-09)
- A per-item default layered on a global default must be resolved at EVERY
  normalization site (init/setEdge/setDefaultEdge) — a missed `!= defaultEdge` strips
  or keeps the wrong overrides.
- Deleted persisted fields still have live VALUES in old defaults — migrate by literal
  key + one-shot marker (absence-of-new-state ≠ migrated; it's also fresh-install).
- Source-audit tests (`ResizeGestureSpaceAuditTests` manifest, ratchets) bite on
  DELETIONS too — deleting a file's audited sites needs the manifest updated.
- First capture-lane run after a VM app rebuild can show a BLANK content WKWebView
  (TSK-1247 class) — re-run before diagnosing a compositing regression.

## Files that matter
- `Sources/ViewerCore/BottomDockTabs.swift` — tab selection resolve + keys.
- `Sources/ViewerUI/DockedToolWindow.swift` — tabbed `BottomDockContainer` (strip /
  gutter / chips), right-dock pane, PanelDragMonitor.
- `Sources/ViewerCore/SidebarPanelKind.swift` — `.terminal` + `preferredDefaultEdge`.
- `Sources/ViewerCore/PanelEdge.swift` — per-panel default resolution + normalize.
- `Sources/ViewerCore/TerminalPanelMigration.swift` — one-shot legacy migration.
- `Sources/ViewerUI/Terminal/TerminalPanelSection.swift` — the panel body (shell
  lifecycle on appear/disappear).
- `Sources/ViewerUI/PanelLayoutStore.swift` — bottomSelection/bottomBandHeight +
  migration hook in init.
- Tests: `TerminalPanelTests` (model+migration+hide-bridge), `BottomDockTabsTests`,
  `DockLayoutStoreTests` (bottom section), reworked `SideDockCompositingTests`.
- `scripts/vm-uitest.sh` — terminal-dock-right = pixel eval (AX-void note).

## Open questions / blockers
- tasked board offline — ticket debt for the whole rework on reconnect.
- Owner-eyeball tail (BACKLOG): tab band feel, terminal-in-dock, migration on the
  owner's real defaults, hex caret/tandem + session HUD + settings grid from the
  previous session.
- OSS-prep O-1..O-6 untouched; `git-filter-repo` still needs owner dep-approval.

## How to resume
1. `git -C /Users/me/Documents/workspaces/claude/markdown_viewer log --oneline -8` ·
   `git status --short` (only the 4 protected untracked files).
2. Check the CI Monitor line for the LAST commit; red → fix forward. Green → build
   release + install to /Applications (owner: ⌘Q+relaunch).
3. Mirror refresh after each committed round (from the CloudDocs side:
   `git -C '<iCloud-Drive>/Documents/workspaces/claude/markdown_viewer' fetch /Users/me/Documents/workspaces/claude/markdown_viewer main`
   then `merge --ff-only FETCH_HEAD`).
4. VM lane: rsync (excludes .build/dist) → `ssh macOS15 'cd markdown_viewer && touch
   rust-core/link/*.a && bash scripts/build-app.sh debug'` → `MDV_VM_SUDO_PASS=<vm-sudo-password>
   bash scripts/vm-uitest.sh run <scene>` → Read the PNG. Scenes: `terminal`,
   `terminal-dock-right`, `fill-check-*`.
