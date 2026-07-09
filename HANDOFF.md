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

CURRENT (2026-07-09): FRESH DIST BUILT on the VM ✅ (dist/TextView.app rebuilt with 6.3 offline,
my render-tail code in it). The offline saga is documented in LESSONS ("Offline VM dist build
recipe") — TSK-1568. build-app.sh now supports MDV_SWIFT_OFFLINE=1. App LAUNCHES on the VM GUI
lane (menu bar confirmed). REMAINING GAP (TSK-1569): screencapture shows the menu bar but NO
window — window-capture issue (off-screen/Space/timing), blocks pixel UAT. Debug via
screencapture -l<winID> (windowid file) or MDV_UI_SCENE + longer settle. Leftover root-owned VM
test instances linger (reap with sudo kill).

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
