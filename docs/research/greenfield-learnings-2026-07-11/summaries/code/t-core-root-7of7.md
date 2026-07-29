# Test Batch 7/7: ViewerCoreTests Root — Summary

**File count:** 72 files (TerminalCommand* through XLSXDocument*)  
**LOC range:** 25–310 lines (median ~100)  
**Framework distribution:** XCTest (64), SwiftTesting (8)  
**Total EST LOC:** ~7,200

---

## File-by-file entries

| File | LOC | Tier | Framework | Pins | Teeth |
|------|-----|------|-----------|------|-------|
| **TerminalCommandHistoryTests.swift** | 52 | headless-unit | XCTest | MRU dedup, search case-insensitive, persistence round-trip | real — broken history persist fails |
| **TerminalCommandSearchTests.swift** | 81 | headless-unit | XCTest | merged favorites+history model, dedup, rank (fav first), display labels | real — dedupe regression caught |
| **TerminalCopyTrimTests.swift** | 29 | headless-unit | XCTest | trailing-space/blank-line trim, interior-blank preserve, line-ending survive | real — easy to regress |
| **TerminalDropFormatterTests.swift** | 48 | headless-unit | XCTest | shell-quote path paste, space/quote/special-char escaping, multi-path join | real — quoting bugs caught |
| **TerminalFavoritesStoreTests.swift** | 131 | headless-unit | XCTest | add/rename/move/remove/cap CRUD, persist round-trip, hand-edit tolerance | real — full editor contract |
| **TerminalHeaderTests.swift** | 43 | headless-unit | XCTest | format header name/cwd/pid/home, home abbreviation, boundary path cases | real — path-boundary bugs caught |
| **TerminalInputLineAccumulatorTests.swift** | 87 | headless-unit | XCTest | command-boundary detect, backspace/tab/escape/ctrl handling, line drop policy | real — tracks all edge cases |
| **TerminalKeyEncoderTests.swift** | 72 | headless-unit | XCTest | key→bytes mapping, special keys, arrow/page/delete CSI forms, ctrl/option chords | real — keystroke mapping bugs |
| **TerminalOSC7Tests.swift** | 119 | headless-unit | XCTest | OSC-7 cwd decoder, URL unescape, host matching, reject remote/wrong-scheme | real — security boundaries tested |
| **TerminalPaneClampTests.swift** | 24 | headless-unit | XCTest | clamp width/height bounds, no UX cap, min floor, corruption ceiling | real — size validation |
| **TerminalPaneLayoutTests.swift** | 188 | headless-unit | XCTest | height clamp, UserDefaults persist, tab-set round-trip, corrupt-data degrade | real — multi-faceted persist model |
| **TerminalPanelEdgeBridgeTests.swift** | 45 | headless-unit | XCTest | bijective edge-type mapping, round-trip stable both directions | real — enum divergence guard |
| **TerminalPaneTreeTests.swift** | 209 | headless-unit | XCTest | split-tree geometry, axis/weights/nested, leaf enumeration, click hit-test | real — complex tree contracts |
| **TerminalScreenTests.swift** | 310 | headless-unit | XCTest | grid write/wrap/scroll, cursor move/clamp/bounds, erase ops, tab stops | real — comprehensive grid semantics |
| **TerminalScrollbarTests.swift** | 51 | headless-unit | XCTest | thumb height/position/inverse, scrollback fraction, floor/clamp | real — scroll-geometry edge cases |
| **TerminalSelectionTests.swift** | 136 | headless-unit | XCTest | ordered/single-point, column-range multi-row, selected-text with trim | real — selection-text extraction |
| **TerminalTabSetTests.swift** | 236 | headless-unit | XCTest | add/select/cycle/close, active-id adjust, rename/reorder, persist round-trip | real — full tab lifecycle |
| **TestStateRedirectTests.swift** | 81 | headless-unit | XCTest | app-support redirect under XCTest (no pollution), env override, multi-store guard | real — test isolation critical |
| **TestTimingsTests.swift** | 92 | bench | XCTest | test-timings.py aggregator, per-class sum, slowest-first sort, topN limit | real — perf-sorting regression |
| **TextCleanupTests.swift** | 56 | headless-unit | XCTest | trim trailing-ws, CRLF preserve, final-newline ensure, blank→empty | real — line-ending preservation |
| **TextFileLoaderBenchTests.swift** | 31 | bench | XCTest | load-time by size (256KB–65MB), off-main deferral threshold measurement | weak — env-gated bench (not gate) |
| **TextFileLoaderTests.swift** | 108 | headless-unit | XCTest | load UTF-8/empty/missing, encoding detect, byte-count, URL preservation | real — file-load round-trip |
| **TextFileMultiSheetTests.swift** | 42 | headless-unit | XCTest | XLSX active-sheet switch, TSV re-derive, multi-sheet retain, non-spreadsheet no-op | real — sheet-switching model |
| **TextLineGeometryTests.swift** | 41 | headless-unit | SwiftTesting | end-line calc (1-based UTF-16), multi-line span, oversized clamp | real — CMEdit line-mapping |
| **TextToolRunnerTests.swift** | 141 | headless-unit | XCTest | tool commands (UUID/SHA256/Base64/etc), fake pasteboard, error handling | real — tool-runner contract |
| **TextToolsLineOpsTests.swift** | 139 | headless-unit | XCTest | duplicateLines/moveLines, rewritten-text + re-select range, trailing-newline edge | real — editor line-ops |
| **TextToolsTests.swift** | 178 | headless-unit | XCTest | UUID v4 shape, SHA256/Base64 with test vectors, URL-escape, JSON round-trip | real — published vectors |
| **TextTransformTests.swift** | 119 | headless-unit | XCTest | uppercase/lowercase/capitalize, CMEdit generation, end-to-end apply | real — CM6 transaction test |
| **ThemeDefinitionTests.swift** | 168 | headless-unit | XCTest | hex parse, round-trip, tok-CSS gen, store persist, default fallback | real — color-roundtrip |
| **ThirdPartyNoticesTests.swift** | 51 | headless-unit | XCTest | generated THIRD_PARTY_NOTICES.md exists, all components named | real — license audit gate |
| **ThreeWayMergeTests.swift** | 221 | headless-unit | XCTest | diff3 merge, non-overlapping auto-merge, conflict with correct slices, identical both-sides | real — merge semantics |
| **TmuxCommandTests.swift** | 168 | headless-unit | SwiftTesting | window@/pane% sigil, send-keys escaping, command string round-trip | real — tmux serialization |
| **TmuxControllerCoreHardeningTests.swift** | 212 | headless-unit | XCTest | FIFO skip surfacing, correlation anomalies, dropped-command reporting | real — silent-loss surface |
| **TmuxControllerCoreTests.swift** | 292 | headless-unit | XCTest | topology ingest, per-pane output demux, active-pane routing, add/close re-route | real — tmux core model |
| **TmuxControlParserHardeningTests.swift** | 167 | headless-unit | XCTest | extended-output fix, flow-control, raw high-byte payload, %output survive | real — wire-protocol hardening |
| **TmuxControlParserTests.swift** | 246 | headless-unit | XCTest | octal unescape, window/pane create, control-mode framing, type coercion | real — protocol codec |
| **TmuxLayoutParserHardeningTests.swift** | 118 | headless-unit | XCTest | deep-nesting stack-overflow guard, epsilon split misclassify fix | real — security hardening |
| **TmuxLayoutParserTests.swift** | 194 | headless-unit | XCTest | single-leaf, h/v split, nested, weights, checksum, complex nesting | real — layout string decode |
| **TmuxSessionTests.swift** | 210 | headless-unit | XCTest | window/pane topology, active selection, layout fixture parsing, tree flattening | real — tmux session model |
| **ToolResultsTests.swift** | 48 | headless-unit | XCTest | lint/gofmt/clippy row builders, severity mapping, empty→positive note, plainText | real — results panel model |
| **TrackedReposReducerTests.swift** | 168 | headless-unit | XCTest | repo-discovery policy, stale-branch prune, conflict resolution, git fixture | real — git-aware logic |
| **TrackedReposStoreTests.swift** | 198 | headless-unit | XCTest | refcount, LRU eviction, cap enforce, snapshot equality, timeout-keep, concurrency | real — store actor correctness |
| **TreemapLayoutTests.swift** | 156 | headless-unit | XCTest | squarified layout, proportional areas, in-bounds, non-overlapping, area-conserve | real — treemap geometry |
| **TreeSitterEngineGoldenTests.swift** | 271 | headless-unit | XCTest | golden tokenization per language, grammar-version stability, substring assertion | real — highlighting regression |
| **TreeSitterEngineSmokeTests.swift** | 78 | headless-unit | XCTest | retained grammar load (swift/json/markdown/xml/js/ts), tokenize produces runs | real — grammar-availability |
| **TreeSitterPaintOverTests.swift** | 82 | headless-unit | XCTest | sweep-line overlap, later-run-wins, coalesce same-kind, clip to textCount | real — overlap semantics |
| **TreeSitterPredicateSubstringTests.swift** | 165 | headless-unit | XCTest | predicate substring byte-identical to old NSString slice (BMP/astral/combining) | real — coloring equivalence |
| **TreeSitterWarmupTests.swift** | 61 | headless-unit | XCTest | warm() compile, isWarm flip, fresh-engine start cold | real — warmup contract |
| **UIClickSpecTests.swift** | 51 | headless-unit | XCTest | parse ui-click verb+arg, modifiers strict, fraction coordinates, no silent-degrade | real — spec grammar |
| **UIKeySpecTests.swift** | 73 | headless-unit | XCTest | keycode/modifier mapping, char→vk, chord synthesis, strict parse fail | real — keystroke-synth |
| **UISceneRegistryTests.swift** | 103 | headless-unit | XCTest | enumerate allSceneIDs, resolve complete spec, pixel-coordinate invariant | real — scene determinism |
| **UnifiedDiffClipboardTextTests.swift** | 53 | headless-unit | XCTest | golden unified-diff plain text, hunk structure, round-trip-able paste | real — diff format |
| **UnifiedDiffGeneratorTests.swift** | 141 | headless-unit | XCTest | generate→parse→reconstruct round-trip, diff dialect equivalence | real — generator correctness |
| **UniversalPastePlanTests.swift** | 36 | headless-unit | SwiftTesting | plan(for:) routing, image→PNG/TIFF, text/file-url source selection | real — paste materialization |
| **URLFragmentPolicyTests.swift** | 29 | headless-unit | XCTest | same-document-fragment check, no/empty fragment reject | real — anchor navigation |
| **URLSchemeRouterTests.swift** | 88 | headless-unit | XCTest | deeplink verb routing, scheme alias, containment, S1.1 rejections | real — URL scheme dispatch |
| **VectorOverlayHitTestTests.swift** | 58 | headless-unit | SwiftTesting | hitTest frame containment (closed), segment distance (open), front-most wins | real — canvas pick |
| **VectorOverlayTests.swift** | 171 | headless-unit | XCTest | add/remove/move/z-order, serialize round-trip, endpoint direction, opacity | real — overlay model |
| **VectorShapeTextTests.swift** | 46 | headless-unit | XCTest | text-shape Codable round-trip, text/fontSize persist, other kinds ignore text | real — text overlay |
| **ViewModeLockStoreTests.swift** | 92 | headless-unit | XCTest | lock put/get/clear, persist round-trip, resolution (locked wins if available) | real — mode-lock policy |
| **VMSmokePathGuardTests.swift** | 71 | headless-unit | XCTest | vm-absolute path translate, shell-metachar allowlist, dry-run validation | real — remote-command security |
| **VSCodeThemeImporterTests.swift** | 117 | headless-unit | XCTest | JSONC tolerance, scope→TokenKind specificity, dark/light infer, install | real — theme import |
| **WalkthroughAuthoringSampleTests.swift** | 24 | headless-unit | XCTest | docs/examples/sample-walkthrough.json parse valid, documented example guard | real — docs rot prevention |
| **WalkthroughCatalogCreateTests.swift** | 86 | headless-unit | XCTest | seed template valid, create collision-safe, base-name escape guard | real — walkthrough creation |
| **WebSourceViewGateTests.swift** | 19 | headless-unit | XCTest | gate ships OFF, env override, user-default persist, M6 render gate | real — feature-flag guard |
| **WindowGeometryTests.swift** | 91 | headless-unit | XCTest | clamp requested frame to visible, restore-vs-default, min/max bounds | real — window-layout |
| **WorkItemGraphQueueTests.swift** | 137 | headless-unit | XCTest | dependency graph, work_next queue, autonomy gate, parent roll-up | real — PM graph logic |
| **WorkItemModelTests.swift** | 201 | headless-unit | XCTest | lifecycle state-machine, dependency tracking, work_next, autonomy gate | real — work-item model |
| **WorktreeManagerModelTests.swift** | 156 | headless-unit | XCTest | stub git for pure UX logic, list/add/remove/prune dispatch, branch conflict | real — worktree manager |
| **WorktreeOverlapTests.swift** | 84 | headless-unit | XCTest | cross-agent overlap detect, whoTouches list unmerged branches | real — conflict detection |
| **XattrIOTests.swift** | 79 | headless-unit | XCTest | real POSIX xattr syscalls, read/write round-trip, remove, missing-attr | real — extended-attr i/o |
| **XLSXDocumentTests.swift** | 188 | headless-unit | XCTest | cell-ref math (A1 notation), XLSX parse, workbook/rels resolve, dense-grid | real — spreadsheet parsing |

