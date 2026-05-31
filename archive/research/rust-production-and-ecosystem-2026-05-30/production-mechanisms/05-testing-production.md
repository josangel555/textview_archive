# Production-Grade Testing for a Headless Rust Core (FFI + WASM, DST, snapshots, flake control, CI at scale)

## Production-Grade Testing for a Headless Rust Core

Beyond the unit/integration/doctest pyramid, the mechanisms that pay off most for a *sans-IO, synchronous, headless core consumed over FFI/WASM/TUI* are: (1) behavioral coverage via property tests + mutation testing, (2) snapshot/golden management, (3) cross-boundary (FFI/WASM) integration tests, (4) deterministic/simulation testing, and (5) CI infrastructure (a real test runner, sharding, flake quarantine). The good news: a sans-IO synchronous core is the *easiest possible thing to test deterministically* — the design choice you already made is the single biggest testability win. Lean into it.

### The layered strategy

| Layer | Tool | What it buys you | Cost to add later |
|---|---|---|---|
| Unit/property | `proptest` | Behavioral invariants, auto-shrink, seed replay | Cheap anytime |
| Behavioral coverage | `cargo-mutants` | Finds tests that execute but assert nothing | Cheap anytime |
| Snapshot/golden | `insta` + `cargo-insta` | Rendered-output regression at scale | Medium (snapshot churn discipline) |
| Fuzzing | `cargo-fuzz` (libFuzzer) | Parser robustness on untrusted input | Cheap to wire, hard to retrofit corpus |
| FFI ABI | `ctest`/`ctest2` + sanitizers + Miri | Header↔Rust signature/layout drift | **Expensive** |
| WASM | `wasm-bindgen-test` | Core behaves identically in browser/Node | Medium |
| Determinism | seeded core / `madsim`/`turmoil` | Replayable bugs, no time/RNG flakes | **Very expensive** |
| Runner/CI | `cargo-nextest` | Per-test isolation, sharding, retries, JUnit | Cheap to swap in early |

### Coverage that actually means something: property + mutation

Line coverage tells you code *ran*; it doesn't tell you a test *asserts* anything. `cargo-mutants` injects bugs (e.g. swaps a return value) and checks whether any test fails — surfacing "tests that execute but verify nothing." It works on an unmodified tree (unlike the abandoned `mutagen`) and is actively maintained (as of Aug 2025). Run it in CI on the diff (mutate only changed functions) to keep it fast. Pair with **`proptest`** over `quickcheck`: proptest uses composable `Strategy` objects (vs quickcheck's one-generator-per-type), shrinks richer inputs to minimal failing cases, and **persists failing seeds to a regression file** that is replayed on every future run — bank those as permanent regression tests.

### Snapshot/golden management at scale

`insta` is the de-facto snapshot library. Workflow: a changed output writes a `.snap.new`; `cargo insta review` gives an interactive accept/reject diff TUI; accepted snapshots promote to `.snap`. **The load-bearing CI rule**: set `CI=true` (or `INSTA_UPDATE=no`) so CI *fails on drift and never writes new snapshots* — otherwise a stale snapshot silently auto-passes. Use `insta`'s `glob!` to run one test body across a directory of input fixtures (ideal for a document parser/renderer). At scale the failure mode is snapshot churn: a formatting tweak rewrites thousands of files and reviewers rubber-stamp them. Mitigate by keeping snapshots small and semantically focused (rust-analyzer's rule: *minimal* snippets, strip everything removable) and redacting volatile fields.

### Crossing the FFI boundary — where retrofitting hurts most

Rust's own type checker stops at the `extern "C"` line; past it you have a hand-maintained contract between Rust and Swift/C headers. Two complementary defenses:

- **Static contract check:** `ctest`/`ctest2` parses your `-sys`/header definitions and *generates* a Rust+C test that asserts function signatures, constant values, and **struct size/layout/alignment** match. This catches the silent killer — a field reorder or `usize`-vs-`u32` mismatch that compiles fine and corrupts memory at runtime. `ctest2` is a maintenance fork ("minimal maintenance" on lib.rs); the original `ctest` resumed maintenance (MSRV 1.88). Generate the header with `cbindgen` and diff it in CI so the C side can't drift from Rust.
- **Dynamic UB check:** **Miri** finds UB (misaligned access, aliasing violations, data races, uninitialized reads, dangling pointers) in *Rust* code — run `cargo +nightly miri test` on the unsafe FFI-edge wrappers. **Critical limitation for your architecture:** Miri executes only Rust; it cannot run across the real FFI boundary into Swift/C (an experimental `-Zmiri-native-lib` exists but is not production-ready). So Miri validates the Rust side of the boundary; for the actual linked artifact you need **AddressSanitizer/LeakSanitizer** builds run from the host-language test harness (Swift XCTest calling the real `.a`/`.dylib`). Sanitizers are your only runtime defense against memory corruption at the true boundary.
- **Fuzz the parsing surface:** parsers "have to behave correctly on untrusted data" and are the canonical high-value fuzz target. Wire `cargo-fuzz` (libFuzzer; needs nightly for sanitizer instrumentation) day one — it's cheap to add but the *corpus* compounds over time, so start it early and consider OSS-Fuzz if the project goes public. Seed the corpus with real documents; use `cargo fuzz cmin` to keep it from bloating.

### WASM boundary

`wasm-bindgen-test` mirrors `#[test]` but runs in Node or a headless browser over WebDriver (`wasm-pack test --headless --firefox/--chrome`). Strategy: run the bulk of the synchronous core's logic tests as native `cargo test` (fast), and a *targeted* WASM suite to catch wasm-specific divergence (32-bit `usize`, float NaN canonicalization, JS interop marshalling, panic=abort behavior). Tests must live in the crate root or a `pub mod` — private modules silently don't register.

### Determinism / simulation testing

A synchronous sans-IO core sidesteps most of this — there's no scheduler, clock, or network *inside* the core to make non-deterministic. The threat is at the **async I/O edges** (file watching, LSP, remote). The S2.dev (Apr 2025) and Polar Signals (Jul 2025) write-ups show the real cost: making async deterministic requires controlling *every* entropy source — `tokio` single-threaded paused-clock + seeded `select!` RNG, plus `madsim`/`turmoil` overriding libc `getrandom`/`clock_gettime`. The non-obvious gotcha they all hit: hidden non-determinism leaks in via dependencies (timestamps in HTTP packets, **Rust's DoS-randomized `HashMap` iteration order**) and shows up as "passes locally, fails in CI." The architecture lesson: keep the deterministic synchronous core as large as possible and the async shell as thin as possible — exactly your stated design.

### CI infrastructure

Swap `cargo test` for **`cargo-nextest`** early (Apache-2.0, widely adopted from OSS to FAANG): per-test process isolation, ~3× faster, slow-test timeouts, automatic retries for flaky tests, JUnit XML, and **build-once/run-many** archiving. For sharding it offers `--partition hash:m/n` (stable bucketing — a test stays in its bucket as the suite grows, the right default) and `--partition slice:m/n` (even round-robin); `count:` is deprecated. The Rust project itself merges via a queue testing one PR at a time across 50+ platform configs, plus a `crater`/cargotest regression run against real downstream crates (servo, ripgrep, tokei) — the scaled-up version of "test your consumers." For flakes, the consensus (Trunk/Datadog, and the Schroeder et al. 2025 Rust flaky-test study) is **detect → quarantine (still run, don't fail the build, cap at ~5% of suite) → assign an owner → fix**. That study found **33.9% of Rust flakes were async-wait bugs and 24.5% concurrency** — and ~51% of fixes were in *product code, not the test*, i.e. flaky tests frequently expose real races. rust-analyzer's hard rules are worth adopting verbatim: **no `#[ignore]`, no `#[should_panic]`** (assert the concrete `Err`/`None`), and gate genuinely slow tests behind an env var (`RUN_SLOW_TESTS=1`).


## Key takeaways
- Your synchronous sans-IO core is the single biggest testability win you already have — non-determinism lives only at the async I/O edges, so keep the deterministic core large and the async shell thin. Full deterministic-simulation testing (madsim/turmoil + seeded clock/RNG) is very expensive to retrofit; you mostly avoid needing it by construction.
- Adopt cargo-nextest as the runner from day one (cheap swap): per-test process isolation, retries, slow-test timeouts, JUnit, and build-once/run-many sharding via --partition hash:m/n (stable bucketing is the right default).
- Coverage % is a lie about test quality; cargo-mutants tells you whether tests actually assert behavior. Run it diff-scoped in CI. Pair with proptest (composable strategies + persisted failing-seed regression files) over quickcheck.
- FFI is where retrofitting hurts most: combine ctest/ctest2 (static signature + struct layout/alignment checks, cbindgen header diffed in CI) with Miri (Rust-side UB) AND AddressSanitizer/LeakSanitizer run from the Swift/host harness — Miri canNOT cross the real FFI boundary into C/Swift.
- Fuzz the document parser early with cargo-fuzz: cheap to wire, but the corpus compounds over time so starting late loses that value. Parsers on untrusted input are the canonical high-value fuzz target.
- insta for snapshots, but the load-bearing rule is setting CI=true so CI fails on drift and never auto-writes snapshots; keep snapshots minimal/redacted to avoid review-rubber-stamping churn.
- Run the bulk of logic tests as fast native cargo test; add a targeted wasm-bindgen-test suite only for wasm-specific divergence (32-bit usize, float NaN, JS marshalling, panic=abort).
- Steal rust-analyzer's discipline: no #[ignore], no #[should_panic] (assert concrete Err/None), minimal test snippets, and gate slow tests behind RUN_SLOW_TESTS=1. Treat flaky tests as likely real bugs — the 2025 Rust study found ~51% of flake fixes were in product code, and 33.9% of flakes were async-wait bugs.

## Gotchas
- Miri executes Rust only — it cannot run through your actual Swift/C FFI calls (experimental -Zmiri-native-lib is not production-ready). For the real linked artifact you must run ASan/LSan builds from the host-language (Swift XCTest) harness; Miri only validates the Rust side of the boundary.
- insta in CI without CI=true (or INSTA_UPDATE=no) silently writes new snapshots and passes — defeating the whole point. Set it explicitly in the CI env.
- Rust's HashMap randomizes iteration order per-process for DoS resistance — a classic source of 'passes locally, fails in CI' flakiness and non-reproducible snapshots. Sort before snapshotting/asserting, or use a deterministic map.
- cargo-fuzz requires nightly (LLVM sanitizer instrumentation isn't stabilized) — budget a nightly toolchain in CI for the fuzz job specifically.
- ctest2 is a maintenance fork flagged 'minimal maintenance' on lib.rs; the upstream ctest resumed (MSRV 1.88). Pick deliberately and pin — don't float between them.
- FFI struct layout mismatches (field reorder, usize-vs-u32, padding/alignment) compile cleanly and corrupt memory only at runtime. Only a generated layout assertion (ctest) or a sanitizer catches these — the type checker won't.
- wasm-bindgen-test tests in a *private* module silently don't register; they must be in the crate root or a `pub mod`.
- Snapshot churn: a single formatting change can rewrite thousands of .snap files, and reviewers rubber-stamp the diff — eroding the regression value. Keep snapshots small, focused, and redact volatile fields.
- Don't make async tests deterministic by sprinkling sleep()s — the 2025 Rust flaky-test study found improper async waits were 38% of async flakes. Use explicit completion signals (channels/notifies), or a paused tokio clock.
- Mutation testing and fuzzing are slow; running them unscoped on every PR will tank CI. Scope mutants to the diff and run fuzzing as a separate scheduled/long job, not a blocking gate.

## Crates
- cargo-nextest — next-gen test runner: per-test process isolation, retries for flaky tests, slow-test timeouts, JUnit XML, build-once/run-many archiving, hash/slice sharding — Apache-2.0, widely adopted (OSS to FAANG), actively maintained; adopt day one
- proptest — property-based testing with composable Strategy objects, rich shrinking, and persisted failing-seed regression files — most-used property framework, actively maintained (proptest-rs org); preferred over quickcheck for complex inputs
- quickcheck — simpler type-driven property testing (one generator/shrinker per type) — maintained (BurntSushi); fine for straightforward cases, less flexible than proptest
- cargo-mutants — mutation testing on an unmodified tree; finds tests that run but assert nothing — actively maintained (sourcefrog, as of Aug 2025); run diff-scoped in CI
- insta + cargo-insta — snapshot/golden testing with interactive review TUI, glob fixtures, serde formats — de-facto standard, actively maintained (mitsuhiko); set CI=true to fail-on-drift
- cargo-fuzz — libFuzzer-based fuzzing; ideal for the document parser surface — maintained (rust-fuzz); requires nightly; OSS-Fuzz integration available for public projects
- ctest / ctest2 — generates Rust+C tests asserting FFI signature/constant/struct-layout/alignment parity for -sys crates — ctest resumed maintenance (MSRV 1.88); ctest2 is a 'minimal maintenance' fork; pick one and pin
- cbindgen — generates C/C++ headers from Rust; diff the output in CI to detect Rust↔header drift — widely used, maintained (mozilla)
- wasm-bindgen-test — #[test]-style tests runnable in Node or headless browser over WebDriver — maintained (rustwasm); use via wasm-pack test --headless
- Miri — interpreter that detects UB (aliasing, alignment, data races, uninit, dangling) in Rust code — official rust-lang tool, actively developed; run on FFI-edge wrappers, but cannot cross into C/Swift
- madsim — deterministic async runtime (tokio-shaped) overriding libc time/RNG for simulation testing — maintained (madsim-rs); only needed if the async edge grows complex
- turmoil — tokio's deterministic network/host/time simulation for distributed tests — maintained (tokio-rs); pair with madsim-style entropy control

## Sources
- https://github.com/sourcefrog/cargo-mutants — cargo-mutants README (active maintenance noted Aug 2025)
- https://mutants.rs/ — cargo-mutants official docs: behavioral coverage vs line coverage
- https://altsysrq.github.io/proptest-book/proptest/vs-quickcheck.html — Proptest vs Quickcheck (strategies, shrinking, seed persistence)
- https://github.com/BurntSushi/quickcheck — quickcheck README
- https://github.com/mitsuhiko/insta — insta snapshot testing (CI=true fail-on-drift, glob, review workflow)
- https://nexte.st/ — cargo-nextest overview (per-test isolation, retries, ~3x faster, CI features)
- https://nexte.st/docs/ci-features/partitioning/ — nextest partitioning: hash vs slice sharding, build archiving examples (accessed May 2026)
- https://github.com/JohnTitor/ctest2 — ctest2 (FFI signature/layout/alignment testing; fork status)
- https://docs.rs/crate/ctest2/latest — ctest2 'minimal maintenance' status
- https://github.com/gnzlbg/ctest — original ctest (resumed maintenance, MSRV 1.88)
- https://rustwasm.github.io/docs/wasm-bindgen/wasm-bindgen-test/browsers.html — Testing in Headless Browsers (wasm-bindgen-test over WebDriver)
- https://rustwasm.github.io/docs/wasm-bindgen/wasm-bindgen-test/usage.html — wasm-bindgen-test usage (pub mod requirement, Node vs browser)
- https://github.com/rust-lang/miri — Miri: UB detection capabilities and FFI limitation (-Zmiri-native-lib experimental)
- https://www.ralfj.de/blog/2025/12/22/miri.html — Ralf Jung, 'What's new in Miri' (Dec 2025)
- https://rust-fuzz.github.io/book/cargo-fuzz.html — Rust Fuzz Book: cargo-fuzz (nightly requirement, libFuzzer, corpus/cmin)
- https://google.github.io/oss-fuzz/getting-started/new-project-guide/rust-lang/ — OSS-Fuzz Rust integration guide
- https://s2.dev/blog/dst — 'Deterministic simulation testing for async Rust', S2.dev (Apr 2, 2025): tokio paused clock, seeded select!, mad-turmoil, hidden entropy gotchas
- https://www.polarsignals.com/blog/posts/2025/07/08/dst-rust — Polar Signals, 'DST in Rust: A Theater of State Machines' (Jul 8, 2025)
- https://github.com/madsim-rs/madsim — madsim deterministic simulator (libc override approach)
- https://docs.rs/turmoil — turmoil deterministic network/time simulation (tokio-rs)
- https://arxiv.org/abs/2502.02760 — Schroeder, Phan, Chen (UIUC, 2025), 'A Preliminary Study of Fixed Flaky Tests in Rust Projects on GitHub': 33.9% async-wait, 24.5% concurrency, ~51% fixes in product code
- https://rustc-dev-guide.rust-lang.org/tests/compiletest.html — Rust Compiler Dev Guide: compiletest test suites
- https://rustc-dev-guide.rust-lang.org/tests/running.html — running rustc tests (RUST_TEST_THREADS, artifact-change skipping)
- https://brson.github.io/2017/07/10/how-rust-is-tested — 'How Rust is tested': merge queue, 50+ platform configs, crater/cargotest downstream regression
- https://rust-analyzer.github.io/book/contributing/style.html — rust-analyzer style: no #[ignore], no #[should_panic], minimal test snippets
- https://rust-analyzer.github.io/book/contributing/ — rust-analyzer contributing: RUN_SLOW_TESTS, unit-test-first workflow
- https://trunk.io/blog/the-ultimate-guide-to-flaky-tests — flaky test detection (rerun vs historical) and quarantine strategy
- https://www.datadoghq.com/blog/datadog-flaky-tests/ — Datadog on flaky-test costs, quarantine, ownership