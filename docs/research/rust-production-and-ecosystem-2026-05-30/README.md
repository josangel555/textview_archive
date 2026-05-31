# Rust Production & Ecosystem Research — 2026-05-30

> Provenance: workflow wf_0597d2a6-f2b (15 agents: 13 research + crate-health verify + synth). Read-only. Detailed per-dimension reports are in the two subfolders; this README holds the cross-cutting synthesis + index.

## Index

### Production mechanisms
- [Production logging in Rust: tracing vs log, structured/span discipline, FFI/WASM/headless output, hot-path cost, redaction, and dynamic levels](production-mechanisms/01-logging.md)
- [Telemetry, Metrics & Distributed Tracing in Rust: ecosystem maturity and day-one design for a desktop + server core](production-mechanisms/02-telemetry.md)
- [Crash Reporting for a Rust Core (FFI-in-Swift, Headless Linux, WASM)](production-mechanisms/03-crash-reporting.md)
- [Debug Mode & Diagnostics in Production Rust](production-mechanisms/04-debug-mode.md)
- [Production-Grade Testing for a Headless Rust Core (FFI + WASM, DST, snapshots, flake control, CI at scale)](production-mechanisms/05-testing-production.md)
- [Other From-The-Get-Go Production Mechanisms for a Rust Core + Headless Service](production-mechanisms/06-other-production.md)

### Ecosystem learnings
- [How Experienced Rust Teams Actually Develop: Mental Models, API Culture, Compile-Time Discipline, and High-ROI Habits](ecosystem-learnings/01-rust-dev-practices.md)
- [Agentic / AI-Assisted Rust Development: What Helps an Agent Produce Correct Rust](ecosystem-learnings/02-agentic-rust.md)
- [Learnings from Large Rust Codebases: Architecture, Compile Times, and Scaling](ecosystem-learnings/03-large-codebases.md)
- [Rust at Mozilla: Shipping Rust Incrementally Inside a Huge C++ Codebase (Servo, Oxidation, Stylo, WebRender)](ecosystem-learnings/04-rust-mozilla.md)
- [Rust in the Linux Kernel: Technical Constraints, Maintainer Friction, and Transferable Lessons](ecosystem-learnings/05-rust-linux.md)
- [Rust at Microsoft: Windows kernel rewrites, the windows-rs interop layer, formally-verified crypto, and what adoption-at-scale actually taught them](ecosystem-learnings/06-rust-microsoft.md)
- [Rust at Large Shops: Documented ROI, Post-Mortems, and Adoption Lessons](ecosystem-learnings/07-rust-other-shops.md)

---

## Synthesis

# TextView Rust Core — Cross-Cutting Synthesis

> **What this is.** The README tying together 13 per-dimension research reports + a live crate-health verification (2026-05-30). It does **not** re-summarize each dimension — it synthesizes *across* them into decisions for a first major Rust project: a `forbid(unsafe_code)`, synchronous, sans-IO, minimal-dependency headless core embedded via Swift FFI, WASM, ratatui TUI, and a headless Linux server.
>
> **Three facts shape every recommendation below.** (1) The core *emits* and *exposes* — it never *installs* a subscriber, recorder, exporter, or panic policy; the four host shells own all of that. (2) The expensive-to-retrofit decisions are not features — they're *postures*: panic strategy, error-type architecture, on-disk format tagging, time-injection, and the FFI ABI shape. (3) The verifier's corrections are applied throughout; refuted claims do not appear.

---

## 1. From-the-get-go production-readiness checklist

Prioritized by **(retrofit cost × blast radius)**, not by how interesting the mechanism is. Each row: the concrete first step, why late is expensive, and the crate verdict under our minimal-deps / no-unsafe / sync-first constraints.

### Tier 0 — Postures that are nearly impossible to retrofit (do before line 1 of logic)

| # | Mechanism | Concrete first step | Crate verdict | Cost of retrofitting late |
|---|---|---|---|---|
| 0.1 | **Panic strategy + FFI firewall** | `panic = "unwind"` in the editor profile; wrap *every* `extern "C"` body in `catch_unwind` → error code; use `extern "C-unwind"` only as a defined-abort backstop. | `std::panic` / `std::backtrace` — **STD-SUFFICES**, zero deps. | Changing unwind↔abort changes ABI obligations at *every* FFI function. UB if you discover late that panics cross into Swift. |
| 0.2 | **Error-type architecture** | Hand-rolled `thiserror` enums in the core, `Send + Sync + 'static`, `#[non_exhaustive]`, `#[source]`/`#[from]` cause chains. `anyhow` confined to host edges. | `thiserror` **2.0.18** / `anyhow` **1.0.102** — **RECOMMEND**. | `anyhow`-in-a-library type-erases errors; every embedder loses the ability to `match`. Un-erasing later is a large mechanical refactor across 4 embeddings. |
| 0.3 | **Time injection (sans-IO discipline)** | Ban `Instant::now()` in the core. Pass `now: Instant` into `handle_timeout(now)` / `poll_timeout() -> Option<Instant>`. | STD. No crate. | This is *the* unlock for deterministic property testing. Retrofitting means threading a clock through every stateful path — quinn-proto/str0m did it day one for this reason. |
| 0.4 | **On-disk / FFI format versioning** | Magic header + format version on persistent state; tolerant deserialize (`serde` `default`/`alias`), **not** `deny_unknown_fields`; upgrade-on-load via compat structs; **test the downgrade path**. | `serde` (STD-adjacent, justified) — **RECOMMEND**. | Highest-regret retrofit in the set. An untagged format + strict deser is a classic prod incident the day an old binary opens a new file. rust-analyzer's *documented* regret: a format went de-facto stable before they meant it to. |
| 0.5 | **Breaking-change insurance** | `#[non_exhaustive]` on public enums/errors; private struct fields; sealed traits; pinned MSRV with a written policy; `cargo-semver-checks` in CI. | `cargo-semver-checks` **0.47.0** — **RECOMMEND**. | Each item is impossible to add later without a major-version bump. 1-in-6 top crates ship an *accidental* semver break; 4 embeddings multiply the blast radius. |

### Tier 1 — Cheap now, awkward later (wire during initial scaffolding)

| # | Mechanism | Concrete first step | Crate verdict | Cost of retrofitting late |
|---|---|---|---|---|
| 1.1 | **`tracing` facade, emit-only** | `tracing` events with **structured fields** (`info!(doc.bytes = n, "opened")`), `#[instrument(skip(content, path, buf))]` everywhere. Core installs **no** subscriber and **never** sets `release_max_level_*`. | `tracing` **0.1.44** — **RECOMMEND**. Keep `log` feature for log-based hosts. | Subscriber wiring is cheap to add per-host; **span boundaries in hot paths are the costly retrofit**. Field-vs-string-interpolation is a global rewrite if deferred. |
| 1.2 | **Panic-hook record capture** | Host-installed `set_hook` captures `(message, location, Backtrace::capture())` while stack is intact, hands a structured record to the host transport. Core stays out of I/O. | STD — **STD-SUFFICES**. | Capturing after the stack unwinds yields useless backtraces. |
| 1.3 | **`diagnostic_snapshot() -> Report`** | One pure fn over top-level core state. Sans-IO makes it trivial; one call feeds logs, crash dumps, a debug command, and a WASM export. Wire triggers (`SIGUSR1`, hidden UI cmd, WASM export) at the edges. | STD. No crate. | Bolting introspection onto a core that wasn't built to expose its state means plumbing accessors through every module. |
| 1.4 | **Panic-lints as policy** | `#![forbid(unsafe_code)]` on the core; `#![deny(clippy::unwrap_used, expect_used, indexing_slicing)]`; centralized `[lints]` in `Cargo.toml`; `clippy -D warnings` in CI. | Clippy (toolchain) — **STD-SUFFICES**. | Adopting clippy/semver-checks late is a demoralizing multi-week cleanup. Agents *obey lints far more reliably than prose* (see §3). |
| 1.5 | **Secrets/PII as types** | Wrap secrets in `secrecy::SecretBox` (no `Debug`/`Display`, zeroize-on-drop) so accidental logging is a **compile error**. Make `skip(content)` the `#[instrument]` default — for an editor, **document content is PII**. | `secrecy` **0.10.3** — **RECOMMEND**. `redact` **0.1.11** — **CAUTION** (0.1.x, low base; evaluate). | Retrofitting redaction after content has leaked into spans/snapshots is a forensic exercise; don't rely on collector-side regex scrubbing. |
| 1.6 | **Supply-chain gates** | Commit `Cargo.lock`; build `--locked`; `cargo-deny` + `cargo-audit` on first green CI; `cargo auditable`; `--remap-path-prefix`. | `cargo-deny` **0.19.8**, `cargo-audit` **0.22.1** — **RECOMMEND**. | Pin exact versions (agents hallucinate versions). `-sys` crates vendoring C are an SBOM blind spot — note for the native edge. |

### Tier 2 — Build the harness early, expand the suite continuously

| # | Mechanism | Concrete first step | Crate verdict | Cost of retrofitting late |
|---|---|---|---|---|
| 2.1 | **`cargo-nextest` runner** | Adopt day one — per-test process isolation, retries, slow-test timeouts, JUnit, `--partition hash:m/n` sharding. | `cargo-nextest` **0.9.137** — **RECOMMEND**. | Cheap swap anytime, but the isolation/flake-retry hygiene wants to be the default from test #1. |
| 2.2 | **Property testing** | `proptest` with composable strategies + **persisted failing-seed regression files**. Sort before snapshot/assert (HashMap iteration is per-process random). | `proptest` **1.11.0** (— `quickcheck` **1.1.0** for simple cases) — **RECOMMEND**. | The seeded-clock + sans-IO core makes property testing *almost free*; the value compounds, so starting late forfeits the corpus. |
| 2.3 | **Parser fuzzing** | `cargo-fuzz` on the document parser early; corpus compounds over time. Prefer **lenient, fuzzed** edge parsing over RFC-strict rejection. | `cargo-fuzz` **0.13.1** — **RECOMMEND** (needs a **nightly** CI toolchain for that job). | Late fuzzing forfeits the accumulated corpus — the single most valuable artifact. Untrusted-input parsers are the canonical high-ROI target (Mozilla mp4parse). |
| 2.4 | **FFI layout verification** | `ctest` (generated `#[repr(C)]` layout/alignment assertions) + `cbindgen` header **checked into the repo and CI-diffed**. ASan/LSan from the **Swift XCTest** harness; Miri for the Rust side only. | `ctest` **0.5.0** — **RECOMMEND** (**prefer `ctest`, migrate off `ctest2`** — the fork is winding down). Miri — **RECOMMEND** (cannot cross into Swift/C). | Struct-layout mismatches (field reorder, `usize`-vs-`u32`, padding) **compile cleanly and corrupt memory at runtime**. Only a generated assertion or a sanitizer catches them. |
| 2.5 | **Snapshot tests** | `insta`, **`CI=true`** so CI fails on drift and never auto-writes. Keep snapshots small + redacted to avoid rubber-stamped churn. | `insta` **1.47.2** — **RECOMMEND**. | `insta` without `CI=true` silently writes new snapshots and passes — defeating the point. |
| 2.6 | **Mutation testing** | `cargo-mutants` **diff-scoped** in CI (not whole-tree on every PR). Coverage % lies; mutants tell you whether tests *assert*. | `cargo-mutants` **27.0.0** (CalVer) — **RECOMMEND**. | Slow if unscoped; scope to diff + run fuzzing as a scheduled job, not a blocking gate. |
| 2.7 | **Dual-profile CI + UB checks** | Run CI in debug **and** a release-like profile with `overflow-checks = true` + `debug-assertions = true`. Since **Rust 1.78**, this arms std's unsafe-precondition checks *at your callsites* — free UB detection on your own FFI-edge unsafe. | Toolchain — **STD-SUFFICES**. | `overflow-checks` default **OFF** in release: offset/length/cursor math wraps silently in prod but panics in dev. A real corruption vector for an editor. |

