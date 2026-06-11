<!-- CLAUDE-HANDOFF v1 -->
# Handoff — validation drain: 151..196 series COMPLETE, BACKLOG series + mislabel sweep in flight (2026-06-10 night)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ 8db08a8

## Mission
SOP rank 1.5 VALIDATION DRAIN (docs/TASK_WORKFLOW.md §3 — read it every firing): drain
the `fixed` lane by re-running each ticket's evidence FRESH; validate on
green-with-teeth, build the missing guard when unpinned, bounce dishonest states,
hold honestly otherwise.

## Current state
- **TSK-151..196 S3/S4 audit-reconciliation series: COMPLETE** (20 tickets, all
  re-verified fresh; 9 new guards built — fold-race seam, vm-smoke dry-run tests,
  dylib-identifier build check, JUnit converter extraction, infra invariants,
  UTF-16 dump pin, watcher-degradation seam, SessionStore parity pin).
- **BACKLOG series (TSK-261..334) in progress.** Validated: 271, 273, 274.
  Visual-only HOLDS awaiting one batched VM pixel run: **261, 268** (tab strip —
  one MDV_UI_SCENE shot covers both). Shared-park hold: 272 (with TSK-306's
  owner decision). Parked: 276 (Debugger — 3-option owner ask).
- **MISLABEL PATTERN (3 confirmed): TSK-326, 276, 279** were "fixed" by work on the
  built-in-TaskList's same-numbered item (#NNN ≠ TSK-NNN trap). All three bounced
  to progress with corrections. **A read-only subagent sweep of ALL remaining
  fixed-lane tickets is RUNNING** to classify CONSISTENT / MISLABELED / UNCLEAR
  with evidence quotes (results expected as a background-task notification).
- Session tally: 25 validated, 3 holds, 3 bounced, 1 parked, TSK-623 caught+fixed
  (stale sync-mount tests in the WebView lane — fixed + VM-re-run green).
- All commits gated; main continuously gate-green. Logs +196..+204 in
  docs/AUTONOMOUS_PROGRESS.md.

## Next action (resume here)
1. Collect the mislabel-sweep agent's report (or re-run the sweep if lost: list
   fixed-lane, task_get each, compare understanding/transition-reasons vs title).
2. BOUNCE every MISLABELED ticket to progress with a correction note (pattern from
   TSK-279's record on 2026-06-10).
3. Resume normal draining over the CONSISTENT list (fresh-run their named suites →
   validate / hold-visual / park).
4. When the visual-hold cluster stops growing: ONE VM GUI-lane pixel run
   (MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password>, ui-snapshot scenes) to clear
   261/268 + any later additions.

## Gotchas (full list in LESSONS.md "validation drain")
- #NNN ≠ TSK-NNN: ALWAYS compare recorded understanding vs board title before
  validating a fixed ticket in the 261..334 band.
- Never pipe VM runs through `tail` — read EXIT= markers (exit-0 masking).
- SwiftUI Buttons/Rectangles don't realize as NSViews; visual claims need VM pixels
  or owner eyes (ImageRenderer = false green, TSK-488).
- Bench-flake gate failures: re-run, look for ZERO named test failures.

## Owner queue
TSK-598 supervised MountedPanesLRU extension · TSK-276 Debugger 3-option ask ·
TSK-306/272 preview-tab validation-bar decision · TSK-139 dismiss · TSK-608 ask ·
261/268 one-glance visual confirms (or wait for the batched pixel run) ·
validated pile awaits one-click done.

## How to resume
1. Read docs/TASK_WORKFLOW.md in full (per-firing mandate).
2. `git status` — commit stray docs if dirty.
3. Continue per "Next action".
