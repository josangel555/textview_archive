# Debug Mode & Diagnostics in Production Rust

## Debug Mode & Diagnostics: what to build in from day one

For a sans-IO functional core that ships as four distinct artifacts (native dylib via Swift FFI, WASM, native TUI link, headless Linux), the single most important fact is that **"debug vs release" is not a property of your program — it's a per-crate codegen setting**, and the four artifacts will frequently be built with *different* settings. Designing your inspectability layer around that reality from the start is cheap; retrofitting it is not.

### The debug/release divergence is larger than people assume

The `dev` and `release` profiles differ on several axes simultaneously, and each can flip behavior, not just speed:

| Setting | dev | release | What flips |
|---|---|---|---|
| `opt-level` | 0 | 3 | 10–100x speed; also exposes UB/timing-dependent bugs |
| `debug-assertions` | true | false | `debug_assert!`, `cfg(debug_assertions)`, **std unsafe-precondition checks** |
| `overflow-checks` | true | false | integer overflow panics (dev) vs **silent two's-complement wraparound** (release) |
| `debug` (debuginfo) | true | false | symbol quality |
| `codegen-units` | 256 | 16 | inlining / layout (heisenbug surface) |
| `panic` | unwind | unwind | (both default unwind; you'll likely want `abort` for FFI/WASM) |

The overflow-checks asymmetry is the classic correctness trap: arithmetic that panics loudly in your tests **wraps silently in production**. For a document core doing offset/length math (byte ranges, cursor positions, scroll math), that is a real corruption vector. Two defensive idioms to adopt from line one: use the explicit `checked_*` / `saturating_*` / `wrapping_*` methods wherever the semantics matter (so the behavior is identical in both profiles and self-documenting), and **turn `overflow-checks = true` on in a release-like CI profile** so you fuzz/test against panics.

### debug_assert! vs assert! — pick deliberately, per assumption

Tratt's framing (2023) is the canonical mental model: `assert!` for assumptions you have *low confidence* will be caught in testing (problem-domain invariants reaching real users — malformed documents, API misuse), `debug_assert!` for internal structural invariants that testing reliably exercises and that are too costly to keep in release. The std docs add the hard rule: **never downgrade an `assert!` to `debug_assert!` if unsafe code relies on it for soundness** — that turns a panic into UB in release. Two concrete gotchas:

- **Side effects in assertions vanish in release.** `debug_assert!(list[i++] > 0)` — the `i++` only happens in debug builds, so behavior silently diverges. Keep assertion expressions pure.
- **`debug_assert!` weakens your guarantees in exactly the builds you ship.** A test suite passing doesn't prove users won't hit the path. Treat `debug_assert!` as a development tripwire, not a safety net.

For a `forbid(unsafe_code)` core, this mostly resolves cleanly: your core uses `assert!`/`debug_assert!` freely for logic invariants, and the only `assert!`-for-soundness cases live at the audited FFI edge.

### The std unsafe-precondition shift (Rust 1.78, May 2024) — a free win

Historically std's `assert_unsafe_precondition!` checks (slice-from-raw-parts alignment, `ptr::offset` bounds, `NonNull`, `unreachable_unchecked`, etc.) only ran if *std itself* was built with debug-assertions — which distributed toolchains are not, so almost nobody ran them. Since 1.78 the check is **resolved at codegen of the caller**, so enabling `debug-assertions` in *your* build now arms std's UB tripwires too. This is exactly the kind of inspectability you want at the FFI edge: build your FFI-test and fuzz profiles with `debug-assertions = true` and you get free UB detection on any `unsafe` you write.

### `#[cfg(debug_assertions)]` vs `if cfg!(debug_assertions)` — know the difference

- `#[cfg(debug_assertions)]` (attribute): item is **removed entirely** from release builds — no codegen, no binary cost. Use for diagnostic-only fields, modules, dump methods.
- `if cfg!(debug_assertions)` (macro): expands to a `bool` const; **both branches must compile and type-check**, the dead one is then const-folded out. Use for inline conditional behavior where both sides are valid.

The trap: a diagnostic helper guarded only by `if cfg!(...)` still pulls its dependencies and types into the release binary. Gate the *definitions* with the attribute to actually strip them.

### Runtime-toggleable verbosity: `tracing`, with compile-time stripping

The ecosystem-standard answer for inspectability without binary bloat is the `tracing` crate, and it solves both halves of the problem:

- **Runtime:** `EnvFilter`/`LevelFilter` choose what executes in an already-compiled binary; with `tracing-subscriber`'s `reload` layer you can flip verbosity *live* (the Tokio demo bumps a single request path to `TRACE` via an HTTP call, no restart). For your headless Linux/remote deployment this is the toggle mechanism — no recompile, targeted by span field.
- **Compile-time:** the `max_level_*` and `release_max_level_*` Cargo features set `STATIC_MAX_LEVEL`; instrumentation below that level is **not emitted into the binary at all**. The standard production recipe is `features = ["max_level_debug", "release_max_level_info"]` (or `release_max_level_warn`): full firehose in dev, low-level traces physically stripped from release. (Bevy's #4069 is the cautionary tale — a low-level crate force-enabling `release_max_level_info` robbed downstream apps of the choice; **never set release max-level features in a library**, only in the top-level binary.)

For a library core, the day-one move is: **make `tracing` a normal dependency and instrument the core**, but if you want a truly zero-overhead/zero-dep posture for some artifacts, gate the `tracing` *dependency* behind an optional feature and provide no-op macros when it's off — the pattern many libraries adopt so consumers opt into the dep.

### Diagnostic-dump mechanism

Build a `fn diagnostic_snapshot(&self) -> DiagnosticReport` on the core's top-level state from the start — a sans-IO core makes this trivial and the same call serves every artifact. Pair it with platform triggers at the edges: a `SIGUSR1` handler (via `signal-hook`) on Linux/TUI to dump state to a log, a hidden command in the SwiftUI app, a JS-callable export in WASM. Keep the *struct* always-present (it's just serializable state), and gate any expensive/verbose fields behind `#[cfg(debug_assertions)]` or a `diagnostics` feature.

### Avoiding debug-only path divergence

The meta-risk: code that only runs in debug builds rots and diverges. Mitigations to bake in: (1) run CI in **both** profiles, including a release+debug-assertions profile; (2) keep debug-only blocks tiny and pure; (3) prefer always-compiled-but-runtime-gated (`tracing` events, the snapshot struct) over `#[cfg]`-removed code paths, so the same instructions run everywhere and you don't ship a release binary whose logic was never exercised.


## Key takeaways
- debug/release differ on overflow-checks, debug-assertions, opt-level, debuginfo and codegen-units simultaneously — each can change behavior, not just speed. The dangerous one is overflow-checks: arithmetic that panics in dev tests silently wraps in release.
- debug_assert! and assert! encode different confidence levels: assert! for domain/user-facing invariants you doubt testing catches; debug_assert! for internal invariants testing reliably exercises. NEVER downgrade an assert! to debug_assert! when unsafe relies on it — that becomes UB in release.
- Since Rust 1.78 (May 2024), std's unsafe-precondition UB checks are armed by the CALLER's debug-assertions setting at codegen, not by how std was built. Enabling debug-assertions in FFI-test/fuzz profiles gives free UB detection on your own unsafe.
- #[cfg(debug_assertions)] removes the item (zero release cost); if cfg!(debug_assertions) compiles BOTH branches and const-folds — so it still pulls deps/types into release. Gate definitions with the attribute to actually strip diagnostics.
- tracing solves inspectability-without-bloat on two axes: runtime EnvFilter/LevelFilter (live-toggleable, even per-span-field, via the reload layer) AND compile-time max_level_*/release_max_level_* features that physically strip low-level instrumentation from the release binary.
- Build a fn diagnostic_snapshot()->Report on the core's top-level state from day one. A sans-IO core makes it trivial and one call serves all four artifacts; wire platform triggers (SIGUSR1, hidden UI command, WASM export) at the edges.
- Turn overflow-checks = true and debug-assertions = true on in a release-like CI profile, and run CI in both profiles, so debug-only paths don't rot and you exercise the assertions you ship.

## Gotchas
- overflow-checks default to OFF in release: integer overflow wraps silently in production but panics in dev tests. Offset/length/cursor math is a real corruption vector — use checked_/saturating_/wrapping_ explicitly where semantics matter.
- Side effects inside debug_assert! (e.g. debug_assert!(list[i++] > 0)) only execute in debug builds, silently diverging behavior between profiles. Keep assertion expressions pure.
- Downgrading a soundness-critical assert! to debug_assert! turns a release panic into undefined behavior. Only debug_assert! safe-code invariants.
- Libraries must NOT set release_max_level_* tracing features — it robs downstream binaries of the choice (Bevy issue #4069). Compile-time max-level belongs only in the top-level binary.
- if cfg!(debug_assertions) does not strip code: both branches are compiled and type-checked, so a diagnostic helper behind it still drags its dependencies and types into the release binary. Use #[cfg(...)] on the definition to strip.
- debug_assertions is per-crate at the crate's own compile time, not whole-program. Your FFI dylib, WASM, TUI and headless builds can each be compiled with different settings, so 'is this a debug build' is ambiguous across artifacts — don't assume one global answer.
- Pre-1.78 std unsafe-precondition checks effectively never ran for most users (std shipped in release). If a mental model predates 1.78, it's stale — enabling your own debug-assertions now arms them.
- Optimization/codegen differences (registers vs memory, inlining, codegen-units) create heisenbugs that appear only in release or only under a debugger; assertions being stripped in release is one such divergence.

## Crates
- tracing — structured, span/event diagnostics framework; the de-facto standard; small dep suitable for libraries, with compile-time level stripping. Verdict: adopt; tokio-rs maintained, ubiquitous.
- tracing-subscriber — runtime EnvFilter/LevelFilter and the reload layer for live-toggleable verbosity; lives in the top-level binary, not the core. Verdict: adopt at the application edge.
- signal-hook — safe, widely-used Unix signal handling for SIGUSR1-style diagnostic-dump triggers on Linux/TUI. Verdict: use at the I/O edge only (not in the no-std-friendly core); widest community support.
- insta — snapshot testing (mitsuhiko); useful for asserting diagnostic_snapshot()/render output stays stable. Verdict: dev-dependency, optional but high-value for a viewer/renderer core.
- static_assertions — compile-time (const) assertions on type sizes/traits/layout; zero runtime cost, good for locking FFI-struct invariants. Verdict: optional, lightweight, dev-time guardrail.
- pretty_assertions — colored diff output for failed assert_eq! in tests; dev-only ergonomics. Verdict: optional dev-dependency.

## Sources
- https://doc.rust-lang.org/cargo/reference/profiles.html — Profiles, The Cargo Book (dev vs release defaults: opt-level/debug-assertions/overflow-checks/etc., profile overrides)
- https://doc.rust-lang.org/std/macro.debug_assert.html — std::debug_assert docs (release stripping, the assert!→debug_assert! soundness caveat)
- https://doc.rust-lang.org/std/macro.assert.html — std::assert docs (assert! for unsafe-relied-on invariants)
- https://tratt.net/laurie/blog/2023/rusts_two_kinds_of_assert_make_for_better_code.html — Laurence Tratt, 'Rust's Two Kinds of Assert Make for Better Code' (2023; domain vs internal assumptions, side-effect gotcha)
- https://nnethercote.github.io/perf-book/build-configuration.html — The Rust Performance Book, Build Configuration (10–100x debug/release gap, overflow/assertion stripping)
- https://doc.rust-lang.org/std/macro.cfg.html — std::cfg macro docs (cfg! evaluates to bool, both branches compile vs #[cfg] removal)
- https://doc.rust-lang.org/reference/conditional-compilation.html — The Rust Reference, Conditional compilation (#[cfg(debug_assertions)] semantics)
- https://blog.rust-lang.org/2024/05/02/Rust-1.78.0/ — Announcing Rust 1.78.0 (2024-05-02; unsafe-precondition checks now keyed to caller's debug-assertions at codegen)
- https://doc.rust-lang.org/core/macro.assert_unsafe_precondition.html — core::assert_unsafe_precondition docs (check_language_ub vs check_library_ub, enabled per caller monomorphization)
- https://github.com/rust-lang/rust/pull/120594 — PR #120594 'Toggle assert_unsafe_precondition in codegen instead of expansion' (saethlin; the 1.78 mechanism)
- https://docs.rs/tracing/latest/tracing/level_filters/index.html — tracing::level_filters (STATIC_MAX_LEVEL, max_level_*/release_max_level_* feature names, compile-time stripping)
- https://docs.rs/tracing/latest/tracing/struct.Level.html — tracing::Level (static disable at compile time; instrumentation absent from binary unless level set dynamically)
- https://tokio.rs/blog/2019-08-tracing — 'Diagnostics with Tracing', Tokio blog (2019; spans vs events, live runtime filter reload via HTTP)
- https://github.com/bevyengine/bevy/issues/4069 — Bevy issue #4069 'bevy_utils should not force tracing's release_max_level_info feature' (library-must-not-set-release-max-level cautionary tale)
- https://blog.logrocket.com/guide-signal-handling-rust/ — 'The guide to signal handling in Rust', LogRocket (signal-hook, SIGUSR1 for print-stats/diagnostic dumps)
- https://blog.logrocket.com/composing-underpinnings-observable-rust-application/ — 'Composing an observable Rust application', LogRocket (optional/conditional telemetry layer pattern)