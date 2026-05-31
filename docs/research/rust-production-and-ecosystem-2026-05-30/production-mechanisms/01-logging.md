# Production logging in Rust: tracing vs log, structured/span discipline, FFI/WASM/headless output, hot-path cost, redaction, and dynamic levels

## Logging in production Rust — what to build in from day one

### The two-layer model: facade vs. implementation

Rust's logging ecosystem is split into **facades** (an API to *emit* records) and **subscribers/loggers** (something that *collects and outputs* them). Two facades coexist:

- **`log`** (rust-lang, v0.4.30) — the original, dirt-simple leveled facade. "Lowest common denominator": a huge fraction of crates emit `log` records, and it's the one to support if you want maximum compatibility.
- **`tracing`** (tokio-rs, v0.1.44) — the modern superset. Adds **spans** (a period of execution with structured context that nests and propagates), **structured fields** on events, and first-class async support. It is the de-facto standard for new applications and is what OpenTelemetry-Rust recommends instrumenting against.

**The single most important discipline distinction** (and the #1 first-timer mistake): a **library NEVER installs a subscriber/logger**. It only depends on the facade and emits. The application — and *only* the application, *once*, *early* — installs the implementation. The docs are explicit:

> `log`: "Libraries should link only to the `log` crate... Executables should choose a logging implementation and initialize it early... The logging system may only be initialized once."
> `tracing`: "In general, libraries should *not* call `set_global_default()`! Doing so will cause conflicts when executables that depend on the library try to set the default later."

For a reusable sans-IO core embedded in 4 hosts (Swift app, WASM, TUI, headless server), this maps perfectly: **the core is a library — it emits `tracing` events and installs nothing.** Each host binary owns subscriber setup.

### Recommendation for TextView's core

Instrument the core with **`tracing`** macros + `#[instrument]`, not `log`. You get structured fields and spans for free, and via the `log` feature it still degrades to `log` records if a host only wires up a `log` backend. Concretely:

- Core crate: `tracing` only (default features; consider `tracing = { features = ["log"] }` so events become `log` records when no `tracing` subscriber is active — useful if a host is `log`-based).
- Never `set_global_default`, never call `tracing_subscriber::fmt::init()` in the core or in any sub-crate. That's host territory.

### Structured fields — not string interpolation

The discipline that separates toy logging from production: **fields are key/value, not baked into the message string.**

```rust
// BAD: ungreppable, unaggregatable
tracing::info!("opened doc {} ({} bytes) in {}ms", path, len, ms);
// GOOD: structured — machines can filter/aggregate
tracing::info!(doc.path = %path, doc.bytes = len, elapsed_ms = ms, "opened document");
```

Sigils: `%x` = `Display`, `?x` = `Debug`, bare `x` = shorthand for `x = x`. Spans carry context so you stop threading request/doc IDs manually:

```rust
#[tracing::instrument(skip(buffer), fields(doc.id = %id))]
fn reparse(id: DocId, buffer: &Rope) { /* every event inside inherits doc.id */ }
```

### Where the output goes per host (the FFI/WASM/headless matrix)

| Host | Subscriber the host installs | Output sink | Key gotcha |
|---|---|---|---|
| Headless Linux server | `tracing-subscriber` `fmt().json()` + `EnvFilter` | stdout (let the platform/collector ship it) | JSON to stdout; don't write files yourself |
| TUI (ratatui) | `fmt` with a **file** writer, never stdout/stderr | log file | stdout/stderr corrupts the TUI — must redirect to a file or in-app pane |
| WASM (browser) | `tracing-web` (maintained) / `wasm-tracing` (fork of unmaintained `tracing-wasm`) | browser `console.*` + `performance` marks | std `fmt` writer to stdout does nothing in the browser; also install `console_error_panic_hook` |
| macOS Swift app (FFI) | Custom `tracing` layer/`MakeWriter` that calls a C callback into Swift `os_log`/`OSLog` | unified logging | See FFI static-duplication trap below |

**The non-obvious FFI landmine:** the global default subscriber lives in a Rust `static`. **Every `cdylib` gets its own copy of all Rust statics.** If your core is one cdylib and a dependency is another, a subscriber set in one is invisible to `tracing::event!` calls in the other — events silently vanish. Mitigations: ship a **single** cdylib (link the rest as rlib/`dylib`), or expose an explicit `init_logging(callback)` FFI entry point that installs the subscriber inside the same static-instance as the emitting code. Build this entry point from day one; retrofitting after you discover dropped logs in prod is painful.

### Hot-path performance — make disabled logs near-free

Two layers of cheapness:

1. **Runtime, disabled level:** if no active subscriber expresses interest in a callsite's metadata, "the corresponding `Span` or `Event` will never be constructed." Field-value expressions aren't even evaluated. Callsite interest is cached, so the steady-state cost of a disabled event is roughly a cached atomic check. This is cheap but **not zero** — avoid a `trace!` inside a per-character reparse loop and assume it's free; it isn't.
2. **Compile-time, fully stripped:** `STATIC_MAX_LEVEL` ("the statically configured maximum trace level"). Via cargo features `max_level_*` / `release_max_level_*`, "trace instrumentation at disabled levels will be skipped and will not even be present in the resulting binary." Classic prod config in the **application** crate:

```toml
tracing = { version = "0.1.44", features = ["release_max_level_info"] }
# trace!/debug! become true no-ops in release — zero bytes, zero branches
```

**Gotcha:** these features are **global and set once for the whole binary** — both `log` and `tracing` docs warn libraries must NOT set them (a library that pins `release_max_level_warn` silently mutes the whole app). The TextView **core must not touch max-level features**; each host binary decides.

### Redaction / PII — opt-in, type-enforced

Free-text `info!("user {}", email)` leaks PII the moment someone logs a struct's `Debug`. Defenses, strongest first:

- **`secrecy`** — `SecretBox<T>` deliberately implements neither `Debug` nor `Display`; access requires the explicit `ExposeSecret` trait, and contents are `zeroize`d on drop. Wrapping a field in `Secret<String>` makes accidental logging a *compile error*, not a runtime leak. This is the day-one move for tokens/keys.
- **`redact` / `redactable`** — derive macros that emit masked `Debug` (`[REDACTED]`, or last-4 for tokens) so structs are safe to log wholesale.
- **Pipeline-level scrubbing** (regex/processor in the collector or Sentry's data scrubbers) — a backstop, not a primary control; brittle on structured JSON.

Establish the convention early: secrets are *types*, not strings.

### Dynamic runtime log-level control

You will eventually want to crank a subsystem to `debug` in prod without a restart. `tracing-subscriber`'s `reload` module wraps a filter and hands back a `reload::Handle`:

```rust
let (filter, handle) = reload::Layer::new(EnvFilter::new("info"));
// later, from an admin endpoint / signal / UI toggle:
handle.modify(|f| *f = EnvFilter::new("textview_core::parser=debug,info"))?;
```

Wire the handle to a host control surface (admin HTTP route on the server, a hidden menu in the macOS app, a key in the TUI). Cheap to add upfront, awkward to bolt on later. Note `Targets` is a lighter-weight filter than `EnvFilter` when you don't need field/span-value matching.

### Async/flush correctness

`tracing-appender::non_blocking` moves writes off the hot thread but returns a **`WorkerGuard`** that must be held for the program's lifetime — "to ensure buffered logs are flushed... in the case of abrupt terminations." Drop it early (e.g. `let (w, _) = ...; ` then it's gone) and the last buffered logs — often the crash you're debugging — vanish. Bind it to a variable that lives in `main`.

### Standardization at scale

Large Rust shops converge on **`tracing` + `tracing-subscriber` + `tracing-opentelemetry` → OTLP** to a backend (Datadog, X-Ray, SigNoz, etc.). Logs, spans, and trace context flow through one API. OpenTelemetry-Rust explicitly tells new projects to instrument against `tracing`. For TextView, OTel is overkill in the core but the host server should keep the door open by using `tracing-subscriber` from the start.


## Key takeaways
- Instrument the reusable core with `tracing` (not `log`) and have it install NO subscriber — emitting-only is the library discipline; each host binary owns subscriber setup exactly once, early. The `log` feature on `tracing` keeps you compatible with log-based hosts.
- Use structured key/value fields (`info!(doc.bytes = n, "opened")`), never string interpolation — fields are what make logs filterable/aggregatable; spans + `#[instrument]` propagate context (doc id, request id) automatically.
- Disabled `tracing` events are cheap at runtime (cached interest check, fields not evaluated) but NOT free; for true zero-cost on hot paths, the APPLICATION crate sets `release_max_level_info` so `trace!`/`debug!` are stripped from the binary entirely. The core/libraries must never set these global features.
- FFI trap to design around from day one: every `cdylib` gets its own copy of Rust statics, so a subscriber set in one is invisible to `tracing` events in another — ship a single cdylib or expose an explicit `init_logging(callback)` FFI entry that installs inside the same static instance.
- Output sink differs per host: stdout-JSON on the headless server, a FILE (never stdout/stderr) for the ratatui TUI, browser `console` via `tracing-web`/`wasm-tracing` + a panic hook for WASM, and a custom MakeWriter/layer bridging to Swift `os_log` for the macOS FFI host.
- Treat secrets as TYPES, not strings: wrap them in `secrecy::SecretBox` (no Debug/Display, zeroize-on-drop) so accidental logging is a compile error; use `redact`/`redactable` derive for masked Debug on PII-bearing structs.
- Build dynamic log-level control upfront via `tracing-subscriber`'s `reload::Handle` wired to a host control surface — cheap now, awkward to retrofit. `Targets` is a lighter filter than `EnvFilter` when field/span-value matching isn't needed.
- `tracing` + `tracing-subscriber` + `tracing-opentelemetry` → OTLP is the at-scale standard; the headless server should start on `tracing-subscriber` to keep that door open without pulling OTel into the core.

## Gotchas
- Library installing a subscriber/logger: the most common first-timer error. `set_global_default` (tracing) or `init` (log) can only run once per process; if the core or any dep does it, the host binary's setup conflicts or is silently ignored. The core must emit-only.
- cdylib static duplication across FFI: each cdylib has its own copy of the global-dispatcher static, so `tracing` events in one library never reach a subscriber set in another. Symptom is silently dropped logs across the FFI boundary. Fix: single cdylib, or an explicit init-with-callback FFI entry point.
- A library pinning `max_level_*`/`release_max_level_*` features: these are GLOBAL and set once for the whole binary. A dependency that sets `release_max_level_warn` silently mutes the entire application's info/debug logs. Only the final binary may set them.
- Dropping the `tracing-appender` non_blocking `WorkerGuard` early (e.g. `let (w, _guard) = ...` where `_guard` then goes out of scope): the background worker is torn down and the last buffered logs — frequently the crash you're investigating — are lost on abrupt exit. Hold the guard in `main` for the process lifetime.
- Logging to stdout/stderr in the TUI host corrupts the ratatui display; logging the std `fmt` writer in WASM goes nowhere (no real stdout in the browser). Each host needs a host-appropriate writer, not the default fmt-to-stdout subscriber.
- Assuming disabled `trace!`/`debug!` calls are zero-cost at runtime: they cost a cached interest check per callsite. Inside a tight per-token/per-char loop that adds up — use compile-time `release_max_level` stripping for genuinely hot paths.
- PII/secret leakage via `Debug`: deriving `Debug` on a struct with a token/password field and then logging `?value` (or it being captured by an `#[instrument]` arg) leaks it. Wrap secrets in `secrecy` or mask with `redact`; don't rely on collector-side regex scrubbing as the primary control.
- tracing-subscriber `EnvFilter` directives filter by target/level but (per upstream issues) do NOT filter by span/field values the way users expect; reach for explicit per-layer filters or `Targets` and verify behavior rather than assuming.
- `tracing-wasm` is effectively unmaintained against current `tracing`/`wasm-bindgen`; use the maintained `wasm-tracing` fork or `tracing-web`, and remember `console`/`performance` globals don't exist in Node/Cloudflare Workers WASM targets.
- Forgetting `console_error_panic_hook` in the WASM host: Rust panics surface as opaque `unreachable executed` / `RuntimeError` with no message in the browser console unless the hook is installed.

## Crates
- tracing — emit structured, leveled, span-based events; the facade the core should instrument against — tokio-rs maintained, de-facto standard, actively developed (v0.1.44)
- tracing-subscriber — application-side: install subscribers, EnvFilter/Targets filtering, fmt (text/JSON) output, reload, per-layer filters — tokio-rs, the canonical companion to tracing
- tracing-appender — non-blocking writer (WorkerGuard) and rolling file appender for the headless/TUI hosts — tokio-rs, standard; mind the guard-lifetime gotcha
- tracing-log — bridge so a tracing Subscriber consumes `log` records from log-only dependencies — tokio-rs, use when deps emit `log`
- log — the older minimal facade; only relevant for interop/compat, not the core's primary instrumentation API — rust-lang maintained (v0.4.30)
- tracing-opentelemetry — export tracing spans/events as OTLP to Datadog/Jaeger/X-Ray etc.; for the at-scale server path, not the core — actively maintained alongside opentelemetry-rust
- wasm-tracing — maintained fork of the unmaintained tracing-wasm; routes tracing to browser console/performance for the WASM host — prefer over tracing-wasm
- tracing-web — alternative WASM/browser subscriber (console + performance marks) — maintained, viable WASM option
- secrecy — SecretBox wrapper with no Debug/Display, ExposeSecret access, zeroize-on-drop; makes accidental secret-logging a compile error — well-established, the day-one choice for tokens/keys
- redact / redactable — derive macros for masked Debug ([REDACTED], last-4 for tokens) so PII-bearing structs are safe to log — newer, evaluate maintenance before adopting
- tracing-flame / tokio-console — span-based profiling and async runtime introspection; optional dev-time observability built on the same instrumentation — tokio-rs ecosystem

## Sources
- https://docs.rs/tracing/latest/tracing/ — tracing crate docs v0.1.44 (libraries must not set_global_default; log/log-always interop; field syntax; disabled spans never constructed) — accessed 2026-05-30
- https://docs.rs/tracing/latest/tracing/level_filters/index.html — STATIC_MAX_LEVEL and max_level_*/release_max_level_* compile-time stripping ('will not even be present in the resulting binary') — accessed 2026-05-30
- https://docs.rs/log/latest/log/ — log crate docs v0.4.30 (facade pattern; libraries link only to log, executables init once early; max_level features global; kv structured logging; pre-init records ignored) — accessed 2026-05-30
- https://github.com/rust-lang/log — rust-lang/log repository and library-vs-executable guidance — accessed 2026-05-30
- https://users.rust-lang.org/t/sharing-global-default-tracing-subscriber-across-ffi-boundaries/113324 — forum thread: each cdylib gets its own copy of Rust statics, so the global default subscriber doesn't cross cdylib FFI boundaries; recommended single-cdylib/dylib/explicit-call fixes — accessed 2026-05-30
- https://docs.rs/tracing-appender/latest/tracing_appender/ — non_blocking WorkerGuard must be held to flush on abrupt termination; rolling file appender — accessed 2026-05-30
- https://docs.rs/tracing-subscriber/latest/tracing_subscriber/reload/index.html — reload module/Handle for dynamic runtime filter/level changes — accessed 2026-05-30
- https://docs.rs/tracing-subscriber/latest/tracing_subscriber/filter/struct.EnvFilter.html — EnvFilter vs lighter-weight Targets; env-filter feature requires std; smallvec optimization — accessed 2026-05-30
- https://docs.rs/secrecy/latest/secrecy/ — SecretBox/Secret with no Debug/Display, ExposeSecret trait, zeroize-on-drop — accessed 2026-05-30
- https://github.com/sformisano/redactable — automatic redaction of sensitive data (classifications/policies, masked Debug) for safe logging — accessed 2026-05-30
- https://crates.io/crates/wasm-tracing — maintained fork of tracing-wasm compatible with current tracing/wasm-bindgen; uses browser console/performance — accessed 2026-05-30
- https://lib.rs/crates/tracing-wasm — tracing-wasm (older, uses global console/performance; not available in Node/Cloudflare Workers) — accessed 2026-05-30
- https://opentelemetry.io/docs/languages/rust/ — OpenTelemetry-Rust recommends instrumenting new apps with tracing; tracing-opentelemetry OTLP export — accessed 2026-05-30
- https://tokio.rs/blog/2019-08-tracing — Tokio 'Diagnostics with Tracing' intro: spans, structured context, reloadable filter via admin endpoint — accessed 2026-05-30
- https://www.lpalmieri.com/posts/2020-09-27-zero-to-production-4-are-we-observable-yet/ — Luca Palmieri, Zero To Production: Rust telemetry, structured logging discipline, library-vs-app responsibilities — accessed 2026-05-30
- https://oneuptime.com/blog/post/2026-01-25-structured-json-logs-tracing-rust/view — structured JSON logs with tracing (fields-not-strings, fmt().json()) Jan 2026 — accessed 2026-05-30
- https://oneuptime.com/blog/post/2026-02-06-redact-sensitive-data-pii-opentelemetry-pipeline/view — pipeline-level PII redaction in the OpenTelemetry collector (backstop control) Feb 2026 — accessed 2026-05-30