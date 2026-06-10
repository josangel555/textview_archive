# testing — rust-core audit 2026-06-09 (final, post-resume)

## Proposals (critique-judged)

### Fuzzing lane for the wire decoder and text parsers (cargo-fuzz — dep approval needed) — verdict: **sound-with-caveats** (effort medium)
- **Critique:** PROBLEM VERIFICATION — the core claims check out:
- Zero fuzz infra confirmed: no `rust-core/fuzz/` exists, and `rust-core/Cargo.lock` has no libfuzzer-sys/arbitrary/afl/honggfuzz entries.
- The inbound decode path is real, not hypothetical: `mdvcore_cm_apply` (rust-core/crates/ffi/src/lib.rs:119), `mdvcore_diff_parse` (lib.rs:165), and `mdvcore_diff_hunk_marks` (lib.rs:210) take raw `*const u8` request frames from Swift and route them through `wire::decode_frame` via `cm_edit::apply_wire` (rust-core/crates/core/src/cm_edit.rs:131-132) and `diff::parse_wire`/`hunk_marks_wire` (rust-core/crates
- **Improvements:** 1. Add (or explicitly scope out, with rationale) a `fuzz_highlight` target: arbitrary text → crates/highlight parse, built with ASan. It's the only workspace surface where fuzzing can find memory-safety (S1) bugs rather than recoverable panics; arguably it should displace `fuzz_cm_apply` in priority.
2. Recalibrate the pitch: in the shipping `dist` profile every panic is caught to MdvStatus::Panic

### Property-based round-trip and op-replay laws (proptest — dep approval; or hand-rolled PRNG generators) — verdict: **sound-with-caveats** (effort medium)
- **Critique:** THE PROBLEM IS REAL BUT OVERSTATED IN ITS PARTICULARS; THE DESIGN AIMS AT THE WRONG TARGETS FIRST AND MISSES THE CRATE'S BEST PROPERTY-TEST OPPORTUNITY.

Claims verified true:
- Wire round-trip coverage is exactly one hand-built shape per type: `sample_table()` at rust-core/crates/core/src/wire.rs:216-223 feeds every round-trip test (wire.rs:295-302, 335-339); Snapshot/WireError each appear once (wire.rs:249-273). Confirmed.
- csv tests are ~23 hand-picked strings (csv.rs:293-477). Session tests replay one 3-row CSV const (session.rs:265) with 2-3 op sequences; the integration test reuses the 
- **Improvements:** 1. Re-rank the properties by yield: (a) optimized-vs-reference filter parity over arbitrary unicode tables/queries (promote the existing oracle at filter.rs:267-287 from 14 examples to generated inputs) — add this, it's missing; (b) csv::parse never-panics + every-row-len==header-len invariant on arbitrary input (real FFI ingress via session_open); (c) session op-replay (version monotonicity, snap

### Shared golden corpus files to replace the hand-synced triplicated parity corpora — verdict: **sound-with-caveats** (effort medium)
- **Critique:** PROBLEM: VERIFIED REAL. The triplication is exactly as claimed: Tests/RustCoreTests/ABTests.swift:20-35 (`sharedCases`) hand-retypes the inputs from rust-core/crates/core/src/csv.rs tests (e.g. "a;b;c\n1;2;3\n" at csv.rs:315 ↔ ABTests.swift:22; the escaped-quote case csv.rs:340 ↔ ABTests.swift:26; José/🎉 csv.rs:426 ↔ ABTests.swift:29). Tests/RustCoreTests/DiffParseABTests.swift:13-14 explicitly documents that its ~14-entry corpus is "kept in lock-step with DiffParserTests" — by convention only. Nothing enforces sync, so a hazard added on one side silently never reaches the A/B. The parity-rot 
- **Improvements:** 1. Replace the SwiftPM resource mechanism with #filePath-relative repo lookup (walk up from the test file to the repo root, read rust-core/testdata/corpus directly). Works on both the host gate and the VM rsync mirror, needs no Package.swift resource declaration, no copy step, no symlinks (which iCloud sync makes risky in this repo). Keep the >= N minimum-count assertion on both sides exactly as p

### Complete the FFI contract-test matrix: misuse tests for all 16 exports + deterministic Busy and poison-recovery tests — verdict: **sound-with-caveats** (effort small)
- **Critique:** PROBLEM IS REAL AND ACCURATELY STATED (verified line-by-line):
- The six named exports — mdvcore_cm_apply (rust-core/crates/ffi/src/lib.rs:119), mdvcore_diff_parse (:165), mdvcore_diff_hunk_marks (:210), mdvcore_hex_render (:259), mdvcore_hex_search (:307), mdvcore_indent_detect (:369) — appear nowhere in rust-core/crates/ffi/src/tests.rs (confirmed by reading the whole 304-line file). Each has hand-written null/len/UTF-8 validation branches (e.g. lib.rs:131, lib.rs:177, lib.rs:222, lib.rs:274, lib.rs:322, lib.rs:382, plus the BadUtf8 gates at lib.rs:337 and lib.rs:391) that are pure dead-lett
- **Improvements:** 1. Fix the count: 14 exports, 12 pointer-taking. State the matrix as 12 × {each-ptr-nulled-with-nonzero-len, len=0 documented behavior, BadUtf8 where text, WireError on garbage/truncated frame, error-path-leaves-out_buf-empty-and-safe-to-free}. That last column is currently implicit (lib.rs writes MdvBuf::empty() before any validation, e.g. lib.rs:129) and worth pinning explicitly — it's the invar

### Gate the un-gated crates: highlight into the merge gate, tui/web tests into a scheduled lane — verdict: **sound-with-caveats** (effort small)
- **Critique:** THE CORE PROBLEM IS REAL AND VERIFIED. `scripts/rust-core-gate.sh:34,37` invokes `cargo clippy --all-targets` and `cargo test` from the workspace root with no `--workspace`/`-p` flags, so both honor `default-members = ["crates/core", "crates/ffi"]` (`rust-core/Cargo.toml:23`). `.github/workflows/pr.yml:90-98` runs only `build-rust-core.sh` + `rust-core-gate.sh` for Rust; `.github/workflows/nightly-vm.yml` contains zero cargo steps; no script under `scripts/` tests the other three crates. Test counts check out exactly: 9 `#[test]`s in `crates/highlight/src/lib.rs`, 60 in `crates/tui/src/main.rs
- **Improvements:** 1. DROP OR CORRECT THE TSK-410 CLAIM. Replace with honest motivation: highlight is the workspace's only other unsafe-FFI surface (C grammar linking), its 9 tests and tui/web's 135 tests run nowhere, and the gate header (`scripts/rust-core-gate.sh:16`) falsely claims full-workspace coverage. If a concrete bug is wanted as evidence, find one in the actually-ungated code — not one that lives in `Sour

### Miri + LeakSanitizer lane for the unsafe FFI crate — verdict: **strong** (effort small)
- **Critique:** PROBLEM IS REAL — every factual claim verified against the tree:

- The gap is admitted in the code itself: `rust-core/crates/ffi/src/tests.rs:207-209` ("a leak/double-free would surface under Miri / ASan. Here we just prove the loop is stable"). Nothing anywhere runs Miri or a sanitizer: `scripts/rust-core-gate.sh` is clippy + `cargo test` only (lines 33-37), and `grep -i miri|sanitizer|asan` over `.github/workflows/pr.yml` + `nightly-vm.yml` finds nothing.
- The hazard surface is exactly as described: `Box::into_raw`/`from_raw` handle lifecycle (`crates/ffi/src/handle.rs:62-93`), `unsafe imp
- **Improvements:** 1. Fix the int→ptr provenance round-trip in `crates/ffi/src/tests.rs:246/:255` (Send wrapper struct around the raw pointer), then run the lane with `-Zmiri-strict-provenance` — without this the lane silently forfeits the strictest aliasing checks. Consider `-Zmiri-many-seeds` (or a handful of fixed seeds) on the contention test to explore more interleavings.
2. Split the lane by cost: `cargo miri 

### Periodic mutation-testing audit with cargo-mutants (tool approval needed) — verdict: **strong** (effort small)
- **Critique:** The problem is real and the proposal's numbers are exactly right — I verified every claimed figure against the tree.

**Problem verification (all confirmed):**
- Test-density claims are exact: `view.rs` 807 LoC / 19 `#[test]`, `format.rs` 633/17, `outline.rs` 447/21, `trace.rs` 200/2, vs the well-tested `csv.rs` 477/22, `wire.rs` 375/10 (`rust-core/crates/core/src/`). `view.rs` is genuinely load-bearing — 13 public functions (`classify`, `content_state`, `cycle`, `build`, `table_query`, `clamp_line`, … at `view.rs:145-404`) that the FFI/front-ends route through.
- The asymmetry with the UI lan
- **Improvements:** 1. Fix the `--in-place` claim: copy-to-temp is the default AND required here (iCloud-synced worktree + build-dirs-outside-tree rule, `rust-core/Cargo.toml:8-9`); explicitly forbid `--in-place`. Set `CARGO_TARGET_DIR` consistent with `scripts/rust-core-gate.sh:26`.
2. Make the first run tractable and targeted: per-file passes on the named thin modules (`cargo mutants -p mdvcore-core -f src/view.rs`

### Perf regression floor for the core hot paths (hand-rolled bench gate in the scheduled lane) — verdict: **sound-with-caveats** (effort medium)
- **Critique:** PROBLEM IS REAL — every factual claim verified. (1) Zero bench infrastructure: no `benches/` dir anywhere under `rust-core/crates/`, no criterion (or any bench harness) in `rust-core/Cargo.lock` or any `Cargo.toml`. (2) The wire single-allocation rewrite was explicitly perf-motivated and is guarded only for correctness: `rust-core/crates/core/src/wire.rs:227` calls the legacy two-step encoder a "byte-identity oracle for the single-allocation rewrite" and the test at `wire.rs:239` (`single_alloc_frame_is_byte_identical_to_legacy`) asserts byte equality — nothing pins the allocation count or spe
- **Improvements:** 1. **Pin the placement**: a new non-default-member crate (e.g. `crates/bench`, excluded from `[workspace] default-members` like tui/web) so the merge gate's `cargo clippy --all-targets`/`cargo test` (which resolve default-members only) never compile it; the clock ban in `clippy.toml` then needs at most a crate-local `#![allow(clippy::disallowed_methods)]` with a comment, and no-panic lints stop be

### Differential parity fuzzing Rust-vs-Swift (stretch, builds on the corpus + fuzz proposals) — verdict: **sound-with-caveats** (effort medium)
- **Critique:** PROBLEM IS REAL AND WELL-MATCHED TO THIS CODEBASE — verified, not speculative:

- The CSV parity surface is exactly 14 hand-picked inputs asserted twice (Tests/RustCoreTests/ABTests.swift:20-35, testCorrectnessParity + testAdapterParityWhenForcedOn), and the diff surface is ~14 more (Tests/RustCoreTests/DiffParseABTests.swift:15-152). That is thin against the actual state-machine complexity.
- The Rust CSV parser is deliberately a dependency-free hand-rolled mirror of the shipping Swift CSVParser — "NO csv crate — the whole point is an A/B against the existing Swift CSVParser" (rust-core/crate
- **Improvements:** 1. Split into two explicit lanes: fixed-seed deterministic run (~2k cases/domain) in the host headless gate; rotating-seed extended run (50-100k cases) in the nightly VM/host lane, seed echoed in the failure message for replay. Never put a rotating seed in the merge gate.
2. Cover the limits/truncation tier: add a test-only FFI entry accepting Limits (or mdvcore-internal parse_with exposure), or i

---

## Full reviewer report

# rust-core Testing + Verification Strategy Audit (2026-06-09)

Scope: `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/` only. Dimension: testing + verification rigor for a production-grade reusable core.

## 1. Inventory — what exists

**Rust-side tests (inline `#[cfg(test)]` per module + 3 integration files):**

| Crate | Tests | Gated in CI? |
|---|---|---|
| `mdvcore-core` (21 modules, 7.6k LoC) | ~280 `#[test]` inline (csv 22, find 28, nav 33, outline 21, diff 19, view 19, format 17, cm_edit 15, hex 13, meta 13, filter 12, wire 10, indent 10, … trace 2) + 2 integration tests (`tests/Audit_*_split_parity.rs`, `tests/Audit_*_snapshot_frame.rs`) | YES — merge gate |
| `mdvcore-ffi` | 17 boundary tests (`src/tests.rs`) + manifest-lint gate test (`tests/no_panic_lints_gate_*.rs`) | YES — merge gate |
| `mdvcore-highlight` (unsafe tree-sitter FFI) | 9 tests | **NO** |
| `mdvcore-tui` | 60 tests | **NO** |
| `mdvcore-web` | 75 tests | **NO** |

**Gate** (`/Users/me/Documents/workspaces/claude/markdown_viewer/scripts/rust-core-gate.sh`): `cargo clippy --all-targets` (deny-level no-panic lints: `unwrap_used`/`expect_used`/`indexing_slicing`/`panic`) + `cargo test` — both honoring `default-members = [crates/core, crates/ffi]` (`rust-core/Cargo.toml:24`). CI (`/Users/me/Documents/workspaces/claude/markdown_viewer/.github/workflows/pr.yml:91,98`) runs `build-rust-core.sh` then the gate. Doctests run via `cargo test` for core+ffi.

**Swift-side cross-language tests** (`/Users/me/Documents/workspaces/claude/markdown_viewer/Tests/RustCoreTests/`, a host-headless XCTest target, in the merge gate): A/B parity vs the shipping Swift implementations for csv (`ABTests.swift`), diff parse (`DiffParseABTests.swift`, 14-case corpus), diff hunk marks, hex render/search, indent detect, cm_edit apply; `BridgeTests.swift` pins panic→`.panic` status mapping end-to-end through the dist-profile staticlib; `MsgPackDecoderNegative_*` covers Swift decoder hostile inputs; `SessionPanicDeadFlag_*` covers the dead-handle contract. CI rebuilds `libmdvcore_ffi.a` fresh before Swift tests, so the A/B genuinely tests current Rust source (on the VM it links the rsynced prebuilt — acceptable, documented).

**Notably good practice found (credit where due):** the wire single-alloc rewrite keeps the legacy implementation in-tree as a byte-identity oracle (`crates/core/src/wire.rs:228-283`); trailing-garbage and framing-bound negative tests exist (`wire.rs:305-374`); `build-rust-core.sh` hard-rejects linking the `panic=abort` profile into the GUI host; the manifest-text gate test (`crates/ffi/tests/no_panic_lints_gate_*.rs`) is a legitimate meta-test guarding a real lint-coverage hole, with an honest writeup of why a manifest assertion is the right probe.

**What does NOT exist:** fuzzing (no fuzz dir, no libfuzzer/afl/arbitrary in `Cargo.lock`), property-based testing (no proptest/quickcheck), Miri/sanitizers, benches (no criterion, no benches/), mutation testing, shared golden corpus files (all parity corpora are inline string literals duplicated per language).

## 2. Findings

**F1 [S2] ~144 tests across three crates never run in any CI lane; the crates are never clippy-linted.** `rust-core-gate.sh` operates on default-members only (core+ffi); `mdvcore-highlight` (9 tests), `mdvcore-tui` (60), `mdvcore-web` (75) are outside it, and no other workflow runs them (`pr.yml` greps confirm only `build-rust-core.sh` + the gate). Evidence: `rust-core/Cargo.toml:24` (`default-members`), `scripts/rust-core-gate.sh:40-44`, `crates/highlight/Cargo.toml` (\"NOT in default-members, so it never enters the merge gate\"). The highlight crate is exactly where the known TSK-410 mis-highlight bug lives (tree-sitter `#match?`/`#eq?` predicates never evaluated — `crates/highlight/src/lib.rs` query handling) — an undertested unsafe-C-binding crate shipping in both front-end binaries. Fix: proposal 5.

**F2 [S3 — TEST LIE] `single_writer_busy_under_contention` cannot fail for the behavior its name claims.** `crates/ffi/src/tests.rs:217-233`: the test name promises Busy-under-contention; the body takes the lock once on one thread, asserts the happy-path `Ok`, and its own comment admits \"To actually test contention we need a concurrently-held guard, so we grab the raw mutex below instead. This branch just sanity-checks the happy path\" — and there is no \"below\"; the contention machinery was never written. Compounding it, the real concurrency test (`concurrent_calls_are_serialized_or_rejected_never_ub`, tests.rs:236-287) treats Busy as merely *permitted* (`busy` counter may be 0 and the test still passes). Net: **the `MdvStatus::Busy` path (handle.rs:110 `WouldBlock → None`) has zero deterministic coverage anywhere**, and the lock-poison recovery branch (`crates/ffi/src/handle.rs:104-109`) has zero coverage of any kind. Fix sketch: barrier-held-lock test asserting Busy exactly, plus a panic-inside-`with` test asserting the handle remains usable (proposal 4).

**F3 [S3] Six of sixteen `extern \"C\"` exports have no Rust-side FFI tests at all.** `mdvcore_cm_apply`, `mdvcore_diff_parse`, `mdvcore_diff_hunk_marks`, `mdvcore_hex_render`, `mdvcore_hex_search`, `mdvcore_indent_detect` (`crates/ffi/src/lib.rs:119,165,210,259,307,369`) appear nowhere in `crates/ffi/src/tests.rs` (grep returns zero hits). The deliberate-misuse matrix (null pointers, null-data-with-nonzero-len, bad UTF-8, garbage frames) exists only for the `session_*` family (tests.rs:84-115,163-178). The Swift A/B tests exercise these exports' happy paths cross-language, which softens this to S3 — but the misuse contract (the part that protects against UB at the C ABI) is untested for 6/16 of the surface. Fix: proposal 4.

**F4 [S3] No fuzzing of any boundary-crossing decoder; no Miri/sanitizer on the only unsafe crate.** `wire::decode_frame` (`crates/core/src/wire.rs:187-210`) parses length-prefixed bytes received across the FFI; `csv::parse`, `diff`, `hex`, `cm_edit` parse arbitrary user files — none fuzzed (no fuzz harness exists anywhere in the workspace). The FFI's own test admits the gap: \"a leak/double-free would surface under Miri / ASan. Here we just prove the loop is stable\" (`crates/ffi/src/tests.rs:208-209`) — and no CI lane runs Miri or any sanitizer. The no-panic clippy wall is static and cannot see panics inside `rmp-serde` internals, debug-overflow arithmetic, or allocation blowups. Fix: proposals 1, 6.

**F5 [S3] Cross-language parity corpora are triplicated by hand with no enforcement.** `DiffParseABTests.swift:13-14`: corpus \"kept in lock-step with `DiffParserTests`\" — by convention only. `ABTests.swift:20-35` re-types the `csv.rs` test cases as Swift string literals. Three copies of truth (Rust unit tests, Swift parser tests, Swift A/B corpus) that drift silently: an edge case added to one is invisible to the others, defeating the purpose of a parity suite. No shared golden corpus files exist anywhere. Fix: proposal 3.

**F6 [S4] Panic-path coverage is single-profile and single-site.** All tests run under the default `panic=unwind` test profile; `mdvcore_force_panic` (tests.rs:65-71, BridgeTests.swift:20-24) panics in a no-lock, no-state path only. There is no test of a panic *while holding the session lock* (the poison path, see F2), and `panic=abort` (`release` profile) behavior is never executed by any test — mitigated decently by the `build-rust-core.sh:43-53` profile rejection guard and the manifest gate test, so this stays S4.

**F7 [S4] No performance regression guard in rust-core.** Zero benches (no criterion in Cargo.lock, no benches/ dir). The Swift `ABTests` measures the parse ratio but only *logs* it (\"ratio logged\", ABTests.swift header) — nothing asserts. The wire.rs single-allocation rewrite shows perf work is happening with no floor under it. Fix: proposal 8.

## 3. Mutation-resistance sampling (would the suite catch real regressions?)

- **csv.rs (477 LoC / 22 tests): STRONG.** Quote-state-machine edges (unterminated quote, escaped quotes, quote-aware detection), all three line-ending regimes, all four caps each individually tripped with exact-output asserts (`abcde…` marker), ragged-row normalization pinned both directions. Most realistic mutants (off-by-one in cap, wrong tie-break in detection — the comma-wins-ties rule is explicitly pinned) die.
- **wire.rs (375 LoC / 10 tests): STRONG.** Byte-identity against the retained legacy implementation is a brutal oracle — nearly any encode mutation dies; decode negatives (trailing garbage at both layers, truncation, hostile 4 GiB prefix, short buffer) kill the decode mutants. Weakness: only one fixed shape per type (no map16/str16 width boundaries) — proposal 2.
- **session.rs (347 LoC / 7 tests + 4 integration): GOOD.** Version monotonicity, idempotent set_filter (version frozen), level-triggered stability, and the snapshot_frame-vs-owned byte equivalence across filtered/empty/refilter states (`tests/Audit_*_snapshot_frame.rs:21-109`) pin the contract tightly for its size.
- **ffi (929 LoC): SPLIT.** Session surface well-defended (null/UTF-8/double-free/1000-handle/8-thread tests); the six stateless exports have zero Rust-side mutants-catchable coverage (F3); Busy/poison branches uncovered (F2).
- **highlight (522 LoC / 9 tests): MOOT — never executed in CI (F1).** Tests themselves are reasonable (per-language classification, segment reconstruction with multibyte) but a regression there is currently invisible to every gate, and TSK-410 demonstrates a real shipped mis-classification the suite didn't block.

## 4. Bottom line

The core+ffi merge gate is genuinely well-built for a PoC — deny-lint wall with a meta-test guarding the lint config, a byte-identity oracle, honest negative tests, real cross-language A/B through the actual staticlib. What separates it from a production core is the **absence of every adversarial-input discipline** (fuzzing, properties, Miri/sanitizers, mutation measurement), **three crates' tests dead in CI** including the unsafe grammar-FFI crate, **a hand-synced triplicated parity corpus**, and two concrete coverage holes at the FFI contract (6 untested exports; the Busy/poison paths — plus one misleadingly-named test that can't fail for what it claims). Proposals 4 and 5 are small, zero-dependency, and close the worst holes immediately; 1, 2, 6 are the production-grade backbone and need owner dep/toolchain approval; 3 and 9 fix the parity strategy structurally.