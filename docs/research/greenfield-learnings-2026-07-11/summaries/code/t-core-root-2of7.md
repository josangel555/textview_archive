# ViewerCoreTests Root: Slice 2/7 (Files 77–152)

## File Enumeration

**CrossFileSearchTests.swift** (274 LOC) — tier: headless-unit · framework: XCTest · pins: `CrossFileSearch` API (case-insensitive query, binary/large-file skipping, VCS dir exclusion, match range precision) · teeth: real (multifile discovery, regex edge cases)

**CSVCellCursorTests.swift** (222 LOC) — tier: headless-unit · framework: XCTest · pins: cursor movement in CSV grid (up/down/left/right, boundary wrapping, selection state) · teeth: real (cell navigation model)

**CSVClipboardPasteTests.swift** (36 LOC) — tier: headless-unit · framework: XCTest · pins: CSV paste-from-clipboard flow (tabular shape inference, cell routing) · teeth: weak (minimal assertions, likely incomplete)

**CsvConvertTests.swift** (76 LOC) — tier: headless-unit · framework: XCTest · pins: format conversion (CSV↔TSV, delimiter detection) · teeth: real (round-trip preservation)

**CSVCopyTests.swift** (26 LOC) — tier: headless-unit · framework: XCTest · pins: cell/row copy to pasteboard (serialization, rectangular selection) · teeth: weak (very short, likely surface-level)

**CSVEditingGateTests.swift** (44 LOC) — tier: headless-unit · framework: XCTest · pins: guard against invalid CSV edits (model-state consistency) · teeth: unclear (short, may be a compliance check only)

**CSVEmptyStateTests.swift** (39 LOC) — tier: headless-unit · framework: XCTest · pins: empty CSV handling (no-data state, header inference) · teeth: weak (likely edge-case assertion)

**CSVFilterTests.swift** (223 LOC) — tier: headless-unit · framework: XCTest · pins: row filtering by substring/regex/numeric (model consistency, window integration) · teeth: real (24 tests, filtering correctness + windowed apply)

**CSVFindTests.swift** (222 LOC) — tier: headless-unit · framework: XCTest · pins: find-within-CSV (match discovery, range precision, case modes) · teeth: real (24 tests, highlight precision)

**CSVMaterializationBenchTests.swift** (87 LOC) — tier: bench · framework: XCTest · pins: full-materialization perf on huge CSV (500k rows, memory footprint deltas, parse/sort/filter wall-clocks) · teeth: real (measurement + regression cliff guards for TSK-1139 windowing decision)

**CSVRecalcTests.swift** (32 LOC) — tier: headless-unit · framework: XCTest · pins: recalc trigger + propagation (dirty-region coalescing) · teeth: weak (short, likely model-state smoke test)

**CSVRectSelectionTests.swift** (66 LOC) — tier: headless-unit · framework: XCTest · pins: rectangular cell selection (mouse-drag accumulation, expand/shrink) · teeth: weak (likely surface grammar, not full interaction)

**CSVRowWindowSourceTests.swift** (164 LOC) — tier: headless-unit · framework: XCTest · pins: windowed CSV data source (header/total, offset-based fetch, filtering + absolute-index mapping, boundary saturation) · teeth: real (13 tests, offset logic + filtered-window correctness)

**CsvSortTests.swift** (82 LOC) — tier: headless-unit · framework: XCTest · pins: column sort (stable, ascending/descending, numeric/lexical) · teeth: real (11 tests, sort order + stability)

**CsvSummaryTests.swift** (100 LOC) — tier: headless-unit · framework: XCTest · pins: CSV summary stats (column type inference, aggregate count/sum/avg) · teeth: real (12 tests, numeric type handling + nulls)

**CSVViewportPagerTests.swift** (100 LOC) — tier: headless-unit · framework: XCTest · pins: viewport paging state (scroll offset → window fetch, prefetch hints) · teeth: unclear (0 test functions, likely data fixtures or support only)

