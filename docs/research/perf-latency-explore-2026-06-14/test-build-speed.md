# Build + test wall-clock — exploration & ranked recommendations

**Date:** 2026-06-14
**Machine:** Apple M2 Max, 12 cores (12 physical), macOS 26.2, Swift 6.3.2, cargo 1.92.0
**Scope:** speed up the merge gate (`scripts/test-headless-gate.sh`) and local iteration.
**Method:** every number below is measured on this host, warm unless stated. Deltas are
from interleaved/back-to-back A/B runs to control for machine load. Per-class timings come
from `swift test --parallel --xunit-output` then parsing the xunit XML.

---

## Executive summary

The gate is **two phases that must be reasoned about separately**:

| Phase | Cold (clean) | Warm / incremental | Notes |
|---|---|---|---|
| Rust core (`build-rust-core.sh`) | ~10s | no-op if `.a` unchanged | rebuilding the `.a` **invalidates RustCore → every Swift module → the whole test bundle** (one-time ~63s relink). |
| Swift build phase (`--build-tests`) | **~78s** (27s app + 51s tests) | **~3s** for a leaf source edit; **0.6s** no-op | index-store off saves ~14s cold. |
| Swift run phase (`swift test --parallel`) | n/a | **~72–85s** warm | I/O / fork-storm bound, NOT CPU bound. |
| Rust gate (`rust-core-gate.sh`) | — | **~6s** warm | clippy + 640 tests; tests run sub-second; already optimal. |

**The three things that actually matter (measured):**

1. **The index-store flag thrash is the biggest hidden cost in the dev loop.** The gate forces
   `--disable-index-store`; interactive `swift build` / `swift test` default to `--auto-index-store`
   (index ON). The flag is part of the build-plan hash, so **alternating between the gate and any
   interactive build forces a full ~63s test-target rebuild every single switch** — in both
   directions. Anyone who runs the gate, then iterates with `swift test --filter`, pays 63s twice
   per loop. **Confirmed:** flip the flag → 63s rebuild; run same flag twice → 0.6s no-op.
   *This is free to fix and saves the most real-world wall-clock.*

2. **The run phase is I/O / subprocess-fork bound, not CPU bound.** Sum of per-test CPU time is
   1098s but wall is ~80s (≈7× parallelism on 12 cores). The tail is set by ~6 classes that spawn
   **real `git`/LSP/`Process` subprocesses** (`GitClient*`, `GitLogStalePageGuard`, `LSP*`,
   `ProcessRunner`, `PluginSubprocessHost`, `FolderWatcher`). Run that subset alone: **22s**.
   In the full run their *attributed* xunit times balloon (a single `GitLog` test shows 9.6s in the
   full run vs **1.2s for the whole class in isolation**) — that gap is contention, not the test.
   35 test files do `git init`; 53 spawn subprocesses; 270 create temp dirs; 108 churn
   `UserDefaults(suiteName:)` domains.

3. **Worker oversubscription is a small, free win.** Default `--parallel` = 12 workers (= cores).
   The tests idle on I/O, so 16–24 workers recovers ~3–5s (~5%); 32 regresses. Real but modest —
   the subprocess tail dominates, so you can't parallelism your way past it.

The build phase for **local iteration is already fast** (~3s leaf edit, 0.6s no-op) thanks to
SwiftPM cross-module incremental — *provided* you don't trip the index-store thrash (#1) or the
Rust-`.a` invalidation.

---

## Ranked recommendations

Ranked by (wall saved × confidence ÷ effort). "Saving" is per-occurrence wall-clock.

### Free — no new tool, no approval

