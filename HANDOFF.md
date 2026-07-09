<!-- CLAUDE-HANDOFF v1 -->
# Handoff — VM restored; render tails awaiting UAT (2026-07-09)

**cwd (canonical):** /Users/me/Documents/workspaces/claude/markdown_viewer (iCloud sync OFF; if
re-enabled, relocate out of ~/Documents FIRST + park a Need-me) · backup rsync →
/Users/me/Local_Docs/local_workspace/markdown_viewer/ · **owner AWAY until 2026-07-10.**

## Mission
Autonomous render-tail build+validate loop (cron job 14956868, every 5min). Read BACKLOG.md
(PENDING-ONLY, 4 classes) each tick. PURE AUTONOMY: never ask inline — decisions = task_park
"Need me". Per cron mandate: build → ONE gate → ONE commit → board-record; NEVER task_validate
(owner validates). One work unit per tick; rsync backup after each.

## ★ Current state (2026-07-09)
- **VM LANE RESTORED (TSK-1550 fixed).** `ssh macOS15` works passwordless again — the host had
  lost its key (relocation incident); re-enrolled ~/.ssh/id_ed25519 via expect+ssh-copy-id (VM
  login pw <vm-sudo-password>), re-pointed ~/.ssh/config. Confirmed end-to-end: build → launchctl-asuser spawn
  → screencapture → pull (menu bar visible). NOTHING to unblock; no owner action pending.
- **P0 launch-wedge fixed earlier (TSK-1566, 12f6e392):** --mcp-connect bridges hoisted above
  NSApplication.shared (was registering with LaunchServices → app un-openable, LS -600) + orphan
  watchdog. App opens fine.
- **7 render tails built this session, ALL at `review` UNVERIFIED, ready for VM UAT:**
  1438 outline panel · 1474 video fallback card · 1469 archive preview+extract · 1477 monitor
  empty-states+auto-refresh · 1478 plugins install/remove · 1470 dep-graph zoom/pan · 1475
  terminal favorites editor. Each has host-tested model + UAT cases on the ticket (task_get).
- **In flight:** none uncommitted. Cleared the VM's stale link product
  (`rm .build/*/debug/MarkdownViewer`) so the next VM build relinks fresh.

## ★ VM LANE IS CAPABLE — no fear, no blocking (2026-07-09)
The VM is 6 GiB (since 2026-06-13) and its build/test/UAT lane is robust — do NOT treat it as
scary or park VM work. My earlier "4GiB/OOM-risk" blocking was a STALE assumption off an old
ssh-config comment; memory held 53% free throughout. RULES (from reference_vm_memory_pressure_build_cache):
NEVER `rm -rf .build` on the VM (it's OFFLINE — no github; SPM deps live in .build/{checkouts,
repositories}; a wipe breaks the build). Build dist with the **6.3** toolchain (default 6.1.2 can
crash the frontend). If the dep cache is ever damaged: ship it from host — `rsync -az
.build/checkouts .build/repositories Package.resolved macOS15:markdown_viewer/.build/` +
`swift package resolve` (or build `--disable-automatic-resolution`).

CURRENT (2026-07-09): ★ VM UAT PIPELINE PROVEN. 8 render tails UAT-VERIFIED ON-SCREEN via the
pyramid (all at `review` w/ screenshot evidence, owner validates): TSK-1474 video fallback ·
TSK-1469 archive browser · TSK-1440 notebook OUTPUTS · TSK-1470 dep-graph CANVAS · TSK-1438
markdown OUTLINE panel (MOUNTED) · TSK-1475 terminal FAVORITES editor (MOUNTED) · TSK-1477 Claude
MONITOR (launch-mode UAT lane) · TSK-1496 secret WARN-BADGE (BUILT the render slice: wired the
shipped-but-inert SecretDetector into a non-modal banner above the editor, behind mdv.secretTreatment).
Two (1438, 1475) crossed built→USABLE; 1496 is a security render-slice BUILD. Offline build
(TSK-1568) + window capture (TSK-1569) SOLVED. Committed UAT scenes: video-unsupported,
archive-preview, notebook, depgraph, outline, favorites, secrets; + aqua-runner `monitor-*` scenes.
GOTCHA (2026-07-09): `.task`/`.onAppear` on a conditionally-EMPTY Group renders as EmptyView and
the modifier NEVER FIRES — anchor async work (scans, loads) on an always-present Color.clear, not
a `Group { if x {…} }`. This hid the secret badge on the first render until fixed (ZStack + a
zero-height Color.clear owning the .task).

