# Telemetry, Metrics & Distributed Tracing in Rust: ecosystem maturity and day-one design for a desktop + server core

## Bottom line

Instrument your **core** against the `tracing` facade only (and optionally the `metrics` facade) — never against an SDK or exporter. Treat `tracing` as the universal IDL for spans/events/structured logs; the *application shell* (macOS app, TUI, WASM, server) picks the `Subscriber`/`Layer` stack and the export backend at the I/O edge. This is the single cheapest day-one decision and the most expensive to retrofit, because it is exactly what keeps the sans-IO core decoupled from OpenTelemetry, Tokio, and any vendor.

## Ecosystem maturity (verified, May 2026)

`opentelemetry-rust` `0.32.0` shipped **2026-05-09**. Signal stability as stated in the repo status table:

| Signal | API | SDK | OTLP exporter | Notes |
|---|---|---|---|---|
| **Logs** | Stable | Stable | RC | Bridge-only API (no end-user logging API) |
| **Metrics** | Stable | Stable | RC | Prometheus exporter still Beta |
| **Traces** | **Beta** | **Beta** | Beta | Targeted to reach logs/metrics parity |

A combined **1.0** (logs+metrics+traces) was planned for mid-2025 and has slipped; the maintainers have publicly committed to a "very high bar" for future breaking changes in the logs/metrics SDKs. Reality check: the 0.x line has been *churny* — **0.28 was a large breaking release across all three signals** and shipped with a dedicated migration guide. Budget for periodic upgrade work, and pin exact versions (`=0.32.0`) — these crates are tightly version-locked to each other and to `tracing-opentelemetry` (which runs one minor *ahead*: `tracing-opentelemetry 0.x` pairs with `opentelemetry 0.(x-1)`).

## The layering that keeps the core clean

```
 core crate            -> depends ONLY on `tracing` (+ maybe `metrics`)  [no_std-friendly-ish, no IO]
   |  emits spans/events/fields
 app shell crate       -> owns tracing_subscriber::registry()
   |                       .with(fmt::Layer)          // dev console / file
   |                       .with(OpenTelemetryLayer)  // server: OTLP
   |                       .with(custom consent gate) // desktop: drop everything if not opted-in
 export edge (IO)      -> OTLP/gRPC (tonic, Tokio) | Prometheus scrape | local JSONL file
```

Key rules, all from primary docs:

- **Libraries depend on `tracing` only**, never `tracing-subscriber`, and must never call `set_global_default()` — that's the application's job (this is the same facade contract `log` established). Same for `metrics`: libraries call `counter!`/`gauge!`/`histogram!`; the app installs exactly one global `Recorder`.
- **`tracing` is the recommended instrumentation surface even if you ship OTel.** `tracing-opentelemetry` converts `tracing` spans into OTel spans; `opentelemetry-appender-tracing` (now **stable**) bridges `tracing` events into OTel **logs**. Note the split: `tracing-opentelemetry` handles traces + metrics but **not** logs export; the appender handles logs. You generally want both layers if you go full-OTel.
- This means the same instrumented core works for the **server** (OTLP -> Collector -> Honeycomb/Datadog/Jaeger), the **TUI/desktop** (a no-op or local-file layer), and **WASM** (a layer that posts to `console`/an in-memory ring buffer) with zero core changes.

## Sans-IO meets OpenTelemetry: the async gotcha (resolved)

Historically the OTel batch exporters *required* a Tokio runtime, which directly conflicts with a synchronous core — and `tonic` (gRPC) drags Tokio in regardless, so even `install_simple` panicked with "no reactor running" outside an async context. **As of 0.28 the batch components were rewritten to spawn dedicated background threads and make blocking calls** (`BatchSpanProcessor`, `BatchLogProcessor`, `PeriodicReader`) — no async runtime required for batching. The `.with_batch_exporter(exporter, runtime::Tokio)` call dropped its runtime argument. The **OTLP/gRPC client still needs Tokio** at the export edge; HTTP exporters can avoid it. For your design: keep all of this *in the shell*, behind your normal I/O boundary — the core never sees a runtime.

## Metrics: two competing facades