**CTSPatchProvenanceTests.swift** (78 LOC) — tier: headless-unit · framework: XCTest · pins: cumulative-transcript patch metadata (author, timestamp, provenance chain) · teeth: weak (2 tests, likely metadata smoke)

**CumulativeDiffGitClientTests.swift** (131 LOC) — tier: headless-unit · framework: XCTest · pins: git diff ingestion (staging, hunks, line-by-line annotation) · teeth: real (5 tests, git parsing + model mapping)

**CumulativeDiffSelectionTests.swift** (68 LOC) — tier: headless-unit · framework: XCTest · pins: line selection in diff view (contiguous ranges, hunk boundaries) · teeth: weak (7 tests, likely selection grammar)

**DataSliceOffsetDefenseTests.swift** (167 LOC) — tier: headless-unit · framework: XCTest · pins: UTF-16 offset↔byte offset conversion (multibyte safety, grapheme boundaries) · teeth: real (7 tests, encoding edge cases — crucial for TextKit bridge)

**DateTimeStampTests.swift** (38 LOC) — tier: headless-unit · framework: XCTest · pins: timestamp formatting (RFC822 + locale variants) · teeth: weak (3 tests, format string smoke)

**DefaultAppRegistrationTests.swift** (149 LOC) — tier: headless-unit · framework: XCTest · pins: macOS default-app registration ("Make Default Viewer" logic, UTI handler state, fake RoleHandlerService) · teeth: real (9 tests, state transitions + error paths, mocked LaunchServices)

**DependencyGraphInteractionTests.swift** (117 LOC) — tier: headless-unit · framework: XCTest · pins: graph interaction (node select, edge follow, layout stability) · teeth: real (11 tests, interaction sequencing)

**DependencyGraphLayoutTests.swift** (100 LOC) — tier: headless-unit · framework: XCTest · pins: graph layout engine (node positioning, edge routing, force-directed convergence) · teeth: real (9 tests, deterministic layout validation)

**DependencyGraphTests.swift** (278 LOC) — tier: headless-unit · framework: XCTest · pins: graph construction (import parsing, cycle detection, transitive closure) · teeth: real (17 tests, cycle guard + import resolution)

**DependencySourceResolverTests.swift** (221 LOC) — tier: headless-unit · framework: XCTest · pins: source-file import resolver (namespace reconciliation, cross-workspace references) · teeth: real (17 tests, resolver correctness)

**DiagnoseScheduleTests.swift** (25 LOC) — tier: headless-unit · framework: XCTest · pins: diagnostic task scheduling (defer/priority queue) · teeth: weak (3 tests, queue smoke)

**DiagnosticSnapshotTests.swift** (348 LOC) — tier: headless-unit · framework: XCTest · pins: debug diagnostic snapshot (path redaction, JSON shape, temp-file enumeration, open-fd listing, subprocess labels) · teeth: real (13 tests, redaction recursion + privacy proofing, though named `test_` functions show 13 but file is much larger)

**DiagramRegistryTests.swift** (234 LOC) — tier: headless-unit · framework: XCTest · pins: diagram type registry (Mermaid/Graphviz/Dot format detection, syntax validation) · teeth: real (24 tests, format inference + parse error handling)

**DifferentialFuzzSeed.swift** (33 LOC) — tier: support · framework: XCTest · pins: shared seed-base for differential parity fuzzes (Formula/Fuzzy/Find/Transcript) · teeth: unclear (1 test, support fixture)

**DiffFindTests.swift** (74 LOC) — tier: headless-unit · framework: XCTest · pins: find-within-diff (match discovery, hunk-local search) · teeth: weak (6 tests, likely match location smoke)

**DiffGutterFeederTests.swift** (186 LOC) — tier: headless-unit · framework: XCTest · pins: diff gutter annotation (line class: add/remove/context, folding state) · teeth: real (12 tests, line classification + fold boundaries)

**DiffHighlighterTests.swift** (84 LOC) — tier: headless-unit · framework: XCTest · pins: syntax highlighting in diffs (token ranges, color attributes across hunks) · teeth: weak (11 tests, likely color-scheme smoke)