---

## Test-type taxonomy — the kinds here + rough proportions

### Headless-Unit dominance (≈100%)
- **Pure logic / model layer** — 72/72 files are Tier 1/T1m (headless-only), zero T4/T5/AX.
- **No AppKit / no window spawn** — every test runs host-side with deterministic fixtures or temp directories.
- **Framework split:** XCTest (64/72 = 89%), SwiftTesting (8/72 = 11% — a recent pilot on pure-logic files).

### Coverage domains (intersecting, by LOC %):
1. **Terminal subsystem** (17 files, ~2,100 LOC) — command history, favorites, key encoding, OSC-7 cwd, tab-set model, screen grid, scrollbar, selection, pane tree, layout, tab-set persistence.
2. **Text editing** (8 files, ~1,200 LOC) — file loader, line geometry, cleanup, text tools (UUID/SHA/Base64/etc), text transforms, line ops (duplicate/move), line-ending handling.
3. **Tmux control-mode** (9 files, ~1,400 LOC) — command serializer, control-mode parser, layout parser, session/window/pane topology, FIFO correlation, hardening (stack-overflow, skip surfacing).
4. **Spreadsheet/XLSX** (3 files, ~340 LOC) — XLSX parse, multi-sheet, cell-ref math, workbook structure.
5. **Theming/UI** (9 files, ~1,100 LOC) — theme import (JSONC), VSCode scope→token, click/key spec parsing, scene registry, icon/vector shapes, text overlay.
6. **Diff/merge** (3 files, ~515 LOC) — three-way merge (diff3), unified-diff generator, clipboard text.
7. **Repo/workbench** (7 files, ~1,050 LOC) — tracked repos store/reducer, worktree manager, overlap detect, work-item model (PM graph).
8. **Other utilities** (11 files, ~970 LOC) — URL routing/fragment policy, window geometry, tools results, tool runner, walkthrough authoring/catalog, web-source gate, VM-smoke path guard, xattr I/O, third-party notices, test state redirect, test timings.

