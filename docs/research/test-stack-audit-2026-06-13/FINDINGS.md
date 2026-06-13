# Test-stack audit — Swift Testing vs XCTest + suite audit (2026-06-13)

Two SPIKES, one doc (they share the same evidence base):

- **TSK-787** — Test framework: adopt/migrate to Swift Testing, or stay on XCTest?
- **TSK-788** — Test-suite audit: scope + depth + ranked gap list.

Spike + design auto-approved (owner, 2026-06-13). Investigated **empirically**
(grep/read of the live tree at commit `25462cf`); no tests were run, no files
mutated. Where this overlaps the prior `docs/TEST_AUDIT_2026-06-07.md`, that doc
is cited and its drifted numbers are refreshed here.

---

## 0. TL;DR / recommendation

| Question | Verdict |
|---|---|
| **Adopt Swift Testing now?** | **No wholesale migration. Stay on XCTest as the substrate; allow Swift Testing for NEW pure-logic suites only, behind a one-suite pilot first.** |
| **Migrate the existing 5,022 methods?** | **No.** Net-negative: weeks of churn, no behavior coverage gained, and it would thread through tier-base-class machinery that is XCTest-class-hierarchy-bound. |
| **Keep XCTest for the UI/live tiers?** | **Yes, mandatory.** T4/T5 and the live-WKWebView suites depend on `XCTestObservation` (the `TierGateObserver` sentinel gate), `XCTSkip`-based self-skip, and class-hierarchy-as-tier. Swift Testing has no equivalent for the gate observer. |
| **Test-suite audit depth?** | A full read-only inventory **already exists** (`TEST_AUDIT_2026-06-07.md`) and is still largely accurate. Recommend **`deep` (not exhaustive)** for TSK-788, scoped to the **4 concrete gaps** below rather than re-inventorying 579 files. |

**The single highest-value test-stack improvement is NOT a framework swap — it is
adding code-coverage measurement (currently zero) and closing the 4 audit gaps.**
Frame the Swift Testing question as "may we use it for new code" (low-stakes yes,
after a pilot), not "should we migrate" (no).

---

## 1. Empirical inventory (refreshed 2026-06-13)

### 1.1 Framework: 100% XCTest, 0% Swift Testing

| Signal | Count |
|---|---|
| `import XCTest` (files) | **575** |
| `XCTestCase`-rooted (files) | **475** direct + tier-base subclasses |
| `import Testing` (files) | **0** |
| `@Test` / `@Suite` macros | **0** |
| Swift Testing anywhere in `Sources/` or `rust-core/` | **0** |

The suite is **entirely XCTest**. Swift Testing has never been introduced.

### 1.2 Volume (grown materially since the 2026-06-07 audit)

| Metric | 2026-06-07 audit | **2026-06-13 (now)** | delta |
|---|---:|---:|---:|
| `.swift` files under `Tests/` | ~430 | **579** | +149 |
| `func test…` methods | ~4,165 | **5,022** | +857 |

Per-target breakdown (today):

| Target | Files | `func test…` | `XCTestCase` classes | Nature |
|---|---:|---:|---:|---|
| `RustCoreTests` | 19 | 123 | 19 | Swift<->Rust FFI bridge (T1, mechanism 3) |
| `ViewerCoreTests` | 284 | 3,098 | 284 | pure-logic + model (T1/T1m) — the bulk |
| `ViewerKitTests` | 16 | 167 | 16 | pure value/type (T1) |
| `ViewerUITests` | 260 | 1,634 | 224 cls (+harness bases) | mixed: T1m model, T2' frame-walk, T4 spawn-app, T5 pixel, live-WebView |

Heavy-tier subclasses today: **21 files** `LiveAppTestCase`/`MultiScenarioTestCase` (T4),
**7 files** `PixelTestCase` (T5), **14 files** call `skipUnlessEnabled()` (live-WebView env gate).

> Rust side (unchanged from prior audit, ~297 `#[test]`): pure-logic core +
> FFI-boundary + TUI/web front-end, gated by `scripts/rust-core-gate.sh`. Not in
> scope for the Swift-framework question.

### 1.3 Toolchain reality

| Where | Swift | Note |
|---|---|---|
| Host (this machine) | **6.3.2** | `swift-tools-version: 6.0`, **no `swiftLanguageMode`/`swiftSettings` pin** -> default **language mode v5** (not strict-concurrency v6). |
| CI runner (`pr.yml`) | Xcode 16.x / Swift 6 | macos-15, explicitly `xcode-select` pinned. |
| VM default | 6.1.2 | rejects the test target's `@MainActor` `super.setUp()` (TSK-439). |
| VM test lane | 6.3 | `scripts/test-in-vm.sh` auto-selects via `TOOLCHAINS`. |

