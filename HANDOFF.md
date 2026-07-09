<!-- CLAUDE-HANDOFF v1 -->
# Handoff — render-tail build+UAT drain (2026-07-09)

**cwd (canonical):** /Users/me/Documents/workspaces/claude/markdown_viewer (iCloud sync OFF; if
re-enabled, relocate out of ~/Documents FIRST + park a Need-me) · backup rsync →
/Users/me/Local_Docs/local_workspace/markdown_viewer/ · **owner AWAY until 2026-07-10.**

## Mission
Autonomous render-tail build+validate loop (cron, every 5min). Each tick: read BACKLOG.md
(PENDING-ONLY, 4 classes) top-down → pick the next §1 render/view tail → build view/wiring + host
tests → ONE gate → ONE commit → board-record (NEVER task_validate; owner validates) → VM-UAT if
render changed → HANDOFF ≤12KB → rsync backup. PURE AUTONOMY: never ask inline — decisions =
task_park "Need me".

## ★ Current state (2026-07-09)
- **VM lane RESTORED + PROVEN** (TSK-1550 fixed): `ssh macOS15` passwordless; offline dist build +
  window-id capture pipeline works end-to-end. The pyramid is real, not a flagpole.
- **★ CADENCE CHANGED (2026-07-09): OVERLOADED CHUNK TICKS.** BACKLOG.md is now CHUNKED (§1 =
  CH-A..CH-K, each 3–5 related tickets). Each tick takes ONE whole chunk: implement all + full test
  pyramid per ticket → ONE gate at chunk end → ONE commit (all TSK ids) → board each to review with
  a SHARED checks artifact. Cron `beb85b23` (every 20 min) carries the new prompt (session-only —
  the BACKLOG mandate is the durable copy). Test pyramid per ticket = mandatory (see BACKLOG).
- **THIS TICK — CH-F (chrome/first-run): 1573 + 1575 (part 1) → `review`** (host-only).
  **1573 recover-deleted** = full enumeration + version picker. ROOT-CAUSE WIN: the ticket claimed the
  store "can't enumerate its paths" but each pathKey dir ALREADY has a `_path` sidecar → added
  `LocalHistoryStore.allTrackedPaths()` (reads the sidecars) so `recoverableDeletedFiles()` surfaces
  LONG-deleted files (not just recents); `resurrectFile(at:version:)` + `recoverableVersions` recreate a
  CHOSEN version; RecoverDeletedFileView got a per-row version Menu. Host-tested (LocalHistoryStore +2,
  DocumentModelResurrection +3). **1575 part 1** = Help ▸ Capabilities: `CapabilitiesDocument` (bundled
  `docs/CAPABILITIES.md` via build-app.sh copy — SINGLE source — + embedded fallback), `openCapabilities`,
  Help menu item. Host-tested (CapabilitiesDocument +3, DocumentModelFirstRun +2). 1575-part2 (walkthrough
  launch points) SPLIT → **TSK-1581**. Render tails (the picker Menu + rendered Capabilities page) = VM-UAT.
- **CH-F remaining:** 1572 launchpad (4 sub-items: sections + arrow-nav model + git-clone plan + universal
  paste — host-testable models + render tail), 1104 multi-window (VM), 1111 bookmarks-open-in-new (VM).
- **CH-D/CH-E remaining are SUBSTANTIAL SINGLETONS:** 1482 menu-audit (declarative-menu refactor OR VM),
  1191 git-history migration (render VM-val), 1205 spreadsheet-grid (render). Each = its OWN focused tick.
- **PRIOR — CH-D/CH-E: 1203-core+1567 (`8253d8cb`); CH-C: 1505+1570-U2 (`62697ec1`); CH-D data-safety
  1423/1269/1165 (`5ed63734`)** — all at `review`. Deferred spikes on the board: 1170/1173/1504/1482/1191/1205.
- **PRIOR — CH-D (data-safety): 1423 + 1269 + 1165 → `review`** (`5ed63734`): hex-search-over-dirty-bytes
  + external-edit 3-way auto-merge wire (host pyramid; CM6 redisplay = render tail).
- **PRIOR (at `review`):** CH-B image tools (`1a6eef77`: 1083/1084/1086/1089; 1090 parked) · CH-A image
  (`a51f9564`: 1055/1088/1114/1441/1574; render→1578) · 1168 vector-edit (`a403011d`) · 1445 CR journey
  (`5ce2a901`) · 1443 git panel (`8a09f977`; U1=1577) · 1444 LSP (`ddd8aa4d`) · 1576 footer (`ebf056fe`).
- **LESSON: not every chunk is 3-5 quick tickets.** CH-C bundled 5 substantial devtools tickets; honest
  output was 1 build + 1 park + 3 deferred. Half-building 5 UI tickets is worse than shipping 1 well.
  **Verify-before-build keeps paying** (CH-A's 1055 + CH-B's 1086 + ops were already done).
- **Per-ticket detail lives on the board (task_get) + git log** — not here.