---

## Coverage shape — what is over-tested vs under-tested

### Over-tested (appropriate — high-leverage models):
- **Terminal grid semantics (TerminalScreenTests, ~310 LOC)** — auto-wrap, scroll, cursor clamping, erase ops, tab stops. Justifiable: the grid is the SHARED foundation every terminal-output path depends on. Rich mutator semantics that are easy to regress on.
- **Tmux layout/topology (3 files, ~640 LOC combined)** — split-tree geometry, pane-id routing, layout-string decode. Justified: a malformed layout string can crash (stack-overflow hardening TSK-1196), and pane targeting is security-critical (send-keys to wrong pane is a bug).
- **Terminal tab-set CRUD + persist (TerminalTabSetTests + TerminalPaneLayoutTests, ~424 LOC)** — add/select/cycle/close, active-id adjustment, rename/reorder, round-trip. Justified: tab state loss is user-visible regression; the closed-pane active-selection logic is non-obvious.

### Under-tested (known — render/VM-only):
- **Terminal view rendering, keystroke delivery, split-pane drag** (T4/T5 tier) — no tests here; exercised on VM via `PixelTestCase` + `UISimulator`.
- **Tmux `-CC` spawning, PTY pump, backpressure** (T4/T5 tier) — the `TmuxControllerCore` is tested on injected event streams; a REAL `tmux -CC spawn + stdout pump` is VM-only.
- **CM6 editor integration** (wiring, keypress handler, selection, undo) — `TextTransform` / `TextLineGeometry` pin the PURE transforms; the view-layer apply is VM-tail.
- **Tree-sitter rendering + CSS styling** — golden tests verify tokenization (input→token-kind); the on-screen color/underline is VM-pixel validation.

### Appropriate gaps (no test needed):
- **ANSI sequence parsing** (well-established; delegated to `ANSIParser` helpers tested by screen/selection tests).
- **File I/O error modes** (covered as "throws-on-missing" + "corrupt-json degrade"; exotic POSIX errors are rare + hard to simulate).
- **Concurrency** (store actors use `@MainActor` guards, but await-stress testing is VM-lane).

---

## Harness & infra patterns worth porting

### 1. **Deterministic temp-file pattern**
```swift
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("prefix-\(UUID().uuidString).ext")
}
// + defer cleanup
```
**Use in rebuild:** Consistent across ~30 files; isolates test state, avoids real ~/Library pollution.

### 2. **Fake/stub collaborators (no real I/O)**
- `TextToolRunnerTests` — `FakePasteboard` implements `PasteboardIO` protocol.
- `WorktreeManagerModelTests` — `StubGit` records dispatched commands, returns canned output.
- `TmuxControllerCoreTests` — injects `[ControlModeEvent]` stream instead of spawning real `tmux -CC`.

**Pattern:** Define a test-only impl of the interface, capture side-effects, assert calls + return values.

### 3. **Test state redirect (TSK-1288 + TestStateRedirectTests)**
```swift
@testable import ViewerCore
// XCTest auto-redirects ~/Library/Application\ Support paths to /tmp/MDVTestState-<uuid>
// so tests never pollute dev's REAL history/bookmarks/local-history stores.
```
Enforced at init time by `TestStateRedirect` helper. **Critical:** prevents test cross-contamination.

