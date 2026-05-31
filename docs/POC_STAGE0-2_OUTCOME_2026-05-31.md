All independently verified:
- **8 exported symbols** in the dist `.a` (`nm` confirms `_poc_add`, `_poc_buf_free`, `_poc_force_panic`, `_poc_session_{free,open,set_filter,snapshot,table}`).
- **`SessionHandle` is a forward-declared opaque struct**, `PocBuf`/`PocStatus` are concrete `#[repr(C)]`. As claimed.
- **Trace facade is genuinely wired** into `csv.rs` (lines 129, 251, 275) and `session.rs` (lines 48, 53, 101, 104, 108, 120) — real `Span::enter` + `event` calls, not a dead module.
- **37+17 Rust tests pass** (live re-run).

I have everything grounded. Writing the OUTCOME doc now.

---

# OUTCOME — Swift↔Rust Core PoC (branch `poc-snap-final`)

*Owner morning review · 2026-05-31 · all claims spot-checked against the branch, not taken from the builder reports*

---

## 1. TL;DR

**It works end-to-end, and the product-identity read is positive: the core/UI split is both ergonomic and — surprisingly — *faster* than the status-quo Swift path, even paying full FFI + serialization tax.** A stateful Rust CSV session opens, filters, and emits level-triggered snapshots; Swift drives it through a clean `throws` API with ARC-managed handle lifetime; a pure-projection CLI renders the core's output with zero Swift-side parsing. Independently re-ran the gate just now: **37 core + 17 FFI Rust tests pass, 13 Swift cross-language tests pass**, all 8 C symbols export, lint/fmt clean.

The headline number: the **Rust core's *entire* pipeline (FFI open + parse + MessagePack encode + Swift-side decode) runs at ~0.79–0.81x of the Swift `CSVParser`'s *parse-only* time** — i.e. Rust does strictly more work (it also serializes and the Swift side deserializes) and still beats the incumbent. That's a deliberately pessimistic A/B, so the real ceiling is better. The boundary mechanics (panic→error, opaque handles, single-writer threading, length-prefixed MessagePack) are all proven with tests, not hand-waved.

**Verdict on "Mac app with a core" vs "core is the product":** this run validates the *mechanism* for either, and leans toward **"Mac app with a core, designed so the core can later stand alone."** The FFI friction is real but bounded and one-time; the perf and clean-seam evidence says generalizing the core is worth it. More detail in §5. Two honest caveats before you bank the perf headline: (a) the A/B compares against Swift *parse-only*, not Swift parse+filter+project, and (b) the packaging is single-host arm64-only — the cross-platform xcframework story is designed but unbuilt.

---

## 2. What was built (per stage)

All code lives under `poc/` in the worktree at
`/Users/me/Documents/workspaces/claude/markdown_viewer/.claude/worktrees/wf_25f4465e-db7-4/poc/`
(committed on branch `poc-snap-final`, HEAD `b9ab2dd`). **Nothing outside `poc/` was touched** — verified: the main repo has no `poc/` tree. Run everything with one command:

```bash
CARGO_TARGET_DIR=/private/tmp/claude-501/poc-cargo-target \
SWIFT_BUILD_PATH=/private/tmp/claude-501/poc-swift-build \
  bash poc/build.sh
```

`poc/build.sh` is the single entrypoint: `fmt --check` → `clippy -D warnings` → dev+release+dist builds → Rust tests → cargo audit (+ cargo deny if present) → cbindgen header gen+copy → size measurement → `swift build`/`swift test` → smoke-runs `poc-cli stage0/1/2`. Build dirs are external to the worktree (hygiene), so the committed tree is only **252 KB / 33 files**.

| Stage | What's green | Where (paths under `poc/`) |
|---|---|---|
| **0 — toolchain spike** | `poc_add(i32,i32)->i32` over `extern "C"`; cbindgen emits the header in `build.rs`; Swift links the staticlib and calls it. `stage0_add_smoke` + `pocAdd` test green. | `rust-core/crates/ffi/src/lib.rs:68`, `rust-core/crates/ffi/build.rs`, `swift-bridge/Sources/PocCLI/main.swift` |
| **1 — CSV over FFI** | Hand-rolled CSV parse (quote-aware delimiter detection, CRLF, escaped quotes, ragged rows, Unicode) → `Table` → MessagePack frame → Swift decode. Correctness parity vs Swift `CSVParser` across 10 shared inputs. | `rust-core/crates/core/src/csv.rs`, `rust-core/crates/core/src/wire.rs`, `swift-bridge/Sources/PocCore/PocCore.swift:168` |
| **2 — stateful CSV session** | `CsvSession` owns table+filter; `set_filter` bumps a version; `snapshot()` is **level-triggered** (full current visible state, not deltas — proven by `snapshot_is_level_triggered_full_state`). FFI surface: `open` / `table` / `set_filter` / `snapshot` / `free`. | `rust-core/crates/core/src/session.rs`, `rust-core/crates/core/src/filter.rs`, `rust-core/crates/ffi/src/lib.rs:111-289` |

