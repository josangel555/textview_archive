# Test audit — 2026-06-07

Read-only audit of **every** automated test in the repo, classified by
(A) the **observation mechanism** each test uses and (B) where it sits in the
project's **tier system**. Built by reading the tier base classes, the harness
sources, the gate scripts, and the test bodies (mechanism markers grepped +
spot-read). No tests were run; no source/test files were modified.

> Source of truth for tiering: `Tests/ViewerUITests/Harness/TierBaseCases.swift`
> + `Tests/ViewerUITests/Harness/TierGateObserver.swift`. **Tier is the type.**

---

## 0. How tier maps to base class (the type IS the tier)

| Base class | Tier | Host-safe? | Enforced by `TierGateObserver`? | What it observes |
|---|---|---|---|---|
| `XCTestCase` (plain) | T1 / T1m (by content) | yes | no (not a heavy subclass) | pure values / `@MainActor` model state / FFI / in-proc NSHostingView or WKWebView depending on body |
| `HeadlessUITestCase` | T1 / T1m / T2' | yes (the floor) | n/a (it's the safe base; registers the observer) | model scalars and/or in-process `NSHostingView` frame-walk |
| `HeadlessMultiScenarioTestCase : HeadlessUITestCase` | T1m | yes | n/a | runs `Scenario` scripts against in-process `HeadlessHarness` (model dump only) |
| `LiveAppTestCase` | **T4** | NO (VM/nightly) | **yes** — must skip in `MDV_HEADLESS_GATE=1` | spawns `dist/TextView.app`, reads JSON `DiagnosticDump` back off disk |
| `MultiScenarioTestCase : LiveAppTestCase` | **T4** | NO | **yes** | same as T4, via `LaunchHarness.runScript` + `Scenario` |
| `PixelTestCase` | **T5** | NO (VM/nightly) | **yes** | spawns app, `screencapture -l<id>` real WindowServer pixels |

Heavy tiers (`LiveAppTestCase`/`PixelTestCase` and subclasses) **self-skip** on a
host with no `dist/` bundle and no GUI session; `LaunchHarness.isAppBuilt`
additionally force-returns `false` whenever `MDV_HEADLESS_GATE=1`, so they skip
even on a dev box that *has* a built bundle. `TierGateObserver` writes a sentinel
file if any heavy-tier test runs its *body* under the gate, turning the merge
gate red.

---

## 1. Mechanism categories (Step 3)

1. **PURE-LOGIC** — plain assertions on structs/funcs/enums; no UI, no app.
2. **MODEL/@MainActor** — drives `DocumentModel` / store / `ObservableObject`,
   asserts on its state (no rendering).
3. **FFI / Rust-core bridge** — Swift↔Rust `extern "C"` round-trips.
4. **NSHostingView / NSView frame-walk** — builds a SwiftUI host / NSView, forces
   layout, asserts on realized-tree shape / geometry. Sees LAYOUT, not real paint.
5. **ImageRenderer raster** — SwiftUI `ImageRenderer` rasterizes SwiftUI's own
   drawing; draws a placeholder for `NSViewRepresentable`s; blind to compositor
   occlusion.
6. **screencapture real pixels (WindowServer)** — the only mechanism that sees
   the true composite.
7. **in-process live WKWebView** — `#192` / `MDV_RUN_WEBVIEW_TESTS`-gated suites.
8. **spawned-app dump (T4)** — spawn `dist/TextView.app`, read a JSON dump back.
9. **Accessibility / XCUITest** — AXUIElement / XCUIApplication. **NONE EXIST** in
   this repo (verified: the only `XCUIApplication` hit is a *comment* in
   `LaunchHarness.swift`).
10. **shell/script gate** — bash harness.
11. **Rust `#[test]`** — cargo unit/integration tests (added beyond Step 3's
    Swift-centric list, for completeness).

---

## 2. Aggregate counts

### Swift (XCTest)

- **~430 `.swift` files** under `Tests/` (incl. harness/page-object/non-test
  helpers). **~412 test-bearing files** (435 `XCTestCase`-rooted class decls,
  many being tiny `Fake*`/`Stub*` doubles).
- **~4,165 `func test…` methods total.**

Method totals by base class (tier):

| Base (tier) | files | test methods |
|---|---:|---:|
| `XCTestCase` (T1/T1m) | 360 | 3,877 |
| `HeadlessUITestCase` (T1/T1m/T2') | 28 | 148 |
| `HeadlessMultiScenarioTestCase` (T1m) | 8 | 23 |
| `MultiScenarioTestCase` (**T4**) | 17 | 104 |
| `LiveAppTestCase` (**T4**) | 2 | 6 |
| `PixelTestCase` (**T5**) | 2 | 6 |

> The plain-`XCTestCase` bucket is overwhelmingly **T1 pure-logic** and **T1m
> model**. Within it sit: the **RustCore FFI bridge** suite (12 files, 68
> methods) and the **6 in-process live-WKWebView** suites (mechanism 7) that are
> mis-based on plain `XCTestCase` (see §6 flags).

### Rust (cargo `#[test]`) — **297 tests**

| Crate / file | tests | nature |
|---|---:|---|
| `crates/core/src/*.rs` (in-module `#[cfg(test)]`) | 198 | pure-logic core (csv/diff/find/hex/nav/outline/cm_edit/wire/view/filter/indent/image/session/trace) |
| `crates/core/tests/*.rs` (integration) | 12 | diff split-parity (8) + session snapshot-frame (4) |
| `crates/ffi/src/tests.rs` | 17 | FFI-boundary tests on the real `extern "C"` symbols |
| `crates/ffi/tests/no_panic_lints_gate_*.rs` | 2 | meta-gate: asserts the no-panic lint policy |
| `crates/tui/src/main.rs` (`#[cfg(test)]`) | 31 | TUI front-end pure-logic |
| `crates/web/src/main.rs` (`#[cfg(test)]`) | 44 | web front-end pure-logic |

All Rust tests are pure-logic / FFI (mechanisms 1 & 3). Gated by
`scripts/rust-core-gate.sh` (`cargo clippy --all-targets` deny-lints + `cargo
test`) and the PR workflow.

### Front-ends

`mdvcore-tui` and `mdvcore-web` are the Rust `crates/tui` + `crates/web` above —
their tests are in-crate `#[cfg(test)]` modules (31 + 44). No separate JS/TS
front-end test target exists.

---

## 3. The pyramid (Swift tiers + Rust base)

```
                         ┌───────────────────────────────┐
   T5  PixelTestCase     │ 2 files / 6 methods            │  WindowServer pixels (VM only)
   (screencapture)       └───────────────────────────────┘
                      ┌──────────────────────────────────────┐
   T4  Live/Multi     │ 19 files / 110 methods                │  spawn dist/TextView.app + JSON dump (VM only)
   ScenarioTestCase   └──────────────────────────────────────┘
                  ┌──────────────────────────────────────────────┐
   T2'/T1m HeadlessUI│ 36 files / 171 methods                    │  in-proc NSHostingView frame-walk + model
   (+Headless multi) └──────────────────────────────────────────────┘
        ┌────────────────────────────────────────────────────────────────────┐
   T1/T1m plain      │ 360 files / 3,877 methods                               │  pure-logic + @MainActor model + FFI bridge
   XCTestCase        │   (incl. RustCore FFI: 12 files / 68;  live-WebView: 6) │
        └────────────────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────────────────────────┐
   Rust #[test]      │ ~20 modules / 297 tests  (core 210 + ffi 19 + tui 31 + web 44)│  pure-logic + FFI boundary
   (cargo)           └──────────────────────────────────────────────────────────────┘
```

Shape is a **healthy, very broad-based pyramid**: ~98% of Swift methods are
host-safe headless tiers; only **116 methods (T4+T5)** are VM-coupled heavy
tiers, and just **6** are real-pixel (T5).

---

## 4. Mechanism distribution

Counts are by **file** (a file's dominant mechanism; some files mix model +
frame-walk — noted). Methods are best-effort.

| # | Mechanism | Swift files | ~methods | Where |
|---|---|---:|---:|---|
| 1 | PURE-LOGIC | ~300 | ~3,300 | bulk of `ViewerCoreTests`, `ViewerKitTests`, much of `ViewerUITests` model-free logic |
| 2 | MODEL / @MainActor | ~70 | ~700 | `DocumentModelTests`, `TabsStateTests`, `SidebarModelTests`, `Sessions/*`, `*RepublishInvariantTests`, all `HeadlessUITestCase` model suites, `Headless*ScenarioTestCase` |
| 3 | FFI / Rust-core bridge | 12 (Swift) + ffi crate | 68 (Swift) + 19 (Rust) | `Tests/RustCoreTests/*` (Swift side); `crates/ffi/src/tests.rs` (Rust side) |
| 4 | NSHostingView / NSView frame-walk | ~14 | ~70 | `ChromeLayoutGateTests`, `ChromeZoomScalingTests`, `TabBarIntrinsicSizeTests`, `ToolPanelBoundingTests`, `CommentCardStructureTests`, `DiffViewReviewTests`, `DiagnosticDumpTests`, `ComponentVisualTests`, `ContentViewHostingTests`, `MermaidHostingTests`, `RenderedFindBarTests`, `FindBarTests`, `FormatToggleTests`, `PaneRetentionMountProbeTests`, `TerminalNSViewResizeTests` |
| 5 | ImageRenderer raster | 2 | 7 | `ChromeLayoutGateTests` (rasterNonBlank), `TerminalTabStripRenderTests` (class `TerminalTabStripRasterTests`) |
| 6 | screencapture real pixels | 2 | 6 | `SourceViewVisualRegressionTests` (T5), `TerminalTabStripVisualRegressionTests` (T5) |
| 7 | in-process live WKWebView | 9 | ~40 | `ComponentVisualTests`, `ContentViewHostingTests`, `DiagnosticDumpTests`, `MermaidHostingTests`, `RenderedFindBarTests`, `FindBarTests`, `FormatToggleTests`, `ComponentModelStateTests`, `PaneRetentionMountProbeTests` (all `skipUnlessEnabled()`-gated) |
| 8 | spawned-app dump (T4) | 19 | 110 | all `MultiScenarioTestCase` + `LiveAppTestCase` (`uat/*`, `Editor/EditorMultiScenarioTests`, `EditorPhase4ScenarioTests`, `ViewModeMatrixSmokeTests`, `InteractionDeepResizeTests`, `LaunchSmokeTests`, `LongFlowRelaunchTests`, `WalkthroughAndCodeReviewUATTests`) |
| 9 | Accessibility / XCUITest | **0** | **0** | **none exist** |
| 10 | shell / script gate | 8 | n/a | see §7 |
| 11 | Rust `#[test]` | ~20 modules | 297 | `rust-core/crates/*` |

> Note: mechanisms 4+7 overlap heavily — the 6 live-WebView NSHostingView
> suites both walk the realized tree (4) AND mint a live WKWebView (7) because
> `ContentView`/`MarkdownRenderedView` instantiate the WebView internally. They
> are counted in both rows.

---

## 5. Per-file table

Legend — Tier: T1 (pure), T1m (model), T2' (in-proc frame-walk), T4 (spawn-app),
T5 (pixels), Rust, shell. Mechanism numbers per §1. FG = false-green risk.

### 5.1 `Tests/RustCoreTests/` — Swift↔Rust FFI bridge (all T1/FFI, plain `XCTestCase`)

| File | Class | Tier | Mech | ~# | Notes |
|---|---|---|---|---:|---|
| ABTests.swift | ABTests | T1 | 3 (FFI A/B) | 4 | Rust-vs-Swift parity |
| BridgeTests.swift | BridgeTests | T1 | 3 | 10 | real `mdvcore_*` symbols; panic-catch round-trip |
| CMEditApplyABTests.swift | CMEditApplyABTests | T1 | 3 | 2 | |
| DiffHunkMarksABTests.swift | DiffHunkMarksABTests | T1 | 3 | 2 | |
| DiffParseABTests.swift | DiffParseABTests | T1 | 3 | 2 | |
| GateAndAdapterTests.swift | GateAndAdapterTests | T1 | 3 | 6 | rust-core gate/adapter seam |
| HexRenderABTests.swift | HexRenderABTests | T1 | 3 | 2 | |
| HexSearchABTests.swift | HexSearchABTests | T1 | 3 | 2 | |
| IndentDetectABTests.swift | IndentDetectABTests | T1 | 3 | 2 | |
| MessagePackEncoderTests.swift | MessagePackEncoderTests | T1 | 1 | 10 | MsgPack encode (pure) |
| MsgPackDecoderNegative_…_Tests.swift | MsgPackDecoderNegativeAuditTests | T1 | 1 | 23 | negative/fuzz decode |
| SessionPanicDeadFlag_…_Tests.swift | SessionPanicDeadFlagAuditTests | T1 | 3 | 3 | post-panic dead-flag |

### 5.2 `Tests/ViewerCoreTests/` — pure-logic + model (all plain `XCTestCase`)

All 221 files are **T1 pure-logic** or **T1m model** (mechanism 1, with a model
subset using mechanism 2). None instantiate `NSHostingView`/`WKWebView` (the
WKWebView mentions are comments). Highlights / non-obvious:

| File | Class | Tier | Mech | ~# | Notes |
|---|---|---|---|---:|---|
| ANSIParserTests | ANSIParserTests | T1 | 1 | 38 | terminal ANSI parse |
| Automation/MCP*Tests (6 files) | MCP* + Stub/Fake hosts | T1m | 1/2 | ~57 | MCP server/protocol; stubs implement `AutomationHost` |
| CMBridgeV1/V2, CMOutboundEncoding, CMEditApplier, CM* (8) | CM* | T1 | 1 | ~150 | CodeMirror bridge encode/decode — pure, **no WKWebView** (CMV2IntegrationTests explicitly "without spinning up a WKWebView") |
| CrossFileSearchBenchTests | CrossFileSearchBenchTests | T1 | 1 | 3 | **perf bench — wall-clock asserts (flaky under load)** |
| DiagnosticSnapshotTests | DiagnosticSnapshotTests | T1 | 1 | 10 | DiagnosticDump *struct* shape (no view) |
| FoldBenchTests | FoldBenchTests | T1 | 1 | 2 | **perf bench (flaky under load)** |
| HotPathPerfRegressionTests | HotPathPerfRegressionTests | T1 | 1 | 6 | **perf bench** |
| LSP/* + LSP*Tests (~35) | LSP* + FakeLSPServer* | T1/T1m | 1 | ~370 | protocol decode/framing pure; FakeLSPServer suites spawn a *fake* helper process (not the app) |
| PerfSignpostTests, LSPPositionConverterPerfTests, Audit_…CSVParser_PerfTests | … | T1 | 1 | 11 | **perf benches** |
| Plugins/* (7) | Plugin* | T1m | 1 | ~59 | PluginSubprocessHost spawns *plugin* subprocesses (not the app) |
| Review/*, ReviewSidecarTests (9) | Review* | T1/T1m | 1/2 | ~93 | code-review model + exporter |
| Sessions/* (12) | Session* | T1m | 2 | ~105 | session store/coordinator/snapshot model |
| Security/* (3) | URLSchemePolicy / RegexComplexityGuard / SymlinkEscape | T1 | 1 | 45 | ReDoS guard, symlink escape |
| Terminal*Tests (8) | Terminal* | T1 | 1 | ~120 | screen/cell/selection model |
| TreeSitter*Tests (3) | TreeSitter* | T1 | 1 | 28 | golden + smoke + paint-over (in-proc engine, no view) |
| Walkthrough/* (6) | Walkthrough* | T1/T1m | 1/2 | ~84 | engine/loader/schema |
| _(remaining ~120 files)_ | _various_ | T1/T1m | 1/2 | _bulk_ | parsers, stores, formatters, layout value types, diff, CSV, hex model, git client (shells out to real `git`) |

### 5.3 `Tests/ViewerKitTests/` — pure value/type (all T1, plain `XCTestCase`)

| File | Class | Tier | Mech | ~# | Notes |
|---|---|---|---|---:|---|
| Audit_…_HighlightedText_ReDoSTests | …ReDoSTests | T1 | 1 | 7 | regex DoS guard |
| Audit_…_ViewMode_SVGFormatterTests | …SVGFormatterTests | T1 | 1 | 2 | |
| FileCategoryMediaTests | FileCategoryMediaTests | T1 | 1 | 7 | |
| FileTypeDetector*Tests (2) | FileTypeDetector* | T1 | 1 | 12 | |
| HelpInfoTests / HelpInfoValueSemanticsTests | HelpInfo* | T1 | 1 | 14 | |
| HighlightedTextTests | HighlightedTextTests | T1 | 1 | 21 | |
| ImageZoomStateTests | ImageZoomStateTests | T1 | 1 | 20 | |
| InfoPlistTests | InfoPlistTests | T1 | 1 | 12 | reads built Info.plist values |
| OpenAsViewerApplicabilityTests | … | T1 | 1 | 10 | |
| ViewMode*Tests (5) | ViewMode* | T1 | 1 | 62 | viewmode enums; caret/editor/rendered/media — WKWebView is a comment, not instantiated |

### 5.4 `Tests/ViewerUITests/` — mixed tiers

**Heavy tier — T4 (spawn `dist/TextView.app`, mechanism 8). Self-skip on host.**

| File | Class | Tier | Mech | ~# | Notes / TIER-JUSTIFY |
|---|---|---|---|---:|---|
| Editor/EditorMultiScenarioTests | EditorMultiScenarioTests | T4 | 8 | 3 | `MultiScenarioTestCase` |
| Editor/EditorPhase4ScenarioTests | EditorPhase4ScenarioTests | T4 | 8 | 4 | |
| InteractionDeepResizeTests | InteractionDeepResizeTests | T4 | 8 | 1 | real-window resize (needs window) |
| LaunchSmokeTests | LaunchSmokeTests | T4 | 8 | 1 | AppDelegate launch wiring |
| LongFlowRelaunchTests | LongFlowRelaunchTests | T4 | 8 | 1 | cross-process persistence across relaunch |
| ViewModeMatrixSmokeTests | ViewModeMatrixSmokeTests | T4 | 8 | 3 | per-(type×mode) routing |
| uat/Cm6EditorUATTests | Cm6EditorUATTests | T4 | 8 (+WebView modes) | 10 | |
| uat/GitPanelUATTests | GitPanelUATTests | T4 | 8 | 5 | |
| uat/LSPUATTests | LSPUATTests | T4 | 8 | 4 | |
| uat/PluginsAndMcpAutomationUATTests | … | T4 | 8 | 9 | |
| uat/PreviewsUATTests | PreviewsUATTests | T4 | 8 | 9 | |
| uat/SearchSurfacesUATTests | … | T4 | 8 | 5 | |
| uat/SessionsUATTests | SessionsUATTests | T4 | 8 | 7 | |
| uat/SettingsMenusAndShortcutsUATTests | … | T4 | 8 | 9 | |
| uat/SidebarFileTreeAndBookmarksUATTests | … | T4 | 8 | 10 | |
| uat/TabsAndWindowChromeUATTests | … | T4 | 8 | 10 | |
| uat/ViewModesUATTests | ViewModesUATTests | T4 | 8 | 13 | |
| uat/WalkthroughAndCodeReviewUATTests | … | T4 | 8 | 6 | `LiveAppTestCase` directly (cacheDisplay/DiagnosticDump) |

**Heavy tier — T5 (screencapture WindowServer pixels, mechanism 6). VM only.**

| File | Class | Tier | Mech | ~# | Notes |
|---|---|---|---|---:|---|
| SourceViewVisualRegressionTests | SourceViewVisualRegressionTests | T5 | 6 | 2 | the canonical compositor sibling-blank guard; has a meta-test proving the check has teeth |
| TerminalTabStripVisualRegressionTests | TerminalTabStripVisualRegressionTests | T5 | 6 | 4 | terminal chip composite; explicitly contrasts vs `ImageRenderer`/`cacheDisplay` false-green |

**Headless frame-walk / model — T2'/T1m (`HeadlessUITestCase`).**

| File | Class | Tier | Mech | ~# | FG flag |
|---|---|---|---|---:|---|
| ChromeLayoutGateTests | ChromeLayoutGateTests | T2' | 4 + **5** | 3 | **FG:** `ImageRenderer` raster "non-blank" — explicitly documents the compositor caveat (LESSONS.md): an offscreen raster can be non-blank while the live window is blank |
| ChromeZoomScalingTests | ChromeZoomScalingTests | T2' | 4 | 6 | frame-walk geometry |
| TabBarIntrinsicSizeTests | TabBarIntrinsicSizeTests | T2' | 4 | 5 | intrinsic size |
| ToolPanelBoundingTests | ToolPanelBoundingTests | T2' | 4 | 3 | |
| CommentCardStructureTests | CommentCardStructureTests | T2' | 4 | 8 | |
| DiffViewReviewTests | DiffViewReviewTests | T2' | 4 | 4 | |
| TerminalNSViewResizeTests | TerminalNSViewResizeTests | T2' | 4 | 1 | NSView resize (no SwiftUI) |
| MermaidRenderModelTests | MermaidRenderModelTests | T1m | 2 | 3 | model only (WebView counterpart is `MermaidHostingTests`) |
| RenderedFindBarModelTests | RenderedFindBarModelTests | T1m | 2 | 3 | |
| ComponentModelStateTests | ComponentModelStateTests | T1m | 2 (+WebView gate) | 5 | `skipUnlessEnabled()` present |
| ModeSwitchRaceTests / …LiveTimingTests | ModeSwitchRace* | T1m | 2 | 7 | |
| ReloadVerbTests, ReviewExportTests, ReviewSessionTests, SplitAndMoveTabVerbTests, GitFileHistoryVerbTests, GitPanelAndLineBookmarkVerbTests, HexDirtySaveClose…, DockLayoutStoreTests, Audit_…AutomationHost…, Audit_…PTYProcess…Lifecycle | _various_ | T1m | 2 | ~50 | model-state verb outcomes |
| HeadlessHarnessTests | HeadlessHarnessTests | T1m | 2 | 11 | tests the harness itself |
| InteractionProfileHarness | InteractionProfileHarness | T2' | 4 | 3 | profiling helper (NSHostingView) |
| TerminalTabStripRenderTests | **TerminalTabStripRasterTests** | T2' | **5** | 4 | **FG:** `ImageRenderer` saturated-pixel checks — sees SwiftUI paint in isolation, blind to occlusion (class name ≠ file name) |

**Headless scenario runner — T1m (`HeadlessMultiScenarioTestCase`).**

| File | Class | Tier | Mech | ~# |
|---|---|---|---|---:|
| GoToPathUITests | GoToPathUITests | T1m | 2 | 3 |
| InteractionDeepTests | InteractionDeepTests | T1m | 2 | 4 |
| InteractionScriptTests | InteractionScriptTests | T1m | 2 | 3 |
| LongFlowTests | LongFlowTests | T1m | 2 | 2 |
| ScenarioTests | ScenarioTests | T1m | 2 | 3 |
| Sessions/OpenInNewSessionUITests | OpenInNewSessionUITests | T1m | 2 | 2 |
| Sessions/SessionsKeyboardUITests | SessionsKeyboardUITests | T1m | 2 | 3 |
| Sessions/SessionTabBarUITests | SessionTabBarUITests | T1m | 2 | 3 |

**In-process live-WKWebView — mechanism 7 (`MDV_RUN_WEBVIEW_TESTS` / `#192`). Plain `XCTestCase` base.**

| File | Class | Tier | Mech | ~# | FG flag |
|---|---|---|---|---:|---|
| ComponentVisualTests | ComponentVisualTests | T2' | 4 + 7 | 10 | **mis-based on `XCTestCase`** (heavy mechanism, not a heavy tier base — observer can't enforce; relies on env gate). Self-skips silently if `MDV_RUN_WEBVIEW_TESTS≠1`. |
| ContentViewHostingTests | ContentViewHostingTests | T2' | 4 + 7 | 6 | same |
| DiagnosticDumpTests | DiagnosticDumpTests | T2' | 4 + 7 | 8 | same; also uses `cacheDisplay` |
| MermaidHostingTests | MermaidHostingTests | T2' | 4 + 7 | 1 | same; only file with literal `WKWebView(` |
| RenderedFindBarTests | RenderedFindBarTests | T2' | 4 + 7 | 2 | same |
| FindBarTests | FindBarTests | T2'(`HeadlessUITestCase`) | 4 + 7 | 9 | gated; on the headless base so observer-adjacent |
| FormatToggleTests | FormatToggleTests | T2'(`HeadlessUITestCase`) | 4 + 7 | 9 | gated |
| PaneRetentionMountProbeTests | PaneRetentionMountProbeTests | T2' | 4 + 7 | 2 | gated; plain `XCTestCase` |
| ComponentModelStateTests | ComponentModelStateTests | T1m(`HeadlessUITestCase`) | 2 + gate | 5 | gated but mostly model |

**Plain `XCTestCase` — T1/T1m pure-logic + model (the bulk of `ViewerUITests`).**

~120 files, ~1,900 methods. All mechanism 1 (pure) or 2 (model). Representative:
`DocumentModelTests` (59), `TabCoordinatorTests` (29), `SidebarModelTests` (32),
`EditorCoordinatorTests` (28), `MarkdownLinkPolicyTests` (27),
`TerminalPaneStoreTests` (27), `CodeMirrorBridgeExtendedTests` (21),
`CodeMirrorBundleTests` (25 — **grep-based JS bundle assertions, NOT a WebView
test** despite mentioning WKWebView in comments), all `*RepublishInvariantTests`
(observed-object republish-storm guards, mechanism 2), `Sessions/*` model suites,
`Walkthrough/*` bridge/anchor suites, `LSPMarkdownRendererTests`,
`HTMLRenderedPolicyTests`, `MarkdownJSEscapeTests`, etc.

---

## 6. Flags (Step 4)

### 6.1 False-green-prone (mechanism asserts/implies visibility it can't prove)

1. **`ChromeLayoutGateTests` — `ImageRenderer` "rasterNonBlank" (mechanism 5).**
   An offscreen `ImageRenderer` raster can be non-blank while the live window is
   blank (the compositor sibling-blank pathology). The file *documents* this
   caveat itself ("COMPOSITOR CAVEAT (LESSONS.md, load-bearing)"), so it's an
   *informed* approximation, not a naive false green — but a reader trusting
   "non-blank ⇒ visible" would be misled. The real guard is the T5
   `SourceViewVisualRegressionTests`.
2. **`TerminalTabStripRenderTests` (class `TerminalTabStripRasterTests`) —
   `ImageRenderer` saturated-pixel checks (mechanism 5).** Sees SwiftUI's own
   paint in isolation; blind to compositor occlusion / z-order / a ScrollView
   rendering its content empty. The matching real-pixel guard is the T5
   `TerminalTabStripVisualRegressionTests`. The pair is correctly designed (raster
   for chip-color regressions, T5 for composite) — the flag is only that the
   raster suite alone cannot prove on-screen visibility.
3. **All T2' frame-walk suites (mechanism 4)** assert on the *realized NSView
   tree / geometry*, which is LAYOUT, not paint. A view can be in-tree with a
   correct frame yet invisible (zero alpha, occluded, color-blended). Per
   `CLAUDE.md` rule #4 this is structurally insufficient for "visible on screen";
   these correctly DON'T claim visibility, but any future assertion phrased as
   "X is visible" in these suites would be a false green.

### 6.2 Mis-tiered / mis-based tests

4. **6 in-process live-WKWebView suites are based on plain `XCTestCase`, not a
   heavy tier base** (`ComponentVisualTests`, `ContentViewHostingTests`,
   `DiagnosticDumpTests`, `MermaidHostingTests`, `RenderedFindBarTests`,
   `PaneRetentionMountProbeTests`). They mint a real `WKWebView` + `WebContent`
   helper process — a heavy, VM/nightly mechanism — but `TierGateObserver` only
   enforces `LiveAppTestCase`/`PixelTestCase` subclasses. So nothing *type-checks*
   that these stay out of the headless gate; they rely entirely on the runtime
   `WebViewTestTeardown.skipUnlessEnabled()` env gate. If a future edit drops that
   `setUp` skip, the suite would silently run live WebViews inside the merge gate
   (the very `#192` SIGABRT hazard) with no observer to catch it. Consider a
   dedicated `WebViewTestCase` base that the observer also treats as heavy.
5. **Class name ≠ file name:** `TerminalTabStripRenderTests.swift` declares
   `TerminalTabStripRasterTests`. Harmless but a `--filter` foot-gun.

### 6.3 Self-skipping suites that can read green when not actually run

6. **The 9 `MDV_RUN_WEBVIEW_TESTS`-gated live-WebView suites** (§5.4 mechanism-7
   table) `XCTSkip` themselves in the bare sweep and in the merge gate (the PR
   workflow does **not** set `MDV_RUN_WEBVIEW_TESTS=1`). They run ONLY in the
   nightly VM lane (`.github/workflows/nightly-vm.yml` "WebView lane"). A
   developer running the host gate sees them green-because-skipped. Acceptable by
   design, but their actual coverage depends on the nightly lane staying healthy.
7. **All T4/T5 heavy suites self-skip on the host** (`isAppBuilt == false` under
   `MDV_HEADLESS_GATE`, no Screen-Recording for T5). Same caveat: green on the
   host means "skipped", not "passed". The `TierGateObserver` makes *running* them
   in the gate a failure, but it cannot make *not-skipping-when-it-should* visible
   — coverage is only real in the VM/nightly lane.

### 6.4 Test targets that exist but the MERGE gate does not exercise

8. **Live-WebView lane is NOT in the PR/merge gate.** `CLAUDE.md` and
   `TierBaseCases.swift` both state the PR job "also runs the
   `MDV_RUN_WEBVIEW_TESTS=1` lane" — but `pr.yml` has **no** such step (verified:
   no `MDV_RUN_WEBVIEW` reference in `pr.yml`). The WebView lane lives only in
   `nightly-vm.yml`. **Documentation drift** — the merge gate is headless-only;
   live-WebView + T4 + T5 are nightly-only. Worth correcting the docs (or adding
   the lane to PR if it's meant to gate).
9. **T4/T5 heavy tiers** are by design nightly-only (not a defect) — flagged here
   only for completeness: 19 T4 files (110 methods) + 2 T5 files (6 methods) never
   run their bodies in the merge gate.

### 6.5 Other notes

10. **Perf benches assert wall-clock** (`FoldBenchTests`,
    `CrossFileSearchBenchTests`, `HotPathPerfRegressionTests`,
    `PerfSignpostTests`, `LSPPositionConverterPerfTests`,
    `Audit_…CSVParser_PerfTests`). Per `CLAUDE.md`, a bench-only gate failure
    under machine load is a known flake — re-run before chasing.
11. **No XCUITest / AXUIElement anywhere** (mechanism 9 = 0). Real user-event
    interaction is exercised only via the T4 `--script` verb dispatcher
    (synthetic verbs, not OS events) and the T5 screencapture suites. Per
    `CLAUDE.md`'s host-limits note, true SwiftUI click/pixel validation is VM-only
    (`NSView.hitTest` returns the hosting view; `cacheDisplay` misses CA layers),
    so the absence of XCUITest is a deliberate consequence, not an oversight — but
    it means the "at least one test INTERACTS with the element" mandate is met for
    SwiftUI only via T4 scripted verbs / the VM `vm-uitest` lane, not via real
    synthesized AppKit events on the host.

---

## 7. Shell / script "tests" (mechanism 10) — harness & gates, not unit tests

| Script | Role | Tier / lane |
|---|---|---|
| `scripts/test-headless-gate.sh` | **THE merge gate.** `MDV_HEADLESS_GATE=1 swift test --parallel` + tier-violation sentinel check | host headless (T1/T1m/T2') |
| `scripts/rust-core-gate.sh` | Rust merge gate: `cargo clippy --all-targets` (deny no-panic lints) + `cargo test` | host, Rust |
| `scripts/test-in-vm.sh` | Full suite on the UTM VM (auto-selects Swift 6.3 toolchain); `all` = build + suite + JUnit | VM (T4/T5 run for real) |
| `scripts/vm-smoke.sh` | Build + launch + screencapture on the VM, copy PNG back (macOS 15 redacts asuser windows — known limitation) | VM |
| `scripts/vm-uitest.sh` + `scripts/vm-uitest/aqua-runner.sh` | Programmatic VM UI validation via a GUI-session LaunchAgent → real pixels → dense-saturated-block eval (PASS/FAIL, no eyeballing) | VM, real composite |
| `scripts/ui-snapshot.sh` | Drive app into an exact scene (`MDV_UI_SCENE`), capture window by id through the compositor, pixel eval | host (window opens) / VM |
| `scripts/visual-smoke.sh` | Build + launch + WindowServer screencapture for human eyeball of the source-area compositor bug | host (window opens) |

> `test-headless-gate.sh` + `rust-core-gate.sh` are what `pr.yml` runs. The rest
> are VM/manual lanes. The `build-app.sh` pre-install smoke is opt-in
> (`MDV_RUN_SMOKE_GATE=1`) and not part of the host gate.

---

## 8. Bottom line

- **~4,165 Swift test methods + 297 Rust tests**, in a textbook broad-based
  pyramid: ~98% of Swift methods are host-safe headless (T1/T1m/T2'); only 116
  methods are VM-coupled heavy tiers (110 T4 spawn-app, 6 T5 real-pixel).
- **Mechanism mix is dominated by pure-logic + model** (correct). The thin top
  is well-placed: only **2 files / 6 methods** read true WindowServer pixels, and
  they exist precisely for the one bug class (compositor sibling-blank) that no
  cheaper mechanism can see.
- **Top risks:** (1) the 6 live-WebView suites mis-based on `XCTestCase` (no
  type-level enforcement, env-gate-only); (2) doc drift claiming the PR gate runs
  the WebView lane when it doesn't; (3) `ImageRenderer` raster suites that can
  read non-blank while the live window is blank (mitigated by the paired T5
  suites); (4) frame-walk suites prove layout, never paint; (5) zero
  XCUITest/AX — real-event interaction is T4-scripted-verb / VM-only.
