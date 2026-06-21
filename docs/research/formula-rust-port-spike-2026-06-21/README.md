# Spike — Formula evaluator → Rust? (2026-06-21)

**Ticket:** TSK-1213 · **Owner question:** *"why are we building these in Swift and not Rust?"* + *"can we do a spike / deep research into tradeoffs and how it would work before we port?"*

**TL;DR recommendation:** **Yes, move formula evaluation to Rust — hand-write/port our own logic (do NOT adopt a crate now), as a STATEFUL `FormulaSession` handle behind the EXISTING `mdvcore_call` command/event envelope, with a coarse, transport-agnostic API from day one.** Defer dependency-graph recalc to a later slice. Keep `formualizer-eval` documented as a fallback if full Excel-grade recalc + 400 functions becomes a near-term priority and the Arrow binary-size cost is accepted.

---

## Why this came up

We shipped a broad Swift `FormulaEngine` this session (TSK-1212: ~40 functions — math/text/lookup/conditional/aggregate/date, 29 host tests). The owner correctly flagged that a pure-logic evaluator is a textbook **rust-core** citizen (deterministic, FFI-trivial, remote-capable) and its consumer (CSV) is **already ported to Rust** — so new engine work cuts against the rust-core/remote-core direction. This spike researches whether/how to port it before sinking more work into either language.

Method note: 4 research agents launched; 2 initially died on API rate-limiting. Gaps were recovered by direct search. Angles covered: prior-art/architecture, Rust crate landscape + maturity, codebase integration map, recalc/FFI boundary.

---

## Finding 1 — Crate landscape: adopt-vs-build has exactly ONE adopt candidate

| Crate | Version / freshness | Coverage | Verdict |
|---|---|---|---|
| **formualizer-eval** | 0.7.0, released 2026-06 (active); ~2.5k downloads; MIT/Apache | 400+ Excel fns, **dependency graph + incremental recalc**, undo/redo, dynamic arrays; Arrow-backed | **Only viable crate** — but pre-1.0, low adoption, **heavy (Apache Arrow)** |
| `formula` | 0.1.0, last release **2022** (~dead, 12 recent dl) | date/text/math/logical | Not viable (abandoned) |
| `xlformula_engine` | 0.1.4, stale | arithmetic + ABS/SUM/PRODUCT | Not viable (too limited) |

xlsx *readers* (`calamine`, `umya-spreadsheet`) read stored values + cached results + formula *strings* — they do **not** evaluate. Reading ≠ evaluating; the two are decoupled deps.

**Implication:** "adopt a crate" means **adopt `formualizer-eval` or nothing.** Its win is free recalc + 400 fns; its costs are a young (v0.7) + heavy (Arrow) dependency.

## Finding 2 — Codebase already has the right boundary machinery

The rust-core "thin waist" is built (TSK-580): `mdvcore_call(method, req, aux) -> out_buf` over **MessagePack frames** (`wire.rs`, `rmp-serde`, u32 length-prefix), routed by a stable `u16` method id (`dispatch.rs`), with capability bits + a panic guard (`ffi/src/lib.rs`). Swift consumes via `CoreClient`/`CoreEnvelope` + per-engine adapters (e.g. `RustCSVAdapter`, opaque `CsvSession` handle). **A formula port extends this exact pattern — no new binding tech needed.**

**The one hard constraint:** the Swift `CellResolver` *callback* (`(CellReference) -> String?`) **cannot cross the C ABI.** So the boundary shape is the central design decision:

| Boundary | How | Recalc fit | Remote fit |
|---|---|---|---|
| **Snapshot (stateless)** | Swift sends all needed cells per eval; Rust returns value | none (lazy, per-call) | poor — re-sends cells; chatty over wire |
| **Stateful `FormulaSession` handle** | Rust owns the grid; Swift calls set_cells / recalc / get_viewport | **persists the dependency graph between edits** | good — coarse commands map to RPC |
| **RPC service** | core is a service; UI sends commands, gets value deltas | same as handle | native fit |

