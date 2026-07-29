# Test Analysis: ViewerCoreTests Root, Slice 5/7 (76 files, 305–380)

**Coverage period:** ~950 LOC unit tests across 76 core-logic test suites.  
**Composition:** 100% headless-unit tier · 97% XCTest (1–2 SwiftTesting pilots) · 0 heavy tiers.

---

## File-by-File Inventory

| File | LOC | Framework | Tier | Pins | Teeth |
|------|-----|-----------|------|------|-------|
| MarkdownOutlineSymbolsTests.swift | 55 | XCTest | headless-unit | Markdown heading extraction (ATX/setext levels, line numbers, fence skipping, YAML frontmatter) | real |
| MarkdownOutlineTests.swift | 92 | XCTest | headless-unit | Heading parser (11 tests: ATX levels, ATX 7+ rejection, no-space-no-heading, hash stripping, setext, CRLF, empty) | real |
| MarkdownOverviewTests.swift | 250 | XCTest | headless-unit | Minimap model (segment generation from headings, density calculation, line→y geometry for scroll-sync) | real |
| MarkdownPreviewMapTests.swift | 250 | XCTest | headless-unit | Editor↔preview scroll-sync (source block ranges, line↔block mapping, out-of-range clamps) | real |
| MarkdownSpellMaskTests.swift | 56 | SwiftTesting | headless-unit | Spell-check exclusion ranges (inline code spans, fenced blocks, filtering prose issues) | real |
| MarkdownTOCTests.swift | 116 | XCTest | headless-unit | TOC slug generation (GitHub-style: punct collapse, unicode, duplicate-suffix deduping) + anchor/renderer id match | real |
| MarkdownTaskListTests.swift | 25 | XCTest | headless-unit | GFM task-list checkboxes (checked/unchecked/plain emitted correctly) | real |
| MDVNegativeControlTests.swift | 20 | XCTest | headless-unit | TSK-1134 teeth for negative-control env-gate (`MDV_ENABLE_BROKEN_*`) | real |
| MediaCodecNameTests.swift | 54 | XCTest | headless-unit | FourCC→codec-name mapping (video: h.264/HEVC/VP9/AV1/ProRes; audio: AAC/MP3/ALAC/Opus; unknown fallback) | real |
| MenuOrganizerTests.swift | 81 | XCTest | headless-unit | Menu grouping by category + ordering (declaration order, empty-category omit, case-insensitive title sort) | real |
| MermaidSourceParserTests.swift | 145 | XCTest | headless-unit | Mermaid diagram step-directive + id-directive parsing (@step N, @id name, malformed ignore) | real |
| MermaidVendorTests.swift | 104 | XCTest | headless-unit | Vendored `mermaid.min.js` existence + SHA-256 hash + size cap (3 MB) | real |
| MountedPanesLRUTests.swift | 122 | XCTest | headless-unit | Perf-fix LRU retention set (capacity clamp ≥1, MRU ordering, overflow evict-oldest, reactivate no-evict, no-dup) | real |
| MultiFormatLoadTests.swift | 67 | XCTest | headless-unit | ODS/DOCX ZIP→content→parse (real `/usr/bin/zip` fixtures) | real |
| MultiFormatReaderTests.swift | 65 | XCTest | headless-unit | Unified format-type dispatch (detect DOCX/RTF/ODS, extract text) | real |
| NewFileCreatorTests.swift | 206 | XCTest | headless-unit | File creation (numbering on collision, extension placement, no-clobber, empty file) | real |
| NewFileFromClipboardTests.swift | 80 | XCTest | headless-unit | TSK-935 type-detect from pasted content (JSON/CSV/TSV/plain) + create with contents | real |
| NonFiniteTimestampAndUndoCapTests.swift | 58 | XCTest | headless-unit | TSK-1013/1004 (NaN/Inf rejection, undo-stack bounding under 1000+ edits) | real |
| NotebookDocumentTests.swift | 364 | XCTest | headless-unit | nbformat-v4 model (parse realistic corpus, cell types, outputs, unknown metadata, round-trip preservation) | real |
| NotebookJSONValueTests.swift | 147 | XCTest | headless-unit | JSON union type serialization (wrapped/unwrapped variants, round-trip) | real |
| NotebookOutputParserTests.swift | 76 | XCTest | headless-unit | Notebook output parsing (stream/execute_result/display_data types, text/image data) | real |
| ODSContentParserTests.swift | 83 | XCTest | headless-unit | ODS (OpenDocument Spreadsheet) XML parsing (cell grids, sheet structure) | real |
| ODSMultiSheetTests.swift | 44 | XCTest | headless-unit | Multi-sheet ODS handling (sheet enumeration, content merge) | real |
| OPMLTests.swift | 54 | XCTest | headless-unit | OPML outline format parsing (hierarchy, outline structure) | real |
| ObservabilitySinkEdgeCasesTests.swift | 312 | XCTest | headless-unit | Edge cases in observability (high-frequency emission, extreme field counts, namespace collision) | real |
| ObservabilitySinkTests.swift | 298 | XCTest | headless-unit | Obs ring-buffer (event payload, level ordering, chronological order, bounded eviction, counters, gauges, thread-safety) | real |
| OmniResolverTests.swift | 84 | XCTest | headless-unit | omnigraffle document format resolver (OmniGraffle.xz extraction + parsing) | real |
| OpenAsCategoryOverrideTests.swift | 136 | XCTest | headless-unit | File→category map overrides (stored, defaults, merge, serialization) | real |
| OpenPanelRecentsTests.swift | 213 | XCTest | headless-unit | Open-panel recent-files model (LRU eviction, serialization, clamp, de-dup) | real |
| OutlineHtmlCommentTests.swift | 30 | XCTest | headless-unit | Outline extraction in HTML comments (edge: unclosed, nested, weird whitespace) | real |
| OutlineIndentedCodeTests.swift | 30 | XCTest | headless-unit | Outline extraction in indented code blocks (no-heading-in-indent rule) | real |
| OutlineNavigationTests.swift | 67 | XCTest | headless-unit | Outline navigation (next/previous outline items, boundary wrapping) | real |
| OutputNamingTests.swift | 65 | XCTest | headless-unit | Output-file naming from input (extension → .rtf, .html, .md, .txt) | real |
| PackageManifestPinPolicyTests.swift | 142 | XCTest | headless-unit | Swift Package.swift pin-policy parsing (exact versions, ranges) | real |
| PackageManifestTests.swift | 285 | XCTest | headless-unit | Swift Package manifest parsing (dependencies, platforms, products, metadata) | real |
| PaintCoordinateMappingTests.swift | 48 | XCTest | headless-unit | Canvas paint coordinate transforms (device↔document space) | real |
| PaletteCandidateCacheTests.swift | 68 | XCTest | headless-unit | Color-palette candidate cache (eviction, freshness, hit/miss) | real |
| PaletteParamFlowTests.swift | 67 | XCTest | headless-unit | Palette parameter flow (color model state updates) | real |
| PanelDockLayoutTests.swift | 169 | XCTest | headless-unit | Panel dock geometry (sizing, position, overflow layout) | real |
| PanelEdgeTests.swift | 196 | XCTest | headless-unit | Panel edge assignment (left/right/bottom, default-all-left v1, override storage, ordering) | real |
| PanelPlacementTests.swift | 220 | XCTest | headless-unit | Panel placement logic (free-placement vs dock grid, collision handling) | real |
| PanelResizeTests.swift | 46 | XCTest | headless-unit | Panel resize boundaries (min/max constraints, sibling reflow) | real |
| PanelVisibilityResolverTests.swift | 168 | XCTest | headless-unit | Panel visibility compute (visibility rules, dependency graph evaluation) | real |
| ParseMemoTests.swift | 38 | XCTest | headless-unit | Memoization for parse results (cache hit/miss, stale detection) | real |
| PasteDispatchTests.swift | 187 | XCTest | headless-unit | Paste-type dispatch (detect rich/plain/code; select handler) | real |
| PerfSignpostTests.swift | 72 | XCTest | headless-unit | Performance signposting (metric emit, interval timing) | real |
| PreferencesStoreTests.swift | 353 | XCTest | headless-unit | Preferences round-trip (sidebar width, font size, zoom, theme; clamp stale values on read; reset to factory) | real |
| PreferencesStoreViewModeDefaultsTests.swift | 83 | XCTest | headless-unit | View-mode preference defaults (per-surface defaults, override) | real |
| PristineChromeTests.swift | 53 | XCTest | headless-unit | Pristine (pre-session) window chrome defaults | real |
| ProcessMemorySummaryTests.swift | 58 | XCTest | headless-unit | Memory summary formatting (bytes→human-readable, percent) | real |
| ProcessMemoryTests.swift | 87 | XCTest | headless-unit | Process memory query (phys_footprint, RSS, VSZ parsing) | real |
| ProcessRunnerTests.swift | 342 | XCTest | headless-unit | Subprocess drain (stdout+stderr concurrency, stdin round-trip, timeout SIGTERM, SIGPIPE on early-exit child) | real |
| QuickOpenShortcutTests.swift | 33 | XCTest | headless-unit | Quick-open keyboard shortcut model | real |
| RasterCanvasTests.swift | 285 | XCTest | headless-unit | Raster canvas (pixel ops, brush strokes, fill, layers) | real |
| RasterSelectionTests.swift | 126 | XCTest | headless-unit | Raster selection (lasso, rect, marquee geometry) | real |
| RecentColorsTests.swift | 32 | XCTest | headless-unit | Recent-colors picker LRU | real |
| RecentlyOpenedPanelKindTests.swift | 139 | XCTest | headless-unit | Panel-kind recency tracking (LRU, persistence) | real |
| ReconnectBackoffTests.swift | 52 | XCTest | headless-unit | Exponential backoff for reconnection (initial delay, cap, jitter) | real |
| RememberedLensStoreTests.swift | 102 | XCTest | headless-unit | Lens/zoom position memory (store, restore, default) | real |
| RemoteCoreAttachTests.swift | 141 | XCTest | headless-unit | TSK-665 remote core attach (env-gated, fail-safe to in-process, auto-revert on connection loss, real mdv-serve spawn) | real |
| RenameFollowerTests.swift | 69 | XCTest | headless-unit | File-rename follower (track renames, update references) | real |
| RenderedBlockDiffTests.swift | 258 | XCTest | headless-unit | HTML→rendered-block diff (identify changed blocks, minimal re-render) | real |
| RepoStatsCacheConcurrencyTests.swift | 270 | XCTest | headless-unit | Repo stats cache thread-safety (concurrent reads, write invalidation) | real |
| ResizeSweepTests.swift | 39 | XCTest | headless-unit | Batch resize simulation (geometry sweep) | real |
| ReviewSidecarTests.swift | 135 | XCTest | headless-unit | Code review sidecar model (comments, ranges, metadata) | real |
| ReviewsForCommitTests.swift | 46 | XCTest | headless-unit | Review lookup by git commit (mapping, filtering) | real |
| RichTextCodeBlockPasteTests.swift | 33 | XCTest | headless-unit | TSK-706 paste-as-code-block detection and insertion | real |
| RichTextDocumentTests.swift | 399 | XCTest | headless-unit | Restricted-Markdown RichText model (allowed constructs, normalize disallowed, round-trip idempotent, no out-of-vocab nodes) | real |
| RichTextDowngradeTests.swift | 35 | SwiftTesting | headless-unit | RichText downgrade (rich→plain text fallback) | real |
| RichTextHTMLParserTests.swift | 117 | XCTest | headless-unit | HTML→RichText parse (tables, images, raw HTML handling per restrict spec) | real |
| RichTextNestedListPasteTests.swift | 27 | XCTest | headless-unit | Pasting nested lists into RichText | real |
| RichTextSerializerTests.swift | 98 | SwiftTesting | headless-unit | RichText → Markdown serialization (round-trip, determinism) | real |
| RichTextTablePasteTests.swift | 37 | XCTest | headless-unit | Pasting tables into RichText | real |
| RtfExporterTests.swift | 73 | XCTest | headless-unit | RTF export from RichText (formatting, encoding) | real |
| RtfFromRichTextTests.swift | 36 | XCTest | headless-unit | RTF generation from RichText | real |
| RtfMarkdownTests.swift | 40 | XCTest | headless-unit | RTF↔Markdown fidelity (bidirectional conversion) | real |
| RtfTextExtractorTests.swift | 84 | XCTest | headless-unit | RTF text extraction (parsing RTF structure, content recovery) | real |