TSK-1085 (image SHAPE GALLERY, review — ON-SCREEN UNVERIFIED): wired the 12 GalleryShape polygons
into the image editor — a Shapes Menu picker + `.galleryShape` tool; drag a box → drawGalleryShape
projects the (host-tested) vertices to pixels → fill/strokePolygon raster op (undoable). Model
host-tested (ImageEditorGalleryShapeTests 3/3 + GalleryShape 7/7). ON-SCREEN UNVERIFIED: the
ImageEditorViewModel is VIEW-LOCAL (@StateObject, unreachable from the scene applier) + the picker
is a Menu (needs a click) + drag-place needs a real drag → no static scene state to capture; the
picker/drag are the AX-event lane. Follow-on TSK-1574 (freeform heart/lightning/callouts, curves).
TSK-1500 (RECOVER deleted file, review): File ▸ "Recover Deleted File…" → a sheet listing
recently-opened deleted-but-has-history files, each Recreate = FileResurrection.recreate (atomic
O_EXCL) + open. Entry point reuses RECENTS (real paths; the history store hashes paths one-way so
can't enumerate). Model host-tested (DocumentModelResurrectionTests 4/4 + FileResurrection 8/8).
UAT scene "recover-deleted". Follow-on TSK-1573 (full enumeration via a path-storing manifest +
version picker). Also isolated UISceneApplierTests.makeModel's localHistory to tmp.
TSK-1249 (terminal HEADER row, review): added a header above the terminal surface — "Terminal —
<name> [<cwd>, pid <n>]" (TerminalHeaderRow observes the TerminalModel → live-updates on OSC-7
cwd + pid via the version bump). Exposed TerminalModel.childPID (public forward to PTYProcess).
Formatter host-tested (TerminalHeaderTests 3/3). UAT scene "terminal-header". COMPOSITOR CATCH:
the header was INVISIBLE on the first VM capture (occluded by the opaque TerminalRepresentable —
the LESSONS/TSK-488 class); fixed w/ .compositingGroup().zIndex(1) above the surface. A live
reminder that present-in-tree ≠ visible + the VM pixel check is what catches it.
TSK-1476 (structural-search HELP, review): wired StructuralSearchHelp into StructuralSearchView —
an Examples popover (language-tailored insertable queries, insert-on-click), the help placeholder,
+ a live under-field validation error as you type. Language auto-seeded (currentEffectiveLanguage).
Help host-tested (StructuralSearchHelpTests 4/4, every example parses). UAT scene "structural-search".
TSK-1489 (new-tab OMNIBOX, review): BUILT the omni field on the EmptyStateView launchpad — one
field wired to OmniResolver.classify → openPath / openURL+gitRemote (browser) / search
(openGlobalSearch). UAT-verified on the VM (omni scene): the field renders w/ placeholder "Open a
path, URL, or git repo — or search…" above New… buttons + Recent list. Dispatch host-tested
(DocumentModelOmniTests 4/4, .openURL skipped — would launch a real browser). Follow-on TSK-1572
(sections / arrow-nav / git-clone / ⌘V paste).
TSK-1480 (format menus, review): the Convert Encoding/Line-Endings submenus now
check-mark the active file's current value + Convert Indentation shows a "Current: <indent>"
header (menuNeedsUpdate → FileFormatMenuState.resolve, host-tested 5/5). The footer ALREADY showed
enc/EOL/indent (existing StatusBar chips) so that half was pre-met. ON-SCREEN submenu check-mark is
UNVERIFIED — the aqua-runner captures windows, not menu-drill navigation, so submenu-checkmark UAT
is impractical; the logic is host-tested with teeth + the footer shows the state on-screen.
NEXT tails to UAT: plugins(1478, Settings→Plugins nav — Settings is a SwiftUI Settings scene,
hard to drive to a tab; needs a settings-tab override or a mount). MOUNT follow-ons filed:
TSK-1570 (outline scroll-highlight+preview-jump), TSK-1571 (mount the Monitor as a menu item —
openClaudeMonitorWindow clobbers self.window, needs a separate window ref).
NEW UAT LANE (launch-mode windows): aqua-runner.sh handles `monitor-*` scenes — builds a fixture
root + launches `--claude-monitor` + MDV_MONITOR_ROOT (no dist rebuild if only Swift is unchanged;
the monitor window writes the same windowid). Reap leftover root-owned VM instances with sudo kill
(not pkill-9). LAYOUT/AX GOTCHAS: a restored terminal + the always-on Bookmarks panel bury sidebar
targets — reset layout (`terminalPane.setOpen(false)`, force target `panelLayout.setOverride(kind,
.shown)` + hide siblings); the ax-reader surfaces sidebar-panel + SEPARATE-WINDOW-root ids
(mdv.claudeMonitor passed) + overlays/menus, but NOT doc-content-view or .sheet-content ids →
those AX-assert FALSE-FAIL; present-in-tree ≠ visible, so READ the PNG.

