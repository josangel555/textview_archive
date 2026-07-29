# ViewerUITests Slice 2 of 6 — Test Learnings

**Batch:** Tests/ViewerUITests root, files 70–138 of ~400  
**File count:** 69 files (11,730 LOC total)  
**Analysis date:** 2026-07-11

---

## File Inventory

| Path | LOC | Tier | Framework | Behavior Guards | Teeth |
|------|-----|------|-----------|-----------------|-------|
| **CrossSearchIntegrationTests.swift** | 138 | headless-unit | XCTest | Cross-file search model + result polling; shows/dismiss state; empty query clears results; case-sensitive toggle | real |
| **CrossSearchModeWiringTests.swift** | 101 | headless-unit | XCTest | Regex error gate (sync); filename vs text mode routing (async); mode-specific result paths | real |
| **CSVEditingWiringTests.swift** | 134 | headless-unit | XCTest | Inline-editor gating (gate OFF, no sort, no filter only); displayIndex→gridRow mapping; commit closure model effect | real |
| **CSVFormulaDisplayTests.swift** | 53 | headless-unit | XCTest | Formula cell display (computed vs raw); computed marker presence; Rust formula gate enabled by default | real |
| **CSVFormulaEditBoxTests.swift** | 60 | headless-unit | XCTest | Edit-route decision (formula→box when gate on, else inline); A1 label grid coord mapping; commit→recalc round-trip | real |
| **CSVSaveEditsTests.swift** | 69 | headless-unit | XCTest | Save flow through editor chokepoint; serialized grid→disk; unknown tab fails safely; round-trip parse | real |
| **CurrentLineHighlightStateTests.swift** | 165 | headless-unit | XCTest | State machine: suppress during drag, resume on end; no stick-after-drag bug; selection suppression logic | real |
| **DefaultViewModePerTypeTests.swift** | 116 | headless-unit | XCTest | Per-type default mode pin/persist/clear; built-in defaults (.md→Rendered, .csv→Table) intact when no pin | real |
| **DeferredLoadViewModeUpgradeTests.swift** | 40 | headless-unit | XCTest | Deferred-load text file hex→source upgrade; binary stays hex; non-hex tabs unaffected; per-category override honored | real |
| **DeinitTeardownBackstopTests.swift** | 110 | headless-unit | XCTest | Deinit backstops for timer-/observer-owning models; StatusBarMemorySampler timer invalidation; GitPanelModel cleanup | real |
| **DependencyGraphWiringTests.swift** | 60 | headless-unit | XCTest | Dependency graph off-main build→hosted tab; no project root→no-op | real |
| **DiagnosticDumpTests.swift** | 356 | webview-inprocess | XCTest | L3 view visibility audit via DiagnosticDump (colors, layer props, text glyphs, zero-sized views, ancestor state); #192 gate | real |
| **DiagnosticDumpTextLengthTests.swift** | 23 | headless-unit | XCTest | DiagnosticDump TextKit2-safe populated metric (textLength, not numberOfGlyphs) | real |
| **DiagnosticDumpTextViewMetricsTests.swift** | 43 | headless-unit | XCTest | String length UTF-16 units (O(1)) not grapheme count; bounded 120-char head (TSK-172) | real |
| **DiffViewCopyTests.swift** | 57 | headless-unit | XCTest | Copy hunk/file to pasteboard via menu model; exact function invocation; payload matches parsed model | real |
| **DiffViewLayoutTests.swift** | 131 | T1m/HeadlessUI | XCTest | Short diff layout via ImageRenderer (not centering); viewport-size content bounds (pure SwiftUI layout, no representable) | real |
| **DiffViewReviewTests.swift** | 139 | T1m/HeadlessUI | XCTest | Review-aware DiffView + comment cards mount window-free; nil session renders identically to today (read-only guard) | real |
| **DiffViewSelectionRenderTests.swift** | 107 | T1m/HeadlessUI | XCTest | Multi-line selection highlight renders via ImageRenderer (accent-color tint); no highlight = identical pixels | real |
| **DockLayoutStoreTests.swift** | 300 | T1m/HeadlessUI | XCTest | Dock size persist/clamp; panel move→edge change + persist; narrow-republish invariant (no DocumentModel churn) | real |
| **DocumentModelAnalysisTests.swift** | 108 | headless-unit | XCTest | Active-doc analysis wiring: stats route to Rust engine; link checker gate (Markdown only), relative-path resolution | real |
| **DocumentModelCleanupTests.swift** | 136 | headless-unit | XCTest | Model cleanup on dealloc; tab cleanup (close→remove); file-watcher paused on dealloc; UI subscriptions unsubbed | real |
| **DocumentModelContentMenuTests.swift** | 71 | headless-unit | XCTest | Content-menu model wiring for file types; context routing | real |
| **DocumentModelCSVExportTests.swift** | 118 | headless-unit | XCTest | CSV export from grid model; header preservation; round-trip serialization | real |
| **DocumentModelEditorForwarderTests.swift** | 308 | headless-unit | XCTest | Forwarder contracts: editor properties sync bidirectionally (model←→EditorCoordinator); save flow wired | real |
| **DocumentModelFirstRunTests.swift** | 77 | headless-unit | XCTest | First-run flow: sidebar state, welcome-content tab seeding, default folder setup | real |
| **DocumentModelFocusShortcutsTests.swift** | 180 | headless-unit | XCTest | Focus commands: focus-sidebar, focus-editor, focus-terminal (if present) via keyboard shortcuts | real |
| **DocumentModelGitPanelTests.swift** | 60 | headless-unit | XCTest | Git panel state: repo-root detection, refresh timer, command execution routing | real |
| **DocumentModelHTMLExportTests.swift** | 115 | headless-unit | XCTest | HTML export wiring: base64 embed, CORS header override, resource sandboxing | real |
| **DocumentModelHTMLTrustTests.swift** | 140 | headless-unit | XCTest | HTML trust model: sandboxed remote, local-trusted, custom domain whitelisting | real |
| **DocumentModelJSONToolsTests.swift** | 119 | headless-unit | XCTest | JSON minify/prettify/validate command wiring through rust-core | real |
| **DocumentModelLanguageOverrideTests.swift** | 152 | headless-unit | XCTest | Language ID override for syntax highlighting; persistence across sessions | real |
| **DocumentModelLineOpsTests.swift** | 149 | headless-unit | XCTest | Editor line operations: delete, duplicate, indent, toggle comment; model effect attestation | real |
| **DocumentModelLineReferenceTests.swift** | 91 | headless-unit | XCTest | Line-reference (e.g., `file.txt:42`) parsing, navigation, scroll routing | real |
| **DocumentModelLoadedTextPrefixTests.swift** | 70 | headless-unit | XCTest | Prefix detection on load; mode resolution (text vs binary); encoding guessing | real |
| **DocumentModelOmniTests.swift** | 104 | headless-unit | XCTest | Omni-search model wiring; query state; result routing | real |
| **DocumentModelPreviewTests.swift** | 313 | headless-unit | XCTest | Preview render request flow; markdown→HTML pipeline; live update on edit | real |
| **DocumentModelRenderableTextModeTests.swift** | 109 | headless-unit | XCTest | Renderable text mode availability (JSON, Markdown, etc.); mode lock persistence | real |
| **DocumentModelResurrectionTests.swift** | 133 | headless-unit | XCTest | Session resurrection: tabs reopen, scroll/cursor restored, unsaved edits preserved | real |
| **DocumentModelScriptConsoleTests.swift** | 80 | headless-unit | XCTest | Script console model: command execution, output capture, error handling | real |
| **DocumentModelSpellingTests.swift** | 193 | headless-unit | XCTest | Spelling checker wiring; language selection; dictionary interaction; context-menu integration | real |
| **DocumentModelSplitTests.swift** | 141 | T1m/HeadlessUI | XCTest | Split pane layout store; left/right view modes; resize persistence | real |
| **DocumentModelStructuralSearchTests.swift** | 64 | headless-unit | XCTest | Structural search model wiring (syntax-tree query); scope selection | real |
| **DocumentModelTabForwarderTests.swift** | 455 | headless-unit | XCTest | Backward-compat forwarders: tab state, editor properties, CSV filter, hex width; round-trip contract | real |
| **DocumentModelTests.swift** | 1702 | headless-unit | XCTest | Core model: open/close tabs, switch, pin, rename; unsaved-edit tracking; file watcher external-edit detection | real |
| **DocumentModelTextTransformTests.swift** | 125 | headless-unit | XCTest | Text transforms: case, sort, reverse, quote, JSON format; model state updates | real |
| **DocumentModelViewModeLockTests.swift** | 75 | headless-unit | XCTest | View-mode lock persistence per file; mode overrides lock; pin/clear contract | real |
| **DocxExportWiringTests.swift** | 109 | headless-unit | XCTest | DOCX export through pandoc wrapper; round-trip preservation (where applicable) | real |
| **DomPatchGateTests.swift** | 24 | headless-unit | SwiftTesting | DOM-patch feature gate (TSK-838): default ON; opt-out with MDV_DOM_PATCH=0 | real |
| **DoubleShiftMonitorTests.swift** | 118 | headless-unit | XCTest | Double-shift key combo detection; debounce; app-focus integration | real |
| **DragDropTests.swift** | 199 | headless-unit | XCTest | File drag-drop: multiple files, folders, URL resolution, tab creation | real |
| **EditorAssistToggleTests.swift** | 108 | T1m/HeadlessUI | XCTest | Editor assist (autocomplete, diagnostics) toggle wiring; state persistence | real |
| **EditorCompletionMappingTests.swift** | 37 | headless-unit | XCTest | Completion model: string→result mapping, filtering, user-selection feedback | real |
| **EditorCompletionWebViewTests.swift** | 96 | webview-inprocess | XCTest | CM6 completion integration; JS bridge message routing; in-process DOM read | real |
| **EditorCoordinatorCleanupTests.swift** | 239 | headless-unit | XCTest | Coordinator cleanup: task cancellation, timer invalidation, pending-op drains; deinit backstop | real |
| **EditorCoordinatorDiskRoundtripTests.swift** | 235 | headless-unit | XCTest | Disk watcher roundtrip: external-edit detection, reload routing, unsaved-conflict prompt | real |
| **EditorCoordinatorInteractionTests.swift** | 374 | headless-unit | XCTest | Cross-coordinator seams: dirty-close prompt (save/discard/cancel), ⌘S routing, external-edit conflict, gotoLine across mode-switch | real |
| **EditorCoordinatorTests.swift** | 702 | headless-unit | XCTest | Coordinator state machine: cursor/scroll per-tab, save wiring, reload flow, diagnostics pending, indentation, insert-at-cursor | real |
| **EditorCursorBlinkWebViewTests.swift** | 117 | webview-inprocess | XCTest | CM6 cursor-blink state via JS bridge; interval, visibility transitions | real |
| **EditorDiagnosticsWebViewTests.swift** | 92 | webview-inprocess | XCTest | Diagnostics marker rendering (squiggles, gutter icons) via CM6 integration | real |
| **EditorFocusVerbTests.swift** | 112 | T1m/HeadlessUI | XCTest | Focus command routing; active editor state; first-responder wiring | real |
| **EditorFoldRangesTests.swift** | 198 | headless-unit | XCTest | Fold region detection (syntax-aware); state persistence per file; toggle contract | real |
| **EditorReplaceWebViewTests.swift** | 102 | webview-inprocess | XCTest | Find-replace JS bridge; model↔UI sync; case-sensitive/regex toggles; replace-all contract | real |
| **EditorRepublishInvariantTests.swift** | 371 | headless-unit | XCTest | Editor mutations must NOT republish DocumentModel unnecessarily; narrow-observation discipline | real |
| **EditorSaveNoClobberTests.swift** | 323 | headless-unit | XCTest | Atomic save: no clobber on concurrent writes; temp file + rename; history snapshot; local-file versioning | real |
| **EditorScrollRestoreWebViewTests.swift** | 151 | webview-inprocess | XCTest | CM6 scroll position: record per-tab, restore on tab-switch (no stale cache), handle mode transitions | real |
| **EditorThemeParityTests.swift** | 224 | webview-inprocess | XCTest | CM6 theme mirrors app theme (light/dark); extension themes; font settings | real |
| **EmptyStateNewImageHostingTests.swift** | 69 | webview-inprocess | XCTest | Empty-state view + image-hosting flow; alt-text wiring | real |
| **EncodingConvertTests.swift** | 95 | headless-unit | XCTest | File encoding detection and conversion (UTF-8, UTF-16, Latin-1, etc.) | real |
| **ExtensionsInventorySettingTests.swift** | 45 | headless-unit | XCTest | Extensions plugin discovery; config loading; on/off toggle persistence | real |

