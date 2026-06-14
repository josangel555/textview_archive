# Build & Test Pipeline Speedup — Synthesis

**Date:** 2026-06-14 · **Author:** research pass (`claude-mdv`) · **Status:** analysis only, not committed
**Scope:** SwiftPM build + headless test gate + Rust-core gate + `.build`/target-dir disk.
**Machine measured:** Apple-silicon, 12 logical cores (8 P + 4 E), Swift 6.3.2, cargo 1.92 / rustc 1.92.

> Read the per-area notes for the evidence behind each row:
> `swiftpm.md` · `rust.md` · `test-execution.md` · `disk-build-dir.md` · `git-deps.md`.

---

## Executive summary

The pipeline is not pathologically slow — clean Swift build 64 s, headless gate 95 s,
Rust gate 11 s warm are all reasonable for ~93 k LOC Swift + ~28 k LOC Rust. The
biggest, lowest-risk wins are about **wasted duplicate work and disk**, not raw
compiler throughput:

1. **`.build` is 4.4 GB because three things are duplicated, not because the build is large.**
   - `index-build/` (1.7 GB) is a **second, completely separate** `swift build` tree that
     SourceKit-LSP's background indexer maintains — including a **full re-clone of every
     tree-sitter git mirror** (814 MB) that already exists under `repositories/` (798 MB).
     That's ~1.6 GB of git packs cloned **twice** for the same grammars.
   - A stale `release/` tree (601 MB) coexists with `debug/` (1.1 GB) — two `ModuleCache`s
     at 225 MB each, two index stores, two dSYMs.
   - These are pure duplication; none of it speeds up the merge gate (which only ever uses
     the `debug` tree).

