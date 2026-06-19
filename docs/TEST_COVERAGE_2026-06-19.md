# Test coverage — current state + how to measure & enforce in the build (TSK-795)

**Question (owner wish):** what is our current test coverage, and how do we
measure it and enforce a floor in the build?

**Short answer:**

1. **Today we measure ZERO coverage.** Neither the Swift nor the Rust gate runs
   with instrumentation; there is no coverage artifact, no number, no floor. We
   have a *lot* of tests (≈7,500 XCTest funcs across 4 Swift test targets, 678
   Rust `#[test]`s) but "how much of the code do they touch" is unknown.
2. **The toolchain already ships everything needed** — no new dependency.
   `swift test --enable-code-coverage` + `xcrun llvm-cov export` for Swift;
   `cargo test` under `-C instrument-coverage` (or `cargo-llvm-cov`, owner-gated)
   for Rust.
3. **This ticket lands the Swift measurement + an enforceable gate** as a
   separate, opt-in step (`scripts/coverage-gate.sh` + the host-tested
   `scripts/coverage_gate.py`), defaulting to **report-only** so it can be wired
   in without ever turning a merge red on day one. Thresholds get ratcheted up
   from a measured baseline.

---

## 1. Current state (audit, 2026-06-19)

| Lane | Tests | Coverage measured? | Coverage enforced? |
|------|-------|--------------------|--------------------|
| Swift host gate (`test-headless-gate.sh`) | ≈7,500 XCTest funcs | **No** | **No** |
| Swift VM lane (`test-in-vm.sh`) | + T4/T5/WebView | **No** | **No** |
| Rust gate (`rust-core-gate.sh`) | 678 `#[test]` | **No** | **No** |

- `test-headless-gate.sh` runs `swift test --parallel` **without**
  `--enable-code-coverage`, so no `.profdata` is ever emitted.
- `.github/workflows/pr.yml` has no coverage step. `nightly-vm.yml` has none.
- `rust-core-gate.sh` runs `cargo test` but not under instrumentation; no
  `cargo-llvm-cov` / `cargo-tarpaulin` is installed.
- The only `coverage` strings in the tree are test *names* (snapshot coverage),
  not tooling.

**Codebase size for context:** ≈125k Swift LOC in the shipping targets
(ViewerCore 341 files, ViewerUI 153, plus ViewerKit/RustCore/MarkdownViewer).
ViewerCore is the bulk of the host-testable logic and the natural first
threshold target.

**Important caveat for any future number:** per the project's testing rules,
SwiftUI/AppKit-*rendered* behavior has **no host coverage** (the render path is
VM-only; host tests cover the model layer). So a host coverage % will read low
for ViewerUI by design — that is expected, not a regression. Gate the
host-coverable surface (ViewerCore, ViewerKit, RustCore bridge, model-layer
logic); do not set a high host floor on ViewerUI.

---

## 2. How to measure (Swift)

SwiftPM has first-class coverage via the LLVM source-based coverage pipeline.
No new dependency — `llvm-cov` / `llvm-profdata` ship inside Xcode:

```bash
# 1. Run the tests instrumented (heavy T4/T5 tiers still self-skip headlessly).
swift test --enable-code-coverage --parallel --scratch-path .build-cov

# 2. SwiftPM merges per-test .profraw into one .profdata; ask it where:
PROFDATA=$(swift test --enable-code-coverage --scratch-path .build-cov \
             --show-codecov-path)

# 3. Export line coverage as JSON, scoped to our shipping Sources/.
xcrun llvm-cov export \
  -instr-profile="$PROFDATA" \
  -ignore-filename-regex='(/\.build/|/Tests/|/checkouts/)' \
  -object .build-cov/*/debug/*.xctest/Contents/MacOS/* \
  > coverage.json
```

`scripts/coverage-gate.sh` does exactly this and pipes the JSON into the gate.

### Why JSON + a custom gate, not `llvm-cov report`?

`llvm-cov report`'s text is human-only. We need a **per-SwiftPM-target** rollup
(the `report` tool groups by file, not by our target boundaries) and a
machine-checkable threshold with a stable exit code. The attribution
(`Sources/<Target>/` → target) and percent math is the part that silently rots,
so it lives in `scripts/coverage_gate.py`, pinned by
`ViewerCoreTests.CoverageGateTests` on the host — the same pattern as
`junit-convert.py` / `JUnitConverterTests`.

---

## 3. How to measure (Rust)

Rust source-based coverage is the same LLVM pipeline:

```bash
RUSTFLAGS="-C instrument-coverage" \
  cargo test --manifest-path rust-core/Cargo.toml --workspace
# → *.profraw → llvm-profdata merge → llvm-cov export, as above.
```