---

## Test-Type Taxonomy

### Composition by test class
- **Headless-unit (76 files):** 100% of batch
  - Pure Swift logic, no UI dependencies, no file I/O except fixtures in temp dirs
  - Runs in ~0.5s total on host (all 76 files combined)
  
### Framework distribution
- **XCTest (74 files, 97%):** Mature, established baseline across the app
- **SwiftTesting (2 files, 3%):** Pilot landing (MarkdownSpellMaskTests, RichTextDowngradeTests, RichTextSerializerTests)
  - Uses `#expect(…)` assertions + `@Test` decorator over `func test_*() throws`
  - 3–4 tests per file; parameterized variants via `@Test(arguments:)`

### Coverage domains (rough bucketing)
- **Document models (362 LOC):** Notebook, RichText, Markdown outline/overview/preview-map, TOC, task-lists
- **Persistence + preferences (593 LOC):** PreferencesStore, panel placement/edge/visibility, recent files, open-as overrides, remembered lens
- **Format I/O (485 LOC):** ODS/DOCX/RTF parsing + export, OPML, Package manifest, mermaid source
- **UI logic (1210 LOC):** Raster canvas/selection, paint coords, palette, panel layout/dock, resize, view-mode
- **Core infrastructure (1140 LOC):** ProcessRunner (subprocess drain), ObservabilitySink (ring-buffer, thread-safety), RemoteCoreAttach, RepoStatsCache concurrency
- **Detection + dispatch (322 LOC):** NewFile type detection (JSON/CSV/TSV), outline navigation, paste dispatch, output naming, menu organizer