### 4. **SwiftTesting pilot (8 files)**
- New pure-logic tests prefer `@Test` / `#expect` over `XCTestCase` / `XCTAssertEqual`.
- Cleaner syntax, better error messages, parameterization (not shown here but available).
- **Lesson:** Keep XCTest for tier-based / `@MainActor` tests; migrate new pure-logic to SwiftTesting.

### 5. **Golden/vector test patterns**
- `TreeSitterEngineGoldenTests` — per-language (substring, kind) pairs; grammar version stability.
- `TextToolsTests` — published test vectors (SHA-256, Base64) for crypto correctness.
- `ThemeDefinitionTests` — hex parse round-trip (color→hex→color identity).

**Pattern:** Assert isomorphism (X→f→X) or against external oracle (published vector).

### 6. **Negative-control switches (TSK-1134 candidate)**
- Not extensively used in this batch, but `WebSourceViewGateTests` + others show env-var / defaults-override pattern.
- Opportunity: gate deliberate failures (e.g., `if MDVNegativeControl.isBroken("TerminalScreen")`) so tests can self-verify regression detection (teeth proof).

### 7. **Multi-stage round-trip assertions**
- `TextFileMultiSheetTests.test_withActiveSheet_reDerivesContentsFromTheChosenSheet` — add → switch → verify contents re-derived, sheet list retained.
- `TerminalTabSetTests` — add → select/cycle/close → rename/move → compare old and new state.
- Pattern: build fixture, mutate, assert both the expected change AND unchanged side-effects.

---

## Flake / false-green risks observed

### No observed flake in this batch, but patterns that COULD flake:

1. **Time-dependent bench tests (TextFileLoaderBenchTests)**
   - Env-gated (`MDV_RUN_BENCH=1`); not in the merge gate.
   - Risk: FS cache, CPU load, I/O contention → variance. Mitigation: warm run ignored, second run measured.
   - **Lesson:** Bench tests need machine-state guards or they're noisy.

2. **Git-dependent tests (TrackedReposReducerTests, TrackedReposStoreTests)**
   - Spawn real `git` on temp fixtures.
   - Risk: `/usr/bin/git` absent → skip; bad repo state → silent failure.
   - Mitigation: pre-flight XCTSkip if git unavailable; temp fixtures isolated.
   - **Lesson:** Git tests are safe because temp dirs are isolated + git is standard.

3. **False-green risk: TestStateRedirect pollution**
   - If a test forgets to use `TestStateRedirect` and reads the real ~/Library, it can PASS locally (polluted state) but FAIL in CI (clean state).
   - Mitigation: `TestStateRedirectTests` itself asserts all major stores redirect.
   - **Lesson:** This is working as intended — the redirect is enforced at the source.

### No architecture-level flake observed:
- No async/await races (tests are synchronous).
- No time-sensitive waits (no `sleep`, no condition variables).
- No AppKit/UI state (all pure logic).
- No file-system races (temp-dir isolation).

---

## Rebuild notes — what day-1 test strategy should take from this

