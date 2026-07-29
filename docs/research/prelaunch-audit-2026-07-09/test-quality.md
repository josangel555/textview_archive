# Pre-launch Product Review — Test Quality & False Greens

**Dimension:** Tests that cannot fail (tautologies, over-mocking), asserts on the wrong thing,
greens that never went red, flaky patterns (timing/shared state), disabled/skipped tests hiding failures.
**Date:** 2026-07-09 · **Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`
**Reviewer scope:** static analysis only (no suite run, no window-opening tests).

---

## Executive summary

The test estate is unusually large and, on the whole, **honest**: the Rust engine tests are
clean (no `#[ignore]`, no `assert!(true)`), the auto-generated `Audit_*` regression suites pin
real behavior with concrete expected values, and the non-smoke LSP tests fail loudly
(`XCTFail`) on the wrong error. The team has even built a *codified negative-control* mechanism
(`MDVNegativeControl.isBroken`) precisely to prove pixel tests can go red.

The false-green risk is concentrated in a few structural places, not scattered tautologies:

1. **Pixel-regression "green that never went red."** Only **2 of 8** T5 `PixelTestCase`
   suites have a codified negative-control teeth proof. The other 6 — including the
   `TerminalTabStrip` surface whose invisibility bug *recurred four times* and is the canonical
   motivating incident in `CLAUDE.md` — have never been demonstrated to fail. This is the single
   highest-value finding for this lens. (P1)
2. **Skip-instead-of-fail on the thing under test.** A handful of tests convert a failure of the
   actual SUT into an `XCTSkip` (malformed output shape → skip; WebView fails to load →
   "environment problem" skip), so a genuine regression vanishes silently rather than going red. (P2)
3. **Env-gated real-integration lanes that never run.** The real sourcekit/tsserver/jdtls LSP
   wire path is gated behind `MDV_RUN_LSP_SMOKE`, which is set **nowhere** in `scripts/` or CI.
   The fake-server substitute covers the protocol layer, but real-server compatibility ships
   unexercised. (P2)
4. **Permanently-disabled UAT cases** (`XCTSkipIf(true, …)`) that advertise coverage of critical
   journeys (typing into the CM6 editor via synthesized keys, scroll-restore, sidebar preview)
   while being off in every lane. (P2)
5. **Tight wall-clock assertions in the merge gate** (50 ms, 20 ms, sub-second bounds) that are
   flake-prone under machine load. (P2/P3)

No P0 (ship-blocker) issues were found *in this dimension*: nothing here is data-loss or a crash;
the risk is that real regressions could slip past green suites, not that the suites are actively
broken.

---

## Methodology

- **What I examined:** ~1,189 Swift test files across `Tests/{ViewerKitTests,ViewerCoreTests,ViewerUITests,RustCoreTests,TestSupport}` and the Rust `#[test]` corpus (72 files) under `rust-core/crates/`.
- **How:** `rg`/`sed`/`find` pattern sweeps for the canonical false-green shapes — `XCTSkip`/`XCTSkipIf(true)`, swallowed `catch {}`, `try?`, tautological asserts (`>= 0` on unsigned, `XCTAssertTrue(true)`), `XCTAssertNoThrow`-only tests, wall-clock timing asserts outside bench files, negative-control teeth switches, and singleton mutation across tests. Then targeted `Read` of the suspicious files to confirm intent vs. accident.
- **Depth:** I read the flagged files in full where a verdict depended on context (LSP smoke gating, the negative-control wiring, the visible_text skip, the pixel-suite teeth). I cross-checked one finding against the repo's own prior review (`docs/code-review/TESTS_2026-05-25.md`) which independently documents the LSP gap.
- **Cross-verification:** confirmed `MDV_RUN_LSP_SMOKE` appears in zero build/CI scripts; confirmed only `MDV_ENABLE_BROKEN_RULER` and `MDV_ENABLE_BROKEN_CANVAS_OVERLAY` exist against 8 pixel suites.
- **Not run:** no `swift test`, no VM lane, no window-opening tiers (per constraints).

---

## Findings