The ergonomic wrapper is **`cargo-llvm-cov`** (`cargo llvm-cov --json`), which
automates the profraw→profdata→export dance and respects the workspace. It is a
**new dev dependency (cargo subcommand)** — *owner-gated*, so this ticket does
NOT add it. The Rust coverage step is filed as a follow-up (see §6). The manual
`RUSTFLAGS` route above needs no new dep and can be wired first if preferred.

---

## 4. How to enforce in the build (what this ticket ships)

```
scripts/coverage-gate.sh          # orchestrator: instrumented test run → llvm-cov → gate
  └── scripts/coverage_gate.py    # pure logic: parse JSON, attribute to target, threshold
        └── Tests/ViewerCoreTests/CoverageGateTests.swift   # host XCTest, pins the logic
```

### Design decisions

- **Separate, opt-in step — NOT folded into the merge gate by default.**
  `--enable-code-coverage` adds instrumentation overhead to every test run;
  forcing it on the hot merge gate taxes every PR. Coverage is a nightly /
  on-demand artifact (`coverage-gate.sh`), like the existing supply-chain and
  VM lanes. (It *can* be added as a fast PR step later if the owner wants a
  per-PR delta — the script is CI-ready.)
- **Report-only by default (all thresholds 0).** First wire establishes the
  *measurement* and the artifact and **always exits 0**. No merge goes red on
  day one from a number nobody has seen yet. This is the deliberate on-ramp.
- **Ratchet from a measured baseline.** Once `coverage-gate.sh` has reported a
  real number, set a floor a few points *below* it (`MIN_TOTAL`, `MIN_TARGET`,
  or per-target `TARGET_OVERRIDES`) so the gate catches *regressions* without a
  big-bang backfill. Raise the floor as coverage climbs. Never set a floor
  above current coverage in one step.
- **Per-target, scoped.** `INCLUDE_TARGETS="ViewerCore ViewerKit"` gates only
  the host-coverable shipping libs; ViewerUI's render-path-light host number is
  excluded from the per-target floor by design (see §1 caveat).
- **Distinct exit codes** (`0` pass / `2` threshold miss / `3` no data) so an
  instrumentation failure or empty run can never read as a false-green 0%.

### Recommended first thresholds (after a baseline run)

```bash
# Step 1 (this ticket): measure only.
bash scripts/coverage-gate.sh                       # report-only, exit 0

# Step 2 (next ticket, once baseline known — illustrative numbers):
MIN_TARGET=0 INCLUDE_TARGETS="ViewerCore ViewerKit RustCore" \
  TARGET_OVERRIDES="ViewerCore=<baseline-3> ViewerKit=<baseline-3>" \
  bash scripts/coverage-gate.sh
```

### CI wiring (recommended, follow-up)

A `coverage` job in `nightly-vm.yml` (or a new `nightly-coverage.yml`) that runs
`bash scripts/coverage-gate.sh`, uploads `coverage.json` +
`coverage.summary.json` as artifacts, and (once ratcheted) fails on a
regression. Report-only until the owner approves a floor.

---

## 5. What "enforce in the build" deliberately does NOT mean here

- **Not a hard merge gate on day one** — that would block PRs on an unmeasured
  number. Report-only first.
- **Not a coverage backfill** — this ticket adds the *mechanism*. Writing tests
  to hit a target is separate, ratcheted work.
- **Not branch/region coverage floors yet** — line coverage is the pragmatic
  first metric. `llvm-cov export` carries branch/region data too; the gate can
  extend to them once line floors are stable.

---

## 6. Follow-up tickets (file separately)

1. **Baseline run + set initial floors** — run `coverage-gate.sh`, record the
   number, set `MIN_TARGET`/`TARGET_OVERRIDES` a few points below it.
2. **Rust coverage** — wire `RUSTFLAGS="-C instrument-coverage"` (no dep) or
   request owner approval for `cargo-llvm-cov` (dev cargo subcommand), then add
   a Rust arm to the gate.
3. **CI artifact** — add the nightly coverage job + artifact upload.
4. **(Optional) per-PR coverage delta** — a fast PR comment showing the
   coverage change, if the owner wants per-PR signal.

---

## 7. Files in this slice

- `scripts/coverage_gate.py` — pure-logic JSON parser + per-target threshold
  evaluator (exit 0/2/3).
- `scripts/coverage-gate.sh` — orchestrator: instrumented `swift test` →
  `llvm-cov export` → gate. Report-only by default; env knobs for thresholds.
- `Tests/ViewerCoreTests/CoverageGateTests.swift` — host XCTest pinning the
  gate's attribution + threshold + exit-code contracts (mirrors
  `JUnitConverterTests`).
- `docs/TEST_COVERAGE_2026-06-19.md` — this doc.