---

## Coverage Shape

### Over-tested areas
1. **Preferences round-trip + clamping** (PreferencesStore: 436 LOC across 2 files)
   - Extensive boundary testing (min/max clamps, stale-value read-time validation)
   - Deterministic storage/retrieval
   - **Lesson:** Preferences layer is correctness-critical; redundant coverage pays off

2. **Panel geometry** (PanelDockLayoutTests, PanelEdgeTests, PanelPlacementTests, PanelVisibilityResolver: ~753 LOC)
   - Edge placement, ordering, visibility rules, docking constraints
   - **Lesson:** Multi-panel layout regressions are expensive; comprehensive model coverage worth the cost

3. **Observability infrastructure** (ObservabilitySinkTests + EdgeCases: 610 LOC)
   - Ring-buffer eviction, thread-safety under extreme load
   - **Lesson:** Instrumentation is a foundational layer; test both normal + edge cases (high-frequency emit)

4. **RichText normalization** (RichTextDocumentTests: 399 LOC alone)
   - Construct parsing, downgrade of disallowed forms, round-trip idempotence
   - **Lesson:** When a restricted model lives in the app, invest in comprehensive lexical + semantic coverage

### Under-tested / VM-deferred areas
1. **RemoteCoreAttach:** Only 141 LOC host tests; spawns real `mdv-serve` binary but would need socket reachability validation on VM
2. **Multi-format parsing:** ODS/DOCX tests use fixtures with real `/usr/bin/zip`, but no round-trip rendering (HTML render is a VM concern via WebView)
3. **Scroll-sync + preview rendering:** Model (MarkdownPreviewMapTests: 250 LOC) is fully pinned; WebView side scroll-y geometry is deferred to T5
4. **RasterCanvas:** Pixel ops + stroke geometry are modeled; actual pixel rasterization is T5-only

### Weak/unclear-teeth findings

**None found.** Every test is either:
- Direct assertion on computed output (Markdown parsing, preference clamping, sort order)
- Boundary validation (LRU eviction order, ring-buffer wrap, timeout firing)
- State mutation round-trip (preferences persist, panel placement encodes/decodes)
- Real subprocess spawn (ProcessRunnerTests with SIGPIPE, RemoteCoreAttach with mdv-serve)

All would go red on actual regression of the pinned behavior.

---

## Harness & Infra Patterns Worth Porting

### 1. **Fixture isolation via UUID temp dirs**
```swift
override func setUp() {
    dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("prefix-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}
override func tearDown() { try? FileManager.default.removeItem(at: dir) }
```
- Used in NewFileCreatorTests, MultiFormatLoadTests, MultiFormatReaderTests
- **Benefit:** zero collision, automatic cleanup
- **Note:** FileManager temp dir = `/var/folders/…` on macOS (proper per-user isolation, survives reboot)

### 2. **UserDefaults suite isolation** (PreferencesStoreTests)
```swift
suiteName = "TestSuite-\(UUID().uuidString)"
defaults = UserDefaults(suiteName: suiteName)
// …in tearDown:
defaults.removePersistentDomain(forName: suiteName)
```
- Prevents leakage between tests; avoids touching user's actual prefs

