<!-- CLAUDE-HANDOFF v1 -->
# Handoff — perf/build-speed audits + free wins  (2026-06-14)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `2c7368c`

## Mission
Autonomous loop driving the `tasked` board toward Done — USER-FACING features/fixes first, host-test the
model, leave render-validation at `review`. This session pivoted to the owner's perf/build-speed asks.

## Current state
- **TOP NEXT ACTION (owner ask, TSK-837):** spin up **UNPRIMED** blank-slate subagents to find APP
  latency/responsiveness + TEST/build wall-clock wins. Owner pushed back that the build audit "led with storage
  wins" — they want SPEED/latency, not GB-reclaimed. Do NOT pre-feed the agents the prior findings (that biases
  them); raw question + how-to-profile + MEASURE rule only. Full prompt-spec is in TSK-837's report + `BACKLOG.md`.
  I had NOT launched these yet when /handoff was called.
- **Done + validated this session:** 7 wishlist features (JS/CSS pretty-print, status-bar memory, terminal
  rename, Open-Terminal-Here, deep FS metadata, image EXIF, clipboard text tools ×15) + 2 deep audits committed
  (`docs/research/{build-test-speedup,source-perf-audit}-2026-06-14/`) + the 3 free build wins F2/F3/F4
  (TSK-832/833/834, `5ebab1d`, ~7.7 GB reclaimed, rust caches 3→1) + TSK-828 line-ruler perf (`2c7368c`) + the
  TSK-366 memory-chip re-body REGRESSION fix (`ee4c55b`).
- **In flight:** nothing half-coded. `BACKLOG.md` + `LESSONS.md` are edited-but-uncommitted (commit them with
  `HANDOFF.md`).
- **Next action after TSK-837:** TSK-830 (no-profiling micro-perf bundle) or the profiler-gated perf tickets.

## Key decisions & rationale
- Built features by host-testing the MODEL and leaving render at `review` (owner: "don't get blocked on VM
  validation"). HOLD is only for a genuinely empty buildable pool — I set that bar too low earlier and got
  corrected. See `feedback_dont_hold_build_vm_tail_features`.
- Build wins: landed only the FREE tier (F2 index-store-off, F3 unify cargo target dir, F4 reap). F1 (kill IDE
  index tree, −1.7 GB) is owner-gated (affects jump-to-def); nextest (T1/TSK-835) needs dep approval.
- F5 (codegen-units) was a no-op — cargo `dev` already defaults to 256.

## Gotchas / lessons (also in LESSONS.md, dated 2026-06-14)
- **Gate wrapper flakes EXIT=1 under machine load** (back-to-back full-suite runs) — always `FoldBench` +
  `GrandchildPipe`; both pass in isolation. Iterate with `--filter`, run the full gate ONCE, grep the log
  (drop `^\[N/M\] Testing` lines) for the real failure before chasing.
- **A `@StateObject`/timer on a SwiftUI PARENT re-bodies the whole parent every tick** — isolate it into a child
  view (the TSK-366 memory-chip-on-StatusBar bug that broke `ChromeBodyEvalCountTests`).
- `swift test --parallel` is process-per-CLASS → the gate tail = slowest single class. lld/mold SLOWER than
  Apple ld on Apple silicon; sccache net-negative; no SwiftPM shallow-clone flag.
- VM lane ≈ 5 min (288s, 3× host). `.build` 4.4 GB ≈ dup index tree + grammar git mirrors + symbols.
- Build/gate scripts now use ONE shared `CARGO_TARGET_DIR=/private/tmp/mdv-rust-target`; gate passes
  `--disable-index-store`.

## Files that matter
- `docs/research/build-test-speedup-2026-06-14/SYNTHESIS.md` + `source-perf-audit-2026-06-14/SYNTHESIS.md` — the
  two audits (full findings; F1-F7/T1-T6 + perf findings ranked).
- `scripts/{test-headless-gate,build-rust-core,rust-core-gate}.sh` — changed this session (F2/F3).
- `Sources/ViewerUI/StatusBarMemory.swift` — `StatusBarMemoryChip` (isolated chip) + change-gated sampler.
- `Sources/ViewerUI/LineNumberRulerView.swift:112` — `newlineUTF16Offsets(in:)` (TSK-828).
- `docs/AUTONOMOUS_PROGRESS.md` — LOG +436 head (this session's narrative).

## Open questions / blockers
- **Owner-gated:** TSK-831 (F1 disable IDE bg-indexing — your call), TSK-835 (cargo-nextest dep approval),
  TSK-598 (perf re-feel, waiting:human), TSK-775 D1/D2/D3 (rust migration decisions), TSK-810 (Stage-B carve-out).

## Tracker
- `tasked` / TSK-837 (reported — the perf-explore NEXT ACTION) · 826/827/829/830 (reported perf, mostly
  needs-profiling) · 828/832/833/834 (validated) · 831/835/836 (filed, gated) · 366/352/348/769 (commented,
  umbrellas open).

## How to resume
1. Read this file, then `docs/AUTONOMOUS_PROGRESS.md` head (+436) + `BACKLOG.md` (2026-06-14 section).
2. Verify clean: `git -C /Users/me/Documents/workspaces/claude/markdown_viewer log --oneline -3` (HEAD ≥ the
   HANDOFF/BACKLOG/LESSONS commit).
3. **Execute TSK-837:** launch ~2-3 UNPRIMED `general-purpose` subagents (background) for (A) app
   latency/responsiveness and (B) test/build wall-clock — raw question + how-to-build/profile + MEASURE rule,
   NO prior findings. Have them write to `docs/research/perf-latency-explore-2026-06-14/`. Synthesize + dedupe
   yourself; file new tickets for findings.
4. Gate discipline: iterate `swift test --filter <suite>`; full gate `bash scripts/test-headless-gate.sh` ONCE;
   EXIT=1 with no real failure = the load flake.