| Approach | What it is | When |
|---|---|---|
| **`metrics` + `metrics-exporter-prometheus`** | Lightweight Rust-native facade (`counter!`/`gauge!`/`histogram!`), global `Recorder`, no OTel machinery | Server scrape endpoint; minimal deps; the closest analog to the `tracing`/`log` facade pattern |
| **OTel metrics SDK** | Full OTel pipeline, OTLP push, semantic conventions | If you already run a Collector and want logs+metrics+traces correlated |
| **`metrics-tracing-context`** | Injects `tracing` span fields as metric labels | Bridge when you want span context on metrics |

For a privacy-sensitive desktop, you likely want **no metrics export at all** by default and just local counters; the `metrics` facade lets the core emit them unconditionally while the desktop shell installs a no-op or in-memory recorder.

## Desktop vs server: opt-in, consent, and PII

The desktop case is governed less by tooling than by *trust*, and the Rust community has a sharp position here. Esteban Küber's "No telemetry in the Rust compiler" argues the principle that should anchor your desktop design: **"user information should never leave their machine in an automated manner, even by accident."** His proposed model — emit metrics **locally to disk**, gate behind explicit config, keep data minimal (platform, version, bounded counters), apply retention limits, and make sharing a **manual, user-initiated upload** — is a near-perfect template for a privacy-sensitive editor.

Contrast with the **VS Code backlash**: VS Code telemetry is **opt-out**, and the GitHub issues ("Require user consent before sending any telemetry", "Could you please respect my decision about telemetry?") are a multi-year demonstration of the reputational cost of getting consent wrong in a developer-facing desktop tool. Lesson: for desktop, **default OFF, affirmative opt-in, no pre-checked boxes, revocation as easy as granting, and show the user the exact payload before it's sent** (transparency is the trust-builder).

Practical split:

- **Server**: telemetry on by default (operator owns the machine), OTLP to a Collector. Do PII scrubbing in the **Collector**, not in-process, via the `redaction` processor (attribute allowlist), `attributes`/`filter` processors, or `transform`/OTTL regex masking. OTel's official guidance: *the framework can't know what's sensitive — that's on you*; minimize data, and beware that hashing low-entropy IDs is reversible.
- **Desktop**: consent gate implemented as a `Layer` that **drops all events unless opted-in**, so the gate is structural, not scattered through call sites. Even when opted in, prefer local-first: write to a rotating local file, let the user inspect/attach it to bug reports. Crash reporting (e.g. Sentry/minidumps) should be a *separate*, separately-consented channel — many users will accept crash dumps but not usage telemetry.

## What to instrument from day one

- **Span the operation boundaries** of the core: document open/parse/render, edit-apply, save, search. `#[instrument(skip(large_buffers))]` — and `skip` anything that could carry document content (that *is* PII for an editor).
- **Structured fields, not string interpolation**: `info!(doc.bytes = n, lang = %lang, "parsed")` so backends can index. Never put file paths, document text, or user content in fields/span names by default.
- **Guard against cardinality from day one.** Metric labels and span *names* must be bounded — normalize dynamic values (`/doc/:id`, not `/doc/3829`). The rule of thumb: anything that could exceed ~10k distinct values (doc id, session id, file path) belongs in a *trace span field*, not a *metric label*. Publish a tiny label allowlist (env, platform, version, status) and a denylist (ids, paths, content) and keep both memorable.
- **Wire a `tracing` panic hook** so uncaught panics become structured events at the edge.
- **`tracing` macros are near-zero-cost when no subscriber is interested** (level/filter check short-circuits), so liberal instrumentation in the core is cheap — the cost lives in the shell's chosen layers.