## Finding 3 — Prior art validates a stateful, coarse, transport-agnostic core

- **Quadratic** (Rust core as a worker): renderer asks core for the **visible viewport + padding**; core, after an op, **pushes only the changed cells in the viewport**. This *viewport-windowed delta-push* is our remote-core read pattern, already proven. The boundary is `postMessage` today; the identical shape runs over a socket.
- **1Password** (Swift UI + embedded Rust core): UI sends **invocations** (a request/response *message* channel, not fine-grained function calls); DTOs synced via `typeshare`; same core also runs WASM/Node. The **command-in / event-out envelope is what makes a core transport-portable** — which is exactly our `mdvcore_call` envelope.
- **Latency hierarchy (~1000×/level):** in-process FFI ~ns · same-machine IPC ~µs · network RPC ~ms+. A one-call-per-cell API is fine in-process and **catastrophic over the wire** (chained dependent calls = pure RTT stall). → **Design the command API coarse/batched NOW** or it can't go remote later.
- **Bindings:** Matrix/Element evaluated UniFFI vs swift-bridge and chose **UniFFI** (swift-bridge less mature, bus-factor-1, Swift-only). We don't need either — our MessagePack envelope already is the command/event channel. (UniFFI is the fallback if we ever want generated bindings.)
- **WASM = portability, not speed** (Flipt measured **35–45% slower** than FFI). WASM is the browser/sandbox client play, not the hot recalc loop.
- **Binary size:** a raw Rust core is ~25–32 MB, cut to ~7 MB with `lto="fat"` + `panic="abort"` + `strip`. Our caps are **26 MB exec / 48 MB bundle** — fits only with those flags. **This is a strong point against `formualizer-eval`: Apache Arrow is a large dep that would pressure the cap.**
- **Versioning trap:** an in-process FFI boundary lets you skip wire versioning — that's the trap. Adopt protobuf-style discipline from commit #1 (stable field ids, never reuse/retype, ignore-unknown for forward-compat) so the remote future has a migration path.

## Finding 4 — Recalc is the swing factor

Hand-writing means later building a dependency-graph recalc engine (dependents map, dirty-marking, topological eval order, cycle detection, volatile-fn handling). That's real work `formualizer` already did. BUT: our current Swift engine has **no recalc either** (it evaluates one cell against a snapshot); the snapshot model is a legitimate first stage. So recalc is a *future* slice, not a blocker — and not a reason to take the Arrow dependency today.

---

## Recommendation

1. **Build, don't adopt (for now).** Hand-write/port the evaluator into `rust-core/crates/core/src/formula.rs`, mirroring the `csv`/`diff` modules. Rationale: minimal-deps policy + the **26 MB exec cap** (Arrow would pressure it) + we already own the exact logic *and* a 29-test corpus to port against (TSK-586 golden-corpus pattern). The arithmetic-core PoC already exists (dormant, ~250 LOC, 8 cargo tests).
2. **Stateful `FormulaSession` handle**, not per-call snapshot — Rust owns the grid; Swift drives it with **coarse commands** (set-cells / recalc / get-viewport-values). This solves the resolver-can't-cross-FFI problem, persists a future dependency graph, and is the transport-portable shape (1Password/Quadratic).
3. **Reuse the existing `mdvcore_call` MessagePack envelope** — add a `Formula*` method/session to `dispatch.rs` + a `RustFormulaAdapter` on the Swift side. No UniFFI/swift-bridge needed.
4. **Transport-agnostic + versioned from day one** — coarse API (per the latency hierarchy), field-id discipline on the wire types.
5. **Defer recalc** — start with snapshot/whole-session eval; add the dependency-graph recalc as a later slice if/when needed.
6. **Pin the size flags** (`lto=fat`, `panic=abort`, `strip`) so the core fits the cap.
7. **Keep `formualizer-eval` as a documented fallback** — revisit only if full Excel-grade recalc + 400 functions becomes a near-term priority and the Arrow binary-size cost is accepted (would need explicit owner dep-approval).

## Slice plan (if approved)

