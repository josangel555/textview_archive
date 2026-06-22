# Formula recalc engine — design (TSK-1213 slice 6)

Status: design (auto-approved spike). Author: claude-mdv, 2026-06-21.

## Why

The pure Rust evaluator (`rust-core/crates/core/src/formula.rs`) is complete and at
full Swift-`FormulaEngine` parity (~60 cross-language parity cases,
`Tests/ViewerCoreTests/FormulaParityTests.swift`). It is reachable from Swift over
the FFI (`Method::FormulaEvaluate` → `evaluate_wire`) and consumable behind
`RustFormulaGate` via `RustFormulaAdapter`.

But the FFI path is **stateless per-formula**: `evaluate_wire` takes
`{formulas, cells}` where `cells` is a snapshot of **raw** cell text, and the
evaluator's `Ref`/`Range` resolution does `coerce_cell(raw)` — it does NOT
recursively evaluate a referenced cell that is itself a formula. The Swift engine
DOES (its `EvalContext.visiting` set is cycle-detection for exactly that recursion).

Consequence — the **recursion gap**: a cell `=A1` where `A1` holds `=B1+1` returns
the wrong value through Rust (it coerces the literal text `"=B1+1"` instead of
evaluating it). So the CSV consumption wiring (slice 5b) is BLOCKED on closing this
gap. The fix is a recalc engine: evaluate every formula cell in dependency order,
resolving references to other cells' **computed values**.

## The blocker: eval resolves to raw strings, not values

`eval(e, resolver: &dyn Fn(CellRef) -> Option<String>)` and ~10 helpers
(`arg_num`, `arg_text`, `numeric_values`, `non_blank_count`, …) thread a
**string** resolver and call `coerce_cell(resolver(cr))` at 11 sites. Recalc needs
refs to resolve to **`Value`** (so a referenced formula cell yields its computed
`Value` — including `Bool`/`Error`, which do NOT round-trip through strings).

### Slice 6a — value-resolver refactor (behavior-preserving)

Change the resolver type from `Fn(CellRef) -> Option<String>` to
`Fn(CellRef) -> Value` throughout `formula.rs`:
- `eval` `Ref`/`Range` arms: `coerce_cell(resolver(cr))` → `resolver(cr)`.
- The ~10 helpers: drop the `coerce_cell(...)` wrap; call `resolver(cr)` directly.
- `evaluate_with(formula, string_resolver)`: compose at the boundary —
  `let vr = |cr| coerce_cell(string_resolver(cr)); eval(&expr, &vr)`. So the public
  `evaluate`/`evaluate_with` string API is UNCHANGED; only the internal resolver
  type widens.
- Teeth: the entire existing suite + the 60-case parity harness must stay green
  (pure refactor, zero behavior change). This is the gate for 6a.

## Slice 6b — the recalc engine (pure Rust)

```
pub fn recalc(cells: &HashMap<String, String>) -> HashMap<String, Value>
```
- Input: ALL cells as raw text (A1 → raw), data + formula.
- Output: A1 → computed `Value` for every FORMULA cell (raw starts with `=`).
  (Data cells aren't returned; the caller already has them.)

Algorithm — memoized recursive evaluation with cycle detection (mirrors Swift's
`visiting`, but computes every formula cell):
1. `resolve(cr)` returns the `Value` of a cell:
   - not present → `Value::Blank`.
   - raw not a formula → `coerce_cell(Some(raw))`.
   - raw is a formula (`=…`):
     - if memoized → return it.
     - if in the `visiting` set → `Value::Error(Cycle)` (and memoize that).
     - else: insert into `visiting`, parse the body → `Expr`, `eval(&expr, &|c| resolve(c))`,
       memoize, remove from `visiting`, return.
2. For each formula cell, call `resolve` and collect into the output map.

Notes:
- The `dependencies(&Expr) -> Vec<CellRef>` walk (Ref + expand Range; recurse
  Call/Neg/Percent/Bin/Cmp) is the explicit-DAG alternative; the memoized recursive
  `resolve` subsumes it and is simpler — prefer `resolve`. Keep `dependencies` only
  if a non-recursive topo order is later needed (e.g. incremental dirty recalc).
- Cycle handling matches Swift: a self/mutual reference yields `#CYCLE` for the
  cells on the cycle, not a hang or stack overflow. Cap recursion depth as a
  belt-and-suspenders DoS guard (the wire frame is ≤16 MiB but a pathological chain
  could be deep) — return `#CYCLE`/`#NUM` past a fixed depth.
- Teeth: unit tests for chained formulas (`A1==>B1==>C1` data), a diamond, a
  self-cycle, a mutual cycle, formula-references-formula producing Bool/Error
  (the cases the string snapshot got wrong).

## Slice 6c — FFI method `FormulaRecalc`

- `dispatch::Method::FormulaRecalc = 14` (NEXT_FREE_ID → 15); update the FFI
  `MDV_METHOD_FORMULA_RECALC` const + the pinning tests + regenerate the cbindgen
  header (`build-rust-core.sh`) — same ABI ripple as slice 4a.
- Wire: `RecalcRequest { cells: HashMap<String,String> }` →
  `RecalcResponse { values: HashMap<String, Value> }` (reuse the serde `Value`).
- `recalc_wire(req) -> Result<Vec<u8>, WireFault>` mirrors `evaluate_wire`.
- Swift `mdvCoreRecalc(cells) -> [String: CoreFormulaValue]` in `CoreClient` +
  the `formula_recalc` transport row.

## Slice 6d — Swift consumption (replaces the stateless per-cell path)

- `RustFormulaAdapter.recalc(cells) -> [CellReference: FormulaValue]` (map keys
  back via `CellReference(a1:)`), `#NAME`-fallback preserved per cell.
- `EditableCSVModel`: a batch recalc that builds the A1→raw snapshot ONCE
  (`colLetters(c)+row`, header = grid row 0 skipped), calls `recalc`, and serves
  `evaluateFormulaCell(at:)` from the cached result when `RustFormulaGate` is on;
  Swift `FormulaEngine` per-cell remains the fallback. This also fixes the O(grid)
  per-cell snapshot cost — one snapshot + one recalc per grid version.
- A/B parity: a multi-formula grid (incl. formula-references-formula + a cycle)
  through both engines, asserting cell-by-cell equality.

## Open questions (none blocking)

- Float formatting for any string round-trip is AVOIDED by resolving to `Value`
  directly (6a) — no `Number→string→Number` precision loss.
- Incremental recalc (dirty-mark + recompute only affected cells) is a later
  optimization; the full recalc-on-edit is correct and fast enough for typical CSVs.
