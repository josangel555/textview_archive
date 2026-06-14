# Rust-core build & gate performance

## Current state

- `rust-core-gate.sh` = `cargo clippy --locked --workspace --all-targets` + `cargo test
  --locked --workspace` + header-drift check. **11 s warm, 640 tests.**
- `build-rust-core.sh` = `cargo build --locked --profile dist` + cbindgen header staging.
  **1 s warm.**
- Workspace: 6 crates (core 12.7k LOC, ffi 2.9k, serve 3.2k, tui 4.8k, web 3.2k, highlight
  1.1k). 159 packages in `Cargo.lock` (mostly tui's ratatui/crossterm tree + serde/rmp).
- Profiles: `dev` (opt 0), `release` (opt z, lto fat, codegen-units 1, panic abort, strip),
  `dist` (inherits release but opt 3 + panic unwind — the shipping/app-link profile).

## THE finding: target-dir fragmentation (~9.7 GB, 3 separate caches)

`.cargo/config.toml` sets a default `target-dir = /private/tmp/mdv-rust-target`, **but every
script overrides `CARGO_TARGET_DIR` with a different path:**

| Script | `CARGO_TARGET_DIR` | Size on disk |
|---|---|---|
| `build-rust-core.sh` (app link) | `…/mdv-rust-csv-target` | **3.5 GB** |
| `rust-core-gate.sh` (merge gate) | `…/mdv-rust-gate-target` | **3.6 GB** |
| `.cargo/config.toml` default (bare `cargo`) | `/private/tmp/mdv-rust-target` | **2.6 GB** |
| stale: `mdv-rust-{audit,review,verify,verify2,verify-core,verify-fresh}-target` | various | ~1 MB now (mostly emptied) |

Because the **build** and the **gate** use different target dirs, they share **nothing**. Run
the gate, then build the app → the app build is a near-cold compile of the same 159 crates, and
vice-versa. "11 s warm" only holds if you stay inside one script; the cross-script reality is
repeated from-scratch-ish compiles. And it's **~9.7 GB of duplicated artifacts** for one
workspace.

**Fix (Rec F3):** make `build-rust-core.sh` and `rust-core-gate.sh` use the **same**
`CARGO_TARGET_DIR` (e.g. both default to the `.cargo/config.toml` path `/private/tmp/mdv-rust-target`,
or one shared `mdv-rust-shared-target`). Then a build warms the gate and vice-versa. Collapses
3 caches → 1 (**~−6 GB `/private/tmp`**) and makes the second invocation genuinely warm. This is
also a *correctness* improvement: the gate and the app would link/test the exact same compiled
artifacts.

> Caveat to verify: the gate runs `dev`-profile (clippy/test) while the app build runs `dist`.
> Different profiles live in **separate subdirs of the same target-dir** (`target/debug` vs
> `target/dist`), so sharing one `CARGO_TARGET_DIR` does **not** cause them to clobber each other
> — they coexist, and crates compiled for both profiles still rebuild per-profile (unavoidable),
> but *dependency* artifacts and incremental state are shared per-profile. Net: strictly better
> than 3 disjoint dirs.

## codegen-units for dev/test (Rec F5)

`[profile.dev]` sets only `opt-level=0`/`debug=true` — it inherits cargo's default
`codegen-units = 256` for dev, which is already parallel. **But** `cargo test` uses the `test`
profile (inherits `dev`), also fine. The lever here is small for *dev* (already 256); the only
place `codegen-units = 1` hurts is `release`/`dist`, which is correct for size and should stay.
**Net: F5 is low-value on this workspace** — the dev profile is already parallel. (Recorded so
it's not chased: the win the web cites — "bump codegen-units" — applies to projects that set it
to 1 globally; this one only sets it for size-opt release. Leave as-is.)

## cargo-nextest (Rec T1 — needs approval)

`cargo test` runs each crate's test binary **serially** at the binary level; nextest schedules
**process-per-test across all binaries**, so the 6 crates' suites overlap. For 640 tests across
6 binaries this is the single biggest test-phase lever. Reported 30–60% (up to 3×) faster;
realistic here = the slowest crate (core, 12.7k LOC) stops starving the others. **Drop-in:**
`cargo nextest run --locked --workspace` replaces the `cargo test` line in `rust-core-gate.sh`;
the clippy + header-drift steps are unchanged. nextest is a single well-maintained binary
(install via `cargo install cargo-nextest` or a prebuilt). **Needs owner approval** as a new
dev-tool dependency (not shipped, not in `Cargo.lock` of the app — it's a runner).

## Anti-recommendations (web advice that does NOT apply on Apple silicon)

- **lld / mold linker:** The Rust Performance Book and naz.io both state lld is **slower than
  Apple's `ld`** on macOS; mold's mac port (`sold`) is paid and not a clear win. Apple's default
  linker is correct here. **Do nothing.** (This is the classic "use a fast linker" advice that
  inverts on macOS.)
- **sccache:** Explicitly **cannot cache incremental builds**; independent benchmarks show it
  *slowed* clean builds 23–153% and even primed-cache rebuilds 25–51%. It helps only
  clean-cache CI with identical flags. This is a local incremental loop → **net negative.** Skip.
- **`-Zthreads` (parallel front-end):** nightly-only; the project is on stable 1.92. Not available.

## Sources
- https://nnethercote.github.io/perf-book/build-configuration.html
- https://naz.io/posts/speeding-up-rust-compile-times/
- https://nexte.st/docs/benchmarks/
- https://nexte.st/docs/design/how-it-works/
- https://earthly.dev/blog/rust-sccache/
- https://neosmart.net/blog/benchmarking-rust-compilation-speedups-and-slowdowns-from-sccache-and-zthreads/
