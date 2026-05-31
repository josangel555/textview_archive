# Other From-The-Get-Go Production Mechanisms for a Rust Core + Headless Service

## Other Production Mechanisms to Build In From Day One

The unifying theme across mature Rust shops: the mechanisms below are *architectural*, not features. They cost a few hours each up front but require ripping through every module to retrofit. For a sans-IO synchronous core embedded across Swift FFI / WASM / TUI / headless Linux, the highest-leverage ones are **panic discipline, error taxonomy, persistent-state versioning, observability seams, and supply-chain hygiene** — because they cross every embedding boundary.

### 1. Panic discipline & graceful degradation (core's #1 retrofit cost)

For a `forbid(unsafe_code)` core that panics-into-Swift/C/WASM, an uncaught unwind is **undefined behavior** ([Rustonomicon, Unwinding](https://doc.rust-lang.org/nomicon/unwinding.html)). Decisions to make now:

- **Library returns `Result`, never panics on caller input** ([Effective Rust, Item 18](https://effective-rust.com/panic.html)). Reserve `panic!` for internal invariant corruption. Pair infallible/fallible variants. Add a CI lint (`clippy::unwrap_used`, `clippy::expect_used`, `clippy::indexing_slicing`) — trivial day-1, painful to bolt on after 30k lines of `slice[i]`.
- **Pick a panic strategy per target, knowingly.** `panic=abort` is smaller/faster and is *forced* on WASM regardless of setting; `panic=unwind` lets embedders recover ([Rust Reference, Panic](https://doc.rust-lang.org/reference/panic.html); [Stanza, Panic & Binary Size](https://www.stanza.dev/courses/rust-performance/profiles/rust-perf-panic-binary)). Libraries should default to unwind to preserve consumer choice.
- **FFI edge = mandatory `catch_unwind` firewall**, or use the `extern "C-unwind"` ABI deliberately ([RFC 2945](https://rust-lang.github.io/rfcs/2945-c-unwind-abi.html)). Under `panic=abort`, a foreign unwind entering a `C-unwind` Rust frame is caught and the process aborts — predictable, unlike UB. The audited FFI shim is the *only* place this belongs.

> Gotcha: `catch_unwind` does **not** catch aborts, and the closure must be `UnwindSafe` — captured `&mut`/`RefCell` state can be left torn. Treat a caught panic as "this operation's state is poisoned," not "retry freely."

### 2. Error taxonomy (cheap now, viral later)

The API Guidelines mandate **meaningful, well-behaved error types** that implement `std::error::Error`, `Display`, `Debug`, and are `Send + Sync + 'static` ([API Guidelines checklist](https://rust-lang.github.io/api-guidelines/checklist.html)). For a library, hand-roll enums with `thiserror`, mark them `#[non_exhaustive]` from the first commit (adding a variant later is otherwise a breaking change), and keep `anyhow`-style type erasure at the *application* edges only. Decide the public-vs-private error split now; widening a leaked private type is a semver break.

### 3. Versioning & migration of persistent state (workspace JSON, sessions)

You already persist `_last.json`. The single highest-regret retrofit is an **untagged on-disk format**. Build in from day one:

- A **format version field / magic header** so a reader can detect and branch ([magic-bytes / tolerant-reader survey](https://www.techinterview.org/post/3233469419/lld-backward-compatibility/)).
- **Tolerant deserialization**: `#[serde(default)]` for added fields, `#[serde(alias)]` for renames, and a `deny_unknown_fields` policy chosen *consciously* — strict readers are a classic incident source when an older binary meets a newer file. The cleanest pattern is **in-memory upgrade on load via compat structs**, never rewriting the on-disk file during migration ([serde issue #1652](https://github.com/serde-rs/serde/issues/1652)).
- A **forward path**: explicit `V1 -> V2 -> V3` migration chain. Crates like `serde_versioning` exist but a hand-rolled `enum VersionedDoc { V1(..), V2(..) }` keeps the core dependency-free.

> Gotcha: roll-back safety. A user who opens a workspace in a new build then reverts must not get a corrupt file. Test the *downgrade* path, not just upgrade.

### 4. Configuration management

Layered precedence, decided once: **defaults (code) < config file < env < CLI** ([LogRocket](https://blog.logrocket.com/configuration-management-in-rust-web-services/)). Two non-negotiables: **deserialize into a typed struct** and **validate at startup / fail fast** rather than crashing mid-request on a bad value. For a minimal-deps core, this is ~80 lines of std + `serde`; reach for `figment`/`config` only at the headless-service edge if env+file+CLI merging gets painful.

### 5. Observability seams (the part you can't add later cheaply)

Instrument with the `tracing` crate facade from day one — even if the core just emits no-op spans. `tracing` is the de-facto standard, structured, and lets each embedder attach its own subscriber (OS log on macOS, console on WASM, OTel on the Linux box) without the core knowing ([lpalmieri, Zero-to-Prod telemetry](https://www.lpalmieri.com/posts/2020-09-27-zero-to-production-4-are-we-observable-yet/)). A sans-IO core should emit *events*, not write logs. Retrofitting span boundaries into hot paths after the fact is the expensive part; the subscriber wiring is cheap.

### 6. Resource limits & backpressure

For the headless/remote deployment, decide bounds at the seams now: **bounded channels** (block/shed on overflow) and **semaphores** to cap concurrency model finite resources and create cascading backpressure ([Sling Academy, bounded channels](https://www.slingacademy.com/article/handling-backpressure-in-rust-async-systems-with-bounded-channels/)). Pattern: bounded *work* channel + unbounded *results* channel to avoid deadlock. The core itself should expose limits as parameters (max doc size, max tabs) rather than hard-coding `Vec::push` with no ceiling.

### 7. Graceful shutdown & signal handling (headless edge)

Tokio's three-part model — **detect** (`ctrl_c` / SIGTERM), **broadcast** (`CancellationToken`), **drain** (`TaskTracker.close().wait()`) ([Tokio shutdown topic](https://tokio.rs/tokio/topics/shutdown)). Cancellation must allow cleanup (flush workspace state) before exit, not hard-kill. Gotcha: `TaskTracker::wait()` only resolves after `close()` *and* all tasks finish.

### 8. Supply-chain hardening & reproducible builds

Wire these into CI on the first green build ([Rust Supply-Chain Security Guide](https://rust-secure-code.github.io/rust-supply-chain-security/build.html); [RustSec](https://github.com/rustsec/rustsec)):

| Tool | Role | Verdict |
|---|---|---|
| `cargo-deny` | License/ban/duplicate/advisory policy gate | CI gate from day 1 |
| `cargo-audit` | RustSec advisory-db scan of `Cargo.lock` | CI + nightly cron |
| `cargo auditable` | Embeds dep manifest in the binary | Cheap, enables post-hoc audit |
| `cargo-vet` | Human review records of deps | Add when criticality warrants |

Plus: **commit `Cargo.lock`**, build with `--locked`, set `--remap-path-prefix` for reproducibility/path-leak removal, build in an ephemeral sandbox (`build.rs` + proc-macros run arbitrary code), generate an SBOM (`cargo-cyclonedx`). Note `-sys` crates can hide C/C++ outside SBOM coverage.

### 9. Semver & MSRV policy

Adopt `cargo-semver-checks` in CI and pin an MSRV in `Cargo.toml` now ([cargo-semver-checks](https://github.com/obi1kenobi/cargo-semver-checks); [MSRV policy discussion](https://github.com/rust-lang/api-guidelines/discussions/231)). Private struct fields, `#[non_exhaustive]` enums, and **sealed traits** (API Guidelines future-proofing) are free insurance against accidental breaking changes — and impossible to add later without a major bump.

### 10. Feature flags — two distinct mechanisms

Don't conflate them. **Cargo features** = compile-time, zero-cost, decide *what exists* in the binary (e.g. per-grammar/per-format gating, matching your lazy-grammar split). **Runtime toggles** (config/env-driven) = *kill switches* to disable a misbehaving feature without a rebuild ([Medium, feature flags in Rust](https://medium.com/@adamszpilewicz/implementing-feature-flags-in-rust-a-practical-guide-to-progressive-delivery-e14f47f0a872)). For a shipped desktop app, a config-file kill switch beats an external flag service.

### Production-readiness checklist (condensed)

- [ ] `Result`-only public API; clippy panic-lints in CI; `#[non_exhaustive]` errors
- [ ] FFI `catch_unwind` firewall + deliberate panic strategy per target
- [ ] Versioned, tolerant on-disk formats with tested upgrade *and* downgrade
- [ ] Typed config, validated at startup, layered precedence
- [ ] `tracing` seams in core; subscriber per embedder
- [ ] Bounded channels / semaphores / explicit size limits
- [ ] Graceful shutdown (detect/broadcast/drain) on headless edge
- [ ] `cargo-deny` + `cargo-audit` + `--locked` + committed lock + `--remap-path-prefix`
- [ ] `cargo-semver-checks` + pinned MSRV + sealed traits + private fields
- [ ] All public types `Debug`; secrets wrapped (`secrecy`/`redact`)


## Key takeaways
- Panic discipline is the single most expensive thing to retrofit for an FFI/WASM-embedded core: enforce Result-only public APIs with clippy panic-lints (unwrap_used, expect_used, indexing_slicing) in CI from commit one, and install a catch_unwind firewall (or deliberate extern "C-unwind") at the audited FFI edge since unwinding into Swift/C is UB.
- Tag persistent state with a format version/magic header and use tolerant deserialization (serde default/alias) from day one — the highest-regret retrofit is an untagged on-disk format; do in-memory upgrade-on-load via compat structs and test the downgrade/rollback path, not just upgrade.
- Instrument the core with the `tracing` facade immediately (emit events, let each embedder attach its own subscriber); span boundaries in hot paths are the costly part to add later, while subscriber wiring is cheap.
- Distinguish Cargo features (compile-time, decide what exists — pairs with the lazy-grammar split) from runtime config-driven kill switches (disable a misbehaving feature without a rebuild); they are complementary, not alternatives.
- Make breaking-change insurance free now: #[non_exhaustive] on public enums/errors, private struct fields, sealed traits, a pinned MSRV, and cargo-semver-checks in CI — each is impossible to add later without a major version bump.
- Wire supply-chain gates on the first green CI run: commit Cargo.lock, build --locked, run cargo-deny + cargo-audit, embed deps with cargo auditable, and set --remap-path-prefix for reproducible, path-leak-free builds.
- Decide error type architecture up front: public hand-rolled enums (thiserror) that are Send+Sync+'static and #[non_exhaustive], with anyhow-style erasure confined to application edges; widening a leaked private error type is a semver break.
- Validate typed configuration at startup and fail fast; bake resource bounds (bounded channels, semaphores, explicit max-size params) into the seams rather than relying on unbounded growth.

## Gotchas
- catch_unwind does NOT catch aborts and only catches unwinding panics; under panic=abort (forced on WASM) it is a no-op. Treat any caught panic as poisoned state — the UnwindSafe bound exists because captured &mut/RefCell data can be left torn.
- Unwinding across an FFI boundary without the C-unwind ABI is undefined behavior, not just a crash — the FFI shim MUST catch or use extern "C-unwind" explicitly.
- Strict deserialization (deny_unknown_fields) is a classic production incident when an older binary opens a file written by a newer one; choose strict-vs-tolerant consciously and prefer tolerant for forward compat.
- On-disk migration must protect the downgrade path: a user opening a workspace in a new build then reverting must not get a corrupt file. Don't rewrite the on-disk file during in-memory migration.
- Cargo features and runtime feature flags are different mechanisms solving different problems; conflating them means you can't ship a kill switch (no rebuild) when you only have compile-time gating.
- TaskTracker::wait() only resolves after BOTH close() is called AND all tasks finish — forgetting close() hangs shutdown forever.
- Adding an enum variant or a struct field to a public type later is a breaking change unless you marked it #[non_exhaustive] / kept fields private from the start.
- -sys crates can vendor C/C++ libraries that are invisible to SBOM tooling and cargo-audit, leaving a blind spot in supply-chain coverage.
- rustup does not validate signatures on downloaded toolchains; for hardened builds prefer standalone/distro-provided compilers.
- MSRV bumps are conventionally NOT semver-breaking per the API Guidelines, so pin and document your MSRV policy explicitly to avoid surprising downstream consumers.

## Crates
- thiserror — derive ergonomic library error enums implementing std::error::Error/Display — de-facto standard, dtolnay-maintained, library-appropriate
- anyhow — type-erased error context for application/binary edges only (not public library APIs) — de-facto standard, dtolnay-maintained
- tracing — structured, span-based instrumentation facade; core emits events, embedders attach subscribers — de-facto observability standard, tokio-org maintained
- tracing-subscriber — subscriber/layer foundation for routing telemetry (OS log / console / OTel) — pairs with tracing, well-maintained
- cargo-deny — CI gate for licenses, banned/duplicate crates, and advisories — Embark-maintained, widely adopted, add day 1
- cargo-audit — scans Cargo.lock against the RustSec advisory-db — RustSec-maintained, run in CI + nightly cron
- cargo auditable — embeds the dependency manifest into the built binary for post-hoc auditing — RustSec ecosystem, low-cost, recommended
- cargo-semver-checks — rustdoc-based linter catching semver violations in the public API — obi1kenobi-maintained, broadly adopted, moving toward Cargo integration
- secrecy — Secret<T>/SecretString wrappers that redact Debug and zeroize on drop (requires Zeroize) — established, good for secrets in config/memory
- redact — lighter secret-redaction wrapper without the Zeroize requirement, wraps any type — alternative to secrecy when zeroize is too restrictive
- figment — hierarchical, layered configuration (file/env/CLI/custom providers) into typed structs — SergioBenitez-maintained, ~16M downloads; use only at the service edge, prefer std+serde in the minimal-deps core
- config — layered configuration system (58M+ downloads) — mature alternative to figment; same edge-only caveat for a minimal-deps core
- cargo-cyclonedx — generates CycloneDX SBOMs from Cargo metadata — for release pipelines; note -sys C/C++ blind spot
- tokio-util (CancellationToken / TaskTracker) — graceful-shutdown primitives for the async headless edge — tokio-org maintained, only needed where async lives

## Sources
- https://rust-lang.github.io/api-guidelines/checklist.html — Rust API Guidelines: Checklist (Rust library team; production-readiness checklist incl. error types, Debug, sealed traits, future-proofing)
- https://effective-rust.com/panic.html — Effective Rust, Item 18: Don't panic (David Drysdale; Result-vs-panic, panic=abort/unwind, catch_unwind, FFI)
- https://doc.rust-lang.org/reference/panic.html — The Rust Reference: Panic (panic strategies, abort vs unwind, WASM forced-abort)
- https://doc.rust-lang.org/nomicon/unwinding.html — The Rustonomicon: Unwinding (unwinding across FFI is UB)
- https://rust-lang.github.io/rfcs/2945-c-unwind-abi.html — RFC 2945: C-unwind ABI (controlled cross-FFI unwinding; abort-on-unwind under panic=abort)
- https://www.stanza.dev/courses/rust-performance/profiles/rust-perf-panic-binary — Panic Strategies & Binary Size (abort smaller/faster; embedded+WASM always abort)
- https://tokio.rs/tokio/topics/shutdown — Tokio: Graceful Shutdown (three-part detect/CancellationToken/TaskTracker model + wait() gotcha)
- https://rust-secure-code.github.io/rust-supply-chain-security/build.html — Rust Supply Chain Security Guide: Build for production (--locked, --remap-path-prefix, ephemeral build, cargo auditable, SBOM, -sys blind spot, rustup signature gap)
- https://github.com/rustsec/rustsec — RustSec project (cargo-audit, advisory-db, cargo-lock; CI usage)
- https://github.com/mozilla/cargo-vet — cargo-vet: supply-chain security for Rust (committed audit records of dependency reviews)
- https://github.com/obi1kenobi/cargo-semver-checks — cargo-semver-checks: scan a crate for semver violations (rustdoc-based, broadly adopted)
- https://github.com/rust-lang/api-guidelines/discussions/231 — MSRV Policies discussion (MSRV bump conventionally not semver-breaking)
- https://blog.logrocket.com/configuration-management-in-rust-web-services/ — Configuration management in Rust web services (layered precedence defaults<file<env<CLI, validate at startup)
- https://github.com/SergioBenitez/Figment — Figment: hierarchical configuration library (layered providers into typed structs)
- https://www.lpalmieri.com/posts/2020-09-27-zero-to-production-4-are-we-observable-yet/ — Luca Palmieri: Are we observable yet? An introduction to Rust telemetry (tracing as the standard; emit telemetry for absent-operator debugging)
- https://www.slingacademy.com/article/handling-backpressure-in-rust-async-systems-with-bounded-channels/ — Handling Backpressure in Rust Async Systems with Bounded Channels (bounded channels + semaphores; bounded-work/unbounded-results deadlock avoidance)
- https://github.com/serde-rs/serde/issues/1652 — serde issue: Migrating serialized config file to new schema (serde default/alias, in-memory compat-struct upgrade on load)
- https://www.techinterview.org/post/3233469419/lld-backward-compatibility/ — Backward Compatibility LLD: Tolerant Reader, Postel's Law (ignore unknown fields, magic-header detection, forward compat)
- https://medium.com/@adamszpilewicz/implementing-feature-flags-in-rust-a-practical-guide-to-progressive-delivery-e14f47f0a872 — Implementing Feature Flags in Rust (compile-time Cargo features vs runtime kill switches; complementary)
- https://leapcell.io/blog/secure-configuration-and-secrets-management-in-rust-with-secrecy-and-environment-variables — Secure Configuration and Secrets Management in Rust with Secrecy (Secret<T>, redacted Debug, zeroize-on-drop)
- https://oneuptime.com/blog/post/2026-01-07-rust-kubernetes-health-checks/view — Health Checks and Readiness Probes in Rust for Kubernetes (liveness vs readiness vs startup; separate endpoints; graceful degradation)