| # | Recommendation | Est. saving | Effort | Risk | Needs approval |
|---|---|---|---|---|---|
| **1** | **Kill the index-store thrash.** Make the index-store setting identical for interactive and gate builds. Cleanest: give the gate its own scratch dir (`swift build/test --scratch-path .build-gate …`) so it never shares incremental state with interactive builds. Alt: a `dev-test` wrapper that always passes `--disable-index-store` so your `--filter` loops match the gate. | **~63s per gate↔interactive switch** (recurring, many/day) | Low (1-line in script + a wrapper alias) | Low — separate scratch dir costs ~2GB disk + one cold build to seed | No |
| **2** | **Bump gate workers to 16–20.** Add `--num-workers 18` to the `swift test` line in `test-headless-gate.sh`. | ~3–8s/gate run (noisy) | Trivial | Low — pure scheduling | No |
| **3** | **Trim fixed sleeps in subprocess tests.** Audit `Thread.sleep`/`Task.sleep` in the tail classes (`FolderWatcher` 3×, `GitLogStalePageGuard` `Task.sleep(50ms)` in a loop, `DocumentModelTests` `Thread.sleep(0.05/0.2)`). Replace fixed sleeps with event/expectation waits where the value is "wait for async settle". | 2–10s aggregate (tail-bound) | Medium (per-test care, must not flake) | Medium — timing tests are flake-prone; needs VM re-validation for UI ones | No |
| **4** | **Shard the subprocess tail across more class-jobs.** The 22s subprocess subset serializes inside a few big classes. Splitting e.g. `GitClient*`/`LSP*` into smaller classes lets the per-class scheduler interleave them with cheap classes instead of one fat job pinning a worker. | 3–8s (tail) | Medium | Low | No |
| **5** | **Reuse expensive fixtures.** 270 tests `createDirectory` a fresh temp dir per test; 35 re-`git init`. Where a class shares an immutable repo/fixture, build it once in `setUp`-class scope (a shared lazily-inited repo) instead of per-method. | 2–5s | Medium | Low–Med (shared mutable state hazard) | No |
| **6** | **Stop the Rust-`.a` over-invalidation when nothing Rust changed.** The gate unconditionally runs `build-rust-core.sh` first; if it rewrites `libmdvcore_ffi.a`'s mtime even on a no-op, RustCore + all downstream relink (~63s). Verify `build-rust-core.sh` is mtime-stable on no-op (only restage the `.a` if its content changed). | up to ~63s on a no-Rust-change gate run | Low (guard in `build-rust-core.sh`) | Low | No |

### Needs a tool / approval

| # | Recommendation | Est. saving | Effort | Risk | Needs approval |
|---|---|---|---|---|---|
| **7** | **`ccache`/`sccache` for the TreeSitter C grammars.** ~165MB of generated `parser.c` across 11 grammars (swift 55MB, c-sharp 30MB, cpp/ts 18MB each) recompile on every clean build. A compiler cache makes the cold-build C phase near-free on the 2nd cold build. | ~10–20s on cold builds | Low (install + `CC` wrapper) | Low | **Yes — new host tool** |
| **8** | **Split the run into per-target parallel invocations in CI** (4 runners: Kit/Core/UI/RustCore) so the long UI tail overlaps the others' wall, and a failure surfaces faster. Only helps CI (multi-runner), not a single host. | CI wall: overlap the 280-file UI target | Medium (CI matrix) | Low | **Yes — CI change** |
| **9** | **Prebuilt/cached `.build` in CI** (actions cache keyed on `Package.resolved` + sources hash) so PR runners skip the ~78s cold Swift build. | ~78s/CI run | Medium | Med (cache-key correctness; stale-cache bugs) | **Yes — CI infra** |

---

## Detail / evidence

### Build phase

- Clean app-only `swift build`: **27.1s**. `--build-tests` on top: **+50.9s** → ~78s cold full gate build.
  Test targets compile 575 files (ViewerCoreTests 295 + ViewerUITests 280); ViewerUITests is the
  heaviest (235 of the test compiles in the incremental run, and the slowest-running target).
- Apples-to-apples clean build in throwaway scratch dirs: index-ON **97.7s** vs index-OFF **83.3s**
  → `--disable-index-store` saves **~14s cold + 133MB** (this is the existing TSK-832 win; keep it).