**Swift Testing availability:** ships in the toolchain from Swift 5.10/6.0+; both
the host (6.3.2) and the VM test toolchain (6.3) support it. The VM default 6.1.2
also supports it — but it already can't compile the test target (TSK-439), so
it's irrelevant. **No toolchain blocker to introducing Swift Testing for new
suites.**

---

## 2. TSK-787 — Swift Testing vs XCTest

### 2.1 What Swift Testing would buy us

- `#expect`/`#require` with operand capture (better failure messages than
  `XCTAssertEqual` without the boilerplate).
- Parameterized tests (`@Test(arguments:)`) — genuinely nice for the many
  table-driven pure-logic suites (`FileTypeDetectorTests`, golden tokenizers,
  CSV delimiter matrices). Today these are hand-unrolled loops or N near-identical
  methods.
- `struct`-based suites with per-test fresh instances -> less `setUp/tearDown`
  state-leak risk than shared `XCTestCase` instances.
- Built-in `async`/actor ergonomics and `.tags`/`.disabled(...)` traits.
- **Coexists with XCTest in the same test target** — add Swift Testing suites
  file-by-file without converting anything.

### 2.2 Why a wholesale migration is the wrong call here

1. **Tier-is-the-type is XCTest-class-hierarchy-bound.** The entire tier model
   (`Tests/ViewerUITests/Harness/TierBaseCases.swift`) encodes tier as a *base
   class*: `HeadlessUITestCase` / `LiveAppTestCase` / `PixelTestCase`, all
   `XCTestCase` subclasses. The headless merge gate's enforcement
   (`TierGateObserver`, `Tests/ViewerUITests/Harness/TierGateObserver.swift`) is
   an **`XCTestObservation`** that watches `testCaseDidFinish` and asserts heavy
   tiers *skipped*. **Swift Testing has no `XCTestObservation` equivalent and no
   class hierarchy** — its suites are structs/free functions with traits. Porting
   the heavy tiers would mean **re-implementing the gate observer from scratch**
   against a different (and less mature) introspection surface. This is the
   load-bearing reason the heavy tiers MUST stay XCTest.

2. **Self-skip is `XCTSkip`-based.** 59 files throw `XCTSkip` for the
   isAppBuilt / Screen-Recording / `MDV_RUN_WEBVIEW_TESTS` gates. Swift Testing
   uses `withKnownIssue` / `.disabled` traits / `#require` — a different model.
   Migrating means re-expressing every skip predicate.

3. **No coverage payoff.** A migration moves 5,022 methods to new syntax and
   asserts *the same behavior*. Zero new bug classes caught. Pure churn risk
   (every touched file is a chance to silently weaken an assertion), for
   readability gains only.

4. **`@MainActor` test classes everywhere.** `HeadlessUITestCase` is `@MainActor`;
   all `ViewerUITests` model tests inherit that. Swift Testing's actor-isolation
   model for suites differs; re-deriving isolation for ~1,600 UI-target methods is
   non-trivial and is exactly the class of skew that bit TSK-401/TSK-439.

5. **XCTest-specific machinery in active use** (each would need a translation):
   `XCTestExpectation`/`wait(for:)` (11 files), `measure(` perf blocks (3),
   `XCTContext` (3), `addTeardownBlock` (7), `XCTUnwrap` (43). Mechanical but
   non-zero, and `measure(` has no clean Swift Testing analogue.

### 2.3 Recommended boundary (the answer to "migrate, or keep XC for UI?")

```
  Swift Testing — ALLOWED (new code only, after pilot)
  +------------------------------------------------------------+
  | NEW pure-logic suites in ViewerCoreTests / ViewerKitTests /|
  | RustCoreTests: parsers, formatters, model value types,     |
  | FFI A/B parity, table-driven golden tests.                 |
  | These are plain XCTestCase today with no tier machinery —  |
  | the cleanest place for @Test(arguments:).                  |
  +------------------------------------------------------------+
  XCTest — STAYS (non-negotiable)
  +------------------------------------------------------------+
  | Everything tier-coupled: HeadlessUITestCase /              |
  | LiveAppTestCase / PixelTestCase + subclasses, the          |
  | TierGateObserver gate, the live-WKWebView suites, all      |
  | @MainActor model/UI tests. Existing 5,022 methods: as-is.  |
  +------------------------------------------------------------+
```

**Decision posture:** reframe TSK-787 from "do we migrate" (no) to "may new
pure-logic tests use Swift Testing" (**yes, low-stakes, after a one-suite
pilot**). The pilot de-risks the two things worth verifying empirically:

- Does `swift test --parallel` cleanly run a **mixed** XCTest + Swift Testing
  target on our toolchain, and does the **`TierGateObserver` still arm**? (It is
  registered from `HeadlessUITestCase.setUp`; a target running only-Swift-Testing
  files first could theoretically run before any XCTest class registers the
  observer — needs checking that the gate isn't silently disarmed.)
- Does the JUnit conversion (`scripts/junit-convert.py`, `test-in-vm.sh`) still
  parse the combined output, or does Swift Testing emit a format the converter
  doesn't handle?

### 2.4 Pilot slice (TSK-787 follow-up, if owner says "allow it")

1. Convert **one** self-contained, high-value table-driven pure-logic suite to
   Swift Testing as the canary — candidate: `FileTypeDetectorTests` (extension->
   category table is the textbook `@Test(arguments:)` case) or a golden tokenizer
   suite. Keep it in the same target.
2. Run `bash scripts/test-headless-gate.sh` and **confirm the sentinel gate still
   fires** (revert a heavy-tier skip guard once to prove the observer still has
   teeth with a Swift Testing file present — see section 4).
3. Run the VM lane (`scripts/test-in-vm.sh test`) + check JUnit output parses.
4. If clean -> document the boundary in `TESTING.md` ("new pure-logic suites MAY
   use Swift Testing; tier-coupled tests stay XCTest") and stop. Do **not**
   backfill-convert existing suites.

**Estimated effort:** pilot ~half a day; the policy doc ~trivial. Wholesale
migration (rejected) ~multi-week, high-risk.

---

## 3. TSK-788 — Test-suite audit (scope, depth, ranked gaps)

### 3.1 A thorough audit already exists

`docs/TEST_AUDIT_2026-06-07.md` is a complete, read-only, mechanism-x-tier
inventory of every test, with a per-file table and a flags section. Spot-checked
against the current tree: **its structural conclusions still hold** (only the raw
counts drifted, +857 methods — refreshed in section 1.2). **Re-running an
exhaustive file-by-file inventory would mostly reproduce it.**

**Recommended depth for TSK-788: `deep`, not `exhaustive`.** Don't re-inventory;
close the 4 concrete gaps below. The audit's own flags section is the seed list —
verified still-open as of today:

### 3.2 Ranked gap list (verified 2026-06-13)

| # | Gap | Severity | Status today | Fix shape |
|---|---|---|---|---|
| **G1** | **No code-coverage measurement anywhere.** Zero refs to `--enable-code-coverage` / `llvm-cov` / codecov in `scripts/` or `.github/`. 5,022 methods, **no idea what they cover.** | **High** | Confirmed absent | Add `swift test --enable-code-coverage` + `llvm-cov export` to a non-gating CI step (or the VM lane); emit per-target % and a top-N-uncovered-files report. Don't gate on it initially (coverage gates cause assertion-padding) — just *surface* it. |
| **G2** | **Live-WebView suites are mis-based on plain `XCTestCase`, not a heavy tier base.** They mint a real `WKWebView` (heavy, VM-only mechanism) but `TierGateObserver` only enforces `LiveAppTestCase`/`PixelTestCase` subclasses, so nothing *type-checks* they stay out of the headless gate — they rely entirely on the runtime `skipUnlessEnabled()` env gate (14 call sites). Drop that `setUp` skip and the merge gate silently runs live WebViews (the `#192` SIGABRT hazard) with no observer to catch it. | **High** | Confirmed (`ComponentVisualTests`, `ContentViewHostingTests`, `DiagnosticDumpTests`, `MermaidHostingTests`, `RenderedFindBarTests`, `PaneRetentionMountProbeTests`) | Introduce a `WebViewTestCase` base that `TierGateObserver.isHeavyTier` ALSO treats as heavy; re-base the 6 suites under it. Tier becomes type-checked instead of env-gate-only. |
| **G3** | **Doc drift: the PR/merge gate does NOT run the WebView lane**, but `CLAUDE.md` and `TierBaseCases.swift` (line 38) both claim "the same job runs the `MDV_RUN_WEBVIEW_TESTS=1` lane." Verified: `pr.yml` has no such step; the lane lives only in `nightly-vm.yml` (line 56). | **Medium** | Confirmed | Correct the docs (the lane is nightly-only), OR add it to `pr.yml` if it's *meant* to gate. Today the claim is false. |
| **G4** | **Teeth/mutation discipline is convention, not enforcement.** CLAUDE.md mandates "break fix -> red -> restore" for every real-UI test, but it's a **manual ritual**. Exactly **ONE** automated negative-control exists: `MDV_ENABLE_BROKEN_RULER` (the T5 `test_meta_brokenRulerIsDetectedAsRegression` in `SourceViewVisualRegressionTests.swift`). No mutation-testing tool (0 refs to muter/stryker/mutant). 225 files cite a regression/bug, but nothing *verifies* those assertions actually fail when behavior breaks. | **Medium** | Confirmed | (a) Cheap: codify the `MDV_ENABLE_BROKEN_*` env-flag negative-control pattern as the standard for new compositor/pixel guards (one flag per guarded bug class). (b) Optional/heavier: evaluate `muter` (Swift mutation testing) on the pure-logic targets only — but it's a new dep (owner approval) and slow; G1 (coverage) is the better first signal. |

### 3.3 Lower-priority / known-and-accepted (not gaps, noted for completeness)

- **Perf benches assert wall-clock** (`FoldBenchTests` 250ms ceiling,
  `CrossFileSearchBenchTests` 5s/3s, `HotPathPerfRegressionTests`,
  `LSPPositionConverterPerfTests`, `PerfSignpostTests`). Ceilings are
  deliberately generous (debug-build, older-CI headroom) and the code comments
  say so; a bench-only failure under load is a **known flake** (CLAUDE.md) — re-run
  before chasing. **Not a defect.** If churn becomes a problem, split benches into
  a non-gating lane (filter out of the merge gate, run nightly with numbers logged
  for trend tracking rather than asserted).
- **Zero XCUITest / AXUIElement.** Real-event interaction is T4-scripted-verb /
  VM-pixel only. Deliberate consequence of host limits (NSView.hitTest returns the
  hosting view for SwiftUI; cacheDisplay misses CA layers) — documented, not an
  oversight.
- **Self-skip-as-green.** T4/T5 + WebView suites read green-because-skipped on the
  host; real coverage depends on the nightly VM lane staying healthy. Acceptable
  by design; the residual risk is silent VM-lane rot (a coverage report from the
  VM lane — G1 — would also surface this).

### 3.4 Recommended TSK-788 execution (the audit, scoped)

Rather than a fresh exhaustive sweep, TSK-788 should spawn **4 child fix-tasks**
(G1-G4), ranked, each with its own teeth test:

1. **G1 coverage instrumentation** (highest leverage; informs everything else).
2. **G2 `WebViewTestCase` heavy base** (closes a real silent-regression hole).
3. **G3 doc-drift correction** (cheap; stop asserting a false fact).
4. **G4 negative-control pattern codification** (cheap; G4(b) muter eval is
   owner-dep-gated, defer).

`exhaustive` depth is **not** warranted — the 2026-06-07 inventory already paid
that cost and remains valid.

---

## 4. Teeth-test discipline — empirical finding (answers TSK-788 (d))

**Is "break fix -> red -> restore" enforced or convention?** -> **Convention,
with exactly one automated instance.**

- The only fault-injection hook in the codebase is `MDV_ENABLE_BROKEN_RULER`
  (+`MDV_ENABLE_DIAGNOSTICS`, unrelated). It flips the compositor bug back on so
  `test_meta_brokenRulerIsDetectedAsRegression` can prove the T5 check goes red.
  This is the **gold-standard pattern** — but it's hand-rolled for one bug class.
- The `TierGateObserver` itself is a genuine *enforcement* mechanism — but it
  enforces *tier placement* (heavy tests skip in the gate), not *assertion
  strength*. A weak assertion that never fails would sail through it.
- No mutation-testing tool is wired (`muter`/`stryker`/`mutant` = 0 hits).
- 225 test files cite a bug/regression, demonstrating the *culture* is real — but
  nothing mechanically confirms those 225 assertions still have teeth.

**Conclusion:** the discipline is real-as-ritual and well-documented, but
**unenforced beyond one meta-test**. G4 addresses this.

---

## 5. Answers to the two tickets, in one line each

- **TSK-787:** Stay on XCTest as the substrate (the tier model + gate observer are
  XCTest-bound and must stay). **Allow Swift Testing for NEW pure-logic suites
  only, after a one-suite pilot** that confirms the gate observer still arms and
  JUnit still parses in a mixed target. **Do not migrate the existing 5,022
  methods** — pure churn, zero coverage gain.
- **TSK-788:** A full inventory already exists (`TEST_AUDIT_2026-06-07.md`, still
  valid). Run the audit at **`deep`** depth scoped to **4 ranked gaps**: G1
  no-coverage-measurement (High), G2 live-WebView mis-based-on-XCTestCase (High),
  G3 PR-gate-WebView-lane doc drift (Medium), G4 teeth discipline
  unenforced-beyond-one-meta-test (Medium). Spawn G1-G4 as child fix-tasks;
  `exhaustive` is not warranted.

---

*Evidence: grep/read of the tree at `25462cf` on 2026-06-13. Cross-refs:
`docs/TEST_AUDIT_2026-06-07.md`, `Tests/ViewerUITests/Harness/TierBaseCases.swift`,
`Tests/ViewerUITests/Harness/TierGateObserver.swift`,
`scripts/test-headless-gate.sh`, `.github/workflows/pr.yml`,
`.github/workflows/nightly-vm.yml`.*