### F1 — 6 of 8 T5 pixel-regression suites have no negative-control teeth proof (green that never went red)
- **Severity:** P1
- **Files:**
  - Suites WITH a codified teeth proof: `Tests/ViewerUITests/SourceViewVisualRegressionTests.swift:85` (`MDV_ENABLE_BROKEN_RULER`), `Tests/ViewerUITests/CanvasOverlayVisualRegressionTests.swift:121` (`MDV_ENABLE_BROKEN_CANVAS_OVERLAY`).
  - Suites WITHOUT: `Tests/ViewerUITests/TerminalTabStripVisualRegressionTests.swift`, `ClaudeMonitorVisualRegressionTests.swift`, `ImageEditorVisualRegressionTests.swift`, `PreviewTabVisualRegressionTests.swift`, `FileTabStripVisualRegressionTests.swift`, `AudioEditorVisualRegressionTests.swift`.
  - Switches defined: only two, in `Sources/ViewerUI/TextDisplayView.swift` and `Sources/ViewerUI/CanvasWebViewHost.swift`.
- **Evidence:** `rg ': PixelTestCase' Tests` → 8 suites. `rg 'MDV_ENABLE_BROKEN' Tests` → only `SourceView` + `CanvasOverlay`. `CLAUDE.md` itself codifies the rule: *"A green that has never been shown to go red is not a guard… Demonstrate TEETH on every real-UI test."* The compositor-occlusion class (opaque `NSViewRepresentable` occluding a SwiftUI sibling) gives a **false green** on `ImageRenderer`/`cacheDisplay`/headless walks — the exact reason the terminal-tab-strip miss recurred 4×. The `TerminalTabStrip` pixel suite (F1's poster child) is one of the 6 unproven.
- **Impact:** For 6 surfaces, a regression that blanks/occludes the surface on screen may leave the pixel test green (baseline compare can pass on a stale/placeholder frame, or the assertion may never have been exercised against a broken build). These are the highest-consequence UI surfaces and the mechanism that has *already burned the team repeatedly*.
- **Suggested fix:** Add an `MDV_ENABLE_BROKEN_<SURFACE>` switch + a spawned-with-broken-env teeth test for each of the 6, mirroring the RULER/CANVAS_OVERLAY pattern. Prioritize `TerminalTabStrip` and `FileTabStrip` (tab strips are the documented recurring failure).
- **Fix size:** L · **Fix risk:** careful (touches `Sources/` guards + VM-lane tests; must confirm each break actually reddens on the VM).

### F2 — `visible_text` truncation test skips instead of failing when the SUT output shape is wrong
- **Severity:** P2
- **File:** `Tests/ViewerCoreTests/Automation/Audit_Sources_ViewerCore_Automation_MCPToolCatalog_swift_VisibleTextTruncationTests.swift:33`
- **Evidence:** the shared helper `runVisibleText` does `guard case .object(let o) = result, … else { throw XCTSkip("unexpected visible_text result shape: \(result)") }`. Every truncation test funnels through this helper. If a regression changes the `visible_text` MCP tool's result envelope (drops `truncated`/`totalBytes`, renames a key, returns an error), the guard fires `XCTSkip` — the entire truncation suite turns **green-by-skipping** rather than red.
- **Impact:** The MCP `visible_text` tool is agent-facing surface; a shape regression is exactly the kind of break these tests exist to catch, and it would be masked. The malformed-shape branch is *the SUT failing*, not an environmental precondition — it must be `XCTFail`.
- **Suggested fix:** Replace the `throw XCTSkip` in the result-shape guard with `XCTFail("visible_text returned unexpected shape: \(result)")` (and `return` a sentinel, or make the helper `throws` a hard error). Skips are for missing external toolchains, never for the SUT's own output.
- **Fix size:** S · **Fix risk:** safe.

### F3 — Real-toolchain LSP wire path is never exercised (env var set nowhere)
- **Severity:** P2
- **Files:** `Tests/ViewerCoreTests/LSPClientSmokeTests.swift:20`, `LSPPoolSmokeTests.swift:20`, `LSPMultiLanguageSmokeTests.swift:34` — all gate on `ProcessInfo…environment["MDV_RUN_LSP_SMOKE"] == "1"`.
- **Evidence:** `rg 'MDV_RUN_LSP_SMOKE' --glob '!Tests/**'` returns only archive/docs — **no `scripts/*.sh`, no `.github/` workflow sets it**. On failure these tests do `if requireSmoke() { XCTFail } ; throw XCTSkip(...)` — since `requireSmoke()` is always false in every automated lane, any real-server failure is downgraded to a skip. The repo's own review already flagged this: `docs/code-review/TESTS_2026-05-25.md:25` — *"the 1.4-KLoC LSPClient/LSPPool happy-path is effectively untested except behind `MDV_RUN_LSP_SMOKE=1`."*
- **Mitigation present:** `Tests/ViewerCoreTests/LSP/LSPClientFakeServerTests.swift` / `LSPPoolFakeServerTests.swift` DO run on host (the `MDVFakeLSPServer` exec is built by `swift test`) and fail loudly (`XCTFail` on wrong error). So the *protocol/decode* layer is covered; only **real sourcekit/tsserver/jdtls compatibility** is unexercised.
- **Impact:** A break in real-server framing/version compatibility (LSP `initialize` handshake, real `documentSymbol`/`hover` payloads) ships without any red test. Medium — the fake server catches most protocol regressions, but real-server drift (e.g. a new sourcekit-lsp response shape) is invisible.
- **Suggested fix:** Add a nightly/VM lane job that sets `MDV_RUN_LSP_SMOKE=1` where the toolchains are present, so the smoke tests actually assert. At minimum, document in the smoke-test headers that they contribute zero coverage in CI today.
- **Fix size:** M · **Fix risk:** safe (adds a lane; no product change).

### F4 — Permanently-disabled UAT cases (`XCTSkipIf(true, …)`) masking unverified critical journeys
- **Severity:** P2
- **Files/lines:**
  - `Tests/ViewerUITests/uat/KeySynthUATTests.swift:79` — `XCTSkipIf(true, "KEY_01: CGEvent keydowns don't insert into the CM6 WKWebView … T4 harness limitation")` → **typing into the editor via synthesized keys is unverified end-to-end.**
  - `Tests/ViewerUITests/uat/ScrollRestoreUATTests.swift:238` and `:333` — both `XCTSkipIf(true, "TSK-1047: CM6 jetsam under spawned-app viaOpen")`.
  - `Tests/ViewerUITests/uat/SidebarArrowPreviewUATTests.swift:46` — `XCTSkipIf(true, "… harness issue … TSK-1243")`.
- **Evidence:** `rg 'XCTSkipIf\(true' Tests` → exactly these 4 cases.
- **Impact:** These are named UAT journeys that read as coverage in the suite manifest but execute nothing. Two are partially mitigated (scroll-restore has an in-process substitute `EditorScrollRestoreWebViewTests`; the notes say so). KEY_01 is the concerning one: *inserting typed text into the CM6 editor* has no green agent-driven proof — it's a documented harness limitation, but the critical "can the user type" path rests on the substitute in-process tests only.
- **Suggested fix:** For each, add an explicit cross-reference assertion that the substitute test exists and covers the behavior (or delete the disabled case so the manifest doesn't overstate coverage). Track the harness limitations as open tickets (they are — TSK-1020/1047/1243), but don't let a `XCTSkipIf(true)` sit in a "UAT" file implying the journey is green.
- **Fix size:** S–M · **Fix risk:** safe.

### F5 — "environment problem, not the unit under test" skip pattern can mask real WebView-load regressions
- **Severity:** P2
- **Files/lines:** `Tests/ViewerUITests/HtmlExportImageContainmentTests.swift:87,128`; `Tests/ViewerUITests/RenderedHTMLAsyncFillTests.swift:69,182`; `Tests/ViewerUITests/CanvasTabMountWebViewTests.swift:64`; `Tests/ViewerUITests/uat/CanvasUATM3Tests.swift:68`.
- **Evidence:** each does `throw XCTSkip("open did not load — environment problem, not the unit under test")` (or "WebContent died") when the tab/WebView fails to load. Compare the *correct* handling one file over: `Tests/ViewerUITests/DocumentModelTests.swift:461` uses `return XCTFail("tab did not load")`.
- **Impact:** "WebView failed to load" is sometimes genuinely environmental (jetsam under the spawned-app lane — documented), but it is *also* exactly what a real regression that breaks document open / WebView mounting looks like. The blanket skip means a genuine "documents no longer render" regression could go green in these suites. The inconsistency (`XCTFail` in one file, `XCTSkip` in the neighbors) shows there's no settled policy.
- **Suggested fix:** Distinguish the two: gate the *known* jetsam-environment skip behind a specific detectable condition (e.g. WebContent-terminated callback), and treat a plain load-timeout as `XCTFail`. Don't let "didn't load" universally mean "skip."
- **Fix size:** M · **Fix risk:** careful (risk of re-introducing flake if the environment skip is removed wholesale — must keep the genuine jetsam guard).

### F6 — Tight wall-clock timing assertions in the host merge gate (flake-prone)
- **Severity:** P2
- **Files/lines (host-gate, not marked bench):**
  - `Tests/ViewerCoreTests/JSONFileStoreTests.swift:224` — `XCTAssertLessThan(elapsed, 0.05, …)` (50 ms bound to prove `enqueueWrite` is async — a single scheduler hiccup under CI load reddens it).
  - `Tests/ViewerCoreTests/Automation/CanvasUATM2Tests.swift:174-175` — `XCTAssertLessThan(pct(applyMs, 0.95), 20, …)` and read `< 20` ms p95.
  - `Tests/ViewerUITests/SplitPaneCloseActionTests.swift:198` — `< 0.5 s`.
  - `Tests/ViewerKitTests/{HighlightedTextTests.swift:144, Audit_…ReDoSTests.swift:96,105,113}`, `Tests/ViewerUITests/RegexCacheTests.swift:79` — `< 1.0 s` wall-clock.
- **Evidence:** `rg 'XCTAssertLessThan\(.*elapsed…' | rg -iv 'bench|perf'`. The generous watchdog-style bounds (5–10 s, the `LineDiff`/`LocalHistory` O(N)-vs-O(n·m) guards) are legitimate and *good* — those assert on the wrong-thing risk (algorithmic complexity) correctly. The tight sub-100 ms / 20 ms ones are the flake risk.
- **Impact:** Intermittent red on `main`'s merge gate under load → either noise-driven "re-run until green" (which trains the team to ignore reds — the worst false-green failure mode) or a real perf regression dismissed as flake. `CLAUDE.md` already carves out bench wall-clock asserts as "flaky under load"; these unmarked ones aren't covered by that carve-out.
- **Suggested fix:** Convert the 50 ms/20 ms bounds to a *behavioral* assertion where possible (e.g. for `enqueueWrite`, assert the write happened on a different thread / the call returned before the write completed, not a 50 ms wall-clock). Where a time bound is genuinely the contract, widen it and/or move it to the perf-bench lane that CI treats as advisory.
- **Fix size:** M · **Fix risk:** safe.

### F7 — Redundant tautological asserts weaken signal (self-aware, low harm)
- **Severity:** P3
- **Files/lines:** `Tests/ViewerCoreTests/ProcessMemoryTests.swift:56` — `XCTAssertGreaterThanOrEqual(count, 0)` where the comment itself notes the value is deterministically 0 in a unit-test process; `Tests/ViewerUITests/MarkdownLinkPolicyTests.swift:342` — `>= 0` on a count already pinned to an exact `expected` two lines above; assorted `>= 0` on `UInt`/frame dims (`VectorOverlayTests.swift:177-178`, `FloatingTooltipTests.swift:170,181`).
- **Evidence:** most are paired with a *real* assertion (`XCTAssertEqual(count, expected)`) and the `>= 0` is documented as a type-level truism. So they don't *hide* bugs — they just add non-signal. `ProcessMemoryTests:56` is the weakest: the honest test would be `XCTAssertEqual(count, 0)` (deterministic in-process), not `>= 0`.
- **Impact:** Minimal. Noise, not a false green — the surrounding assertions carry the weight.
- **Suggested fix:** Tighten `count >= 0` → `count == 0` where the value is deterministic; drop the pure type-truism `>= 0` lines.
- **Fix size:** S · **Fix risk:** safe.

### F8 — Source-introspection tests are brittle and skip on parse/locate failure
- **Severity:** P3
- **Files:** `Tests/ViewerCoreTests/Automation/ScriptVerbCatalogTests.swift:90` (`throw XCTSkip("ScriptVerbDispatch.swift not reachable from this run")`); ~98 test files read `Sources/` at runtime (`rg -l 'String(contentsOf|contentsOfFile' Tests` → 98).
- **Evidence:** `ScriptVerbCatalogTests` parses `ScriptVerbDispatch.swift` text at test time to check catalog↔dispatch parity; if the file can't be located (refactor, path change, build-layout change) it skips rather than fails, so a genuine catalog/dispatch drift vanishes exactly when the code is reorganized. This is a whole class (source-text-parsing tests: `PackageManifestPinPolicyTests`, `SurfaceCoverageMatrixTests`, `FileIconClassifierTests`, etc.) coupled to file layout.
- **Impact:** These tests are load-bearing for "every verb is cataloged" invariants but degrade to no-ops under refactors — a silent coverage cliff rather than a red.
- **Suggested fix:** For parity tests, make "source file not found" an `XCTFail` (the file is a build input the test *depends on* — its absence is a real defect, not an environment quirk). Longer term, prefer reflecting over the compiled catalog/dispatch tables rather than parsing source text.
- **Fix size:** M · **Fix risk:** careful (some source paths legitimately differ across build layouts; needs a robust locator before flipping skip→fail).

---

## Positive observations

- **Rust engine tests are clean.** No `#[ignore]`, no `assert!(true)`/`assert_eq!(1,1)` tautologies across `rust-core/crates/`. Only ~27 `is_ok()`/`is_some()`-only asserts (minor). The sans-IO engine tier — the correctness core — is the most trustworthy part of the estate.
- **The `Audit_*` regression suites are substantive.** e.g. `Audit_…IndentDetector…CRLFTests.swift` pins the exact CRLF-collapse bug against the live `RustIndentAdapter.detect` with concrete expected strings (`"Spaces (4)"`, `"—"`, lone-CR, mixed-ending cases); `Audit_…HighlightedText…ReDoSTests.swift` enumerates real catastrophic-regex shapes. These are model-real, not tautologies.
- **Non-smoke LSP tests fail loudly.** `LSPPoolTests`/`LSPClientFakeServerTests` catch blocks do `XCTFail("unexpected: …")` / `XCTFail("expected …, got …")` — correct polarity, and the `MDVFakeLSPServer` gives real host coverage of the protocol layer.
- **A codified negative-control mechanism exists.** `MDVNegativeControl.isBroken` + `MDV_ENABLE_BROKEN_*` (`MDVNegativeControlTests.swift`) is exactly the right answer to "green that never went red." F1 is that it's under-applied (2 of 8), not absent.
- **Complexity watchdogs assert the right thing.** The generous wall-clock guards on `LineDiffTests`/`LocalHistoryStoreTests` explicitly assert O(N)-not-O(n·m) — a good use of a loose time bound to pin algorithmic behavior.
- **The team self-audits.** `docs/code-review/TESTS_2026-05-25.md` independently documented the LSP gap (F3), and the heavy-tier self-skip architecture (T4/T5 skip in the headless gate) is deliberate and disclosed, not accidental hiding.

---

## Coverage gaps (what I did NOT examine)

- **No suite execution.** Verdicts are static; I did not run `swift test` or any VM/pixel lane, so I could not observe which env-gated tests *actually* skip on a given host vs. run, nor confirm any pixel baseline is stale.
- **Cross-test shared state.** `rg '.shared.' Tests/ViewerCoreTests` → ~111 singleton touches without an obvious per-test reset. The testing-strategy doc warns SwiftUI hosting state is process-global and not reset between tests. I did not trace these to confirm real bleed — potential flaky-shared-state findings remain un-audited (low-confidence lead, not a filed finding).
- **The 207 `sleep`/`Task.sleep`/`usleep` sites** were counted but not individually audited for race-based flakiness beyond the wall-clock-assert subset (F6).
- **Rust crate depth.** I confirmed no tautologies/ignores at the corpus level but did not read every crate's test bodies (canvas DSL, formula, nav) for assert-on-wrong-thing.
- **VM/nightly lane reality.** Whether the 8 pixel suites and the WebView suites actually pass (and against fresh baselines) on the VM is unverified — F1 is about *teeth*, not current pass/fail.
- **`try?` in tests (1,133 occurrences)** were not individually triaged; most are legitimate setup helpers, but a swallowed `try?` around a SUT call would be a false green I did not exhaustively rule out.