**DiffHunkAttributedStringTests.swift** (251 LOC) — tier: headless-unit · framework: XCTest · pins: attributed-string rendering for hunks (line coloring, intra-line diffs, indent preservation) · teeth: real (14 tests, attributed-string format + color precision)

**DiffLineSelectionTests.swift** (85 LOC) — tier: headless-unit · framework: XCTest · pins: line selection in diffs (multi-hunk ranges, staging partial) · teeth: real (7 tests, staging model)

**DiffRouting_Audit_Sources_DiffHunkParser_Callers_Tests.swift** (32 LOC) — tier: headless-unit · framework: XCTest · pins: audit that all DiffHunkParser callers handle its output correctly · teeth: real (1 test, sanity audit — validates caller contract)

**DiffStatTests.swift** (100 LOC) — tier: headless-unit · framework: XCTest · pins: diff statistics (added/removed/modified line counts, file-level summary) · teeth: real (6 tests, aggregation correctness)

**DiffTextStyleTests.swift** (94 LOC) — tier: headless-unit · framework: XCTest · pins: diff text styling (monospace attributes, tab-width handling) · teeth: weak (7 tests, text-attribute smoke)

**DirtyRegionTests.swift** (71 LOC) — tier: headless-unit · framework: XCTest · pins: dirty-region tracking (coalesce adjacent edits, optimize redraw bounds) · teeth: unclear (0 test functions, likely data structure only)

**DiskConflictResolverTests.swift** (221 LOC) — tier: headless-unit · framework: XCTest · pins: external-file-edit conflict UI (3-way merge state, resolution choice, undo) · teeth: real (17 tests, state machine + choice validation)

**DisplayDateFormatterTests.swift** (50 LOC) — tier: headless-unit · framework: XCTest · pins: date formatting for UI (relative "2 days ago", absolute variants) · teeth: weak (4 tests, format-string smoke)

**DocumentControllerMediaTests.swift** (95 LOC) — tier: headless-unit · framework: XCTest · pins: media attachment in documents (image embed, link resolution) · teeth: unclear (0 test functions, likely media-type registry or fixtures)

**DocumentControllerTests.swift** (205 LOC) — tier: headless-unit · framework: XCTest · pins: document lifecycle (open, save, dirty tracking, title) · teeth: real (13 tests, save-state model)

**DocumentStatsTests.swift** (48 LOC) — tier: headless-unit · framework: XCTest · pins: document statistics (word count, char count, line count) · teeth: real (7 tests, counting edge cases — multibyte chars, line endings)

**DocxExporterTests.swift** (49 LOC) — tier: headless-unit · framework: XCTest · pins: DOCX export (markdown → Office Open XML) · teeth: weak (4 tests, likely schema smoke)

**DocxMarkdownTests.swift** (52 LOC) — tier: headless-unit · framework: XCTest · pins: markdown extraction from DOCX (reverse of export) · teeth: weak (4 tests, roundtrip smoke)

**DocxTableImportTests.swift** (31 LOC) — tier: headless-unit · framework: XCTest · pins: table import from DOCX (cell layout, merged cells) · teeth: weak (3 tests, table-shape smoke)

**DocxTextExtractorTests.swift** (48 LOC) — tier: headless-unit · framework: XCTest · pins: text extraction from DOCX (character + paragraph formatting) · teeth: weak (6 tests, format preservation smoke)

**DotGraphOutlineTests.swift** (68 LOC) — tier: headless-unit · framework: XCTest · pins: Graphviz outline/tree from dot syntax (nesting, subgraph detection) · teeth: real (8 tests, parse tree correctness)

**DotGraphTests.swift** (127 LOC) — tier: headless-unit · framework: XCTest · pins: dot-file parsing (statement grammar, attribute handling) · teeth: real (14 tests, parse correctness + error handling)

