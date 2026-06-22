<!-- CLAUDE-HANDOFF v1 -->
# Handoff — Rust FormulaEngine port + on-screen wiring (TSK-1213/1215)  (2026-06-22)

**Session:** claude-mdv (AUTONOMOUS, ~5min cron).  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `12fdd237` (verify `git log -1`).

## Mission
Owner redirect: STOP new engine work in Swift; PORT the Swift `FormulaEngine` to rust-core,
hand-written, ZERO deps. Then (this session's later arc) surface it on screen + drain the board.

## Current state — DONE this run (all on main, gates green per item, gated OFF)
- **Rust FormulaEngine port (TSK-1213)** — full Swift parity (arith/refs/ranges/cmp/aggregates/
  conditional-agg/logical/IS*/lookup/text/math/dates) → FFI (`FormulaEvaluate`+`FormulaRecalc`) →
  `RustFormulaAdapter` (gate + #NAME-fallback) → `EditableCSVModel.recalcAllFormulas` (cycle-detecting
  recalc). ~60 A/B parity cases (`FormulaParityTests`).
- **Extensions beyond Swift (TSK-1216, validated):** wildcards `* ? ~`, COUNTIFS/SUMIFS/AVERAGEIFS,
  IFNA, TEXTJOIN, CHOOSE.
- **Formula ON-SCREEN wiring (TSK-1215, BUILT @ 9983e46d):** `CSVTableView` renders computed values,
  gated behind `RustFormulaGate` (OFF) + file order → **zero-risk** (gate-off/sorted/filtered = raw,
  byte-identical). Pure helper `formulaCellDisplay` host-tested. This was the missing view consumer.
- **Web rendered Markdown (TSK-256, validated):** `.md` renders to sanitized HTML BY DEFAULT in the
  std-only web front-end (Source/Hex toggles).
- **Integrity + infra:** corrected an over-claimed CHANGELOG formula entry; `EngineConsumptionGuardTests`
  (TSK-1217, partial); roadmap (TSK-775) + test-audit (TSK-788) + bundle spike (TSK-1214) docs.

## Next action — 4 OWNER decisions (all parked, full homework; see AUTONOMOUS_PROGRESS.md → DECISIONS NEEDED)
1. **TSK-1215** — flip `MDV_RUST_FORMULA` ON after a soak (lights up engine + on-screen display together)
   → VM/owner confirm the rendered values → delete the Swift twin. **The build is done; this is just the
   flip + a VM pass.** THE highest-value unlock.
2. **TSK-775** — migration horizon: engines-only (recommended) vs whole-core.
3. **TSK-1214 / TSK-1098** — bundle cap target (exec ~60MB at cap; CLAUDE.md 26MB stale vs script 60MB)
   → then grammar lazy-load (meaty) or accept+raise. Precise `__TEXT` breakdown needs bloaty/linker-map
   (nm -S gives zeros on the stripped binary).
4. **TSK-788** — test-audit depth (recommend STANDARD).

## Key gotchas / lessons (also LESSONS.md)
- **Engine tested ≠ feature shipped:** green tests prove the MODEL, never view consumption. Grep
  `Sources/` for a non-test consumer before claiming/CHANGELOG-ing. A grep guard can't do reachability
  (markdown core-mediated vs formula dead-ref look identical) — needs call-graph.
- **Gated-zero-risk render pattern:** to build render features host-side safely, gate the new behavior
  default-OFF (gate-off branch byte-identical), host-test the pure decision helper, leave gate-on at review.
- **Per-method FFI ABI ripple:** dispatch enum + NEXT_FREE_ID + from_u16 + router + `MDV_METHOD_*` const +
  3 pinning tests in `ffi/src/tests.rs` + regenerate cbindgen header via `build-rust-core.sh` (gate's
  ABI-drift check fails until restaged). After ANY rust-core change, run `build-rust-core.sh` before the
  Swift parity tests so the linked `.a` has the new behavior.
- **Commit messages: NO backticks** (zsh command-substitutes inside `-m "..."`).
- **ChromeBodyEvalCountTests.test_findTypeahead_doesNotReBodyChromeStrip** is a pre-existing flake (fails
  under full-suite parallel load, passes isolated; unrelated to anything I changed).

## How to resume
1. `git -C <cwd> log -1`; both gates green: `bash scripts/rust-core-gate.sh` + `bash scripts/test-headless-gate.sh`.
2. The clean agent-actionable code vein is EXHAUSTED this run; the leverage is the 4 owner decisions above.
   If continuing autonomously: re-check the board (`mcp__tasked__task_next`/`task_list`) for genuinely-new
   actionable items; do NOT manufacture marginal spikes. Don't run T4/T5/WebView/dist on the host.
3. Per-engine port loop (if more migration work): read Swift impl → implement in `formula.rs` → cargo test →
   Swift parity cases → `build-rust-core.sh` → both gates (background) → confirm verdict separately → commit.

Commit trailer:
