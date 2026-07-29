# Dimension: Test Types — markdown_viewer → greenfield rebuild

Sources: `summaries/code/t-*.md` (9 reports over ~450 test files, ~35K LOC of test
inventory), `summaries/docs/d-lessons-*.md` (LESSONS.md), `summaries/docs/d-progress-*.md`
(AUTONOMOUS_PROGRESS.md), `docs/TEST_PYRAMID.md` (via CLAUDE.md quotes), and the repo's
own `CLAUDE.md` testing-mandate sections (dated owner directives 2026-06-06 → 2026-07-10).

---

## Taxonomy — the distinct test kinds in this codebase

| # | Kind | Tier name | Frequency (of ~450 UI test files + rust-core) | What it actually proves | Evidence |
|---|---|---|---|---|---|
| 1 | **Pure-logic / model unit tests** | T1 (`HeadlessUITestCase` base, or plain XCTest in `ViewerCoreTests`) | Dominant — 81% of `ViewerUITests` root slices (`t-ui-root-6of6.md`); ~100% of `ViewerCoreTests` (`t-core-root-*.md`) | State-machine correctness, `@Published` mutation, parsing, geometry math. Zero rendering proof. | `t-ui-root-6of6.md` distribution table; `t-core-root-1of7.md` "XCTest dominates 98.7%" |
2 | **Headless-UI / in-process hosted-view tests** | T1m / T2′ (`HeadlessUITestCase` w/ `NSHostingView`) | 16–40% depending on slice | View-model wiring, layout math, verb dispatch against an in-process `DocumentModel` — no real window, no compositor. | `t-ui-root-3of6.md` (69 files, 96% headless-UI); `t-ui-harness.md` dual-path harness section |
3 | **In-process live WebView (WKWebView) tests** | "webview-inprocess", `WebViewTestCase`, gated by `#192`/`MDV_RUN_WEBVIEW_TESTS=1` | 5–13% of UI slices | Real WKWebView mounts, JS eval, DOM structure — but smoke-only in most files (1–2 cases); NOT pixel/scroll/interaction correctness. | `t-ui-root-6of6.md` §"WebView smoke ≠ WebView correctness"; `t-ui-harness.md` #5 (TCC disclaimer, WebContent teardown) |
4 | **T4 live-app (spawned `.app`) tests** | `LiveAppTestCase`, `MultiScenarioTestCase` | 19 UAT suites, ~8,700 LOC, largest single category by LOC in `t-ui-harness.md` | End-to-end feature flows via a real spawned `dist/TextView.app` + script-verb runner; catches AppDelegate↔coordinator wiring the in-process harness can't reach (window geometry, real launch path). | `t-ui-harness.md` full UAT enumeration; `LaunchSmokeTests` "only test that exercises full boot path" |
5 | **T5 WindowServer-pixel tests** | `PixelTestCase`, real `screencapture` | **Vanishingly rare: 1 file per ~69-file slice, 1.4% overall** | The ONLY tier that proves pixels actually composited on screen — compositor occlusion, z-order, actual visibility. | `t-ui-root-3of6.md`/`4of6`/`6of6` all independently converge on "1 T5 test in ~69 files"; `FileTabStripVisualRegressionTests`, `ImageEditorVisualRegressionTests`, `TerminalTabStripVisualRegressionTests` |
6 | **AX (accessibility-tree) structural tests** | out-of-process AX reader | Near-zero; explicitly named as the one off-limits agent tier | Element presence in the AX tree; interaction (press/type) requires real hardware-level events, not agent-synthesizable | CLAUDE.md testing-rules section; `t-ui-root-4of6.md` "AX tests: 0 files" |
7 | **Bench / perf-regression guards** | ratio-based, not wall-clock-absolute | Handful (`TabOpPerfTests`, `PerfMicroBundle2GuardTests`, rust-core `bench` module) | Measured-fact regressions (e.g., "hugeMs/tinyMs stays < 50×"), NOT absolute timing — tolerant of scheduler noise. | `t-rust-kit-support.md` §5 "Measured Perf Guard"; `d-progress-1of3.md` perf-floor ratchet |
8 | **proptest / fuzz / differential tests (rust-core)** | proptest, cargo-fuzz, A/B parity | 7 A/B contract files (CSV/find/hex/markdown/diff/indent), negative/fuzz on MessagePack decoder | Proves byte-identical behavior across a Swift→Rust port, and "never panics on malformed/arbitrary input" for parsers | `t-rust-kit-support.md` §"Engine-Port A/B Contract Tests", §"Negative/Fuzz Test Pattern" |
9 | **Negative-control "teeth" switches** | `MDVNegativeControl.isBroken("<NAME>")` | Rare, deliberately codified, not yet applied everywhere it should be | Proves a regression guard actually goes RED on a deliberate break — repeatable, committed, no hand-reverting | CLAUDE.md §"Demonstrate TEETH"; `t-ui-root-4of6.md` #5 |
10 | **UAT scenario suites (T6 agent-driven journey)** | "T6" per CLAUDE.md; built from Scenario+PageObjects at T4/T1m | 19 suites, ~11K LOC | Multi-step, cross-surface flows (open→edit→close→relaunch), the highest-confidence agent-executable acceptance layer | `t-ui-harness.md` full enumeration; CLAUDE.md §"T6 — agent-driven journey UAT" |