## ✅ FOOTER-CAPTURE ROOT (2026-07-09, TSK-1576 — corrects a wrong first theory)
Scene captures missed the footer because the scene restored a TINY (600×360 min) saved window frame,
NOT because of screen clipping. `MDV_WINDOW_DIAG` proved the VM is 1920×1200 @2× and the window was
600×360 fully on-screen (the 1200×776 PNGs were that small window at 2× retina). At 600×360 the
footer is squeezed out; at 1280×860 it renders. Fix forces 1280×860 for all `MDV_UI_SCENE` spawns.
LESSON: DUMP THE GEOMETRY (`MDV_WINDOW_DIAG=1`, now aqua-runner-forwarded) before theorising. The
ax-reader still doesn't surface `mdv.statusBar.*` children → footer `scene_expect` targets the
`mdv.statusBar` parent; the chip is a pixel-only assert (read the PNG).

## Follow-ons filed
1570 outline scroll-highlight+preview-jump · 1571 mount Monitor as menu item · 1572 omnibox launchpad
· 1573 recover-deleted full enumeration · 1574 shape-gallery freeform · 1575 first-run Capabilities
page · 1576 footer-capture UAT lane (DONE) · **1577 git-panel render scene** (view-local @StateObject).
STILL to UAT: 1478 plugins (Settings→tab, hard to drive).

## VM UAT recipe (proven)
1. Add a scene to `UISceneRegistry.staticScenes` + an inline handler in `UISceneApplier` that
   reaches the surface; map `scene_expect` in `scripts/vm-uitest.sh`.
2. Full-repo rsync (`rsync -az --delete --exclude=.build/ … ./ macOS15:markdown_viewer/`; a
   `Sources/` trailing slash lands files at the WRONG level → "unknown scene"), then on the VM
   `touch -t 202607010000 rust-core/link/libmdvcore_ffi.a && MDV_SWIFT_OFFLINE=1 bash
   scripts/build-app.sh debug` (skip the rebuild if only shell/scripts changed).
3. `MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/vm-uitest.sh run <scene>` — its 30s poll is short (agent
   finishes ~60-90s); poll `~/.mdv-uitest/done` then `scp macOS15:.mdv-uitest/<scene>.png`.
4. **READ the PNG — pixels are AUTHORITATIVE.** Reap leftover root-owned VM instances with sudo kill
   (not pkill-9) — they accumulate + screencapture can grab the wrong window-id.
- Launch-mode windows (not scene-driven): `aqua-runner.sh` handles `monitor-*` (builds a fixture +
  launches `--claude-monitor` + MDV_MONITOR_ROOT). Extend for other launch-mode UIs.

## Gotchas (full list LESSONS.md)
- **present-in-tree ≠ visible**: the ax-reader surfaces sidebar-panel + separate-window-root ids +
  overlays/menus, but NOT doc-content-view or `.sheet`-content ids → those AX-assert FALSE-FAIL.
  Always READ the PNG. A WKWebView-rendered markdown BODY often shows blank in VM captures (known
  webview-lane limit) even when the doc loaded (the outline panel populating proves the parse).
- **COMPOSITOR occlusion (LESSONS/TSK-488)**: a SwiftUI sibling drawn before an opaque
  NSViewRepresentable (terminal/CM6 surface) is OCCLUDED — give it `.compositingGroup().zIndex(1)`.
- **`.task`/`.onAppear` on a conditionally-EMPTY Group** renders as EmptyView → never fires; anchor
  async work on an always-present `Color.clear`.
- **SIZE-CHECK a complex surface before deep recon**: is the vm reachable from the scene applier
  (view-local @StateObject = NO)? does it render on scene-apply (a Menu/drag does NOT)? If not, it's
  host-test + UNVERIFIED-flag, not a scene UAT.
- Layout: a restored terminal + always-on Bookmarks panel bury sidebar targets — reset in the scene
  (`terminalPane.setOpen(false)`, `panelLayout.setOverride(kind, .shown)` + hide siblings).
- VM clock ~3 days behind (judge dist freshness by git log). GUI lane needs MDV_VM_GUI_SESSION=1 +
  MDV_VM_SUDO_PASS=<vm-sudo-password>. NEVER `rm -rf .build` on the VM (offline; deps live there). Never `killall
  MarkdownViewer` (owner's app). Never touch OwnerWishlist*/Untitled*.
- Gate: read the GATE_DONE rc marker in tmp/. EditorAssistToggleTests is a known parallel flake
  (TSK-1567) — re-run once. **HANDOFF ≤12KB is a RED test (ContextBudgetTests)** — keep it CURRENT
  STATE, move history to git/board.

## How to resume (cold)
1. `cd /Users/me/Documents/workspaces/claude/markdown_viewer && git log --oneline -5 && git status`.
2. Read this file + BACKLOG.md (§1 render/view tails queue, top-down).
3. Verify VM: `ssh macOS15 'echo ok'` (passwordless; else LESSONS VM-key recipe).
4. Pick the next §1 tail → size-check (scene-reachable? renders on apply?) → build+host-test →
   gate → commit → VM-UAT or UNVERIFIED-flag → board-record at `review` → backup.