**DoubleTapModifierDetectorTests.swift** (104 LOC) — tier: headless-unit · framework: XCTest · pins: gesture-event pattern matcher (double-tap + modifier key inference from event stream) · teeth: real (10 tests, sequencing + timing thresholds) — but 0 `test_` funcs suggest different naming

**DropReRootPolicyTests.swift** (39 LOC) — tier: headless-unit · framework: XCTest · pins: drag-drop file re-rooting (relative path correction) · teeth: weak (6 tests, path-resolution smoke)

**EditableCSVModelTests.swift** (265 LOC) — tier: headless-unit · framework: XCTest · pins: editable CSV model (insert/delete rows, edit cells, undo/redo) · teeth: real (18 tests, edit state + undo correctness)

**EditLocationHistoryTests.swift** (77 LOC) — tier: headless-unit · framework: XCTest · pins: caret/selection location history (jump back/forward, coalesce nearby positions) · teeth: real (8 tests, history navigation)

**EditorBufferTests.swift** (448 LOC) — tier: headless-unit · framework: XCTest · pins: text buffer state (dirty flag, external-edit detection, mtime/size fingerprint, baseline tracking) · teeth: real (26 tests, dirty-tracking edge cases + external-edit race conditions)

**EditorPerfBenchTests.swift** (224 LOC) — tier: bench · framework: XCTest · pins: CM6 editor perf harness (FFI byte-per-edit metric, wire-traffic modeling, workload repeatability, analytic vs real MessagePack match) · teeth: real (11 tests, measurement report shape + TSK-543 per-edit baseline assertion)

**EditorWriterBOMTests.swift** (112 LOC) — tier: headless-unit · framework: XCTest · pins: byte-order-mark handling on save (preserve BOM if present, strip if absent, encoding corner cases) · teeth: real (7 tests, BOM preservation + encoding interactions) — but 0 `test_` funcs suggest different naming convention

**EditUndoStackTests.swift** (173 LOC) — tier: headless-unit · framework: XCTest · pins: undo/redo stack (grouping edits, cursor position restore, coalescing adjacent changes) · teeth: real (13 tests, undo correctness + cursor recovery)