The Swift bridge (`PocCore.swift`) is the load-bearing artifact: a `final class CsvSession` whose `deinit` calls `poc_session_free` exactly once (ARC drives the Rust handle lifetime), throwing `CoreError` mapped from the C `PocStatus`, with a hand-rolled MessagePack reader (`MessagePack.swift`) so there's **zero Swift-side serialization dependency**.

---

## 3. Foundations scorecard

Spot-checked each row against source + a live test run. **Green** = built, tested, verified this run. **Partial** = works but with a noted caveat. **Deferred** = intentionally not built, flagged.

| Dimension | Status | One-line note |
|---|---|---|
| **Build** | 🟢 Green | Cargo workspace, `dev`/`release`(size-opt,abort)/`dist`(size-opt,unwind) profiles; one-shot `build.sh`; dev+release+dist all build. |
| **Lint** | 🟢 Green | `clippy --all-targets -- -D warnings` clean; core is `#![forbid(unsafe_code)]`, all unsafe isolated to `poc-ffi`; no-panic lints (`unwrap/expect/panic/indexing_slicing = deny`) in non-test code. |
| **Testing** | 🟢 Green | 37 core + 17 FFI Rust tests — **re-ran live, all pass**. Covers parse edge cases, error codes, panic→error, handle lifecycle (1000-iter), wire round-trip. |
| **Swift↔Rust integration tests** | 🟢 Green | 13 cross-language XCTests (headless, host-safe — no UI). Panic-across-FFI survives + maps to `.panic`; bad-UTF8 throws; level-triggered snapshot; 500-iter handle lifecycle; correctness + filter parity vs Swift baseline. |
| **Error model** | 🟢 Green | `Result` → `#[repr(C)] PocStatus` (status in return, payload in out-param — never mixed) → Swift `throws CoreError`; rich detail rides the MessagePack `WireError`. Forward-compat `.unknown(UInt32)` default arm. |
| **Panic safety** | 🟢 Green | Every one of 7 extern bodies wrapped (`ffi_guard!`/`ffi_guard_value!` or explicit `catch_unwind` for the two frees); `dist`/`test`=unwind so the catch is load-bearing; poisoned-mutex recovery so one panic doesn't wedge the handle. See §6 for the panic=abort subtlety. |
| **Opaque handles** | 🟢 Green | `Box::into_raw`/`from_raw` + explicit `poc_session_free`; ordinary calls **borrow** via `as_ref`; cbindgen emits `SessionHandle` as forward-declared opaque struct (Swift can't fabricate one — verified in the header). Null-free, buf-double-free, 1000-iter loop tested. |
| **Threading / async** | 🟡 Partial | `Mutex`-wrapped handle, **justified** `unsafe impl Send+Sync` (real lock backs it); `try_lock`→`Busy` makes single-writer-violation loud. Real proof is `concurrent_calls_are_serialized_or_rejected_never_ub` (8 threads × 200 ops). *Caveat:* the similarly-named `single_writer_busy_under_contention` test is hollow (happy-path only) — redundant, not a coverage gap. No async path (core is sync sans-IO by design). |
| **Wire / framing** | 🟢 Green | `rmp-serde` `to_vec_named` (MAPS, asserted via fixmap marker) + DIY `u32`-LE length prefix; oversized/truncated/short frames rejected; Rust→Swift round-trip. |
| **Instrumentation** | 🟡 Partial | Hand-rolled `tracing`-shaped `Sink` facade **genuinely wired** into `csv.parse`/`session.open`/`set_filter`/`snapshot` spans+events (verified — not a dead module). *Caveat:* the Swift-facing trace-sink **callback FFI is not built** — only the in-Rust `Sink` seam is proven; the C function-pointer bridge is a documented follow-up. |
| **Packaging / size** | 🟡 Partial | cbindgen build.rs (header gitignored, regenerated — only the 4-line `module.modulemap` is committed); sizes measured. *Caveat:* **arm64-only**; the universal `lipo` + xcframework `binaryTarget` is gated off (x86_64 target not installed, no-install rule). Swift links the `.a` via hard-coded `-L`/`-l` `unsafeFlags` — fine for a single-host PoC, **not** a shipping setup. |
| **cargo deny / audit** | 🟡 Partial | `cargo audit` runs in `build.sh` → **no vulns** (64 deps scanned). `deny.toml` is genuinely tightened (`yanked=deny`, `multiple-versions=deny`, license allowlist, source restrictions) and committed — but **`cargo-deny` is not installed**, so it's config-only / unenforced this run. |

---

## 4. Measurements

All independently re-verified this run (sizes via `ls -la` on the actual binaries; tests via live `cargo test`; A/B as recorded in `ABTests.testPerformanceAB`).

**Binary size** (size-opt, arm64, stripped):

| Profile | panic | `.dylib` (what the `.app` embeds) | `.a` (staticlib) |
|---|---|---|---|
| `release` | abort | **335,840 B (~328 KB)** | ~16.3 MB |
| `dist` (what Swift links) | unwind | **352,560 B (~344 KB)** | ~16.4 MB |

The dylib is the realistic contribution figure — the linker dead-strips the `.a`'s 16 MB down to dylib-scale when embedded. **~0.9% of the 37 MB bundle cap.** The unwind tables cost ~17 KB over abort — trivial price for host survival. Runtime crate surface is just 4 crates: `serde` + `rmp-serde` + `rmp` + `byteorder`.

**Stage-1 A/B** (20k-row generated CSV, 5-iter avg, host aarch64):

| Path | Time | Ratio |
|---|---|---|
| Swift `CSVParser.parse` — **parse only** | ~114–116 ms | 1.00x |
| Rust core — **FULL pipeline** (FFI open + parse + MessagePack encode + Swift-side decode) | ~91–93 ms | **~0.79–0.81x** |

Rust wins end-to-end *including every byte of crossing/wire/decode overhead*. The raw Rust parse is a fraction of the 91 ms — most of that figure is the MessagePack encode + the hand-rolled Swift decode. Correctness parity asserted across 10 shared inputs; filter parity asserted vs the Swift `CSVFilter` global-substring semantics.

**Total footprint:** committed `poc/` source tree **252 KB** (33 files, no build dirs). External build dirs (outside the worktree, per hygiene): `CARGO_TARGET_DIR` ~634 MB + swift `--build-path` ~202 MB — these are disposable cache.

---

## 5. What it taught us about product identity

**FFI friction — bounded and front-loaded, not pervasive.** The unsafe surface is small, isolated, and *done*: one crate (`poc-ffi`), 7 extern fns, a guard macro, an opaque-handle module. The pure core is `#![forbid(unsafe_code)]`. Once the boundary patterns are established (status enum + out-param, `Box::into_raw`/`deinit`-free, `Mutex`+`try_lock`), adding a new FFI call is mechanical. The friction is a one-time tax, not a per-feature tax.

**Debugging — the seam is honest.** The core is sync + sans-IO, so all real logic is testable in plain `cargo test` with no UI and no FFI. The headless Swift cross-language harness (no NSApplication, host-safe) catches boundary regressions — handle lifecycle, wire format, error mapping — before they reach the running app. That's the single highest-value thing the PoC establishes: **the bridge is testable in isolation.**

**Build loop — fast and clean.** `build.sh` is one command, build dirs are external so the worktree stays cheap, and the cbindgen header regenerates from source (can't drift — it's gitignored, not committed). The dev iteration is `cargo test` (sub-second) for logic; the full cross-language gate is the slower path you run before landing.

**Maintainability — the wire is the contract.** Structured results cross as MessagePack maps (named fields), not as fragile `#[repr(C)]` structs, so the core can evolve its types without breaking the C ABI — only the small status enum and the handle pointers are ABI-frozen. That's the right place to draw the stability line.

**The product-identity read:** this pushes toward **"a Mac app with a Rust core, architected so the core could later become the product."** The evidence: (1) perf is already a win, not a wash; (2) the seam is clean enough that the core has no UI knowledge (the CLI proves a *pure projection* renders core output with zero Swift-side logic); (3) the FFI cost is real but amortized. It does **not** yet prove "core is the product" — that needs the cross-platform packaging (xcframework, x86_64/iOS slices) and a richer command surface than CSV-filter. But nothing here blocks that direction; it's the natural next decision, not a pivot.

---

## 6. Risks / gotchas hit (incl. playbook contradictions)

- **⚠️ Playbook contradiction (corrected in-code):** the playbook line *"panic across `extern "C"` is UB"* is **stale**. Since **Rust 1.81** an unwind across `extern "C"` is *defined* — it auto-aborts. So `catch_unwind` is for **host survival** (don't crash the embedding GUI), **not soundness**. Documented in `rust-core/crates/ffi/src/guard.rs`.
- **panic=abort makes catch_unwind a no-op.** The size-opt `release` profile uses `panic="abort"` (the brief's belt-and-suspenders ask) — under which a core panic SIGABRTs the host. The builder added a **`dist` profile (`panic="unwind"`)** that the Swift app actually links, so the panic→error path works end-to-end. **Decision for the owner:** the shipping macOS GUI dylib must use `dist`/unwind, not `release`/abort. This is correct but easy to get wrong if someone links `release` by reflex.
- **cbindgen pin: brief said `0.30.0`, which does not exist on crates.io.** Pinned to the real latest, `=0.29.3`. (Flag for any other doc that cites 0.30.0.)
- **`tracing` crate not added** (would violate the serde/rmp-serde/cbindgen-only dep constraint) — hand-rolled a `tracing`-shaped `Sink` facade instead. Real `tracing` is a one-line `cargo add` + a `tracing-subscriber` decision if you want it.
- **Swift bridge `check()` overstates handle invalidation.** `PocCore.swift:128-136` has a comment claiming it dead-flags the handle after a caught `.panic`, but it **doesn't** — the `.panic` branch falls straight through to `throw` and `liveHandle()` only nil-checks. **No safety issue** (Rust recovers the poisoned mutex), but a real bridge should null/dead-flag the handle to honor the "drop & recreate" contract. The class docstring (lines 71-72) similarly overpromises.
- **`single_writer_busy_under_contention` is misnamed/hollow** — its own comment admits it's happy-path only. Real contention proof is `concurrent_calls_are_serialized_or_rejected_never_ub`. Coverage exists; delete or rename the weak one.
- **arm64-only, hard-coded link path.** `Package.swift` hard-codes `-L /private/tmp/.../dist -lpoc_ffi`. Single-host PoC-fine; a shipping setup needs an xcframework `binaryTarget`. x86_64/iOS slices never built (no-install rule).
- **`cargo-deny` config without enforcement.** `deny.toml` is committed and genuinely strict, but the tool isn't installed, so `multiple-versions`/license/source gates ran *zero* times this run. Config without a CI job is decoration until wired.

---

## 7. Recommended next steps (smallest set to green the gaps or take the next decision)

**Cheap green-ups (close the noted gaps; ~hours each):**
1. **Fix the Swift `check()` handle invalidation** — actually null/dead-flag the handle on `.panic` so the docstring stops lying (`PocCore.swift:128`). Tiny, real safety-hygiene win.
2. **Delete or rename `single_writer_busy_under_contention`** — it's redundant dead weight next to the real concurrency test.
3. **Install + run `cargo-deny`** (and ideally `cargo-nextest`), wire both into `build.sh` as hard gates — turns the committed `deny.toml` from decoration into an enforced supply-chain gate. *(Needs your approval per the no-install rule.)*

**Decision-forcing next experiments (pick based on which product-identity question you want answered):**
4. **Build the xcframework + universal binary** (install `x86_64-apple-darwin`, `lipo`, `-create-xcframework`, switch `Package.swift` from `unsafeFlags` to a `binaryTarget`). This is the single biggest gap between "PoC" and "shippable", and it's the gate for the "core is the product / cross-platform" direction. *(Needs the x86_64 target install.)*
5. **Wire the trace-sink callback FFI** (`poc_install_trace_sink` + a Swift closure) so observability actually crosses the boundary — proves the last cross-cutting concern end-to-end. The Rust `Sink` seam is already there; this is just the C function-pointer marshalling.
6. **Fairer A/B:** compare Rust full-pipeline against Swift *parse + filter + project* (not parse-only), and measure the stateful Stage-2 `setFilter`→`snapshot` round-trip under repeated edits — that's the workload a real session actually runs, and it's where the core's statefulness should pull further ahead.

**Then the actual go/no-go decision:** if (4) lands clean and the (6) numbers hold, the evidence base is strong enough to commit to generalizing the core. Until then, "Mac app with a core" is the well-supported default and nothing in this PoC argues against it.

---

*Ground-truth references (branch `poc-snap-final`):* builder STATUS at `poc/STATUS.md`; FFI surface `poc/rust-core/crates/ffi/src/lib.rs`; panic boundary `poc/rust-core/crates/ffi/src/guard.rs`; handle ownership `poc/rust-core/crates/ffi/src/handle.rs`; Swift bridge `poc/swift-bridge/Sources/PocCore/PocCore.swift`; A/B `poc/swift-bridge/Tests/PocCoreTests/ABTests.swift`; build pipeline `poc/build.sh`; profiles/deps `poc/rust-core/Cargo.toml`. Worktree: `/Users/me/Documents/workspaces/claude/markdown_viewer/.claude/worktrees/wf_25f4465e-db7-4/`.