- Incremental (warm): leaf ViewerCore source edit **3.2s**; ViewerKit comment-only edit **0.9s**
  (SwiftPM correctly sees the public interface unchanged and skips downstream); test-file edit **2.4s**;
  no-op **0.6s**. **Local iteration build is already fast** — protect it (rec #1, #6).
- **Index-store flag thrash (rec #1):** `swift build --build-tests` twice with the same flag → 0.6s
  no-op; flip `--disable-index-store` on↔off → **63s full rebuild each flip**. The gate (off) and
  interactive defaults (on) thrash each other.

### Run phase

- Warm `swift test --parallel --disable-index-store` (run-phase only): **72–85s** across samples
  (machine-load sensitive; an early sample hit 162s under my own concurrent measurement load).
- Sum of per-test CPU time = **1098.5s** over 5272 tests / 600 classes → wall/CPU ≈ 1/7 (≈7× on 12 cores).
- LPT bin-pack of the 600 class-jobs onto 12 workers → ideal makespan **91.6s** *using inflated xunit
  times*; real isolated class times are far smaller, so the true CPU floor is well under that — the
  gap to measured wall is **subprocess/fork-storm I/O contention**, not packing.
- **Worker sweep (quiesced):** 12→72.6s, 16→69.6s, 24→69.3s, 32→77.2s. Sweet spot 16–24,
  ~3–4s gain, 32 regresses. Interleaved 12-vs-18 A/B: run1 18 wins by 4s, run2 tie → small & noisy.
- **Subprocess tail:** the git/LSP/process/folder-watcher subset run together = **22.3s**. Each of
  those classes in *isolation* is 0.7–1.2s wall — the full-run xunit attributes them 9–19s, which is
  pure contention. This subset is the real floor; recs #3/#4/#5 target it.

### Rust gate

- Warm `rust-core-gate.sh` = **6.0s** (clippy dominates; the 640 tests run sub-second per crate).
  Already optimal; not worth chasing. (User's ~11s figure is likely a colder clippy.)

---

## Tickets to file

- **TSK-A [perf][ci] Eliminate index-store build thrash between gate and interactive builds.**
  Give the gate its own `--scratch-path .build-gate` (or ship a `scripts/dev-test.sh` that always
  passes `--disable-index-store`). Confirm: gate run then `swift test --filter X` no longer triggers
  a 63s rebuild. *High confidence, low effort, biggest real-world win.*
- **TSK-B [perf][ci] Bump headless-gate `swift test` to `--num-workers 18`.** Measure on CI hardware
  too (core count differs). *Low effort, small gain.*
- **TSK-C [perf] Make `build-rust-core.sh` mtime-stable on no-op** (only restage `libmdvcore_ffi.a`
  if content changed) so a no-Rust-change gate doesn't relink the world (~63s). *Verify current
  behavior first — may already be stable.*
- **TSK-D [perf][test] Trim fixed sleeps + shard subprocess-tail classes** (`GitClient*`,
  `GitLog*`, `LSP*`, `ProcessRunner`, `PluginSubprocessHost`, `FolderWatcher`). Replace fixed
  `Thread.sleep`/`Task.sleep` with expectation waits; split fat classes. UI-touching ones need VM
  re-validation. *Medium effort, attacks the 22s tail floor.*
- **TSK-E [perf][test] Share immutable git/temp fixtures across a class** instead of per-method
  `git init` / `createDirectory` (35 + 270 sites). *Medium effort, watch for shared-state hazards.*
- **TSK-F [perf][build][needs-approval] Evaluate `ccache`/`sccache` for TreeSitter C grammars**
  (~165MB generated `parser.c`). *New host tool — owner approval required.*
- **TSK-G [perf][ci][needs-approval] CI: cache `.build` keyed on resolved deps + source hash, and/or
  split the run into a per-target matrix** so the UI tail overlaps. *CI infra — owner approval.*