2. **The Rust target-dir is fragmented across ~3 full caches (~9.7 GB in `/private/tmp`).**
   `build-rust-core.sh` builds into `mdv-rust-csv-target`, `rust-core-gate.sh` builds into
   `mdv-rust-gate-target`, and `.cargo/config.toml` defaults to a third (`mdv-rust-target`).
   Nothing is shared, so alternating "build the app" and "run the gate" pays a cold-ish
   Rust compile each way instead of reusing one warm cache. (This is the hidden time cost
   behind "11 s warm" — it's only warm if you stay in one script.)

3. **Index-while-building runs twice and is never consumed by the gate.** The main
   `swift build` emits a 244 MB index store (`--auto-index-store` default), and the LSP
   maintains its own. The CLI gate doesn't read either. Disabling the index store for the
   *gate's* build is a free wall-clock + disk win.

**Headline opportunity:** ~3–3.5 GB of `.build` and ~6–7 GB of `/private/tmp` reclaimable
immediately with zero behavioural risk, plus a measurable cut to the gate's build phase by
turning off index-store + sharing the Rust cache. No new dependencies required for the top
tier. `cargo-nextest` and a SwiftPM local registry mirror are the two "needs approval"
levers with the largest upside if the owner wants to go further.

---

## Prioritized recommendations

### Free wins (no new tools, no behaviour change to test semantics)

| # | Recommendation | Est. impact | Effort | Risk | Approval |
|---|---|---|---|---|---|
| F1 | **Disable SourceKit-LSP background indexing's separate build tree** (or accept it but stop double-cloning git mirrors — see R1/F8). Set `swift.backgroundIndexing: false` in editor settings, OR point the index build at the main `.build` once Apple supports it. Today: just delete `.build/index-build` and disable bg-indexing in the editor. | **−1.7 GB disk**; removes a parallel `swift build` that competes for CPU/IO during interactive edits | Low | Low (lose live cross-file index until next manual build; symbol jump degrades) | No |
| F2 | **Add `--disable-index-store` to the gate's `swift build --build-tests`** in `test-headless-gate.sh`. The CLI gate never consumes the index. | **−244 MB disk**, **~5–15% off the build phase** of the gate (index-store adds 10–30% to swift compile per multiple sources; conservative here) | Low | Low | No |
| F3 | **Share one `CARGO_TARGET_DIR` between `build-rust-core.sh` and `rust-core-gate.sh`** (e.g. both default to `/private/tmp/mdv-rust-target`, matching `.cargo/config.toml`). | **~−3.5 GB disk** (collapse 3 caches → 1); **gate goes from cold→warm** when run after a build (saves the from-scratch 159-crate compile, multiple seconds–tens of seconds depending on staleness) | Low | Low (gate and app then link the *same* artifacts — actually a correctness plus) | No |
| F4 | **Reap stale Rust target dirs + the stale `.build/release` tree.** `mdv-rust-{audit,review,verify*}-target`, `mdv-rust-csv`/`gate` if F3 collapses them, and `.build/arm64-apple-macosx/release` (601 MB, last touched 2 days ago, gate uses debug only). | **~−6 GB `/private/tmp` + −601 MB `.build`** one-time; recurring if a cleanup step is added | Low | None (regenerable caches) | No |
| F5 | **Set `codegen-units` higher for the Rust `dev`/`test` profiles** (e.g. `codegen-units = 256`) so debug/test compiles parallelize across LLVM units. The gate runs `dev`-profile clippy+test; only `dist`/`release` need `codegen-units = 1` for size. | **~10–20% off cold Rust `dev` compile** | Low | None (debug perf irrelevant; `dist` unchanged) | No |
| F6 | **Skip the dSYM for the gate build.** Debug builds emit a 49 MB `MarkdownViewer.dSYM`; the headless gate doesn't symbolicate crashes from it. `-Xswiftc -gnone` or `--disable-...` on the gate's test build drops debug-info generation. | **−49 MB**, small compile/link win | Low | Low (lose symbolicated stacks in *gate* failures — keep full debug for the interactive `swift build`) | No |
| F7 | **`git gc --aggressive` / repack the `.build/repositories` mirrors, or stop keeping full history.** Each mirror is a *full* clone (tree-sitter-c-sharp = 191 MB pack / 1081 commits) of a repo whose only needed content is one pinned revision's `parser.c`. | Marginal alone (packs are already packed) — real fix is F8/R3 | Low | Low | No |

### Tradeoff wins (need a small tool, a behaviour change, or owner approval)

| # | Recommendation | Est. impact | Effort | Risk | Approval |
|---|---|---|---|---|---|
| T1 | **Adopt `cargo-nextest` for `rust-core-gate.sh`** (`cargo nextest run --workspace`). Process-per-test scheduling parallelizes across the 6 crates' test binaries instead of running them serially; 640 tests. | **up to ~30–60% off the `cargo test` phase** (project-dependent; biggest when one crate's binary is slow and starves the others) | Low–Med | Low (nextest is widely used, well-maintained; clippy step unchanged) | **Yes — new dev dependency** |
| T2 | **Vendor the tree-sitter grammars via a local SwiftPM registry / path mirror, or pre-generate `parser.c` into the repo**, instead of full git clones. The grammars are huge because they ship generated tables + full history; we consume one pinned `parser.c`/`scanner.c` per grammar. | **−800 MB to −1.5 GB disk** (`repositories/` + `checkouts/`), faster cold `resolve`/fetch | Med–High | Med (changes dependency provenance model; the alex-pinkus revision-pinning rationale in `Package.swift` must be preserved) | **Yes — provenance/model change** |
| T3 | **Split the giant test targets so `swift test --parallel` actually scales.** XCTest parallelism is **process-per-class**, but ViewerCoreTests/ViewerUITests are 295/279 files in 2 targets; parallelism is bounded by class count *within the run*, and a few heavy classes serialize the tail. Rebalancing the slowest classes is the lever. | **~10–25% off the 95 s gate** if the tail is class-bound (needs a profiling pass to confirm — see T6) | Med | Low | No (but it's real work) |
| T4 | **Faster Rust linker for local dev** — Apple's `ld` is already the macOS default and is faster than `lld` here, so the web's "use lld/mold" advice does **not** apply on Apple silicon. Skip. Listed to record the non-result. | ~0 (anti-recommendation) | — | — | No |
| T5 | **Use a single shared Swift `ModuleCache`** across debug/release instead of one per config (225 MB each). SwiftPM doesn't expose this cleanly; `-Xswiftc -module-cache-path` to a shared dir is possible but fiddly. | −225 MB + warmer system-module cache when switching configs | Med | Med (cross-config module-cache sharing has had correctness foot-guns) | No |
| T6 | **Profile the gate to attribute the 95 s** (build vs test, and which test classes dominate). `swift test --parallel` doesn't print per-class timing by default; a one-off `--xunit-output` parse or `xctest` timing gives the data to target T3 precisely. MEASURE before investing in T3. | Enables targeting; no direct saving | Low | None | No |

---

## What the web says that **contradicts** the obvious

- **"Use lld/mold for faster Rust links" is wrong on macOS/Apple-silicon.** Multiple sources
  (Rust Performance Book, naz.io) say lld is *slower* than Apple's `ld` on macOS; mold's mac
  port (`sold`) is not clearly a win and is paid software. The default Apple linker is the
  right call here. (See `rust.md`.)
- **`sccache` is a likely net-negative for this repo.** It explicitly **cannot cache
  incremental builds** and slowed clean builds 23–153% in independent benchmarks; it only
  helps clean-cache CI with identical flags. This is a local incremental workflow, so skip it.
  (See `rust.md`.)
- **SwiftPM compilation caching / explicit-module caching is not yet usable for SPM packages**
  (requires explicit module support not wired for SPM). The "module cache" wins people cite are
  Xcode/Bazel, not `swift build`. Don't chase it. (See `swiftpm.md`.)
- **There is no `--depth`/`--shallow` for SwiftPM SCM dependencies.** SwiftPM full-clones each
  git dependency into `repositories/` as a mirror. The only levers are the registry, a local
  path override, or vendoring — *not* a clone flag. (See `git-deps.md`.)
- **Index-while-building (`swift build`) and SourceKit-LSP background indexing are TWO
  separate index pipelines, and the LSP one keeps its own entire build tree** (incl. duplicate
  git mirrors). This is the single biggest disk surprise and is invisible unless you look.
  (See `disk-build-dir.md`.)

---

## Suggested order of execution

1. **F4 + F1** (reap stale + kill the duplicate index-build tree) — instant ~3.5 GB `.build`
   + ~6 GB `/private/tmp` back, zero risk.
2. **F3** (one Rust target dir) — collapses fragmentation, makes the gate warm after a build.
3. **F2 + F5 + F6** (index-store off + codegen-units + no-dSYM on the *gate* build) — trims the
   gate's build phase.
4. **T6** (profile) → then **T1** (nextest, needs approval) and **T3** (test-target rebalance).
5. **T2** (grammar vendoring) only if the disk/clone cost becomes a real pain — it's the
   highest-effort, highest-blast-radius item.