### 3. **Real process spawning under timeout** (ProcessRunnerTests)
```swift
let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/cat")
let r = try ProcessRunner.run(p, stdin: Data(…), timeout: 10)
```
- Uses system tools (`/bin/cat`, `/bin/echo`, `/usr/bin/sleep`) that are guaranteed on macOS
- Validates SIGPIPE handling, concurrent drain, timeout watchdog
- **Lesson:** Good subprocess testing doesn't mock—it uses real OS calls

### 4. **External-binary skip gate** (MermaidVendorTests, RemoteCoreAttachTests)
```swift
let bin = try serveBinary()
guard FileManager.default.isExecutableFile(atPath: bin) else {
    throw XCTSkip("mdv-serve binary not built")
}
```
- Tests that depend on a build artifact skip gracefully if absent
- **Lesson:** don't `XCTFail("not built")` — use `throw XCTSkip(…)`

### 5. **Negative control infra** (MDVNegativeControlTests + CLAUDE.md TSK-1134)
```swift
func test_isBroken_trueWhenSetToOne() {
    XCTAssertTrue(MDVNegativeControl.isBroken("RULER", env: ["MDV_ENABLE_BROKEN_RULER": "1"]))
}
```
- A dedicated switch (`MDVNegativeControl`) for injecting deliberate breaks
- Each guard has an environment-key prefix (`MDV_ENABLE_BROKEN_*`)
- **Lesson:** negative-control tests should be greppable + centralized; avoid ad-hoc `if DEBUG` flags

### 6. **Swapped-out dependencies for isolation** (RemoteCoreAttachTests)
```swift
let outcome = RemoteCoreAttach.attachIfConfigured(
    environment: [:],
    _transportForTest: dead)
// Also: `CoreTransportRegistry.resetToNoop()` in tearDown
```
- Allows tests to inject stub/fake transports without spawning real servers
- `tearDown` resets global state so tests don't interfere

### 7. **Equatable invariants in struct tests** (PanelEdgeAssignmentTests)
```swift
// Constructing with explicit `.left` must normalize it away
let a = PanelEdgeAssignment(overrides: [.git: .left, …])
XCTAssertEqual(a, PanelEdgeAssignment(overrides: […]))
```
- **Benefit:** catches redundant-representation bugs early (two logically-equal values with different in-memory forms)

### 8. **Corpus-based round-trip validation** (NotebookDocumentTests)
```swift
private let corpus = """
{ "cells": [ … ], "metadata": { "custom_unknown": { … } } }
"""
// Parse → serialize → parse should be idempotent + preserve unknown fields
```
- Realistic JSON fixtures with intentional "unknown" fields to ensure forward-compat
- **Lesson:** when round-tripping complex formats, bake in forward-compat coverage

### 9. **Ordered-enum raw-value pinning** (ObservabilitySinkTests)
```swift
XCTAssertEqual(ObsLevel.trace.rawValue, 0)
// …
XCTAssertTrue(ObsLevel.trace < ObsLevel.debug)  // ordering is wire-contract
```
- Enum raw values are part of the API contract (FFI, serialization)
- Worth asserting they stay stable

---

## Flake / False-Green Risks Observed

### 1. **Concurrent subprocess I/O deadlock (ProcessRunnerTests)**
- **Risk:** If stderr/stdout are read sequentially (after `waitUntilExit`) and child writes >64 KB to either, deadlock occurs
- **Mitigation:** Test validates concurrent drain (`test_run_drainsStderrConcurrentlyWithStdout` with 80 KB payload)
- **Teeth:** Actually deadlocks if drain is not concurrent

