# Spike/Decision: Swift Testing vs XCTest (TSK-787) — 2026-06-19

**Question (owner):** Do we migrate the test suite to Swift Testing, or keep XCTest (perhaps "for UI only")?

**Recommendation: HYBRID, no big-bang migration.** Keep XCTest as the backbone for the tier system (T1–T5), all UI/live/pixel tiers, and the existing suite. Allow — and prefer — **Swift Testing for NEW pure-logic tests** in `ViewerCoreTests` / `RustCoreTests`, incrementally. Do **not** convert the ~7.5k existing funcs or rebuild the tier infra. Revisit a fuller migration only if Swift Testing grows a first-class test-observation/run-gating hook.

---

## The homework (this codebase's reality)

| Fact | Value | Source |
|---|---|---|
| Total test funcs | **~7,492** (ViewerCore 4968, ViewerUI 2156, ViewerKit 196, RustCore 172) | `grep -rh 'func test'` |
| Files coupled to XCTest tier/lifecycle infra | **275** | `XCTestObservation`/`TierGateObserver`/`setUp`/tier base classes |
| Swift Testing already in use | **none** (no `import Testing`/`@Test`) | grep |
| Tier system | T1 `HeadlessUITestCase` (host) · T4 `LiveAppTestCase` · T5 `PixelTestCase` (VM) | `Tests/ViewerUITests/Harness/TierBaseCases.swift` |
| Heavy-tier merge-gate enforcement | `TierGateObserver` (an **`XCTestObservation`**) writes a sentinel if a heavy-tier body runs in the host gate | `test-headless-gate.sh` |

## Framework comparison (for *this* codebase)

**Swift Testing wins (for new pure-logic tests):**
- `#expect`/`#require` capture sub-expression values → far better failure diagnostics than `XCTAssertEqual`.
- Parameterized `@Test(arguments:)` — collapses the many table-driven loops in parser/model/parity tests (we have lots: golden corpora, capture maps, fuzz tables).
- Traits (`.tags`, `.enabled(if:)`, `.timeLimit`, `.serialized`) — cleaner cross-cutting selection than naming conventions.
- Value-type suites (struct + `init`/`deinit`) — no shared mutable `setUp` state; async-first.

**XCTest wins (and is load-bearing here):**
- **The tier system is built on `XCTestObservation`** (`TierGateObserver`'s heavy-tier sentinel) + `setUp`/`tearDown` gating + the `MDV_VM_GUI_SESSION` self-skip. Swift Testing has **no direct `XCTestObservation` equivalent** — the merge-gate's "did a heavy tier run on the host?" enforcement would need a from-scratch re-implementation (custom trait + a different sentinel channel).
- 7.5k funcs + 275 infra files already work, are CI-wired, and gate `main`. Churn here is pure risk against the project's #1 rule (every change green).
- Swift Testing's **parallel-by-default** would surface ordering assumptions in the stateful UI/live tiers (they rely on serialized, window-owning execution) — exactly where we can least afford flakiness.

## Cost / risk

- **Full migration:** mechanically convert ~7,492 funcs **and** rebuild the tier infra (base classes → traits/suites; `TierGateObserver` → a bespoke Swift Testing run-observer; VM-lane gating; host-gate self-skip). The infra rebuild is the hard, risky part — it touches the VM-validation discipline that this project guards above almost everything. **High cost, high risk, marginal benefit.**
- **Hybrid:** ~zero cost. XCTest and Swift Testing coexist in the same target/run. New pure-logic tests opt into `import Testing`; everything else is untouched. Benefit accrues incrementally exactly where it's cheapest and safest (pure ViewerCore/RustCore logic).

## Decision options for the owner

1. **(Recommended) Hybrid** — XCTest stays the backbone (tiers/UI/VM/existing suite); new pure-logic `ViewerCore`/`RustCore` tests may use Swift Testing. Add a one-line `CLAUDE.md` convention. Zero migration.
2. **Keep XCTest only** — simplest mental model; forgoes `#expect`/parameterized ergonomics on new tests.
3. **Full migration** — not recommended; the tier-observation rebuild + 7.5k-func conversion is disproportionate to the gain.

**Why hybrid is "the right thing":** it captures Swift Testing's real ergonomic wins on new code at zero risk, while preserving the XCTest-coupled tier/VM discipline that is this project's quality backbone — no churn, no defect surface, future-proof (can deepen later if Swift Testing adds run-observation).