### Deferred — do **not** build preemptively (the get-go discipline cuts both ways)

| Mechanism | Why defer | Trigger to revisit |
|---|---|---|
| Out-of-process minidump capture (`crash-handler` + `minidumper` + `minidump-writer`) | Real value, but heavyweight; in-process minidump writing is unreliable. Panic hook + offline symbolication covers the common case first. | When native (non-panic) segfaults in the FFI/native edge become a real support burden. Crates are healthy (**0.7.0 / 0.10.1 / 0.12.0**). |
| OTel SDK / exporters | Tightly version-locked 0.x, churny (0.28 broke all 3 signals); Traces still **Beta**, combined 1.0 slipped past mid-2025. Pulls Tokio at the gRPC edge. | When the headless server needs OTLP. Start the server shell on `tracing-subscriber` to keep the door open; **never** pull OTel into the core. |
| `sentry` crash channel | Heavy transitive tree; can't capture hard native crashes anyway (only panics). | Consent-gated, at the host edge only. `sentry` **0.48.2** — CAUTION (weight). |
| `madsim`/`turmoil` full DST | Very expensive to retrofit — but you mostly *avoid needing it by construction* via the sans-IO core. | Only if the async shell grows non-trivial concurrency. |
| Salsa / query-engine incrementality | Heavy; rustc/rust-analyzer earned it under interactive-latency pressure. | When large-doc latency forces fine-grained incrementality. Start with dirty-flag recompute. |
| `static_assertions`, `divan`, `figment` | `static_assertions` (2019, dormant) — modern `const {}` asserts cover most of it; `divan` (slowing, single-maintainer) — `criterion` **0.8.2** is the safer benchmark default (the "criterion unmaintained" worry is **stale**); `figment` (~2 yrs stale) — `config` **0.15.23** is *more* active now, but prefer **std + serde** in the core regardless. | Edge-only, if a concrete pain point justifies the dep. |

---

## 2. What the ecosystem learnings mean for US

The cross-org pattern is unambiguous: **the language is the cheap part; integration, governance, and discipline are the project.** Mozilla's mp4parse was ~6 weeks of Rust and ~a year of build/CI/platform plumbing. Translate that into concrete dos/don'ts for a first major Rust project.

### The convergent wins (every org agrees)