### 1. **Start with Tier 1 (headless-unit) — it's >90% of the value**
This batch shows pure logic can be extensively tested without a UI. Terminal grid, tmux topology, text transforms, theme import, PM graph — all verified on-host. The rebuild should:
- Build a rich pure-logic test suite for EVERY data model (Session, Workspace, Plugin, LSP, etc.).
- Keep those tests in the merge gate (host-side, fast).
- Push render/UI to T4/T5 (VM-only), but ONLY for pixels + interaction (not model validation).

### 2. **Adopt the temp-file + stub pattern for isolation**
- No test should read ~/Library or write to user directories.
- Stub external services (git, LSP, plugins) to assert dispatch + return values, not run the real thing.
- Pattern is proven across 30+ tests here; transfer it 1:1.

### 3. **Use SwiftTesting for new pure-logic tests**
- TextLineGeometryTests, TextToolRunnerTests, VectorOverlayHitTestTests show a clean pilot.
- Cleaner assertion syntax, better error messages, future-proof.
- Keep XCTest for (a) tier-based tests, (b) existing large suites to avoid churn.

### 4. **Build "teeth" into every test class**
- Every assertion must correspond to a realistic regression. A test that can't fail on the broken build is not a guard.
- Terminal grid tests fail if cursor clamping breaks.
- Tmux layout tests fail if stack-overflow guard is removed.
- Theme tests fail if hex parse diverges.
- **In rebuild:** deliberate negative-control switches (TSK-1134 pattern) for render-path tests that are hard to break locally.

### 5. **Layer test evidence: model + behavior + round-trip**
- Model layer: "can I construct this state?" (unit test).
- Behavior layer: "does this state transition work as expected?" (behavior test).
- Round-trip layer: "does serialize→deserialize preserve identity?" (integration test).
- Example: TerminalTabSetTests covers all three for tab CRUD.

### 6. **Golden tests for grammar/format stability**
- TreeSitterEngineGoldenTests shows substring-based golden patterns.
- Apply to: language/grammar changes (any vendor update), format/protocol changes (YAML/JSON/diff dialect).
- Pattern: assert specific substring gets tokenized as expected; grammar bump that changes the output fails loudly.

### 7. **Expect to rewrite tests as the model evolves, but the COVERAGE structure is durable**
- This batch's 72 tests cover ~8 architectural domains (terminal, text, tmux, spreadsheet, ui, diff, repo, util).
- Each domain's test count + file structure is roughly proportional to model complexity.
- In rebuild: plan for similar coverage density (3–5 files per domain), not fewer.

### 8. **Host-only tests should stay below 500ms (median ~100ms here)**
- No test in this batch takes >1s except benches (which are env-gated).
- Fast feedback is load-bearing: a slow test suite (>30s total) gets skipped locally.
- Pattern: avoid sleeps, avoid expensive fixtures, keep temps in memory when possible.

### 9. **Document the "why" of each test class in the doc comment**
- Every file in this batch has a TSK-### reference + a plain-English explanation.
- "Pure logic, host-testable" vs "render-tail, VM-only" is stated up front.
- **In rebuild:** copy this pattern; it helps future maintainers decide where to add a new test.

### 10. **Adopt test-state-redirect pattern from day 1**
- `TestStateRedirectTests` shows this is non-negotiable.
- Real ~/Library must never be touched by tests.
- The `MDVTestState-<uuid>` auto-redirect is cheap + effective.

---

## Summary table

| Aspect | Finding | Recommendation |
|--------|---------|-----------------|
| **Volume** | 72 files, ~7,200 LOC, 64 XCTest + 8 SwiftTesting | Sustainable; scale linearly with model complexity |
| **Coverage** | Terminal (17), Text (8), Tmux (9), Spreadsheet (3), UI (9), Diff (3), Repo (7), Util (11) | Domains well-balanced; each has 3–9 files proportional to interaction surface |
| **Tier** | 100% headless-unit (T1/T1m), zero T4/T5 | Pure-logic model tests on host; render/interaction on VM |
| **Flake risk** | Very low; isolation is tight, no async races, no UI state | Continue patterns; add negative-control gates for render tests |
| **Reusable infra** | Temp-file pattern, stub collaborators, state redirect, golden assertions, round-trip tests | Copy directly; proven across 30+ files |
| **Teeth proof** | High; every file has concrete regression cases (scroll clamping, dedupe, keyboard encoding, etc.) | Maintain; expand negative-control switches for VM-testable behaviors |
| **Ready for rebuild?** | Yes; structure + patterns are production-grade and transferable | Start with model-layer tests using same patterns; defer render to T4/T5 |