## Key takeaways
- Instrument the core against the `tracing` facade only (plus optionally the `metrics` facade). Never let the core depend on `tracing-subscriber`, an OTel SDK, an exporter, or Tokio — the application shell owns the Subscriber/Layer stack and the export backend. This is the cheapest day-one decision and the most expensive to retrofit.
- Ecosystem status (opentelemetry-rust 0.32.0, 2026-05-09): Logs and Metrics APIs+SDKs are STABLE; Traces are still BETA. A combined 1.0 was planned for mid-2025 and slipped. Pin exact versions — the crates are tightly version-locked and the 0.x line has had large breaking releases (0.28 broke all three signals).
- Since 0.28 the OTel batch processors run on dedicated background threads and no longer require an async runtime, which removes the historic conflict with a synchronous sans-IO core. The OTLP/gRPC (tonic) exporter still needs Tokio, but only at the export edge — keep it in the shell.
- Desktop telemetry should follow the rustc 'local-first' principle: data never leaves the machine automatically. Default OFF, affirmative opt-in, no pre-checked boxes, easy revocation, and show the exact payload before sending. The multi-year VS Code opt-out backlash is the cautionary tale.
- Server vs desktop differ structurally: server is on-by-default with OTLP to a Collector that does PII redaction; desktop uses a consent-gate Layer that drops all events unless opted-in, prefers local rotating-file output, and treats crash reporting as a separate consented channel.
- tracing is the recommended instrumentation surface even under OpenTelemetry: tracing-opentelemetry converts spans (traces+metrics, NOT logs), opentelemetry-appender-tracing (stable) bridges events to OTel logs — you typically need both layers for full-signal export.
- Guard cardinality from day one: anything with >~10k distinct values (doc id, session id, file path, document content) goes in a trace span field, not a metric label or span name. Normalize dynamic path segments at the instrumentation layer; publish a short label allowlist + denylist.

## Gotchas
- opentelemetry-rust 0.x is churny: 0.28 was a large breaking change across logs/metrics/traces and shipped with a migration guide. Pin exact versions and budget for periodic upgrade work; the planned combined 1.0 has slipped past its mid-2025 target.
- tracing-opentelemetry runs one minor version AHEAD of the opentelemetry crates (e.g. tracing-opentelemetry 0.26 pairs with opentelemetry 0.25). Mismatched versions fail to compile or silently no-op — verify the pairing on every bump.
- tracing-opentelemetry exports traces and metrics but NOT logs. To export logs you need opentelemetry-appender-tracing as a separate layer. Easy to wire up tracing-opentelemetry, see traces flowing, and not realize logs are being dropped.
- The OTLP/gRPC client (tonic) requires a Tokio runtime even with install_simple — historically this caused 'no reactor running' panics in synchronous apps. Batching no longer needs a runtime (since 0.28), but the gRPC export edge still does. Use an HTTP exporter if you must avoid Tokio.
- Libraries must NEVER call set_global_default() (tracing) or install a global Recorder (metrics) — only the application binary may. A library that installs a subscriber breaks every downstream consumer. Same rule for the metrics global recorder, which can only be set ONCE per process.
- For an editor, document content IS PII. Default #[instrument] captures function args; forgetting skip() on buffers/paths/text leaks user documents into spans. Span names and file paths also leak. Make 'skip content' the default convention.
- OpenTelemetry explicitly will not detect sensitive data for you — redaction is entirely your responsibility. Hashing low-entropy identifiers (user/doc ids) is reversible in practice and is NOT real anonymization.
- VS Code's opt-OUT telemetry generated years of user backlash (multiple high-traffic GitHub issues). For a privacy-sensitive desktop app, opt-out is a reputational hazard; affirmative opt-in is effectively mandatory.
- metrics label cardinality explodes silently: a single user_id/session/path label can create millions of Prometheus time series, bloating memory and bills, with no compile-time warning. Enforce bounded labels at the instrumentation layer.

