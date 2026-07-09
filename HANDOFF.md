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

## NEXT ACTION (continue autonomously while owner is away)
UAT-validate the 7 stacked tails on the now-open VM, leave each at `review` with screenshot
evidence (owner does final task_validate tomorrow):
1. `rsync -az --delete --exclude='.build/' --exclude='.swiftpm/' --exclude='dist/'
   --exclude='.git/objects/pack/' ./ macOS15:markdown_viewer/`
2. `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh all`
   — `all` = build_all REBUILDS dist (vm-smoke ships a STALE dist — do NOT trust it for fresh
   render; see LESSONS). Capture FULL output (not `| tail`).
3. Per ticket: drive its UAT cases via the GUI lane (spawn dist, screencapture -l<winID>, Read
   the PNG) and attach a checks artifact + note the pass/fail. Leave at `review`.
Then resume BACKLOG §1 top-down for any remaining render tails (settings IA 1481, first-run
wiring 1448, resurrection 1500, notebook outputs render, etc.).

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