---

## Test-Type Taxonomy

### By Tier
- **Headless-unit (XCTestCase, no UI):** ~50 files — pure model logic, state machines, file I/O, wiring contracts, forwarders
- **T1m (HeadlessUITestCase):** ~8 files — NSHostingView mount (no window), layout geometry, ImageRenderer pixel rendering
- **Webview-inprocess (#192-gated, `WebViewTestCase`):** ~8 files — in-process WKWebView tests, CM6 bridge messaging, JS integration
- **T4/T5/AX:** 0 files in this slice (deferred to VM/render lane and owner)

### By Feature Domain
- **DocumentModel:** 15+ files (comprehensive—analysis, cleanup, content, CSV, editor, first-run, focus, git, HTML, JSON, language, line ops, omni, preview, resurrection, spelling, split, structural search, text transform, view-mode lock)
- **EditorCoordinator & CM6 integration:** 10+ files (state machine, cleanup, interactions, cursor/scroll, diagnostics, completion, replace, fold, theme, save atomicity)
- **CSV engine:** 3 files (editing, formula display, formula edit box, save)
- **DiffView + Code Review:** 4 files (copy, layout, review with comments, selection highlight)
- **Cross-search:** 2 files (integration, mode wiring)
- **Support & diagnostics:** 10+ files (DiagnosticDump variants, deinit cleanup, dependency graph, drag-drop, encoding, extensions, double-shift, docx, dom-patch, deferred-load, default view mode)

### Framework Mix
- **XCTest:** 68 files (all but one)
- **Swift Testing:** 1 file (DomPatchGateTests) — a pilot demonstrating parameter-driven testing

---

## Coverage Shape: Over- and Under-Tested

### Over-Tested on Host
- **DocumentModel wiring:** 15 separate files drilling into every model API, forwarder contract, state persistence
  - _Rationale:_ Model is the central hub; wiring bugs are cheap to find early and hard to debug in rendered UI
  - _Trade-off:_ Comprehensive, but 1700 LOC in one file (DocumentModelTests) is a refactoring target for greenfield
- **CSV operations:** 3 dedicated files (editing, formula display, formula edit box)
  - _Well-factored:_ Each file tests a specific wiring seam (gating, A1 mapping, commit→recalc)
- **State persistence & tab coordination:** Over 10 files collectively testing model.tabs, TabCoordinator, EditorCoordinator
  - _Strength:_ These failures are user-visible (lost tabs, lost cursor position)

### Under-Tested on Host (Deferred by Design)
- **Actual pixel rendering:** Most view tests explicitly defer to VM/T5 (ImageRenderer used carefully with caveats)
  - _Comment pattern:_ "the on-screen behavior is VM-only" / "real-screen interaction is owed" / "live behavior is VM/owner review"
- **AX interactions:** 0 tests (correctly off-limits on host)
- **WebView pixel behavior:** 8 files marked `#192` (in-process, gated, not in bare sweep)
- **Drag-drop gesture:** Model tested, real pointer drag deferred

---

## Harness & Infrastructure Patterns Worth Porting

### 1. **TierBaseCases Class Hierarchy**
```swift
// From Harness/TierBaseCases.swift (referenced via imports)
class HeadlessUITestCase: XCTestCase {
  // @MainActor, NSApplication-free, window-free
}

class WebViewTestCase: XCTestCase {
  // #192-gated in-process WebView tests; self-skips if not enabled
}
```
**Portable lesson:** The three-tier split (headless unit, headless UI, webview-in-process) is load-bearing for fast, parallelizable tests. Greenfield should inherit this structure early.

### 2. **Test Seams for Dependency Injection**
EditorCoordinatorTests pattern:
```swift
private final class CaptureBox {
  var replaceLog: [(Int, ViewerCore.Tab)] = []
  // … other mutation logs
}

private func wire(_ ec: EditorCoordinator, _ tc: TabCoordinator) -> CaptureBox {
  let box = CaptureBox()
  ec.onReplaceTab = { [tc, box] idx, tab in
    box.replaceLog.append((idx, tab))
    tc.replace(at: idx, with: tab)
  }
  // … wire other closures for side-effect capture
  return box
}
```
**Portable lesson:** Injecting effect closures (not mocks) keeps coordinators testable without invasive mocking frameworks. Capture-box pattern enables assertion on side effects without intrusive inspection.

### 3. **Temp Directory + Per-Test UserDefaults Isolation**
Standard setUp pattern:
```swift
override func setUp() async throws {
  tmpDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("TestName-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
  suiteName = "TestName-\(UUID().uuidString)"
  defaults = UserDefaults(suiteName: suiteName)
}

override func tearDown() async throws {
  try? FileManager.default.removeItem(at: tmpDir)
  defaults.removePersistentDomain(forName: suiteName)
}
```
**Portable lesson:** UUID-based isolation prevents cross-test pollution and allows parallel test execution. UserDefaults per-suite keeps prefs from one test polluting another. _Fast iteration benefit:_ tests can run in any order, 10+ at once.

### 4. **Negative-Control Gates for Proving Test Teeth**
DomPatchGateTests (Swift Testing):
```swift
@Test func gate_optOutOnlyWithExplicitZero() {
  #expect(MarkdownRenderedView.domPatchEnabled(env: "0") == false)
}
```
DeinitTeardownBackstopTests (XCTest):
```swift
// Deliberately exercise the deinit path WITHOUT calling stop()
// to prove the backstop actually invalidates the timer:
// (if deinit is missing, timer.isValid stays true and test fails)
```
**Portable lesson:** Code a deliberate test that would FAIL if the regressed behavior were reintroduced. For example, for a feature gate, test _both_ that the gate controls the behavior _and_ that reverting the gate reverts the behavior.

### 5. **Clear Tier-Aware Commenting**
Pattern across files:
```swift
/// Host-safe (T1m): drives `runCrossSearch()` against a temp fixture
/// and reads state. No window.

/// The on-screen behavior is VM-owed; this pins the model wiring.

/// #192-gated in-process WebView test; skips in the bare sweep.

/// Pure-logic state machine; the real pointer shift-click is AX-owed.
```
**Portable lesson:** Docstring each test class with its tier, what it guards, and what's deferred. Downstream workers know exactly what to trust and what to verify elsewhere.

### 6. **DocumentModel Factory Pattern**
Every DocumentModel test:
```swift
private func makeModel() -> DocumentModel {
  DocumentModel(
    controller: DocumentController(),
    history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
    sidebar: SidebarModel(),
    preferences: PreferencesStore(defaults: defaults)
  )
}
```
**Portable lesson:** A factory method ensures consistent setup and catches constructor contract changes early (when the factory fails to compile).

### 7. **Async Polling for Async Work**
CrossSearchIntegrationTests pattern:
```swift
private func waitFor(timeout: TimeInterval, until predicate: () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if predicate() { return true }
    try? await Task.sleep(nanoseconds: 50_000_000)
  }
  return predicate()
}
```
**Portable lesson:** Instead of fixed sleeps (brittle), poll with a timeout. Speeds up tests when work completes early; catches hangs when it doesn't.

---

## Flake & False-Green Risks Observed

### 1. **ImageRenderer Limitations (Documented & Addressed)**
- **DiffViewLayoutTests**, **DiffViewSelectionRenderTests** use `ImageRenderer` but with explicit caveats:
  - ✓ Safe for pure SwiftUI layout geometry (no representable occlusion)
  - ✗ NOT safe for on-screen visibility (rendererer draws placeholders for AppKit views)
  - Files explicitly state: "the on-screen behavior is VM-only"
- **Mitigated in greenfield:** Avoid using ImageRenderer as proof of visual correctness; use it only for layout geometry on pure-SwiftUI views, then VM-validate the actual render.

### 2. **#192 WebViewTestCase Gate**
- **DiagnosticDumpTests**, **Editor*WebViewTests** self-skip in bare sweep if gate not enabled
- **Risk:** A developer might assume "tests are passing" when heavy-tier tests aren't running
- **Mitigated:** Tests leave a skip log; CI/nightly runs with `MDV_RUN_WEBVIEW_TESTS=1` forces them to run

### 3. **Fixed Sleeps (Mostly Eliminated)**
- **Old pattern:** `try? await Task.sleep(nanoseconds: 200_000_000)` then assert
  - Under load, 200 ms might not be enough; false flake
- **New pattern:** `waitFor(timeout: 3.0) { model.crossSearchResults.isEmpty == false }`
  - Succeeds immediately when work completes; handles machine load
- **Status:** Batch consistently uses polling, not fixed sleeps; low flake risk

### 4. **Async/Await Completeness**
- All test functions are `async` when they do async work
- `setUp` / `tearDown` are `async throws`, catching file I/O errors explicitly
- **Risk:** If a test forgets `async`, it won't await a Task.sleep; false-pass on timing bugs
- **Mitigated:** Type system enforces this; Xcode will error if `await` is forgotten

---

## Rebuild Notes: What to Carry Forward

### Strategy: Layered Structure
1. **Tier 1 (Host-safe, required for merge):**
   - Pure-logic model tests (DocumentModel, Coordinators, state machines)
   - Temp directory ± UserDefaults pattern mandatory for speed + parallelism
   - Target: compile in 5 min, run in 2 min on a quiet Mac

2. **Tier 2 (Host, optional for local iteration):**
   - HeadlessUITestCase (ImageRenderer, NSHostingView) — fast but defers pixel claims
   - Target: compile in 2 min, run in 1 min, no window opens

3. **Tier 3 (Nightly/CI, VM):**
   - WebViewTestCase (#192 gated)
   - T4 LiveAppTestCase, T5 PixelTestCase — deferred to VM
   - Run on UTM via `bash scripts/test-in-vm.sh`

### Key Takeaways for Greenfield
1. **Don't merge DocumentModel tests into one 1700-LOC file; split by domain.** Current slice shows 15+ specialized tests — keep that granularity to isolate failures.

2. **Embrace test seams (dependency injection via closures) over mocking frameworks.** EditorCoordinatorTests pattern is far more lightweight than OCMock/Mockito equivalents.

3. **Explicit tier comments are load-bearing.** Maintainers need to know what each test _can_ and _cannot_ verify. Docstrings save hours of confusion.

4. **Temp directory + UUID + UserDefaults per-suite is the fast-path formula.** Don't reach for more invasive isolation (sandboxing, subprocess spawn); per-test tmpdir works at scale.

5. **Negative-control gates prove teeth.** For any feature gate or critical behavior, code a test that would flip red if the behavior regressed.

6. **CSV and formula engines split into focused tests, not one mega-suite.** This batch shows 3 CSV files (editing, display, edit-box); each one tests a specific wire. Easier to debug failures, easier to land incremental improvements.

7. **DiffView layout/selection use ImageRenderer deliberately, but with documented caveats.** Greenfield should reserve ImageRenderer for layout geometry only; defer pixel/color correctness to VM T5.

8. **Explicit `#192` gates for WebView tests are essential.** They self-skip in bare sweep, unblock CI, and keep developer machines window-free. Don't mix in-process WebView tests into the headless gate.

9. **Factory-method pattern for model construction prevents drift.** Every DocumentModel test calls `makeModel()`, so a constructor signature change breaks all at once, not silently in a few.

10. **Polling > fixed sleeps** for async work. This batch consistently uses timeout-based predicates; almost zero flake risk.

---

## Summary

This slice (70–138) represents **the model-centric layer** of ViewerUITests: comprehensive, well-factored, with clear tier boundaries. Heavy on DocumentModel (15+ files) and EditorCoordinator (10+), with specialized CSV and DiffView testing.

**Strengths to carry forward:**
- Clear, documented tier split (host unit, host UI, webview-inprocess)
- Strong isolation (temp directories, per-test UserDefaults)
- Dependency injection via closures (no heavy mocks)
- Explicit documentation of what each test does/doesn't prove
- Async-aware polling patterns

**Risks to watch:**
- ImageRenderer over-trust (documented but easy to miss)
- #192 gate opacity (tests self-skip; CI/nightly must force-enable)
- Monolithic DocumentModelTests.swift (refactor into smaller domains)

**Recommended greenfield starting point:**
Copy the TierBaseCases hierarchy, adopt the temp-dir + UserDefaults pattern, use dependency-injection seams, and start with a small DocumentModel to avoid the 1700-LOC pitfall. Tier comments are non-negotiable.
