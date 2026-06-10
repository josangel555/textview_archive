<!-- CLAUDE-HANDOFF v1 -->
# Handoff — validation drain mid-stream; TSK-622 guard batch complete (2026-06-10 late)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ 68705f7 (+1 board record on TSK-622; LESSONS/HANDOFF commit follows)

## Mission
SOP rank 1.5 VALIDATION DRAIN (docs/TASK_WORKFLOW.md §3 — read it every firing): drain
the `fixed` lane (~38 tickets left) by re-running each ticket's evidence FRESH; validate
on green-with-teeth, build the missing guard when unpinned, hold honestly otherwise.

## Current state
- Done this run (validated, 19 total): 599/600/609 + epic TSK-590→review; 266, 440
  (divider wiring guards 3bab1d3), 134, 181, 150 (stale-page guard 1f41c2a), 141
  (fingerprint pin 49c5ce2), 142+143 (rust cache pin a58eda9), 147 (FW-S3 seam 0a42e5f),
  138 (PTY reap 8480367); earlier same day: 602/108/621/615/613-wave.
- TSK-622 (guard batch) at `fixed`: 4/4 guards shipped; residue = (a) PTY sibling test
  `test_start_afterSelfExit_respawns` red in FOREGROUND sandboxed runs only (env flake,
  must fix before that suite gates), (b) TSK-139 → recommend owner dismiss.
- In flight: NOTHING torn. All commits gated (`==> headless gate PASSED` / rust EXIT=0).

## Next action (resume here)
Continue the drain over the remaining `fixed` tickets — list via
`mcp__tasked__task_list {project: tasked, state: fixed, sort: priority}`. Remaining
series: TSK-151..196 (S3/S4 audit reconciliations) + TSK-261..334 (BACKLOG fixes).
Per ticket: task_get → confirm code evidence on main → find the PINNING test (audit
suites `Audit_Sources_..._Tests` often exist) → run fresh → validate with checks
artifact, or build the guard (seam + teeth pattern, see LESSONS "validation drain"),
or hold with the gap named on the ticket. Batch ~3/tick directly or delegate recon to
a general-purpose subagent (read-only board access; re-run its named suites yourself
before validating — workflow-self-report ≠ gate-green).

## Gotchas (fresh ones in LESSONS.md "2026-06-10 (validation drain)")
- Assert at the corruption window, not after convergence (two masked-teeth incidents).
- Gated suite ∉ lane list runs NOWHERE (how TSK-621 shipped); wiring lists IS part of a fix.
- zsh: `--include=*.swift` unquoted fails; bare `===` tokens glob-error.
- Bench-flake gate failures: re-run twice, look for ZERO named test failures.

## Owner queue (unchanged, crisp)
TSK-598 supervised MountedPanesLRU extension (top perf unblock) · TSK-139 dismiss ·
TSK-608 3-option ask · 591/592/601 live/waiting-human · 327/359/452 P1s waiting-human ·
TSK-590 epic review · validated pile awaits one-click done.

## How to resume
1. Read docs/TASK_WORKFLOW.md in full (per-firing mandate; §1.5 = the drain).
2. `git -C ... status` — commit stray docs if dirty.
3. Pull the fixed-lane list and continue per "Next action".