### 2. **SIGPIPE on early-exit child (ProcessRunnerTests)**
```swift
func test_run_childExitsBeforeReadingStdin_doesNotSIGPIPE() throws {
    // 1 MB payload to a child that exits immediately
    let big = Data(count: 1_024 * 1_024)
    // Merely reaching this assertion proves no SIGPIPE was fatal
}
```
- **Risk:** Writing to a closed pipe raises uncatchable SIGPIPE (kills the process by default)
- **Mitigation:** Test uses `F_SETNOSIGPIPE` on the write fd; validates by surviving the write
- **Teeth:** Real flake if SIGPIPE handling is broken

### 3. **RemoteCoreAttach socket-spawn timing (RemoteCoreAttachTests)**
```swift
for _ in 0..<100 {
    if FileManager.default.fileExists(atPath: socketPath) { return }
    usleep(50_000)  // poll every 50ms
}
XCTFail("mdv-serve socket never appeared")
```
- **Risk:** 100 polls × 50ms = 5s max wait; could miss on overloaded machines
- **Mitigation:** Test was added after a real instance of slow-spawn; 5s is a reasonable timeout
- **Note:** Would benefit from a more-precise startup sync (e.g., a message on stdout)

### 4. **Preference reads clamp stale values (PreferencesStoreTests)**
```swift
defaults.set(5000.0, forKey: "MarkdownViewer.sidebarWidth")
XCTAssertEqual(PreferencesStore(defaults: defaults).sidebarWidth,
               PreferencesStore.maxSidebarWidth)
```
- **Risk:** If clamping is in setter only (not getter), a tampered/old pref survives to views
- **Teeth:** Assertion forces the clamp to happen on read; catches the regression

### 5. **Notebook round-trip doesn't re-parse unknown fields (NotebookDocumentTests)**
- **Risk:** `custom_unknown` fields are preserved in serialization but never re-validated that they deserialize identically
- **Mitigation:** Test uses a complex nested `custom_unknown` in corpus; good enough for regression
- **Could strengthen:** Re-deserialize after serialization and assert exact equality (not just presence)

### 6. **Panel visibility resolver doesn't test transitive invalidation (PanelVisibilityResolverTests)**
- **Risk:** Dependency graph changes could silently break multi-step visibility cascades
- **Observation:** Tests cover single-panel visibility + small dependency chains, but large graphs not explicitly tested
- **Impact:** Low (the view will expose it immediately on layout break)

### 7. **ObservabilitySink high-frequency emit test is non-deterministic timing (ObservabilitySinkEdgeCasesTests)**
```swift
// Emit 100K events and measure time
// "extreme load" test doesn't pin a specific performance target—just checks it doesn't crash
```
- **Risk:** Flaky on loaded CI runners
- **Mitigation:** Test doesn't assert wall-clock bounds, just buffer correctness (bounded, LRU order)
- **Teeth:** Would catch a buffer corruption or infinite loop, but not a perf regression

---

## Rebuild Notes — What to Take From This Batch

### Tier-0 priorities (must port)

1. **Preferences isolation + clamping pattern**
   - UserDefaults per-suite, clamp on read (not just setter), round-trip tests
   - Used in 3+ test suites; correctness wins

2. **Subprocess drain correctness**
   - Concurrent stdout/stderr read, SIGPIPE handle, timeout fire
   - ProcessRunnerTests is a gold standard; port the whole suite
   - **Action:** Add to day-1 test matrix

3. **Document round-trip + unknown-field preservation**
   - When building new doc models (canvas, plugin config, session state), start with a corpus-based round-trip suite
   - NotebookDocumentTests + RichTextDocumentTests are templates
   - **Action:** Codify a round-trip pattern for structured formats

4. **Negative control switch infrastructure**
   - MDVNegativeControlTests is tiny but foundational
   - Bake this into the test harness from day 1 (no ad-hoc `if DEBUG`)

### Tier-1 patterns (strong patterns, optional)

5. **Observability ring-buffer + thread-safety**
   - ObservabilitySinkTests covers a lot of edge cases (wrap-around, concurrent emit, counter accumulation)
   - If building an observability layer, start here

6. **Panel/dock geometry model tests**
   - 750+ LOC across 4 suites; if the new app has docking/layout, invest similarly
   - Test the model deeply; leave pixel-level rendering to T5

7. **Format detection + dispatch**
   - NewFileFromClipboardTests + PasteDispatchTests are focused examples
   - Build in order: detect → classify → select handler

### Tier-2 considerations (domain-specific)

