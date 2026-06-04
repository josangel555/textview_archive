# Rust-core migration — execution plan (2026-06-04)

> Synthesized from a 6-agent mapping workflow (`wf_ae970068`: ViewerCore
> inventory · DocumentModel anatomy · rust-core template · Swift↔Rust seam ·
> one unprimed architect → ranked synthesis). Builds on the locked decisions in
> `docs/RUST_CORE_MIGRATION.md §1` and the proven CSV beachhead (`ace7d5c`).
>
> **Goal:** move as much pure/domain logic as possible out of Swift into the
> Rust core so the SwiftUI app becomes a *projection*; the same core later backs
> a TUI and a web front-end with no new core code.
>
> **Prime directive (carried from the CSV slice):** every slice lands behind a
> **default-OFF, fail-safe** gate with **A/B parity tests** vs the Swift
> incumbent. The Swift path is never deleted until a slice has shipped ON by
> default and soaked. Nothing here deletes a working Swift code path this turn.

## Phasing

- **Phase A — stateless transforms (no new deps, headless).** `bytes → encode →
  call → decode`. No handle. This is the bulk of the cheap wins and needs zero
  owner approval. Slices 2–8 below.
- **Phase B — stateful sessions.** Opaque handle (`open/dispatch/snapshot/free`),
  like `CsvSession`. Requires a **Swift→Rust MessagePack encoder** (only the read
  path exists today) for command dispatch. EditorBuffer+undo, TabsState.
- **Phase C — streaming / IO-edge.** file-watch, LSP, remote tier. Deferred;
  open decisions (sync framing vs a contained tokio thread).

## Slice ledger (ranked)

| # | Slice | Purity | Value | Risk | New dep? | Phase |
|---|---|---|---|---|---|---|
| 1 | **CSV** parse+filter+session | pure | high | low | none | **DONE** (`ace7d5c`) |
| 2 | **CMEditApplier** (CodeMirror edit batch → string) | pure | high | low | none | A |
| 3 | **Diff parsers** (unified-diff → hunks; → gutter marks) | pure | med | low | none | A |
| 4 | **HexDumpBuilder + HexLayout + HexCaretMap** | pure | med | low | none | A |
| 5 | **HexSearchEngine** | pure | med | low | none | A |
| 6 | **FuzzyMatcher** (palette/file-nav scoring) | pure | med | low | none | A |
| 7 | **IndentDetector** | pure | low | low | none | A |
| 8 | **FileIconClassifier** | pure | low | low | none | A |
| 9 | **FindEngine** (regex/literal text search) | pure | high | med | **`regex`** ⚠️ | A* |
| 10 | **ClaudeLogParser + ClaudeMonitorLog** (JSONL → events) | pure | med | low | **`serde_json`** or hand-decode ⚠️ | A* |
| 11 | **Markdown→HTML + highlight spans** | pure | high | med | **`comrak`+`tree-sitter`** ⚠️ | A* |
| 12 | **JSON/XML pretty-printer** | mixed | low | med | XML needs `sxd-document` ⚠️ | spike-first |
| B | **EditorBuffer + undo/redo (HistoryStore)** | stateful | high | med | none | B |
| B | **TabsState / Sessions** state machine | stateful | high | **high** | none | B (eyes-on) |

`*` = no-dep parts are Phase-A-ready; the dep is the gate (see Owner approvals).

**Critical port hazards** (the parity corpus must cover these or the port
silently corrupts): **UTF-16 vs UTF-8** — Rust `str` is UTF-8, CodeMirror/
`NSString` index in UTF-16 code units; `CMEditApplier` and `FindEngine` line/col
must convert, with astral-plane + CRLF cases in the A/B corpus. `FindEngine`'s
**P11 monotonic line/col cursor** must port exactly (naive walk = perf
regression). `comrak` (strict) vs Apple `swift-markdown` (permissive) GFM quirks
will surface as silent rendering diffs — the parity corpus is the only guard.

## FFI seam evolution (1 → N)

~90% of the CSV seam is reusable verbatim: the two-crate split
(`mdvcore-core` `#![forbid(unsafe_code)]` + `mdvcore-ffi` unsafe edge), the
`ffi_guard!`/`catch_unwind → MdvStatus` mapping, the `#[repr(C)] MdvStatus`,
the opaque `Mutex`-wrapped handle (`Box::into_raw` / `*_free`, `try_lock →
Busy`), `wire::encode_frame` (`u32`-LE prefix + `rmp_serde::to_vec_named`), the
cbindgen `build.rs` header regen, and `trace::Sink`. **Re-implement per slice,
do NOT generalize prematurely:** the parser, `Limits`, `Query`, the session
type, and the Swift gate/adapter.

Staged generalization (avoid baking CSV-shaped assumptions in with n=1):
1. **NOW (additive, zero-risk, this turn):** `RustCoreGates` (one predicate per
   capability, env > UserDefaults > false), `RustCoreFallback<T>` (try-Rust /
   fall-back-to-Swift with a `.rust/.swiftFallback/.swiftBecauseGateOff` source
   tag), `RustABTestable` (copy-paste parity harness), and a hand-rolled
   **Swift→Rust MessagePack encoder** (read path only exists today). CSV gate/
   adapter refactor to delegate, zero behaviour change.
2. **After slice 2–3 land:** unify the FFI guard usage + `CoreError` once 2–3
   real error surfaces exist (not before).