**Which tiers caught REAL bugs vs FALSE-GREENED:**

- **Caught real bugs:** T5 pixel (TSK-488 tab-strip occlusion — 4 separate recurrences before the guard existed, per `d-lessons-1of2.md`); FFI boundary negative tests (MsgPack OOM-abort, `SessionPanicDeadFlag` audit); the loopback A/B parity tests (`RemoteTransportLoopbackTests` — "if binary EXISTS but handshake fails → FAILURE, never silent skip"); the first real run of the WebView suite on the VM immediately found 3 genuine regressions headless missed (`d-progress-2of3.md` TSK-163).
- **False-greened (documented, repeated failure classes):**
  - `ImageRenderer` / `cacheDisplay` — rasterizes the SwiftUI tree in isolation and draws a **placeholder rectangle** for any `NSViewRepresentable`; structurally blind to compositor occlusion (TSK-488, recurred 4×). `d-lessons-1of2.md`, `t-ui-root-3of6.md`.
  - `layoutManager.numberOfGlyphs` — a TextKit-1 metric that stays ~0 for a populated TextKit-2 view; reported "blank" on a fully-rendered HEX grid (TSK-1032). `d-progress-1of3.md` §4.
  - VM `screencapture -x` full-screen capture does NOT framebuffer-composite app-window **content** (only system chrome) even though the window is AppKit-healthy — only window-ID-targeted capture (`-l<id>`) forces real compositing (TSK-1247). `d-lessons-1of2.md` (2026-06-29 entry).
  - `ViewModeMatrixSmokeTests` — 521 LOC, 3 cases, uses `ImageRenderer`, **excluded from the merge gate** — a "false-green factory" per its own summary report. `t-ui-root-6of6.md`.

---

## What worked — practices that earned their keep

1. **Tier as an explicit, machine-checkable TYPE, not a convention.** `HeadlessUITestCase`/`LiveAppTestCase`/`PixelTestCase` base-class hierarchy + `TierGateObserver` fails the *build* (via a sentinel file) if a heavy-tier test's body executes inside the merge gate. This is called out independently as "the keystone innovation" and "the single highest-ROI thing to transplant" in `t-ui-harness.md`. Not documentation — runtime-enforced.

2. **Dual-path harness with one shared dump schema.** `LaunchHarness` (spawns the app) and `HeadlessHarness` (in-process model) emit the *same* JSON dump shape to the *same* Page Objects — a test written once can run at T1m (microseconds, host-mergeable) or T4 (30s, VM-only) with zero assertion rewriting. `t-ui-harness.md` §2.

3. **Pure-function pixel-eval separated from screenshot capture.** `FileTabStripPixelEvalTests` unit-tests the separator-detection *algorithm* on synthetic bitmaps (host-safe); `FileTabStripVisualRegressionTests` (T5) re-uses the same static function against a live WindowServer capture. Splits "is my detector correct" from "did the screenshot even happen" — double-validation at low cost. `t-ui-root-3of6.md` #4.

4. **Compositor-occlusion T5 sniff test as a reusable pattern.** A vivid quadrant-color fixture + assertion of ≥3 distinct colors in a region; if an opaque `NSViewRepresentable` occludes a SwiftUI sibling, the region reads uniform and the test fails. Cited as "THE guard against the recurring sibling-blank pathology" across three independent batch reports (`t-ui-root-3of6.md`, `4of6`, `6of6`).

5. **ABI-version skew detector + capability-bit pinning at the FFI boundary.** Every bit position explicitly asserted on both sides; forward-compat contract tested (unknown bits tolerated). Called "foundational — if header/library ABI drift, nothing else works." `t-rust-kit-support.md` §1–2.

6. **Negative/fuzz testing on every wire-protocol change.** The MessagePack decoder has an explicit test per malformed-input class (short header, truncation-per-tag-type, OOM-guard, unsupported-tag, depth-cap) — audit-driven, named `Audit_Sources_<module>_<finding>`, tying tests directly to findings. `t-rust-kit-support.md` §3.

7. **Real fixtures over hand-stamped stubs.** SQLite test fixtures are shelled out to `/usr/bin/sqlite3` with real DDL rather than a 4096-byte zeroed header — eliminates a whole false-green class where the extension routes correctly but schema enumeration fails. `t-ui-harness.md` #6.

8. **Nonce-counter / nonce-bump assertions for idempotency.** Proves a state transition fired N times independent of the resulting value — catches "lost mutation" bugs a plain state check would miss. Called "gold standard," widely imitated (`FindCoordinatorTests`, `FloatingTooltipTests`, `HoverCursorBalanceTests`). `t-ui-root-3of6.md` #2.

9. **A/B parity / loopback tests for the Rust migration.** Every ported engine (CSV, find, hex, markdown, diff, indent) proven byte-identical against the retired Swift twin before deletion; the loopback server test proves local-vs-remote transparency for the eventual remote-core goal. `t-rust-kit-support.md` §"Engine-Port A/B".

10. **The "render slice vs pixel slice" split as a day-to-day discipline** — model + non-pixel render code ships and is host-tested immediately; the T5/pixel tail is a deferred, separately-tracked follow-on. This is credited with unblocking ~100+ items from a false "everything render-touching is VM-only" brake. `d-progress-1of3.md` §2, Pattern "Host Model + Render Tail".

---

## What hurt — costly failures and root-cause mechanism

1. **Inverted test pyramid, discovered late (week ~4+ of an 8-week project).** 81% pure-logic/headless-unit, ~16% headless-UI, ~9% webview-smoke, **1.4% T5 pixel** — the exact inverse of where the costliest bug class (compositor occlusion, invisible-but-state-perfect UI) actually lives. Mechanism: logic was proven first because it's cheap and fast to write; render validation was added *reactively*, after the bug shipped, not proactively. Independently confirmed by three separate batch reports converging on the same ratio. `t-ui-root-3of6.md`, `4of6`, `6of6` (which explicitly states "rebuild should be ~3:1 or tighter" vs the observed ~57:1 headless:real-render ratio).

2. **`ImageRenderer`/`cacheDisplay` used as if it were render validation — a structural false-green, not a flaky test.** Root cause: `ImageRenderer` rasterizes SwiftUI's *own* tree in isolation and paints a *placeholder* for any `NSViewRepresentable` (WKWebView, terminal surface, any AppKit-hosted view). There is no opaque layer to occlude in that isolated raster, so an actually-occluded view renders "fine." This recurred **4 separate times** on the tab-strip alone (TSK-488) before the fix (real WindowServer pixel capture via window-ID-targeted `screencapture`) was made mandatory. `d-lessons-1of2.md`, CLAUDE.md §"Compositor occlusion + the ImageRenderer false-green trap".

3. **"Engine tested/ported ≠ feature shipped."** A fully-tested engine (dense unit tests + A/B parity) can have zero view consumers and ship as a totally inert dead path — a passing test suite proves the model, never that a view reaches it. A grep-based "consumption guard" can't tell a real call-graph-reachable consumer from a dead reference that's textually identical. Root mechanism: multi-frontend architecture (Rust core / multiple UI surfaces) makes "ported but unwired" a structurally likely failure mode, not an edge case. `d-lessons-1of2.md` (2026-06-21 entry); `INDEX.md` most-cited anti-patterns.

4. **Coverage-mandate arrived reactively (TSK-1539, week ~7), not day 1.** The per-surface real-render matrix (`SurfaceCoverageMatrixTests` — every ViewMode lens/aux surface maps to ≥1 real-render evidence suite or an explicit exempt ticket) is exactly the guard that would have prevented the inverted pyramid — but it was built AFTER the 4th occlusion recurrence, not before the 1st. `t-ui-root-6of6.md` §2.

5. **VM lane infrastructure crises repeatedly blocked the *only* tier that catches render bugs.** Swift 6.1.2 (default toolchain) can't compile the test target at all (rejects `try await super.setUp()` in `@MainActor` classes) — this alone blocked ~50 downstream validations until fixed. TCC screen-recording denial to the xctest process required a private-SPI disclaim workaround. Orphan PIDs hung `test-in-vm.sh all` for days with the render lane silently red and nobody noticing. `d-progress-2of3.md` §5, `t-ui-harness.md` #5.

6. **A "stale `dist/` build" trap repeatedly produced fake regressions.** `test-in-vm.sh test` mode never rebuilds `dist/`, and the rsync sync excludes it — so a UAT/render run can silently test a build weeks stale, producing symptoms indistinguishable from a real critical regression (e.g. a fake "editor save does not persist" alarm). `d-lessons-1of2.md` (2026-06-15 entry), CLAUDE.md §"RENDER/UAT validation MUST use `all`".

7. **Wide, cheap state-machine test coverage was mistaken for adequate coverage on render-adjacent surfaces.** Find infrastructure has 970 LOC / 10 files of exhaustive state-machine tests but zero VM validation of visual emission (highlight position, bar visibility) — despite the find-bar being exactly the kind of surface the owner's earlier occlusion bug hit. Git panels: 900+ LOC of state-machine tests, zero pixel guard on diff-view rendering or row-highlight visibility. `t-ui-root-3of6.md` "Over-tested" section.

8. **AX interaction testing is structurally the hardest gap and was still unresolved at project end.** In-process accessibility (NSAccessibility) does not expose an element tree; AX must be driven from a separate out-of-process harness, and even a present-in-AX-tree element is not proof of on-screen visibility for overlay/sheet content — "the only reliable signal is pixels." A `.accessibilityIdentifier` alone is frequently invisible to the out-of-process AX reader unless the container is explicitly promoted with `.accessibilityElement(children: .contain)`. `d-lessons-1of2.md` (2026-06-25/26 and 2026-06-13 entries).

---

## Design implications for the rebuild

### Build day 1, not week 4+

- **The tier-as-type-hierarchy + `TierGateObserver` enforcement mechanism.** This is infrastructure, not a "nice to have added once you have enough tests" — it's cheap to build early (a few hundred LOC) and its entire value is preventing silent tier drift, which only bites once the suite is large enough that nobody reads every file.
- **The per-surface real-render coverage matrix** (`SurfaceCoverageMatrixTests` shape) — as soon as there is a second custom-rendered UI surface (i.e., almost immediately), require every ViewMode lens / panel / aux surface to map to ≥1 real-render evidence suite (WebView-inprocess, T4, or T5) OR carry an explicit exemption ticket. Make it a compile-time-forced dictionary + file-exists disk check so a renamed/deleted evidence file reds the gate, not silently rots.
- **The compositor-occlusion T5 sniff-test template** (quadrant-color fixture, ≥3-distinct-colors assertion) — apply it proactively to *every* `NSViewRepresentable`/WKWebView-beside-SwiftUI-sibling pairing the first time such a pairing is introduced, not after the 4th recurrence of a sibling-blank bug.
- **ABI-version skew detector + capability-bit pinning**, from the very first FFI boundary commit — this is the foundational gate for a Rust-core-over-FFI architecture; retrofitting it after drift has already happened is much more expensive.
- **The dual-path harness (spawn-app vs in-process, same dump schema, same Page Objects).** Building this early means every subsequent feature test can default to the cheap T1m path and only escalate to T4 when it genuinely needs a real window — instead of everything defaulting to expensive T4 because the cheap path didn't exist yet.
- **Negative-control switches (`isBroken("<NAME>")`) as a standing pattern from the first regression-guarded render test**, not bolted on later. Every render/compositor guard should be provably able to go red.

### Accept as inherent cost (don't fight it, budget for it)

- **VM lane fragility is structural, not a one-time fix.** Toolchain-version mismatches (host default vs test-target-required), TCC/screen-recording grants, stale-`dist/` traps, and orphan-PID hangs recurred across the *entire* 8-week project, each with its own specific fix. Budget explicit "VM infra health" maintenance time into the loop's cadence rather than treating each occurrence as a one-off surprise.
- **AX-driven interaction testing stays the one genuinely off-limits agent tier** (per this project's own directive) — structural AX-presence checks are agent-buildable, but real press/type events need either a human rung or hardware-level event synthesis this project never solved. Plan the UAT ladder with AX-interaction as an explicitly human/owner-gated exception from the start, not an aspiration the loop keeps almost-reaching.
- **Some ratio of state-machine-tests-that-outrun-render-tests is fine as a *temporary* state during a feature's build-out** (model lands first, pixel tail follows) — the inherent cost is the discipline to actually close the tail, not the existence of the gap itself. The failure mode to avoid isn't "model shipped before pixel," it's "model shipped, pixel tail silently never tracked."

---

## Portable rules — candidate directives for the next project (verbatim-adoptable)

1. **Tier is a type, enforced at runtime.** Define `HeadlessTestCase` / `LiveAppTestCase` / `PixelTestCase` base classes plus a gate observer that fails the build if a heavy-tier test executes its body inside the merge-gate env var — from the first UI test onward, not retrofitted.
2. **A view/panel/surface is not "covered" until it has at least one real-render evidence class (in-process WebView / spawned-app / WindowServer-pixel).** State-machine tests alone never satisfy this. Enforce via a machine-checked coverage matrix, not a checklist in a doc.
3. **`ImageRenderer`, `cacheDisplay`, and any headless view-tree walk are debugging tools for SwiftUI layout, NEVER render-validation tools.** They are structurally blind to opaque `NSViewRepresentable`/WebView compositing. The only authority for "did it actually reach the screen" is a real WindowServer pixel capture.
4. **Every regression-guarded test must demonstrate teeth before being trusted: pass with the fix, fail when the fix is reverted (via a negative-control switch), pass again when restored.** A test that has never been shown to go red is a false green, full stop.
5. **"Engine ported and unit-tested" is not "feature shipped."** Require an explicit non-test consumer (ideally call-graph-verified, not grep-verified) before closing a ticket that claims a feature landed.
6. **Every FFI/wire-protocol boundary gets an ABI-version skew detector, explicit capability-bit pinning with forward-compat tolerance, and a negative/fuzz suite covering every malformed-input class — built alongside the first version of that boundary, not after the first incident.**
7. **Render/pixel work is the agent's lane end-to-end (build + VM-validate), with a named exception list of exactly one tier (AX real-event interaction).** Don't let "VM-only" or "render is the owner's job" become an unexamined excuse to defer — audit whether the actual blocker is a genuine screen-capture/hardware-event limitation or just an assumption.
8. **Track VM/render-lane infrastructure health as its own recurring maintenance line item** (toolchain version, TCC grants, `dist/` freshness, orphan-process reaping) — it will break repeatedly across a multi-month project regardless of how well it's built once, and each break silently zeroes out coverage for the entire tier until noticed.