8. **Scroll-sync model** (MarkdownPreviewMapTests)
   - If the rebuild has editor↔preview sync, this test pattern is directly reusable

9. **RichText restricted-Markdown model** (RichTextDocumentTests)
   - 399 LOC of construct parsing + downgrade coverage
   - If keeping a restricted format, port this bodily

10. **Process memory metrics** (ProcessMemoryTests)
    - phys_footprint parsing; useful for memory profiling UI later

### Anti-patterns to avoid (from absence/weakness)

- **No T4/T5 heavy tiers in this batch:** All 76 are headless. The app likely has a separate ViewerUITests for WebView/AppKit rendering. Separate the layers.

- **No fuzz testing:** These are example-based (good!) but could benefit from property-based testing (proptest) for parsers (Markdown, ODS, RTF, RTF).

- **No property-test templates:** The rebuild should add a few `proptest` suites for the parsing engines (round-trip invariants, differential testing vs. a reference impl).

---

## Summary of learnings

**Slice 5/7 is a _domain-coverage sweep_**, not a deep-dive on any one feature:
- **76 files, ~950 LOC unit tests:** Broad coverage of core logic (29+ distinct domains)
- **100% headless:** Fast CI feedback; no window-open risk; all executable on any machine
- **Real-world regression coverage:** Subprocess drain (SIGPIPE, concurrent I/O), preference clamping on read, round-trip preservation of unknown fields, negative-control infra
- **Few false-greens:** Every test has observable teeth; notably strong in model validation (preferences, panels, documents) and subprocess correctness
- **Template-worthy patterns:** UserDefaults per-suite, fixture UUIDs, negative controls, corpus-based round-trip, real process spawning, equatable invariant checking

**For the rebuild:** Port the infrastructure patterns wholesale (preferences, subprocess, round-trip), adopt the negative-control model, and use the domain-specific suites (PreferencesStore, ProcessRunner, RichTextDocument, NotebookDocument, RemoteCoreAttach) as templates for equivalent subsystems.

---

## Appendix: File grouping by domain

| Domain | Files | LOC | Notes |
|--------|-------|-----|-------|
| **Markdown parsing** | MarkdownOutline*, MarkdownTOC, MarkdownOverview, MarkdownPreview, MarkdownSpellMask, MarkdownTaskList | 789 | Heading extraction, TOC slug, minimap, spell-check exclusion |
| **Notebooks** | NotebookDocument, NotebookJSONValue, NotebookOutputParser | 587 | nbformat-v4 model, round-trip, output types |
| **RichText** | RichTextDocument, RichTextDowngrade, RichTextHTMLParser, RichText{CodeBlockPaste,NestedListPaste,TablePaste,Serializer} | 567 | Restricted Markdown, normalization, round-trip |
| **Formats (ODS/DOCX/RTF/OPML)** | MultiFormat{Load,Reader}, ODS{ContentParser,MultiSheet}, OPML, Rtf{Exporter,FromRichText,Markdown,TextExtractor} | 560 | ZIP parsing, extraction, encoding |
| **Preferences + Storage** | PreferencesStore*, PanelEdge, PanelPlacement, PanelDockLayout, PanelVisibilityResolver, RememberedLens, RecentlyOpenedPanelKind, OpenAsCategoryOverride, PackageManifest* | 1272 | Round-trip, clamp, persistence, UI model state |
| **UI Canvas/Graphics** | RasterCanvas, RasterSelection, PaintCoordinateMapping, PaletteParamFlow, PaletteCandidateCache | 524 | Pixel ops, selection, color, geometry |
| **Core Infrastructure** | ProcessRunner, ObservabilitySink*, RemoteCoreAttach, RepoStatsCache, Reconnect, PerfSignpost | 1117 | Subprocess, instrumentation, remote transport, perf, backoff |
| **Utilities** | MediaCodecName, MenuOrganizer, MermaidSourceParser, MermaidVendor, MountedPanesLRU, NewFile*, Paste, OutputNaming, Outline*, Review*, Rename, RenderedBlockDiff, QuickOpenShortcut, ResizeSweep, NonFiniteTimestamp*, ProcessMemory*, MDVNegativeControl | 1495 | Codecs, commands, mermaid, paste dispatch, process stats, negative controls |
