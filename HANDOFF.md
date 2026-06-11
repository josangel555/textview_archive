<!-- CLAUDE-HANDOFF v1 -->
# Handoff — "once done with the current ones": drain checkpoint, mislabel sweep pending (2026-06-10 night)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ 870ceef (+ LESSONS/CLAUDE.md/HANDOFF commit follows)

## Mission
SOP rank 1.5 VALIDATION DRAIN (docs/TASK_WORKFLOW.md §3 — read it every firing): drain
the `fixed` lane by re-running each ticket's evidence FRESH; validate on
green-with-teeth, build missing guards, bounce dishonest states, hold honestly.

## Current state
- Done: **TSK-151..196 series COMPLETE** (20 tickets, 9 new guards). BACKLOG series
  partial: 271/273/274 validated; 261/268 visual-holds; 272 shared-park hold;
  276 parked (Debugger 3-option ask); 326/279 mislabels bounced to progress.
  Session tally: 25 validated · 3 holds · 3 bounced · 1 parked · TSK-623
  caught+fixed. Main continuously gate-green; logs +196..+204.
- **MISLABEL SWEEP COMPLETE: 19 total mislabeled tickets** (16 found by the
  sweep + 3 hand-caught), ALL bounced to progress with correction notes. Full
  classification AND the 52-ticket CONSISTENT drain queue (with suite names) are
  in docs/AUTONOMOUS_PROGRESS.md LOG +205. Fallout back in the open pool:
  TSK-270 (file-open delay) and TSK-372 (tab duplication on reopen) — owner-felt
  bugs that had been falsely closed, both annotated with reproduce-first notes.
- Next action: (1) drain the CONSISTENT queue from LOG +205 in suite-cluster
  batches — rust e83408d cluster first (TSK-394–398: ONE fresh rust-core gate run
  covers all five), then terminal cluster (456–459), then singles → (2) ONE
  batched VM GUI pixel run for the visual-hold cluster (261+268+489; tab-strip
  MDV_UI_SCENE shot; MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password>).

## Key decisions & rationale
- Mislabel remedy = `task_record {to: progress}` + correction note (the only legal
  agent edge out of `fixed`); park on top when the real ask needs owner
  prioritization. Chosen over dismiss (work IS needed) and over leaving at fixed
  (lane fraud).
- Visual-only residuals batch into ONE VM pixel run, not per-ticket runs — GUI
  lane setup cost dominates.
- TSK-272 deliberately NOT validated despite green model tests — it shares
  TSK-306's parked owner decision; validating would pre-empt the park.

## Gotchas / lessons (full entries in LESSONS.md "2026-06-10 night" section)
- #NNN ≠ TSK-NNN mislabeled-as-fixed pattern — title-match before ANY validation
  (now also a CLAUDE.md rule).
- `ssh … | tail` eats exit codes — write `EXIT=$?` markers.
- SwiftUI Buttons/Rectangles never realize as NSViews — placement claims are
  VM-pixel-or-owner-eyes only.
- An armed lane's first real run is expected to be red (TSK-163 → TSK-623).

## Files that matter
- `docs/AUTONOMOUS_PROGRESS.md` LOG +196..+204 — per-wave narrative.
- `Tests/ViewerCoreTests/InfraInvariantTests.swift` — infra pins incl. the
  SessionStore↔vm-smoke parity pin.
- `Tests/ViewerUITests/FileWatcherDegradationCueTests.swift` + the
  `FileWatcher.forceConstructionFailure` seam (`Sources/ViewerCore/FileWatcher.swift:105-119`).
- `scripts/junit-convert.py` (+ `JUnitConverterTests`), `scripts/check-dylib-identifiers.sh`.

## Open questions / blockers (owner queue)
TSK-598 supervised MountedPanesLRU · TSK-276 Debugger 3-option ask · TSK-306/272
preview-tab validation bar · TSK-139 dismiss · TSK-608 ask · 261/268 visual
confirms · validated pile awaits one-click done.

## Tracker
Board live-synced through wave 13 (every move recorded with artifacts at action
time). Validated this session: 602,615,108,621,599,600,609,266,440,134,181,150,
141,142,143,147,138,151,157,159,160,161,162,163,623,170,171,172,173,183,185,187,
189,190,191,192,193,196,271,273,274. Bounced: 326,276(parked),279. Holds:
261,268,272.

## How to resume
1. Read docs/TASK_WORKFLOW.md in full (per-firing mandate).
2. `git status` — commit stray docs if dirty (`.profiling/` untracked is expected).
3. Continue per "Next action" above (sweep first).
