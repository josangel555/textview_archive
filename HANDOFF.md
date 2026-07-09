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
- **§1 "Fresh models" render tails are DRAINED** — all at `fixed`/`review`. Build frontier = §1
  "Older pool" (genuinely-`reported` features w/ a deep backend + no front). Done recently: 1444 LSP
  status · 1576 footer-capture lane · 1443 git panel · **1445 CR journey (THIS TICK)**. Next: 1168
  vector editing · 1441 image-editor feel · 1494 cursor mode.
- **THIS TICK — TSK-1445 code-review journey verified end-to-end → `review`** (commit `5ce2a901`).
  Backends/UI/per-unit tests/MCP tools already existed; the gap was "never driven as a whole."
  `ReviewJourneyTests` drives the full loop on a REAL commit diff (openCommitReview → comment(anchored)
  → reply(threaded) → resolve → flush → reopen-from-disk survives → export carries the hunk →
  get_review_context MCP parity). No product friction. Documented workflow in `docs/CAPABILITIES.md`
  §5. U1 diff-render + U3 scroll-nav = WebView/AX tier.
- **PRIOR TICKS (at `review`):** 1443 git panel (`8a09f977`, 19 host tests; render U1 = TSK-1577) ·
  1444 LSP chip (`ddd8aa4d`, VM-verified via 1576) · 1576 footer-capture fix (`ebf056fe`, VM-verified).
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