## Crates
- tracing — structured, span-based instrumentation facade; THE crate the core should depend on. Maintained by Tokio team, de-facto standard, extremely widely used. Verdict: adopt as the core's only telemetry dependency.
- tracing-subscriber — Subscriber/Layer implementations (fmt, EnvFilter, registry, layering). Application/shell only, never the core. Verdict: standard, use in shells.
- opentelemetry / opentelemetry_sdk — OTel API + SDK. 0.32.0 (2026-05-09); Logs+Metrics stable, Traces beta. Verdict: use in server shell only; pin exact version, expect breaking 0.x bumps.
- opentelemetry-otlp — OTLP exporter (gRPC via tonic / HTTP). RC for logs+metrics. Verdict: server edge; gRPC pulls in Tokio, HTTP can avoid it.
- tracing-opentelemetry — bridges tracing spans -> OTel traces+metrics (NOT logs); Tokio-maintained, runs one minor ahead of opentelemetry. Verdict: server shell; mind the version pairing.
- opentelemetry-appender-tracing — bridges tracing events -> OTel logs; now STABLE. Verdict: pair with tracing-opentelemetry when full-signal log export is needed.
- metrics — lightweight Rust-native metrics facade (counter!/gauge!/histogram!), global Recorder, mirrors the tracing/log facade pattern. Verdict: good fit for the core if you want metrics decoupled from OTel; install recorder in shell.
- metrics-exporter-prometheus — Prometheus backend for the metrics facade without the full prometheus crate. Verdict: server scrape endpoint; minimal-dependency choice.
- opentelemetry-prometheus — OTel-native Prometheus integration; still Beta. Verdict: only if standardizing on OTel metrics pipeline.
- metrics-tracing-context — injects tracing span fields as metric labels. Verdict: optional bridge; watch cardinality.
- opentelemetry-stdout — console exporter for local debugging. Verdict: dev/desktop-debug only.
- sentry / sentry-tauri — crash/minidump reporting with consent gating. Verdict: desktop crash channel ONLY, separately consented from usage telemetry; evaluate dependency weight before adopting.

## Sources
- https://github.com/open-telemetry/opentelemetry-rust — opentelemetry-rust repo, project status table + 0.32.0 release (2026-05-09)
- https://opentelemetry.io/docs/languages/rust/ — Rust | OpenTelemetry, official language status (Logs/Metrics stable, Traces beta)
- https://github.com/open-telemetry/opentelemetry-rust/blob/main/docs/migration_0.28.md — 0.28 migration guide (batch processors no longer require async runtime)
- https://github.com/open-telemetry/opentelemetry-rust/discussions/2137 — 'Using opentelemetry-otlp without an async runtime' (tonic/Tokio gotcha)
- https://github.com/open-telemetry/opentelemetry-rust/issues/2611 — 0.28 breaking-change scope + 1.0 plan
- https://docs.rs/tracing-opentelemetry — tracing-opentelemetry: traces+metrics bridge, version-pairing note (one minor ahead)
- https://github.com/open-telemetry/opentelemetry-rust/blob/main/opentelemetry-appender-tracing/README.md — appender bridges tracing logs to OTel; logs not handled by tracing-opentelemetry
- https://tokio.rs/tokio/topics/tracing-next-steps — Tokio: tracing -> OpenTelemetry/Jaeger layering, recommended subscriber stack
- https://docs.rs/tracing-subscriber/ — tracing-subscriber: libraries should not depend on it / not call set_global_default()
- https://www.lpalmieri.com/posts/2020-09-27-zero-to-production-4-are-we-observable-yet/ — Luca Palmieri, 'Are we observable yet?' (facade pattern, instrumentation vs processing split)
- https://docs.rs/metrics/latest/metrics/ — metrics facade + Recorder design, single global recorder
- https://github.com/metrics-rs/metrics — metrics-rs ecosystem overview
- https://esteban.kuber.com.ar/rustc-metrics/ — Esteban Küber, 'No telemetry in the Rust compiler' (local-first principle, data never leaves machine automatically)
- https://github.com/microsoft/vscode/issues/176269 — 'Require user consent before sending any telemetry' (VS Code opt-out backlash)
- https://github.com/microsoft/vscode/issues/123037 — 'Could you please respect my decision about telemetry?' (consent friction)
- https://code.visualstudio.com/docs/configure/telemetry — VS Code telemetry docs (opt-out model, crash reporting)
- https://opentelemetry.io/docs/security/handling-sensitive-data/ — OTel official: PII is your responsibility, data minimization, hashing caveats
- https://opentelemetry.io/docs/security/handling-sensitive-data/ + Collector processors (redaction/attributes/filter/transform-OTTL) for in-collector scrubbing
- https://grafana.com/blog/how-to-manage-high-cardinality-metrics-in-prometheus-and-kubernetes/ — metric cardinality management (bounded labels, allowlist/denylist)
- https://github.com/timfish/sentry-tauri — Tauri Sentry plugin (separate consented crash/minidump channel)
- https://opentelemetry.io/docs/specs/otel/versioning-and-stability/ — OTel versioning & stability spec