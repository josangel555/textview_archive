# Test-suite audit (TSK-788)

Status: spike/findings (auto-approved). Author: claude-mdv, 2026-06-21. Standard
depth: tier inventory + known weak spots + ranked gaps + a depth recommendation.
Written with fresh context from a long session that exercised the host gate, the
rust-core gate, the cross-language A/B parity harnesses, and the FFI boundary.

## 1. Tier inventory
- **Host headless tiers** (`HeadlessUITestCase` T1/T1m/T2', `ViewerCoreTests`,
  `ViewerKitTests`, `RustCoreTests`) — the merge gate (`scripts/test-headless-gate.sh`,
  `MDV_HEADLESS_GATE=1 swift test`); window-free, host-green. ~8,700 cases.
- **rust-core gate** (`scripts/rust-core-gate.sh`) — strict clippy (`-D`
  indexing/panic/cast-truncation/etc. + missing-docs) + all crate tests
  (core/ffi/web/tui/serve/highlight) + a cbindgen **ABI-header-drift** check.
- **Heavy tiers** (`LiveAppTestCase` T4, `PixelTestCase` T5, in-process WKWebView
  suites) — VM-only (`MDV_VM_GUI_SESSION=1`, `scripts/test-in-vm.sh`); self-skip
  off the GUI lane. Real WindowServer pixels / spawned app.
- **T6 agent-driven journey UAT** (`run-uat` skill) — the on-screen confirmation tier.
- **Web/TUI** — plain `cargo test` (host, no VM): web 96 cases, TUI cases — std-only
  Rust, fully host-testable (ratatui `TestBackend` gives per-cell pixel assertions).

## 2. Strengths (what's well-covered)
- **Pure-logic / engine layers are strong**: rust-core engines (csv/diff/hex/find/
  fuzzy/transcript/markdown/formula/…) have dense host tests under the strict gate;
  behavior + edge/error cases pinned.
- **Cross-language A/B parity is a genuine asset**: e.g.
  `Tests/ViewerCoreTests/FormulaParityTests.swift` runs the same inputs through the
  Swift engine and the Rust port and asserts equality — catches drift no per-engine
  test can. This pattern (and the rust-core "TestBackend pixel-teeth" for the TUI)
  should be the template for every ported engine.
- **Teeth discipline is documented + partly codified**: the negative-control switch
  (`MDVNegativeControl.isBroken`, `MDV_ENABLE_BROKEN_*`) lets a T5 guard be proven to
  go RED on a deliberate break (LESSONS/CLAUDE).

## 3. Weak spots (ranked by risk)
1. **"Engine tested ≠ feature shipped" (HIGH).** The flagship example found this
   session: the FormulaEngine (Swift + Rust port) has rich host tests + A/B parity,
   yet ZERO view consumers — `=A1+B1` shows literal text on screen
   (`CSVTableView` renders raw `Text(cell)`). Tests are green; the feature is
   invisible. There is no test tier that asserts "this engine is actually wired into
   a view." A prior CHANGELOG entry over-claimed it (corrected this session). GAP: a
   lightweight "consumption" assertion (grep/symbol check, or a model-level
   view-wiring test) per shipped engine.
2. **Render-path is VM-only, and the false-green traps are real (HIGH, known).**
   `ImageRenderer`/`cacheDisplay`/headless frame-walks give FALSE GREEN for
   compositor-occlusion + SwiftUI-CA-layer bugs (CLAUDE.md TSK-488). Only stage-④
   WindowServer pixels (T5) are authoritative — and those run only on the VM. So any
   SwiftUI render change is host-unverifiable; the merge gate cannot catch a
   render regression. This is structural, not fixable host-side; the mitigation is
   discipline (T5 + teeth on the VM) + keeping logic in host-testable model layers.
3. **SwiftUI body-eval-count tests are load-flaky (MEDIUM).**
   `ChromeBodyEvalCountTests.test_findTypeahead_doesNotReBodyChromeStrip` fails under
   full-suite parallel load but passes in isolation (observed repeatedly this
   session). Body-eval counting is timing/scheduler-sensitive. GAP: either serialize
   these (a non-parallel tier) or make them count-tolerant; today they cause
   intermittent false reds in the gate.
4. **#192 WebView self-skip + the live-WKWebView suites (MEDIUM, known).** The
   in-process WebView suites `#192`-gate themselves out of the bare sweep
   (`MDV_RUN_WEBVIEW_TESTS=1` to run); they live in the VM/nightly lane. Risk: easy to
   forget; nightly-only coverage for the rendered-MD/Mermaid/find-bar WebViews.
5. **Perf benches are wall-clock + load-flaky (LOW, known).** `FoldBench`/
   `CrossFileSearchBench`/MsgPack micro-benches assert wall-clock and flake under
   machine load — documented, but they intermittently red the gate.

## 4. Recommendation
- **Depth: STANDARD is sufficient now** — the engine/pure-logic layers are densely +
  well tested; the gaps are structural (render = VM-only) or specific (the
  consumption gap, the body-eval flake), not a broad coverage hole. A *deep/
  exhaustive* per-file coverage sweep is NOT warranted yet (low yield vs effort);
  prefer fixing the specific gaps below.
- **Highest-value test-infra work, ranked:**
  1. A per-engine **"consumption guard"** — a cheap host test (or a CI grep) asserting
     each gated engine has ≥1 non-test view consumer, so "ported but unwired" (gap #1)
     fails loudly. Directly prevents the formula-class over-claim.
  2. **De-flake the body-eval-count tier** (gap #3): a serial tier or count tolerance.
  3. Make the **A/B-parity pattern mandatory** for every remaining/future engine port
     (it's the cheapest high-signal cross-language guard).
- No new test dependency needed for the above. (cargo-fuzz is a separate Phase-3 ask,
  audit TSK-538.)

These are filed/trackable as test-infra follow-ups; none block the merge gate, which
is healthy (host-green, window-free).