3. **Phase B:** consider a unified `CoreClient` / `RustSessionHandle` protocol —
   spike first; each session may need domain-specific commands.

Slice shapes: **Type-1** stateless (no handle) for A; **Type-2** stateful
(open/dispatch/snapshot/free) for B; **Type-3** streaming for C.

## DocumentModel split

**Anatomy:** ~4071 lines, ~60% pure-domain computation, ~40% `@MainActor`
view-glue. Pure-domain (extractable): tab select/close/move state machine
(~3308–3589), file-open dispatch routing (~504–567), CSV filtering (already a
handle), cross-file search (already pure). View-glue (stays Swift): the child
`ObservableObject`s (`TabCoordinator`, `EditorCoordinator`, `FindCoordinator`,
`SourceViewChannel`, `SidebarModel`, `PanelLayoutStore`) — **deliberately NOT
forwarded** to `DocumentModel.objectWillChange` (PERF #1); modal/lock/cross-
search presentation; per-tab caches.

**Safe extractions (headless, no observation change):** the pure ViewerCore
units (slices 2–8) are *already* split out as standalone types — porting them to
Rust IS the safe split. The remaining in-`DocumentModel` candidate is the pure
tab select/close/move **index math** → a tested `TabsReducer` value type that
`DocumentModel` delegates the *decision* to while keeping `updateDerived()`/
republish exactly as-is. (Do this behind characterization tests; it's central,
so verify behaviour-preservation carefully.)

**Observation restructure — OWNER-GATED, eyes-on, NOT headless.** End-state:
`DocumentModel` becomes a CoreClient **projection** — holds an opaque handle +
last-decoded snapshot; `@Published` props become derived; user actions forward
as core inputs; the core's level-triggered snapshot reconciles into published
state (resend-and-reconcile). This is **#202 / dead-toggle territory**
(`LESSONS.md`): child `ObservableObject` changes are intentionally not forwarded
to the parent; a naive projection routes updates through the parent and views
observing children go dead, or `lastSnapshot = newSnap` fails to fire
`objectWillChange` and the projection silently stops. The recent "republish at
async load completions" + "live view-mode smoke gate" commits are scar tissue
from exactly this. **Must be a supervised turn with the live view-mode smoke
gate; never headless-only; never while the screen is locked.**

## Owner approvals required (do NOT treat as free)

Approved-on-paper ≠ in `Cargo.lock`. Today's lock has only
serde/rmp-serde/rmp/byteorder. Each **first link** is a real build/size/supply-
chain event, size-checked against the **16 MB exec / 37 MB bundle caps**
(`scripts/check-bundle-size.sh` is load-bearing):

- **`regex`** — for FindEngine (slice 9) + Find/Filter sessions.
- **`comrak` (`default-features=false`, ~13 pure crates) + `tree-sitter`** — for
  the markdown→HTML slice (11). Multi-MB; the size cap is the real gate.
- **`serde_json`** (or hand-decode via the rmp path) — for the Claude log
  parsers (10). Pick the route with sign-off.
- **`sxd-document`** (or similar) for XML pretty-print (12) — NOT on the
  shortlist; **spike a latency measurement first** to prove the cost is real
  before requesting.
- **`tokio`** (~30 deps) — only if the tokio-thread LSP route wins over
  hand-rolled sync framing (Phase C; decide at spike time).

## Risks (ranked)

1. **Premature seam unification** — with only CSV as data, generalizing the FFI
   guard / `CoreError` / a unified `CoreClient` now bakes CSV assumptions into N
   slices. Only `RustCoreGates`/`RustCoreFallback`/`RustABTestable` are safe to
   unify now.
2. **Dep-creep masquerading as approved** — see Owner approvals; every first
   link is size-gated.
3. **UTF-16/UTF-8** in CMEditApplier + FindEngine — silent edit corruption on
   astral/CRLF without targeted parity cases.
4. **Dead-toggle** in any DocumentModel observation change — off-limits to
   headless automation; supervised only.
5. **No-baseline A/B** — HTMLRenderer, FileIconClassifier, Formatter lack
   isolated Swift tests; author golden corpora *before* porting.
6. **FindEngine P11 + ReDoS guard** — port the cursor opt exactly; decide
   `RegexComplexityGuard` placement (cross-FFI vs Swift-side pre-call) first.
7. **comrak vs swift-markdown GFM** quirks — parity corpus is the only guard.
8. **Bundle-size cap** — the markdown slice especially must be gated behind
   `check-bundle-size.sh`.

## Roadmap (per-turn)

- **This turn (safe, headless):** seam scaffolding — `RustCoreGates`,
  `RustCoreFallback<T>`, `RustABTestable`, Swift→Rust MessagePack encoder; CSV
  gate/adapter delegate-refactor (zero behaviour change). Plus this doc.
- **Next headless turns (no new deps):** slices 2 → 8 each end-to-end on the CSV
  template (core module + wire + ffi + Swift adapter/gate + cargo + Swift A/B).
  CMEditApplier first (highest value). Author golden corpora for HTMLRenderer /
  FileIconClassifier. Write the FindEngine ReDoS-placement decision.
- **Owner-gated:** approve (or decline) `regex` / `comrak`+`tree-sitter` /
  `serde_json` per the size budget → unlocks slices 9–11.
- **Supervised/eyes-on:** the `TabsReducer` extraction, then the DocumentModel→
  projection observation restructure with the live view-mode smoke gate.