1. ✅ Arithmetic core (dormant PoC: literals, `+ - * / ^ %`, parens, precedence; 8 cargo tests).
2. Cell references + ranges + value coercion (Number/Text/Bool/Blank/Error parity with Swift).
3. Function library — port the ~40 Swift fns; validate against the Swift test corpus (golden cases).
4. `FormulaSession` handle + `dispatch` method + `wire` types (the command/event envelope).
5. `RustFormulaAdapter` (Swift) + route the CSV `=` cell path through it (gated, A/B vs Swift).
6. (Later) dependency-graph incremental recalc + viewport-windowed delta read.

## Open questions for the owner

- **Build vs adopt** — confirm hand-write (recommended), or do you want `formualizer-eval` evaluated as a dep (Excel-grade recalc sooner, but Arrow + v0.7)?
- **Recalc priority** — is live dependency-graph recalc a near-term need, or is per-edit snapshot eval fine for now?
- **Scope of the Swift twin** — once ported, the Swift `FormulaEngine` becomes bugfix-only then deleted (per migration policy) — confirm.

---

## Update (2026-06-21) — decision, progress, recalc/FFI research

**Owner decision: Option A — build it ourselves, no dependencies** (not `formualizer-eval`).

**Port progress** (hand-written, `rust-core/crates/core/src/formula.rs`):
- ✅ Slice 1 — arithmetic core (`03105441`)
- ✅ Slice 2 — cell refs + resolver + value coercion (`4b414d90`)
- ✅ Slice 3a — function calls + ranges + core fns: SUM/AVERAGE/MIN/MAX/COUNT/PRODUCT, IF/AND/OR/NOT (`bc6590b7`)
- Next: **3b** comparison operators (`>`/`<`/`=`/`>=`/`<=`/`<>`) + the text/math/lookup library vs the Swift 29-test corpus; then **4** `FormulaSession` FFI handle; **5** Swift consumer; **6** (later) recalc.

**Recalc + FFI deep-research (agent 3) — VALIDATES the plan:**
- *Recalc* (slice 6, when added): **support graph** (forward dependents) + interned **range vertices** + overlapping-range sharing + tile spatial index; **dynamic precedent capture** (record cells actually read — mandatory for INDIRECT/OFFSET/conditional branches, which static AST analysis over-approximates); dirty-mark via bitset + reusable worklist **seeding volatiles every pass**; **Kahn over the dirty SUBSET**, levelized for Rayon, serial lane for impure fns; cycles via `Computing`-state DFS + opt-in per-SCC iterative (max-iter + ε). Mirrors where IronCalc + Formualizer converge and Sestoft's formal model (*Spreadsheet Implementation Technology*).
- *FFI boundary* (slices 4–5): **stateful Rust handle with a message-shaped (RPC-style) API** — coarse, batched, **delta-returning** (the dirty-mark→topo output *is* the boundary payload). Rust owns the grid + graph; Swift mirrors the viewport only. Mechanics: opaque `Box` handle + `Arc<Mutex>` for the `!Send/!Sync` trap; **`catch_unwind` at every FFI seam** (needs `panic="unwind"` — the `dist` profile already uses it); **binary codec, not JSON** (the xi-editor lesson); **do NOT go out-of-process prematurely** (xi's mistake — the win is the message-shaped API *in-process*). Generator: swift-bridge or hand `cbindgen`; UniFFI only if Kotlin/Web. The existing `mdvcore_call` MessagePack envelope already *is* this shape.
- *Anti-patterns* (each cost a named project real pain): per-cell set/get chatter; rebuilding the dep graph per call; letting a Rust panic unwind into Swift; a fine-grained pointer API with no message envelope (dies at the first sandbox/remote boundary — Mullvad).

Prior art + sources are captured in the TSK-1213 board comments (Quadratic viewport-delta-push, 1Password command/event core, Sestoft/CoreCalc, HyperFormula, IronCalc, Pearce–Kelly DTO, the xi-editor retrospective, the UniFFI-vs-swift-bridge Matrix decision, the Flipt FFI→WASM measurement).