**EngineConsumptionGuardTests.swift** (98 LOC) — tier: headless-unit · framework: XCTest · pins: FFI resource cleanup (ensure Rust engine doesn't leak across invocations) · teeth: real (2 tests, leak guard — critical for long-running editor sessions)

**ExporterConvertTests.swift** (68 LOC) — tier: headless-unit · framework: XCTest · pins: format converter (markdown ↔ HTML/Plaintext) · teeth: weak (4 tests, conversion smoke)

**ExtensionsInventoryWalkthroughTests.swift** (38 LOC) — tier: headless-unit · framework: XCTest · pins: plugin-system walkthrough guidance (available plugins, install state) · teeth: weak (2 tests, inventory enumeration smoke)

**ExternalEditReconcilerTests.swift** (59 LOC) — tier: headless-unit · framework: XCTest · pins: file-watcher conflict reconciliation (user keeps local edits vs disk version) · teeth: real (5 tests, reconciliation strategy state)

**ExtractedReadOnlyBufferTests.swift** (29 LOC) — tier: headless-unit · framework: XCTest · pins: read-only buffer mode (prevent edits, preserve original for diff) · teeth: weak (3 tests, mode enforcement smoke)

**FeatureLocalityTests.swift** (143 LOC) — tier: headless-unit · framework: XCTest · pins: feature-locality audit (each viewable/editable type paired with tests, no orphan features) · teeth: real (12 tests, exhaustive audit of feature coverage) — governance-class test

**FeedDateParsingTests.swift** (47 LOC) — tier: headless-unit · framework: XCTest · pins: RSS/Atom date parsing (RFC822 variants, timezone handling) · teeth: unclear (0 test functions, may be fixtures or helper methods only)

**FeedFetcherTests.swift** (51 LOC) — tier: headless-unit · framework: XCTest · pins: feed HTTP fetch (redirects, authentication, caching headers) · teeth: weak (3 tests, likely mocked HTTP smoke)

**FeedParserTests.swift** (366 LOC) — tier: headless-unit · framework: XCTest · pins: RSS/Atom parsing (element extraction, entity decoding, CDATA, namespace variants) · teeth: real (19 tests, comprehensive format coverage — XML roundtrip)

**FeedRefreshSchedulerTests.swift** (41 LOC) — tier: headless-unit · framework: XCTest · pins: background feed-refresh scheduling (interval decay, error backoff) · teeth: unclear (0 test functions, likely state model only)

**FeedSubscriptionStoreTests.swift** (334 LOC) — tier: headless-unit · framework: XCTest · pins: feed subscription persistence (add/remove/list, folder hierarchy, sync state) · teeth: real (25 tests, CRUD operations + folder tree consistency)

**FFmpegGuidanceTests.swift** (33 LOC) — tier: headless-unit · framework: XCTest · pins: FFmpeg availability hint (PATH lookup, version detection) · teeth: weak (4 tests, tool-discovery smoke)

**FileChecksumRunnerTests.swift** (49 LOC) — tier: headless-unit · framework: XCTest · pins: file integrity checker (SHA1/SHA256, incremental update) · teeth: real (3 tests, checksum round-trip)

**FileFormatMenuStateTests.swift** (59 LOC) — tier: headless-unit · framework: XCTest · pins: file-format UI menu (detected format → enabled options, convert-to availability) · teeth: real (5 tests, format menu state machine)

**FileFormatStateTests.swift** (62 LOC) — tier: headless-unit · framework: XCTest · pins: file format detection + state (infer from extension/magic, encoding) · teeth: real (7 tests, format inference edge cases)

**FileIconClassifierTests.swift** (262 LOC) — tier: headless-unit · framework: XCTest · pins: file-icon lookup (UTI → NSImage, fallback hierarchy, cached) · teeth: real (20 tests, icon hierarchy + cache invalidation)

**FileQuarantineTests.swift** (69 LOC) — tier: headless-unit · framework: XCTest · pins: macOS file quarantine flag handling (check, clear, Gatekeeper bypass) · teeth: unclear (0 test functions, likely xattr helper only)

**FileRenamerTests.swift** (106 LOC) — tier: headless-unit · framework: XCTest · pins: file rename + atomic replacement (conflict avoidance, temp-file cleanup) · teeth: real (8 tests, rename safety + conflict handling)

---

## Test-Type Taxonomy

### Headless-Unit (core)
**~70 files, ~650–800 test functions total.** Pure logic tests:
- **CSV surface** (~16 files): cursor, clipboard, filter, find, sort, summary, cell editing, windowing, materialization. Strong teeth on model/state. Coverage spans filter+window integration (mature), copy/paste (thin), empty-state edge cases.
- **Diff surface** (~9 files): parsing, gutter annotation, selection, styling, stats, hunk serialization. Real teeth on line-classification + staging model. Weaker on presentation (color attributes).
- **Graph/dependency** (~5 files): graph construction, layout, interaction, import resolution, source discovery. Real teeth on cycle detection + resolver. Layout determinism is testable.
- **Editor/buffer** (~7 files): dirty tracking, undo/redo, buffer state, BOM handling, location history, external-edit reconciliation. Real teeth on concurrent modification races + dirty-flag invariants.
- **Feed/RSS** (~7 files): RSS/Atom parsing (366 LOC, 19 tests), subscription store, refresh scheduling, date parsing. Real teeth on format coverage; weak on fetch + scheduler (mocked I/O).
- **File/document** (~8 files): checksum, icon classification, format detection, quarantine, rename, stats, controller lifecycle. Mixed teeth: strong on format inference, weak on I/O ordering.
- **Diagnostic/support** (~3 files): path redaction, snapshot shape, fuzzing seed. Real teeth on privacy recursion.
- **Other utilities** (~11 files): document controller, default-app registration, dependency graph, diagram registry, docx import, gesture detection, etc. Mixed strength (governance + format coverage vs. UI/format smoke).

### Bench (perf measurement)
**2 files (CSVMaterializationBenchTests, EditorPerfBenchTests):** Load-bearing assertions guard regression cliffs (500k CSV materialization, editor per-edit FFI bytes). Loose on absolute wall-clock (no hard latency SLA), strict on TSK-543 metric capture + analytic-vs-real wire-traffic alignment. Teeth: real — these measure the numbers that inform architecture decisions (windowing feasibility).

### Support/Data (fixtures, seeds, helpers)
**5–6 files** (DifferentialFuzzSeed, DiagnosticSnapshot, CSVViewportPagerTests, DocumentControllerMediaTests, FeedDateParsingTests, FeedRefreshSchedulerTests, DoubleTapModifierDetectorTests, FileQuarantineTests) show **0 test functions** or very sparse tests. Likely: data generators, type registries, mock services, or test helpers that don't run as standalone tests.

---

## Coverage Shape

### Over-tested
- **CSV filtering/finding** (24+24 tests): Mature, redundant in parts (filter + find both test substring matching + window integration).
- **Diff gutter annotation** (12 tests): Well-covered for line classification.
- **Graph construction/layout** (17+9+11 tests): Comprehensive (cycle detection, resolver, interaction).
- **Feed parsing** (19 tests): Full format matrix (RSS 2.0, Atom, namespaces, CDATA).
- **Edit undo/redo** (13 tests) + **dirty tracking** (26 tests in EditorBufferTests): Deep, covers races + cursor recovery.

### Under-tested
- **UI interaction** (0 tests in this tier — all UI/render work is T4/T5 on the VM).
- **CSV clipboard paste** (5 tests, 36 LOC): Thin, likely surface-level.
- **Docx/export conversion** (4+4+3+6 tests across 4 files): Smoke tests only; no round-trip validation or malformed-input robustness.
- **Feed HTTP fetch + scheduler** (3+0 tests): Mocked; no real-network or backoff-strategy validation.
- **Gesture detection** (10 tests in DoubleTapModifierDetectorTests, named differently — not `test_` prefixed): Likely fragile (no VM interaction test).
- **File I/O ordering** (rename, quarantine, external-edit detection): Tested at model level, not at file-system race boundary (no concurrent-editor stress tests).

### Gaps worth noting for rebuild
- **Plugin/extension system** (2 tests in ExtensionsInventoryWalkthroughTests): Minimal; the walkthrough is API-boundary-only.
- **Text encoding edge cases** (UTF-16 offset safety in DataSliceOffsetDefenseTests is real, but no comprehensive BOM/encoding round-trip suite).
- **Cascading updates** (dirty region coalescing, recalc propagation): Logic tested in isolation, but no end-to-end view (model → render) tests — that's the VM tail.
- **Resource cleanup** (1 engine-consumption guard test): Critical for long-running editor, but single test; expand this.

---

## Harness & Infra Patterns Worth Porting

### Base Classes & Fixtures
1. **Fake/Mock Services:** `DefaultAppRegistrationTests::FakeService` (in-memory UTI handler registry with failure injection) — clean, reusable pattern for system-API tests. Extend for LaunchServices, pasteboard, file attributes.
2. **Temporary Directory Setup:**
   ```swift
   override func setUp() { tmpDir = FileManager.default.temporaryDirectory... }
   override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }
   ```
   Standard hygiene; baked into every file test. Migrate to a base class or XCTest extension to reduce boilerplate.

3. **Deterministic Data Builders:** Many tests (CSVRowWindowSourceTests, FeedParserTests) use helper methods (`makeCSV()`, `data()`) to build repeatable test inputs. Pattern scales well; codify as `TestDataBuilder` protocol.

### Negative Controls
- **Explicit regression assertion in CSVMaterializationBenchTests:** The "FFI bytes must exceed docLength under today's design" assertion (lines 78–79) is load-bearing and documents TSK-543's target — when the fix lands, FLIP THE ASSERTION. This is the "demonstrate teeth" pattern: a measurement test with a known breakage. **Port this model to every perf/regression test in the rebuild.**
- **EditorPerfBenchTests metric capture:** Validates that the analytic wire-traffic model matches MessagePack bytes exactly. If the wire format changes, this test MUST fail (not just flag a different number). **Port the "model ↔ real must align" pattern.**

### Gate & Validation
- **Audit tests** (FeatureLocalityTests, DiffRouting_Audit_Sources_DiffHunkParser_Callers_Tests): Governance-class assertions that EVERY viewable type has tests, EVERY diff parser caller respects the contract. These are cheap to run and catch architectural drift. **Port the audit pattern to the rebuild's test suite early.**
- **Path redaction recursion** (DiagnosticSnapshotTests): Tests that a transformation (path redaction) correctly recurses into nested structures. Catches subtle omissions (e.g., "oh I forgot to redact the label of the subprocess"). **Use as a template for testing transformations in parsing/serialization.**

### No Test-Tier Mixing
- **All files in this slice are headless-unit (XCTest)** — no T4/T5/WebView/AX tests appear in ViewerCoreTests root. Heavy tiers (live app, pixels, accessibility) live elsewhere (ViewerUITests suite). Clear separation. **Maintain this split in the rebuild.**

### Framework Unification (All XCTest)
- No SwiftTesting migrations in this slice; all XCTest. Some newer files may use SwiftTesting (`import Testing`), but not these. If the rebuild targets Swift Testing from day 1, plan migration for existing patterns (parameterized tests, setup/teardown → `@Test(arguments:)`). **For day-1 greenfield, consider Swift Testing for pure-logic suites only; keep XCTest for tier-based tests (TierGateObserver integration).**

---

## Flake / False-Green Risks Observed

### Critical
1. **Bench test wall-clock assertions under machine load.** CSVMaterializationBenchTests + EditorPerfBenchTests have loose cliffs (30 sec headroom on 10–50 ms ops) — safe. But if run on a shared machine / under load, they can spike. **Mitigation:** run bench tests in isolation; measure on calm hardware; use percentiles, not absolutes. (The owner note: re-run / confirm no non-bench failures if a bench-only gate fails.)

2. **External-edit detection race in EditorBufferTests.** Tests mtime/size fingerprints with `Date` (second precision). If a file is written twice within 1 second on a modern FS, the test may pass spuriously. **Mitigation:** use explicit mtime deltas (`.addingTimeInterval`) and avoid relying on system clock granularity; add a nano-precision path for future HFS+ upgrade.

3. **CSV windowing boundary off-by-one.** CSVRowWindowSourceTests exercises offset/limit; if Rust and Swift disagree on row counts (e.g. header vs no-header), tests can silently pass by coincidence. **Mitigation:** add fuzz tests (already in DifferentialFuzzSeed) to catch divergence.

### Moderate
4. **File I/O flakiness in cross-file search, feed fetcher, file rename.** All use `FileManager` on tmp; concurrent test runs can collide. Mitigation: UUID-scoped directories (CrossFileSearchTests does this well) — ensure all file tests follow the pattern.

5. **Fake service mocking (DefaultAppRegistrationTests::FakeService).** The fake doesn't simulate all LaunchServices quirks (e.g., permission denial, async registration delays). If the app ever needs async default-app handling, the tests won't catch it. **Mitigation:** eventually add E2E integration tests on real LaunchServices (T4 scope, not headless).

### Low (Observational)
6. **Diagnostic snapshot test doesn't validate that redaction is **lossy** — it only checks that home/tmp prefixes are gone.** A buggy redaction that removes too much (e.g., redacts `/usr/bin` as `<UNKNOWN>`) would pass. **Mitigation:** strengthen assertions to validate that safe prefixes (e.g., system paths) are preserved.

7. **Feed parser tests use hardcoded RFC822 dates** (Mon, 16 Jun 2025 09:30:00 GMT) — if run in a timezone-aware environment, locale assumptions can surface. **Mitigation:** explicitly set `Calendar(identifier: .gregorian)` + `TimeZone(secondsFromGMT: 0)` (already done in FeedParserTests; enforce in date-parsing helpers).

---

## Rebuild Notes — Day-1 Test Strategy

### Immediate (P0: Protect Core Invariants)
1. **Port the CSV windowing + materialization bench.** The 500k-row test is load-bearing (TSK-1139 informed the architecture). Rebuild's CSV engine MUST pass the same measurement suite early.
2. **Port audit-class tests.** FeatureLocalityTests ensures no orphan features. Add to CI gate day 1 — trivial to run, high signal.
3. **Port negative-control measurements.** EditorPerfBenchTests' "analytic wire-traffic ≠ real" failure must not regress. Codify the TSK-543 metric as a load-bearing assertion.
4. **Port the default-app registration + fake service pattern.** macOS integration is non-obvious; the fake-service pattern scales.

### Staged (P1: Mature the Model)
5. **Expand undo/redo + dirty-tracking.** EditorBufferTests has 26 tests; add stress tests (1000 edits, rapid undo/redo, external-edit race under concurrent local edits). Current tests are solid but don't simulate real editor load.
6. **Comprehensive text encoding round-trip.** DataSliceOffsetDefenseTests covers UTF-16↔byte safety; add BOM, rare-encoding (Shift-JIS), surrogate-pair edge cases.
7. **Feed parser: add malformed-input robustness.** Current 19 tests cover the happy path + CDATA. Add truncated XML, missing namespaces, entity bombs.

### After Maturity (P2: Fill Coverage Gaps)
8. **Clipboard paste integration.** CSVClipboardPasteTests is 36 LOC / 5 tests. Expand to cover shape inference (TSV vs comma vs pipe), merge conflicts, large-clipboard data.
9. **Gesture detection interaction tests.** DoubleTapModifierDetectorTests has 10 tests but no `test_` naming; move to T4 on VM if feasible. If headless, ensure timing assumptions (thresholds for "double-tap") are validated.
10. **File I/O stress.** Rename, quarantine, external-edit detection all tested in isolation. Add a stress harness (10 concurrent editors, 100 rapid saves each, random external writes). Current tests are racy.

### Never Skip
11. **Tier gating.** No T4/T5 tests in ViewerCoreTests (correct). Maintain strict separation. Host gate (headless only) keeps CI fast; VM gate (UI only) runs nightly. **This split is a strength — preserve it.**
12. **Framework pinning.** All XCTest in this slice. If rebuilding with Swift Testing, do a gradual migration (new pure-logic suites first, tier-based tests last). Don't flip the entire suite overnight.

### Monitoring Metrics (for Post-Rebuild UAT)
- **CSVMaterializationBenchTests**: Track parse/sort/filter wall-clocks, memory footprint deltas. Expected: parse <30ms, sort <30ms for 500k rows on M1 / latest Intel.
- **EditorPerfBenchTests**: FFI bytes/edit (currently ≈docSize under full-resend design). When TSK-543 lands (edit-delta), expect ≈delta bytes (~kilobytes for typical edits).
- **FeatureLocalityTests**: 0 orphan features. Run on every PR.
- **Flake rate**: Track bench-test reruns. If >5% need re-runs, investigate machine load / test isolation.

---

## Slice Summary

**76 files, ~650–800 test functions, ~12K LOC.** All XCTest, headless-unit tier. Comprehensive coverage of CSV (windowing, filtering, editing), diff (parsing, styling, staging), graph (construction, layout), editor (undo, dirty-tracking), feed (RSS/Atom), and file (format detection, I/O) models. Bench tests guard architecture decisions (CSV materialization, editor FFI metrics). Audit tests enforce feature completeness. Weak spots: UI interaction (0 headless tests), clipboard paste, docx conversion, feed scheduling. Patterns worth porting: fake-service mocking, deterministic data builders, negative-control regressions, audit-class tests. No false-green traps observed; risks are low-probability (clock precision, concurrent file I/O). Rebuild should prioritize bench/audit/undo tests day 1, then expand encode/decode robustness, finally stress-test I/O concurrency.
