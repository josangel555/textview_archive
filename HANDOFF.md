<!-- CLAUDE-HANDOFF v1 -->
# Handoff — Rust FormulaEngine port (TSK-1213)  (2026-06-21)

**Session:** claude-mdv (AUTONOMOUS, cron ~5min).  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `54b2da7a` (verify `git log -1`).

## Mission
Owner redirect (overrides the older "drain user-facing features" handoff): STOP building
new engine work in Swift; PORT the Swift `FormulaEngine` to rust-core, **hand-written,
ZERO new dependencies**. Sibling to the CSV/diff/hex rust ports.

## Current state — PORT FUNCTIONALLY COMPLETE + CONSUMED AT THE MODEL LAYER
All slices hand-written, zero-dep, gated OFF by default (`RustFormulaGate` / `MDV_RUST_FORMULA`),
each gated+committed. ~60 Swift↔Rust A/B parity cases all green.
- **Pure evaluator** (`rust-core/crates/core/src/formula.rs`): full current-Swift function
  parity — arithmetic, refs/ranges, comparisons, aggregates, conditional-aggregates, logical,
  IS*, lookup (MATCH/INDEX/VLOOKUP/HLOOKUP), text, math (incl. CEILING/FLOOR/ROUNDUP/DOWN/TRUNC/
  SIGN/EXP/LN/LOG10), dates (DATE/YEAR/MONTH/DAY/WEEKDAY/DATEDIF/EDATE/EOMONTH, hand-rolled
  Hinnant civil-date). PROPER is NOT ported — handled by `#NAME!`-fallback to Swift in the adapter.
- **FFI**: `Method::FormulaEvaluate` (id 13) + `Method::FormulaRecalc` (id 14) over `mdvcore_call`;
  `evaluate_wire`/`recalc_wire`; MessagePack float support added Swift-side (`MessagePack.swift`).
- **Swift consumption**: `RustFormulaAdapter` (`Sources/ViewerCore/`) — `mapValue`, `rustEvaluate`,
  gated `evaluate` (#NAME-fallback), `recalc`. `EditableCSVModel.recalcAllFormulas()`
  (`Sources/ViewerCore/FormulaEngine.swift`) — ONE-pass batch recalc, A/B parity-proven.
- **Recalc engine** (slice 6b): memoized recursive `recalc()` with `visiting` cycle set (→ #CYCLE);
  closes the recursion gap (a formula cell referencing another formula cell sees its COMPUTED value).

## Next action (remaining = render-path / owner-gated TAIL, NOT agent-closeable to `done`)
1. **VIEW WIRING**: make the CSV view call `model.recalcAllFormulas()` (batch) instead of per-cell
   `evaluateFormulaCell`. Render-path -> REVIEW CEILING + VM/owner on-screen confirmation. Leave at review.
2. **GATE FLIP**: `MDV_RUST_FORMULA` default OFF->ON after a soak (owner decision; see
   `RustCoreCapability.defaultEnabled` in `Sources/ViewerCore/RustCoreGates.swift`).
3. **SWIFT ENGINE DELETION**: migration-policy endgame (owner-gated, after gate-ON soak).
If the formula tail is exhausted/owner-gated, fall back to the board: validate `fixed` items, drain curated.

## Key facts / gotchas (also LESSONS.md)
- **The Swift `FormulaEngine` GREW** past the original corpus (CEILING/IFERROR/etc.); diff the live
  fn sets before claiming parity. Verify with the cross-language parity harness
  (`Tests/ViewerCoreTests/FormulaParityTests.swift`), not per-engine unit tests.
- **`String.capitalized` is ICU word-segmentation**, not whitespace — don't reproduce in Rust; PROPER
  stays Swift via the `#NAME!`-fallback (Rust fn-set is a subset of Swift's, so a genuine #NAME matches both).
- **Per-method ABI ripple** (adding a `dispatch::Method`): enum + `NEXT_FREE_ID` + `from_u16` + router +
  FFI `MDV_METHOD_*` const + 3 pinning tests in `ffi/src/tests.rs` + regenerate the cbindgen header via
  `scripts/build-rust-core.sh` (the headers `Sources/CMdvCore/mdvcore.h` + `ffi/include/mdvcore.h` are
  GITIGNORED generated artifacts; the rust-core gate's ABI-drift check fails until restaged).
- **After ANY rust-core change**, run `scripts/build-rust-core.sh` BEFORE the Swift parity tests so the
  linked `.a` (`rust-core/link/libmdvcore_ffi.a`) has the new behavior.
- **`ChromeBodyEvalCountTests.test_findTypeahead_doesNotReBodyChromeStrip`** is a pre-existing SwiftUI
  body-eval-count flake under full-suite parallel load — passes in isolation; unrelated to formulas.
- **Commit messages: NO backticks** (zsh command-substitutes them inside `-m "..."`).

## How to resume
1. `git -C <cwd> log -1`; both gates should be green: `bash scripts/rust-core-gate.sh` +
   `bash scripts/test-headless-gate.sh`.
2. Per-slice loop that's been working: read Swift impl (authoritative) -> implement in `formula.rs` ->
   Rust unit test (`cargo test -p mdvcore-core formula`) -> Swift parity cases -> `build-rust-core.sh` ->
   `swift test --filter FormulaParityTests` -> both gates (background) -> confirm verdict in a SEPARATE
   step -> commit per slice (trailer below). Record on TSK-1213 (`mcp__tasked__task_record`).
3. The remaining formula work is render/owner-gated; if so, drain the board instead. Don't run T4/T5/
   WebView/dist on the host.

Commit trailer:
