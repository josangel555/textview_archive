# Test Pyramid — the canonical map (TSK-1255)

> **One doc, the whole ladder.** This is the single source of truth for "what
> tiers exist, what each proves, where it runs, and how it's enforced." The
> dated audits (`TEST_SUITE_AUDIT_*`, `TEST_COVERAGE_*`, `TEST_AUDIT_*`,
> `UI_TEST_GAPS_*`) are point-in-time snapshots; the `agent-uat-framework-*` dir
> is the T6 design. When they disagree with this file, this file wins — update it.

Snapshot (counts from `Tests/`, 2026-06-26): **64** `HeadlessUITestCase`
suites · **3** `LiveAppTestCase` (T4) · **7** `PixelTestCase` (T5) · **16**
WebView-lane suites · **22** `MultiScenarioTestCase` script-bus UAT suites ·
**~8,960** XCTest `test*` fns + **75** Swift-Testing `@Test` fns across 5 suites.

```
                         ▲ fewer, slower, more real
   ┌─────────────────────────────────────────────────────────────────────┐
   │ T6  agent-driven journey UAT      run-uat skill (NOT swift test)      │  owner/major-release
   ├─────────────────────────────────────────────────────────────────────┤
   │ T5  PixelTestCase   WindowServer pixels (screencapture)   VM only     │  7 suites
   │ AX  AXInteractionTestCase (out-of-process AXUIElement)    VM only     │  bootstrapped 2026-07-31
   │ T4  LiveAppTestCase spawns dist/TextView.app (--script)   VM only     │  3 suites
   │ WV  WebView lane    in-process live WKWebView (#192)       VM/nightly  │  16 suites
   ├─────────────────────────────────────────────────────────────────────┤
   │ T2' NSHostingView walk (DiagnosticDump, realized geometry) host       │ ┐
   │ T1m @MainActor model/coordinator (DocumentModel, verbs)   host        │ ├ HeadlessUITestCase (64)
   │ T1  pure value/logic (ViewerCore/ViewerKit, parsers, FFI) host        │ ┘  ← the floor, the merge gate
   └─────────────────────────────────────────────────────────────────────┘
   rust-core: a parallel ladder — `cargo test` units + ratatui TestBackend
   per-cell pixel-teeth (HOST pixel coverage, no VM) — gated by rust-core-gate.sh
                         ▼ more, faster, more isolated
```

## The tiers (tier == the base type — `Tests/ViewerUITests/Harness/TierBaseCases.swift`)

| Tier | Base class | Mechanism | Proves | Runs |
|---|---|---|---|---|
| **T1** | `HeadlessUITestCase` | plain XCTest / Swift-Testing | pure value/logic, parsers, FFI decode, security guards | host (merge gate) |
| **T1m** | `HeadlessUITestCase` | hermetic `DocumentModel` / `HeadlessHarness` verbs | model/coordinator state, the republish-storm + leak classes — THE leverage tier | host (merge gate) |
| **T2'** | `HeadlessUITestCase` | in-process `NSHostingView` + `layoutSubtreeIfNeeded` + `DiagnosticDump` | realized-tree **shape/geometry** (not pixels) | host (merge gate) |
| **WV** | `WebViewTestCase` | real in-process `WKWebView` + `evaluateJavaScript`/`cmDispatch` | CM6 editor / rendered-markdown / mermaid render behavior (the CDP-equivalent) | VM / nightly (`MDV_RUN_WEBVIEW_TESTS=1`) |
| **T4** | `LiveAppTestCase` | spawns `dist/TextView.app` via `--script`, reads its dump | real process boundary: AppDelegate↔coordinator launch wiring, cross-process persistence, real-`NSWindow` geometry | VM (GUI session) |
| **AX** | `AXInteractionTestCase` (TSK-1254, bootstrapped 2026-07-31) | **out-of-process** `AXUIElement` + `AXDriverCore` find-by-`mdv.*`-id + AXPress / CGEvent-at-frame; first suite `AXChromeInteractionTests` (spawn → find by id → AXPress → observe the tree change) | native-chrome real-event interaction (click/scroll/read by id) — the missing apex | VM (GUI session + AX TCC; targeted run: `test-in-vm.sh pixel --filter ViewerUITests.AXChromeInteractionTests`) |
| **T5** | `PixelTestCase` | `screencapture(1)` of the live window | stage-④ WindowServer compositing (occlusion/blank-sibling class) — no headless equivalent | VM (GUI session + Screen-Recording TCC) |
| **T6** | *(run-uat skill)* | agent-driven journey UAT (PARTIAL per change / FULL per release) | end-to-end on-screen behavior with the agent's own eyes | owner / major release |

## Gating (who runs what)

- **Merge gate (host, every PR)** — `scripts/test-headless-gate.sh` (= `MDV_HEADLESS_GATE=1 swift test --parallel`, what `.github/workflows/pr.yml` runs). Runs the **headless tiers only**; T4/T5/WebView **self-skip** (no `dist/`, no GUI session, no `MDV_RUN_WEBVIEW_TESTS`). `TierGateObserver` makes this non-regressable: if a heavy-tier body *runs* in the gate, the gate goes RED.
- **VM / nightly lane** — `scripts/test-in-vm.sh` (`.github/workflows/nightly-vm.yml`) builds `dist/` and runs T4 + T5 + the WebView lane for real (GUI login session + TCC). The AX tier runs here too (`AXInteractionTestCase` gates on `MDV_VM_GUI_SESSION=1` + `AXIsProcessTrusted`, so it rides the same lane; on the VM the ssh chain already holds the Accessibility grant).
- **rust-core gate** — `scripts/rust-core-gate.sh`: `cargo test` + the ratatui `TestBackend` per-cell pixel-teeth (host pixel coverage for the TUI render, no VM needed).

## The tier-justify rule (the guardrail)

> A test may sit at tier N+1 only if it asserts on an observable tier N cannot
> faithfully produce. A `LiveAppTestCase`/`PixelTestCase` subclass MUST carry a
> `// TIER-JUSTIFY: <the observable>` comment, or it's a lower-tier test in a
> heavy costume — demote it.

`TierGateObserver` enforces "headless stays headless" by class membership; the
`TIER-JUSTIFY` comment is the human-reviewable artifact for opting up.

Teeth are mandatory and hand-run (no automation by design): break the code under
test → confirm the new test goes RED → restore. War stories + the four footguns
(self-referential oracle, uncompiled mutant, `git checkout` wipes the fix,
mutate-during-build) live in `LESSONS.md`; the SOP is
`docs/TEETH_DEMONSTRATED_TESTS_SOP_2026-06-19.md`.

## Self-driving / UAT — two SEPARATE lanes (owner decision, 2026-06-26)

1. **Structural lane (TEST + agent-drivable)** — find by `mdv.*`
   `accessibilityIdentifier`, addressed via the **out-of-process** AX driver
   (`AXDriverCore` find/resolve + the VM `AXUIElement` adapter) for native
   chrome, and `evaluateJavaScript`/`cmDispatch` for WebView content. The
   addressable surface is curated in `AXIdentifierCatalog` (the AX sibling of
   `ScriptVerbCatalog`, the action-verb surface). This is deterministic and
   pixel-free.
2. **Human-like lane** — stays **PURELY screenshot-based** (computer-use:
   capture → vision picks coordinates → synthesize a click). A separate harness;
   no AX. (Owner: keep these distinct.)

## The gap this doc exists to close

The base is strong (T1/T1m/T2' + the WebView lane), but the **native
real-interaction apex is ~absent**: the broad UAT layer (22
`MultiScenarioTestCase` script-bus suites) drives `DocumentModel` at the
**model level**, not real user events — so real-event-only bugs
(Enter-leaks-to-filenav, click-makes-selection) slip through, and the lone AX
probe found the **in-process** AX tree is empty (SwiftUI materializes AX only for
external clients). The fix is the out-of-process AX tier (**TSK-1254**:
`AXDriverCore` + `AXIdentifierCatalog` landed host-side; the `AXUIElement`
adapter + driver executable + agent-driven entry are VM-tail subtasks
TSK-1260/1261/1263). Element-reference sharing (TSK-1256) builds on the same
addressing foundation.

## MANDATES (owner-ratified 2026-07-04) — the enforcement layer

The 2026-07-04 session diagnosis: ~30 content surfaces vs 24 real-UI test fns is the structural
cause of repeated regressions + agent overclaiming. Mandates existed but nothing REQUIRED
per-surface real-render coverage. These four rules close that, each with a MECHANICAL tooth:

1. **Per-surface real-render matrix (TSK-1539).** Every content surface in the catalog must map
   to ≥1 test in a real-render tier (WV/T4/T5/AX). Tooth: a host-side matrix guard test
   (EngineConsumptionGuardTests pattern) — unmapped surface = RED merge gate. A feature ticket
   is not `fixed` without its real-render guard or an explicit justified exemption IN the ticket.
2. **AX interaction everywhere (TSK-1543).** Every action (~167 verbs + ~131 palette commands)
   and every interactive UI element gets an INTERACTION test (real events + effect assert), not
   just appearance. Substrate: the native AXUIElement adapter (TSK-1260/1261/1263) — System
   Events proven insufficient 2026-07-04 (can't see SwiftUI AXIdentifiers, can't traverse
   SwiftUI+WKWebView trees). Accessibility TCC on the VM: GRANTED 2026-07-04. Tooth: the matrix
   guard extends to catalog-entry-without-interaction-test = RED.
3. **UAT is AGENT-DRIVEN.** Validation ladders must be agent-executable end-to-end (host →
   VM lanes → driven journey + machine-checked evidence → task_validate with checks). Human
   involvement is the exception (AX-blocked observable, broken lane, product call) — never a
   checklist. Rationale: human gates breed overclaiming (owner, 2026-07-04). SOP artifact:
   docs/STAGE_B_DELETION_UAT_2026-07-04.md is the reference shape.
4. **Tickets carry their test requirements.** The ticket contract names the REQUIRED evidence
   classes (e.g. "WV DOM assert + AX press + T5 pixel") at grooming time, derived from the
   surface catalog — workers implement to the named classes; the gate refuses `fixed` without
   them. (This is the enforcement hook for the worker-loop PM model.)

Evidence channels, in increasing realism — screenshot-eyeballing is the garnish, not the
foundation: model asserts (host) → live-DOM asserts (WV `cmDispatch`) → machine-computed pixel
asserts (T5) → PNG + agent vision (unknown-unknowns) → AX real-event interaction (pixel-free).
Open levers: WV-on-host offscreen audit (TSK-1540 — would move 103 fns into the merge gate);
Sequoia capture-nag mitigation (TSK-1542).

## Frameworks

- **XCTest** — everything tier-based (the `TierBaseCases` hierarchy + the live tiers) and all existing suites.
- **Swift Testing** (`import Testing`, `@Test`/`#expect`) — NEW pure-logic suites only; both frameworks run together under one `swift test`. See `docs/TEST_FRAMEWORK_SWIFT_TESTING_VS_XCTEST_2026-06-19.md`.

### rust-core property + fuzz lanes (owner-approved 2026-06-27 — USE them)
The rust-core has two strengthening lanes beyond example tests — reach for them when you add/touch a rust engine (also in CLAUDE.md "Rust-core dev tooling"):
- **proptest** (TSK-585) — property/round-trip/differential tests for pure-logic engines (wire codec round-trip, CSV parse invariants, session op-replay, find/diff invariants). New engines SHOULD add a suite, not just examples. Runs under `scripts/rust-core-gate.sh`.
- **cargo-fuzz** (TSK-584, nightly/ad-hoc) — libfuzzer targets for PARSERS (untrusted-byte decoders). New parsers SHOULD get a target + seed corpus.
- (memchr `memmem` for substring hot paths + the wasm32 portable-core build are the perf/portability siblings — see CLAUDE.md.)