PER-RENDER-TAIL UAT RECIPE (proven): (1) add a scene to UISceneRegistry.staticScenes + an inline
handler in UISceneApplier that reaches the surface; (2) rebuild dist on the VM — use the CORRECT
full-repo rsync (`rsync -az --delete --exclude=.build/ ... ./  macOS15:markdown_viewer/`; a
`Sources/` trailing-slash drops files at the WRONG level → "unknown scene"), then
`touch -t 202607010000 rust-core/link/libmdvcore_ffi.a && MDV_SWIFT_OFFLINE=1 bash
scripts/build-app.sh debug`; (3) `MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/vm-uitest.sh run <scene>` —
its 30s poll is too short (agent finishes async ~60-90s); poll `~/.mdv-uitest/done` then
`scp macOS15:.mdv-uitest/<scene>.png`; (4) READ the PNG — pixels are AUTHORITATIVE (the ax-reader
does NOT surface content-view a11y ids, only overlays/menus → AX-presence asserts false-fail for
content views). Leave the ticket at `review` (owner validates; agent never task_validates).

## NEXT ACTION — build the PYRAMID, not a flagpole (owner directive 2026-07-09)
The test pyramid is currently a flagpole (host unit tests only); the VM/render/UAT/AX tiers are
the real gap. Once the dist build lands:
1. Dist is ALREADY fresh on the VM. First resolve TSK-1569 (window not in screencapture) —
   capture by window id (the app writes a windowid file) instead of -x, or drive MDV_UI_SCENE.
   To rebuild dist if needed: `MDV_SWIFT_OFFLINE=1 bash scripts/build-app.sh debug` on the VM
   (deps + git configs already staged; if the STALE-LINK tooth trips, `touch -t <old>
   rust-core/link/libmdvcore_ffi.a` first).
2. UAT the 7 review-lane tails (1438/1474/1469/1477/1478/1470/1475): spawn dist, drive each
   ticket's UAT cases, screencapture -l<winID>, Read the PNG, attach evidence, leave at `review`.
3. GROW the pyramid: add T5/WV/AX tests for the new render surfaces (they only have host models
   today) so the tiers exist as committed guards, not one-off checks.
Kick VM jobs in the BACKGROUND; let cron ticks proceed; harvest results next tick.

## Gotchas (full list LESSONS.md tail)
- VM "can't ssh" = check the HOST key first (`ls -la <IdentityFile>`, `ssh -v` for an Offering
  line); the VM is fine. Re-enroll recipe in LESSONS + memory reference_vm_ssh_key_restore.
- vm-smoke.sh ships a STALE dist (Jul-4 build, relink warning) — use `test-in-vm.sh all` for
  fresh render/UAT, or `rm .build/*/debug/MarkdownViewer` on the VM first.
- VM clock is ~3 days behind — judge dist freshness by git log, not mtime.
- GUI lane needs MDV_VM_GUI_SESSION=1 + MDV_VM_SUDO_PASS=<vm-sudo-password> (silent no-op without the pass).
- Gate: read the GATE_DONE rc marker in tmp/, not the wrapper exit. Re-run once on a lone
  flake (EditorAssistToggleTests shared-UserDefaults parallel race = TSK-1567, known-flaky).
- Never `killall MarkdownViewer` (owner's app). Never touch OwnerWishlist*/Untitled*.

## Tracker
TSK-1550 → fixed (VM restored, evidence attached). 7 tails at `review` (1438/1474/1469/1477/
1478/1470/1475) — UAT-pending, owner validates. TSK-1566 P0 → fixed. TSK-1567 filed (gate flake).

## How to resume (cold)
1. `cd /Users/me/Documents/workspaces/claude/markdown_viewer && git log --oneline -5 && git status`.
2. Read this file + BACKLOG.md (§VM LANE RESTORED banner + §1 queue).
3. Verify VM: `ssh macOS15 'echo ok'` (should be passwordless). If it fails → LESSONS VM-key recipe.
4. Do NEXT ACTION above: sync → test-in-vm.sh all → per-ticket UAT → leave at review.
