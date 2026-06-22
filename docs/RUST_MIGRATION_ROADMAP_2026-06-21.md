# Rust migration roadmap (TSK-775)

Status: spike/design (auto-approved). Author: claude-mdv, 2026-06-21. Consolidates
the Swift→Rust migration into one authoritative view + frames the horizon choice.
Supersedes the scattered state across `docs/RUST_MIGRATION_PLAN_2026-06-04.md`,
`docs/FEATURE_PORT_PLAN_2026-06-04.md`, the rust-core audit
(`docs/research/rust-core-audit-2026-06-09/`, epic TSK-538), and the per-engine port
tickets.

## The model
**One core, N front-ends.** `rust-core` (`crates/core`) holds the engines; the
SwiftUI macOS app, the std-only web front-end (`crates/web`), and the ratatui TUI
(`crates/tui`) consume them — the macOS app over the `mdvcore_call` FFI
(`crates/ffi`, MessagePack thin-waist + `dispatch::Method` ids), web/TUI as direct
Rust deps. A future `mdv-serve` (`crates/serve`) makes the FFI transport-swappable
(remote core). Each engine ships behind a per-capability gate
(`RustCoreGates`/`RustCoreCapability`, env `MDV_RUST_<CAP>` > persisted toggle >
shipped default); cross-language **A/B parity tests** are the regression net; the
endgame deletes the Swift twin (TSK-649 Stage B).

## The lifecycle of a port — and the trap this session found
A migration item is NOT done at "engine ported." The real ladder is:
1. **Engine** ported to `crates/core`, host-tested.
2. **FFI** method + wire types + Swift adapter (for the macOS app).
3. **Consumption** — a real app/view path CALLS the adapter.
4. **Gate flip** — `defaultEnabled` OFF→ON after a soak.
5. **Bake-in** — delete the Swift twin, retarget twin-coupled tests (owner-gated).

> **SYSTEMIC FINDING (2026-06-21): "ported + gated + validated" ≠ "user-visible."**
> The FormulaEngine port (TSK-1213) reached steps 1–2 fully (engine at full Swift
> parity + extensions, FFI evaluate/recalc, `RustFormulaAdapter`, all host-tested +
> A/B-parity-green) — yet step 3 was NEVER done for formulas IN EITHER LANGUAGE:
> `grep` of `Sources/` shows `FormulaEngine.evaluate`/`evaluateFormulaCell`/
> `recalcAllFormulas` have ZERO view consumers; `CSVTableView` renders cells as raw
> `Text(cell)`, so `=A1+B1` shows literal text on screen. A prior CHANGELOG entry
> over-claimed it as user-facing (removed @ e4ad9f10). The migration tracking must
> separate **engine-done** from **feature-shipped**; a validated engine ticket
> should link the consumption ticket (e.g. TSK-1213 → TSK-1215) and the CHANGELOG
> entry waits for step 3, not step 1.

## Current state (2026-06-21)
Gate defaults (`RustCoreCapability.defaultEnabled`): **ON** — csv, hex, hexSearch,
fuzzy, find, transcript, markdown, cmEdit, highlight (Stage A complete, soaked).
**OFF (new)** — formula (this session; awaiting soak + consumption, TSK-1215).
Retired-to-rust-only (gate removed, Swift twin gone): indent, diff.

| Engine | Engine | FFI | Consumed | Gate | Swift twin |
|---|---|---|---|---|---|
| csv | ✓ | handle | ✓ (CSVTableView) | ON | present (Stage B pending) |
| diff | ✓ | ✓ | ✓ | rust-only | DELETED |
| indent | ✓ | ✓ | ✓ | rust-only | DELETED |
| hex / hexSearch | ✓ | ✓ | ✓ | ON | present |
| fuzzy / find / transcript / markdown | ✓ | ✓ | ✓ | ON | present |
| cmEdit | ✓ | ✓ | ✓ | ON | present |
| highlight | ✓ | ✓ (separate crate) | ✓ | ON | present |
| **formula** | ✓ (+beyond Swift) | ✓ evaluate+recalc | ✗ **NOT WIRED** | OFF | present (bugfix-only) |

Web/TUI front-ends: the FEATURE_PORT_PLAN's ~29 structural-parity features are
substantially landed (find, hex search, table filter, diff, sort, hidden toggle,
goto-line, grep, outline, image, breadcrumb, reload, whitespace, word-wrap); web
markdown rendered view landed this session (TSK-256). TUI markdown stays source-only
(owner). Engines live in `core::view`/`core::*` so both render identically.

## Remaining work, by phase
- **Finish formula (TSK-1213 tail):** wire `recalcAllFormulas` into `CSVTableView`
  (TSK-1215, owner-gated product call: computed value in-grid, formula on edit,
  recalc on edit) → soak → flip → delete Swift twin. This is the one outstanding
  engine that hasn't crossed step 3.
- **Stage B bake-in (TSK-649, owner-gated per engine):** delete the soaked Swift
  twins (CSVParser/CSVFilter, HexDumpBuilder/HexSearchEngine, FindEngine,
  FuzzyMatcher, ClaudeLogParser, HTMLVisitor-structural, CMEditApplier) +
  retarget tests. Order: smallest blast radius first.
- **rust-core production audit (TSK-538, Phase 0–3):** the hardening roadmap in
  `docs/research/rust-core-audit-2026-06-09/synthesis.md` (windowed snapshot, error
  v2, envelope, DocId registry, FFI codegen TSK-634).
- **Remote-core (Phase 1 contract):** keep the wire transport-agnostic; the DocId
  registry is the remote enabler.

## Horizon choice — for the owner
Two scopes for "how far does the migration go":
- **(A) Engines-only.** Port + own the heavy/parseable engines in Rust (current
  trajectory); SwiftUI keeps all view/interaction/state. Lowest risk, most of the
  value (correctness + reuse across front-ends), nearly done. Recommended default.
- **(B) Whole-core.** Push more app logic (session/state/view-model) into rust-core
  toward a thin SwiftUI shell + a real remote core. Larger, longer, higher-reward
  for the multi-front-end/remote goal; depends on the Phase-1 contract maturing.

Recommendation: **continue (A) to completion** (finish formula consumption + Stage B
bake-in + the audit), and treat (B) as a separate, later, explicitly-scoped epic
once the remote-core contract (Phase 1) is proven. The owner's call on whether/when
to commit to (B) is the one genuine decision here; everything in (A) is
agent-actionable with the discipline above.