| Lesson | Source convergence | Concrete DO for TextView |
|---|---|---|
| **Sans-IO synchronous core is the validated shape** | quinn-proto, str0m, rust-analyzer (hir/ide), Firezone connlib, Dropbox Nucleus | Already chosen — *commit to it.* Pass time/I/O in as data; expose `handle_input` / `poll_transmit` / `handle_timeout` / `poll_timeout`. Surgical parallelism only where embarrassingly parallel (Stylo's cascade succeeded; Servo's parallel layout was "completely broken" and rewritten). |
| **`unsafe`-confined-to-audited-edge is the actual model** | Google (~4% unsafe still vastly safer), Microsoft (2019 rule, unchanged), Linux RfL (thin audited FFI + safe wrappers) | `#![forbid(unsafe_code)]` on the core; `unsafe` only in the FFI shim, locally encapsulated, extra review scrutiny. Don't blanket-`unsafe` host calls — it causes **alarm fatigue** and hides the genuinely dangerous sites. |
| **Type-system-enforced invariants are the moat** | Stylo (compile-time data-race-freedom enabled parallelism two C++ attempts couldn't), Dropbox ("design away invalid states") | Newtype + typestate + make-illegal-states-unrepresentable. Encode invariants **once**; all four embeddings inherit them. This is zero-cost and the single highest-leverage habit. |
| **CI gate from commit one** | Every large shop; rust-analyzer; the agentic literature | `clippy -D warnings`, `nextest`, `cargo-semver-checks`, `cargo-deny`, fmt, doc-lint. Adopting late is "a demoralizing cleanup." |
| **Async strictly at the I/O edge** | corrode, WyeWorks, Rust Foundation, Cloudflare (went all-in on tokio *only because Pingora is purely I/O-bound*) | Keep async out of the core entirely — `'static`-on-spawned-tasks fights the borrow checker and pins libraries to one executor. **Don't cargo-cult "tokio everywhere"** from proxy case studies into a CPU-bound document core. |

### The non-obvious DON'Ts (the expensive surprises)

- **Don't transfer allocation ownership across FFI** when Rust and Swift use different allocators — "disastrous consequences." Provide Rust-side destructor FFI fns, or pin a shared `#[global_allocator]`.
- **Don't pass non-POD types by value across FFI** — works on some toolchains, broken on MSVC, ABI-fragile. Marshal through `#[repr(C)]` POD structs at the boundary. Keep the boundary to a **C ABI** (C++ interop is the genuinely hard part, not C).
- **Don't read a C-set integer as a Rust enum** — C enums can hold invalid values, Rust enums can't; out-of-range → instant UB. Use integers for bitflag-style fields across FFI.
- **Don't make the FFI surface chatty.** Aim for ~10 coarse-grained functions per component (Stylo's tight callback-heavy integration was Mozilla's hardest-ever; the engineer who built it says *don't copy it*). Chatty FFI also defeats inlining (Servo perf regression).
- **Don't reach for `Rc<RefCell<T>>` as the reflexive `shared_ptr` translation** — it compiles but discards static aliasing guarantees and converts compile-time errors into runtime panics. It's a smell your ownership graph is wrong.
- **Don't trust strictness as a force field.** Google's first near-miss (CVE-2025-48530) was a buffer overflow in *safe-ish* Rust, saved only by allocator guard pages — and crash reporting initially failed to find the cause. Keep allocator hardening, fuzzing, and observability **even with a safe core**.
- **Don't over-genericize.** `impl Trait`/generics everywhere → monomorphization blowup: slower builds, bigger binaries — directly relevant to the **16 MB executable sub-cap**. Use `dyn` where speed doesn't justify the cost.
- **Don't expect telemetry forgiveness.** VS Code's opt-*out* telemetry drew years of backlash. Desktop telemetry must be **opt-in, default-off, no pre-checked boxes, show-the-payload** (rustc's local-first principle). Server is opt-in-by-default-with-redaction — a structurally different posture.

### The cultural reality to budget for

- **Seniors struggle *more* than juniors** — hubris (forcing familiar C++/Swift shapes) is the #1 failure mode. Budget several weeks of reduced productivity; type-driven development pays it back.
- **Write a one-page style guide on day one.** "Multiple valid ways" generates low-value review churn (clone-vs-lifetime, generics depth, macros) — a recurring friction tax without a written guide.
- **Compile time is a daily metric.** Inner loop = `cargo check` + a background watcher; split into workspace crates early (the crate boundary is *the* parallelism/incrementality lever — crates are whole-program-compiled); profile with `cargo build --timings` before optimizing. One integration-test crate, not many (each `tests/*.rs` relinks separately). **Don't** adopt `cargo-hakari` early (earns its keep only past dozens of crates).
- **Keep dependencies current continuously.** A multi-year-abandoned Rust codebase rots hard (Servo's revival needed massive dep upgrades before any feature work). The 0.x OTel churn makes this acute at the server edge.
- **Sustainability is the real risk for a solo/small project.** Servo's near-death was funding/ownership, not tech. The solo analogue is **scope discipline** — don't build more engine than one person can maintain.

---

## 3. Agentic-Rust setup

The strongest reason Rust suits coding agents: **`cargo check` + clippy + the trait solver form a tight, machine-verifiable loop that mechanically rejects unsound output before review.** But the academic numbers are sober — best baseline on Rust-SWE-bench (real repo bugs) is ~21% resolved (~29% with the best scaffolding); greenfield agentic Rust is strong, repo-level bug-fixing is still hard. Structure the repo so the agent's failure modes are designed out.

### The two quantified failure modes → structural countermeasures

| Agent failure mode | Share of compile errors | Repo structure that addresses it |
|---|---|---|
| Failing to model repo-wide structure | **43.7%** | **Many small crates, small files.** Flat `crates/*` workspace, crate-name == folder-name, virtual root manifest, internal crates at `0.0.0`. Automation as a `cargo xtask` crate. |
| Violating type/trait semantics | **32.6%** | **Strong types + small APIs.** Newtype/typestate constrain what the agent *can* write. Over-genericized APIs are where weak models spiral on lifetimes. |
| Reproduction-stage failure | **44.5%** of repo-level tasks | **Trivial reproducibility.** Sans-IO pure functions + an automated test workspace + runtime tracing drove almost the entire framework win. This is the single highest-leverage agentic investment. |

### Encode policy as lints, not prose

Agents obey the compiler far more reliably than a `CLAUDE.md` paragraph — and **IDE-based tools sometimes ignore context-loaded rule files entirely.** Back every convention with an enforced lint:

```toml
# Cargo.toml — centralized [lints], the agent cannot escape these
[lints.rust]
unsafe_code = "forbid"        # agents silence the compiler with stray `unsafe impl Send`; forbid is the only reliable guard

[lints.clippy]
unwrap_used = "deny"
expect_used = "deny"
indexing_slicing = "deny"     # offset/cursor math is a corruption vector
# clippy -D warnings in CI
```

### Tooling that tightens the loop

| Tool | Verdict | Agentic role |
|---|---|---|
| `cargo check --message-format=json` | toolchain | Structured diagnostics the agent can parse precisely. |
| `cargo-nextest` **0.9.137** | RECOMMEND | Per-test isolation + flake retries. |
| Background check/clippy/test watcher (`bacon`) + `mold`/`lld` linker | toolchain | Sub-second feedback. **Skip `sccache`** — it's a cross-machine cache, ~no single-dev win; prefer `cargo check` + faster linker + nextest. |
| `rust-analyzer` MCP server | use with care | Must run its **own sandboxed RA instance** or it fights your editor's LSP and gives flaky results. |

### Discipline that matters for agent-generated code specifically

- **Contracts > tests for correctness of AI-generated code.** Invariants/pre/post-conditions as test-build asserts caught a subtle Paxos safety bug in the literature. Pair `diagnostic_snapshot()` invariants with `debug_assert!`-style contracts.
- **Watch clone-spam — the compiler won't.** LLMs escape borrow-checker errors with `.clone()`/`Arc`/`Rc` that compiles, passes tests, and silently accretes allocations. **Clone-spam detection is an explicit human/review responsibility** in a perf-sensitive core. Worth a periodic `cargo tree --duplicate` + grep pass.
- **Lightweight specs, not rigid spec-driven dev.** ~one user story per agent task. Rigid synced requirement/design/task markdown becomes a maintenance headache as implementation drifts.
- **Pin versions; gate with `cargo-deny`/`cargo-audit`.** Agents hallucinate crate versions — don't trust agent-chosen ones.
- **Don't trust line-count metrics.** "100K lines in 4 weeks" hides compounding architectural incoherence; HN practitioners flagged 1,300 tests for a consensus engine as *low*. Steal rust-analyzer's test discipline: **no `#[ignore]`, no `#[should_panic]`** (assert concrete `Err`/`None`), minimal snippets, slow tests behind `RUN_SLOW_TESTS=1`.
- **Treat flaky tests as likely real bugs** — the 2025 Rust study found ~51% of flake *fixes* were in product code, and 33.9% of flakes were async-wait bugs. Don't paper over with `sleep()`s (38% of async flakes were improper waits) — use explicit completion signals or a paused tokio clock.

### Write an `ARCHITECTURE.md` once past ~10k LOC

matklad's finding: figuring out **where** to change code is 10× the cost of writing the patch — and this is exactly the agent's #1 failure mode. Document **invariants, especially the absence of something** ("the core does no I/O", "the core never calls `Instant::now()`"). Name symbols in prose (hyperlinks rot); review a few times a year, don't keep it line-accurate.

---

## 4. Open questions / decisions for the owner

| # | Decision | Why it's load-bearing | Recommendation / default |
|---|---|---|---|
| 4.1 | **Single cdylib vs multiple across FFI?** | Each `cdylib` gets its **own copy of Rust statics** — a `tracing` subscriber (and the `metrics` global recorder) set in one is invisible to events in another. Silently dropped logs across the boundary. | **Ship a single cdylib**, or expose an explicit `init_logging(callback)` / `init_metrics(...)` FFI entry that installs *inside the same static instance*. Decide before the FFI surface solidifies. |
| 4.2 | **macOS Mach exception port ownership.** | A Rust crash handler claiming the task exception port can **shadow Apple's reporter**; conversely a plain `SIGSEGV` handler never fires because Mach reporters preempt it. `RUST_BACKTRACE=1` has historically *segfaulted* on macOS. | Decide port ownership deliberately and **chain the previous handler**. Default: lean on panic-hook + offline `dSYM` symbolication first; defer in-process native capture. |
| 4.3 | **WASM panic posture.** | `wasm32-unknown-unknown` is `panic=abort` by default — a panic **traps and poisons the whole instance** (sibling state lost, no destructors); `catch_unwind` is a no-op there. `panic=unwind` is now possible but needs **nightly + `-Zbuild-std`**. | Default: accept `panic=abort`; install `console_error_panic_hook`; **JS host detects the `RuntimeError` and recreates/reloads the instance.** Revisit `panic=unwind` only if instance-recreation cost becomes painful. |
| 4.4 | **Cargo-vs-host build bridge.** | If SwiftPM/CMake drives the macOS build, integrating Cargo into a non-Cargo build is **real work** (Microsoft couldn't use Cargo's test harness internally). Plan it early, not as a retrofit. | Decide on a Corrosion-style bridge up front. Verify **Rust + LLVM target support for every target** (Swift FFI, `wasm32`, the TUI/Linux triples) *before* committing — Mozilla took ~6 months across its platform matrix. |
| 4.5 | **`metrics` facade — yes/no in the core?** | Optional second facade alongside `tracing`. Adds a (small) surface; the OTel path can carry metrics via `tracing-opentelemetry` without it. Cardinality (doc id, path, session) explodes Prometheus series silently. | **Best guess: skip the `metrics` facade in the core initially**; emit counts as `tracing` span fields, add `metrics` only if the server needs decoupled metrics. If adopted: enforce a **bounded label allowlist** at the instrumentation layer. `metrics` **0.24.6** is healthy if you want it. |
| 4.6 | **MSRV policy.** | MSRV bumps are conventionally *not* semver-breaking, so consumers can be surprised. Note: `extern "C-unwind"` needs **Rust ≥ 1.81** (corrected from the report's erroneous "1.71/2023"); std unsafe-precondition checks arm at the **caller's** debug-assertions since **1.78**. | Pin via `rust-toolchain.toml` from day one; **write and document an explicit MSRV policy**. Treat upgrades as deliberate events, not drift. |
| 4.7 | **`config` vs `figment` vs std at the edge.** | The verifier **flipped the usual default**: `figment` is ~2 yrs stale (**0.10.19**); `config` (**0.15.23**) is now more active. | **Prefer std + `serde` in the core**; if a host edge genuinely needs layered config, reach for `config`, not `figment`. Validate typed config at startup, fail fast. |
| 4.8 | **TUI / WASM log sinks.** | Logging to stdout/stderr **corrupts the ratatui display**; std `fmt` writer in WASM **goes nowhere**. Hold the `tracing-appender` `WorkerGuard` in `main` for process lifetime or you **lose the last buffered logs — frequently the crash itself**. | Per-host writers: stdout-JSON (server), **file** (TUI), `console` via `wasm-tracing` **2.1.0** (not the stale `tracing-web`), Swift `os_log` MakeWriter (macOS). Confirm the `WorkerGuard` lifetime in each host's `main`. |

---

### Verifier corrections applied (so refuted claims don't propagate)

1. **`extern "C-unwind"` stabilized in Rust 1.81 (Sept 2024)** — *not* 1.71/2023. 1.71 only began the abort-on-unwind transition.
2. **`tracing-subscriber` floor is `>=0.3.20`** due to RUSTSEC-2025-0055 (ANSI log-injection, low sev); current **0.3.23**. The only advisory hit in the entire set.
3. **Prefer `ctest` (0.5.0, now under rust-lang/libc) and migrate off `ctest2`** — the fork is explicitly winding down (sharper than "pick one and pin").
4. **`config` (0.15.23) > `figment` (0.10.19, ~2 yrs stale)** for the edge — the implied default is flipped.
5. **`divan` and `static_assertions` are slowing/dormant** — `criterion` (**0.8.2**, active again; the "unmaintained" worry is stale) is the safer benchmark default, and modern `const {}` asserts cover most of `static_assertions`.

**Net:** the entire `tracing` / OTel / metrics / crash / test stack is current and healthy; **no RUSTSEC advisories on any recommended crate** except the `tracing-subscriber` floor above. Apply the minimal-deps lens relentlessly — `std::panic`/`std::backtrace` for panics, `const` asserts over `static_assertions`, std + `serde` over config crates in the core, and keep `sentry` / OTel SDKs / exporters strictly at the host shell edge.


---

## Crate-health verification (appendix)

The doc's OTel claims check out: Logs+Metrics stable, Traces still Beta, combined 1.0 planned mid-2025 and slipped (the "Tracing API Stable" milestone was due Sept 29 2025 and is only ~32% complete). The "0.28 broke all three signals" and "pin exact versions" guidance is sound for a 0.x line moving this fast. I have all the data needed. Compiling the final verdicts.

---

# Crate Fact-Check Verdicts (verified 2026-05-30/31)

All versions/dates pulled fresh from the crates.io API; advisories from rustsec.org; stabilization claims from Rust blog + RFC tracking issues. **Bottom line: the recommendations are overwhelmingly current and accurate** — only a handful of dated version floors, two factual errors, and a few "lighter option / std suffices" nuances to flag.

## Logging / Tracing

| Crate | Doc claim | Verified (date) | Verdict |
|---|---|---|---|
| `tracing` | v0.1.44 | **0.1.44** (2025-12-18), 624M dls | **RECOMMEND** — accurate, de-facto standard, healthy |
| `tracing-subscriber` | 0.3.20 | **0.3.23** (2026-03-13) | **RECOMMEND** — but see advisory note below; pin `>=0.3.20` |
| `tracing-appender` | "standard" | **0.2.5** (2026-04-17) | **RECOMMEND** — actively maintained |
| `tracing-log` | bridge | current ecosystem crate | **RECOMMEND** (interop only) |
| `log` | v0.4.30 | plausibly current (0.4.x line, rust-lang) | **CAUTION** — only for interop, not core instrumentation (doc agrees) |
| `wasm-tracing` | maintained fork | **2.1.0** (2025-08-04), 92K dls | **RECOMMEND** — correct call over abandoned `tracing-wasm` |
| `tracing-web` | "maintained, viable" | **0.1.3** (2023-11-30) | **CAUTION** — ~2.5 yrs stale; prefer `wasm-tracing` (the doc's own preference) |
| `secrecy` | "day-one choice" | **0.10.3** (2024-10-09) | **RECOMMEND** — ~19 mo old but a stable, low-churn API; mature |
| `redact` | "newer, evaluate" | **0.1.11** (2025-07-25), 2.1M dls | **CAUTION** — still 0.1.x, low download base; doc's "evaluate maintenance" caveat is correct |

> **RUSTSEC-2025-0055 / CVE-2025-58160** — `tracing-subscriber < 0.3.20` has an ANSI-escape log-injection advisory (CVSS 2.3, low). The doc happens to recommend exactly `0.3.20` (the patched floor), but **pin `>=0.3.20`** explicitly; current is `0.3.23`. This is the one advisory hit in the whole set and it directly validates the version floor.

## Telemetry / Metrics / OTel

| Crate | Doc claim | Verified | Verdict |
|---|---|---|---|
| `opentelemetry` / `_sdk` | 0.32.0 (2026-05-09), Logs+Metrics stable, Traces beta | **0.32.0** (2026-05-08); status confirmed | **RECOMMEND** (server shell only) — accurate, incl. the slipped-1.0 narrative (Tracing-stable milestone ~32% done, was due 2025-09-29). Pin exact. |
| `tracing-opentelemetry` | "one minor ahead" | **0.33.0** (2026-05-18) | **RECOMMEND** — version-pairing claim (0.33 vs 0.32) is correct |
| `opentelemetry-appender-tracing` | "now stable" | **0.32.0** (2026-05-09) | **RECOMMEND** — accurate |
| `metrics` | facade | **0.24.6** (2026-05-13), 84M dls | **RECOMMEND** — healthy; reasonable if you want metrics decoupled from OTel |
| `metrics-exporter-prometheus` | minimal-dep | **0.18.3** (2026-04-30) | **RECOMMEND** — actively maintained, lighter than full `prometheus` |
| `sentry` / `sentry-tauri` | crash channel | `sentry` **0.48.2** (2026-05-11) | **CAUTION** — fine but heavy; consent-gate it, and doc's "evaluate dependency weight" is right. `sentry` pulls a large transitive tree. |

## Crash Reporting

| Crate | Doc claim | Verified | Verdict |
|---|---|---|---|
| `std::panic` / `std::backtrace` | zero-dep | stdlib | **STD-SUFFICES** — correct; the panic path needs no crate |
| `crash-handler` (Embark) | de-facto pure-Rust | **0.7.0** (2026-01-13), 1.3M dls | **RECOMMEND** — healthy |
| `minidumper` (Embark) | maintained | **0.10.1** (2026-05-12) | **RECOMMEND** — fresh |
| `minidump-writer` | maintained | **0.12.0** (2026-05-07) | **RECOMMEND** — fresh |
| `sentry-rust-minidump` (timfish) | "~11 stars, vet first" | **0.16.0** (2026-05-13), 270K dls | **CAUTION** — more active than doc implies, but still a tiny single-maintainer project; the "vet before depending" flag stands |
| `console_error_panic_hook` | maintained | **0.1.7** (2021-10-11) | **CAUTION** — ~4.5 yrs untouched, but a 2-fn debugging aid; low risk, effectively feature-complete |
| `backtrace` | superseded by std | maintained | **STD-SUFFICES** for capture — doc agrees |

> **Factual correction — `extern "C-unwind"`:** doc says *"stable since Rust 1.71, 2023."* It was **stabilized in Rust 1.81 (2024-09-05)**, not 1.71. 1.71 only began the transition (made unwinding-past-`extern "C"` abort under a lint). Fix the version/year. (blog.rust-lang.org/2024/09/05/Rust-1.81.0; rust-lang/rust#115285.) The WASM panic=unwind claim (nightly + `-Zbuild-std`, WASM exception handling) is **correct** and corroborated by Cloudflare's 2026-04 wasm-bindgen reliability post.

## Debug / Testing Tooling

| Crate | Doc claim | Verified | Verdict |
|---|---|---|---|
| `cargo-nextest` | adopt day one | **0.9.137** (2026-05-26), 10.5M dls | **RECOMMEND** — very active |
| `proptest` | preferred | **1.11.0** (2026-03-24), 131M dls | **RECOMMEND** |
| `quickcheck` | "simpler, maintained" | **1.1.0** (2026-02-10) | **RECOMMEND** (for simple cases) — recently re-released, healthier than its long-dormant reputation |
| `cargo-mutants` | "active as of Aug 2025" | **27.0.0** (2026-03-07) — CalVer | **RECOMMEND** — now on CalVer (27.x), more current than the doc's Aug-2025 reference |
| `insta` / `cargo-insta` | de-facto | **1.47.2** (2026-03-30), 68M dls | **RECOMMEND** |
| `cargo-fuzz` | maintained, nightly | **0.13.1** (2025-06-27) | **RECOMMEND** — slower cadence (~11 mo) but stable; nightly requirement correct |
| `cargo-llvm-cov` | (listed) | **0.8.7** (2026-05-13), 5.9M dls | **RECOMMEND** — active |
| `criterion` | (no version given) | **0.8.2** (2026-02-04), 211M dls | **RECOMMEND** — note: the old "criterion is unmaintained" (2023) worry is **stale**; it's active again |
| `divan` | (listed) | **0.1.21** (2025-04-10) | **CAUTION** — ~13 mo, no release since; single-maintainer (nvzqz). Slowing. `criterion` is the safer default now |
| `static_assertions` | "lightweight guardrail" | **1.1.0** (2019-11-03) | **CAUTION (but STD-leaning)** — ~6.5 yrs untouched/effectively unmaintained. Zero runtime, compile-time only, so risk is near-nil; **but** much of it (`const{}` asserts, `size_of` checks) is now doable with plain `const` blocks on modern Rust — **std increasingly suffices** |
| `pretty_assertions` | optional dev | (not re-pulled) | **RECOMMEND** (dev-only ergonomics, low stakes) |
| `wasm-bindgen-test` | maintained | (rustwasm, current) | **RECOMMEND** |
| `Miri` | official tool | rust-lang, active | **RECOMMEND** (FFI-edge UB) — doc's "can't cross into C/Swift" caveat is correct |
| `ctest` / `ctest2` | "ctest resumed (MSRV 1.88); ctest2 minimal-maint; pick one" | `ctest` **0.5.0** (2026-01-29), now under rust-lang/libc; `ctest2` self-deprecating | **PARTIALLY OUTDATED** — guidance should be sharper: **prefer `ctest`, migrate off `ctest2`** (ctest2's own docs now redirect to rust-lang/libc/ctest). The "pick one and pin" framing understates that the fork is winding down. |
| `cbindgen`, `madsim`, `turmoil` | maintained | not individually re-pulled; no reason to doubt | **RECOMMEND** (as scoped) |
| `signal-hook` | (Unix signals) | **0.4.4** (2026-04-04), 176M dls | **RECOMMEND** — note it's now on **0.4.x**, not the 0.3.x most older docs cite |

## Error Handling / Supply-Chain / Config

| Crate | Doc claim | Verified | Verdict |
|---|---|---|---|
| `thiserror` | de-facto | **2.0.18** (2026-01-18), 1.04B dls | **RECOMMEND** — note it's on the **2.x** line now (doc gave no version) |
| `anyhow` | app edges only | **1.0.102** (2026-02-20), 709M dls | **RECOMMEND** |
| `cargo-deny` | day 1 | **0.19.8** (2026-05-28), 3.9M dls | **RECOMMEND** — very fresh |
| `cargo-audit` | CI + cron | **0.22.1** (2026-02-04) | **RECOMMEND** |
| `cargo-semver-checks` | broadly adopted | **0.47.0** (2026-03-08) | **RECOMMEND** |
| `secrecy` | (see above) | 0.10.3 | **RECOMMEND** |
| `redact` | (see above) | 0.1.11 | **CAUTION** |
| `figment` | "~16M dls" | **0.10.19** (2024-05-17), 27M dls | **CAUTION** — **~2 yrs since last release**; the doc's "prefer std+serde in the core" caveat is right, and notably `config` is now the *more* actively maintained of the two |
| `config` | mature alt | **0.15.23** (2026-05-14), 91M dls | **RECOMMEND** (edge only) — reverses the usual assumption: more active than `figment` right now |
| `tokio-util` (Cancellation/TaskTracker) | async edge only | tokio-rs, current | **RECOMMEND** (async edge only) |

## Summary of corrections to make in the doc

1. **`extern "C-unwind"` was stabilized in Rust 1.81 (Sept 2024), not 1.71/2023.** 1.71 only started the abort-on-unwind transition. (Primary: Rust 1.81 release blog; rust-lang/rust#115285.)
2. **`tracing-subscriber` floor should be `>=0.3.20` due to RUSTSEC-2025-0055** (ANSI log injection, low sev). The doc names 0.3.20 but should say "minimum"; current is 0.3.23. (rustsec.org/advisories/RUSTSEC-2025-0055.html, 2025-08-29.)
3. **`ctest` vs `ctest2`: prefer `ctest` (0.5.0, Jan 2026, now under rust-lang/libc) and migrate off `ctest2`** — the fork is explicitly winding down, sharper than the doc's "pick one."
4. **`figment` is ~2 years stale (0.10.19, May 2024); `config` (0.15.23, May 2026) is the more active alternative** — flip the implied default if you must pull a config crate at the edge.
5. **`divan` (0.1.21, Apr 2025) and `static_assertions` (1.1.0, 2019) are slowing/dormant** — both low-risk, but `criterion` (active again, 0.8.2) is the safer benchmark default, and modern `const{}` asserts cover much of `static_assertions`.

Everything else (the whole `tracing`/OTel/metrics/crash/test stack) is current, healthy, and the version + status claims hold up — including the more nuanced ones (OTel 1.0 slip, Traces still beta, opentelemetry-appender-tracing now stable, tracing-opentelemetry one minor ahead). **No RUSTSEC advisories on any recommended crate except the tracing-subscriber floor already covered.** Apply the minimal-deps lens: `std::panic`/`std::backtrace`/`backtrace` for the panic path, `const` asserts over `static_assertions`, std+serde over `figment`/`config` in the core, and keep `sentry`/OTel SDKs/exporters strictly at the shell edge as the doc already insists.

Sources: [crates.io API](https://crates.io/) (per-crate, live), [RUSTSEC-2025-0055](https://rustsec.org/advisories/RUSTSEC-2025-0055.html), [Rust 1.81 blog](https://blog.rust-lang.org/2024/09/05/Rust-1.81.0/), [rust-lang/rust#115285](https://github.com/rust-lang/rust/issues/115285), [opentelemetry-rust Tracing-stable milestone](https://github.com/open-telemetry/opentelemetry-rust/milestone/1), [wasm-bindgen catch-unwind guide](https://wasm-bindgen.github.io/wasm-bindgen/reference/catch-unwind.html), [Cloudflare wasm-bindgen reliability post (2026-04)](https://blog.cloudflare.com/making-rust-workers-reliable/), [ctest2 lib.rs](https://lib.rs/crates/ctest2).