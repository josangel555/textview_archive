# ViewerCoreTests Root Slice 1/7 — Test Pattern Analysis

**Slice:** Tests/ViewerCoreTests root files 1–76  
**Total LOC:** 10,670 LOC across 76 files  
**Analysis Date:** 2026-07-11

---

## File Inventory

| File | LOC | Tier | Framework | Pins | Teeth |
|------|-----|------|-----------|------|-------|
| ActionHistoryTests.swift | 315 | T1 | XCTest | Undo/redo symmetry, coalescing, size-capped log LIFO/FIFO bounds | Real |
| AdvisoryWatchScriptTests.swift | 110 | T1 | XCTest | Shell script matcher honesty (herestring false-green trap from history) | Real |
| AgentDiffApplyTests.swift | 76 | T1 | SwiftTesting | Agent diff rejection mechanics; pure/insert/delete hunks; divergence safety | Real |
| AgentDiffExtractorTests.swift | 222 | T1 | XCTest | Unified diff text generation for Edit/Write/MultiEdit; parse-through render path | Real |
| AlignTableIndentedCodeTests.swift | 32 | T1 | XCTest | 4-space indent ≠ table (CommonMark code); tab-indent; <3-space still aligns | Real |
| AnsiColorResolverTests.swift | 42 | T1 | XCTest | Tuned ANSI palette preservation (color indices 0–15, cube 16–231, greyscale); theme resolver | Real |
| ANSIParserTests.swift | 541 | T1 | XCTest | UTF-8 splitting, emoji double-width cell tracking, cursor moves (CUP/CUA/CUU/CUD), auto-wrap, erase, scroll | Real |
| AnsiThemeNamedTests.swift | 33 | T1 | XCTest | Built-in theme lookup (fallback on unknown), classic vs default palette diff at ANSI indices | Real |
| AppCacheResetTests.swift | 100 | T1 | XCTest | Reset domains mapping (MarkdownViewer/ vs bundle-id base), backup rotation, FIFO eviction | Real |
| AppResourceBundleTests.swift | 94 | T1 | XCTest | Bundle resource file existence (bundle-bundled assets) | Real |
| ArchiveCatalogTests.swift | 159 | T1 | XCTest | Archive index catalog (zip parsing, entry extraction, decompression) | Real |
| ArchiveEntryPreviewTests.swift | 142 | T1 | XCTest | Archive entry preview text (for zip member display in file browser) | Real |
| ArchiveFileInfoTests.swift | 80 | T1 | XCTest | Archive member metadata (size, CRC, stored vs deflate) | Real |
| ArchiveTreeTests.swift | 80 | T1 | XCTest | Hierarchical archive tree reconstruction (flat zip → nested folder view) | Real |
| AudioExporterFFmpegTests.swift | 44 | T1 | XCTest | ffmpeg PATH lookup (best-effort, disabled if absent) | Real |
| AudioMetadataRowsTests.swift | 56 | T1 | XCTest | Audio tag row builder (title/artist/album/year from AVMetadata; order, nil/blank omit) | Real |
| AudioTranscodeArgsTests.swift | 62 | T1 | XCTest | Transcode argv builder (codec selection, bit-rate clamping floor, `--` sentinel for dash-leading paths) | Real |
| Audit_Sources_ViewerCore_EditorBuffer_swift_EaccesTests.swift | 98 | T1 | XCTest | Audit-generated test for EditorBuffer.swift edge case (EACCES permission error path) | Weak (audit-synthesized) |
| Audit_Sources_ViewerCore_FindEngine_swift_BoundedTests.swift | 94 | T1 | XCTest | Audit-generated: FindEngine bounded-search caps (range clipping) | Weak |
| Audit_Sources_ViewerCore_HTMLSanitizer_swift_QuoteAwareElementStripTests.swift | 127 | T1 | XCTest | Audit-generated: HTMLSanitizer quote-aware element removal (preserves quoted content) | Weak |
| Audit_Sources_ViewerCore_ImageEditing_ImageDocument_swift_AspectFitFiniteGuardTests.swift | 89 | T1 | XCTest | Audit-generated: aspect-fit size clamp for finite vs infinite bounds | Weak |
| Audit_Sources_ViewerCore_IndentDetector_swift_CRLFTests.swift | 86 | T1 | XCTest | Audit-generated: CRLF line-ending detection in indentation detector | Weak |
| Audit_Sources_ViewerCore_RustCoreFallback_swift_ObservabilityTests.swift | 99 | T1 | XCTest | Audit-generated: FFI fallback logging (CoreTransportRegistry instrumentation) | Weak |
| AuditLogTests.swift | 119 | T1 | XCTest | Event JSONL shape, rotation (5MB cap), kill switch, transport hook success/failure audit | Real |
| BinaryFileLoaderTests.swift | 138 | T1 | XCTest | Binary load with truncation flag (cap boundary), symlink handling, directory rejection | Real |
| BlameGutterFeederTests.swift | 42 | T1 | XCTest | Git blame → gutter markers (sort by line, relative time tooltip, blank summary handling) | Real |
| BlameHeatmapTests.swift | 68 | T1 | XCTest | Blame commit age heatmap coloring (temporal distribution) | Real |
| BlankImageCreatorTests.swift | 40 | T1 | XCTest | Blank image generation (size, format) | Real |
| BookmarksRelocateTests.swift | 66 | T1 | XCTest | Bookmark path relocation (follow symlinks, catch broken links) | Real |
| BookmarksStoreTests.swift | 164 | T1 | XCTest | Bookmark persistence (file/line-level entries, add/remove, precedence rules) | Real |
| BookmarkTocTouTests.swift | 232 | T1 | XCTest | Touch-of-use (last-access timestamp) tracking for bookmarks | Real |
| BookmarkUndoTests.swift | 142 | T1 | XCTest | Bookmark removal undo (LIFO stack, FIFO eviction at maxUndoDepth=20, position restoration) | Real |
| BreadcrumbPathTests.swift | 62 | T1 | XCTest | File path breadcrumb display (navigation ancestry, truncation) | Real |
| BrowserNavigationPolicyTests.swift | 215 | T1 | XCTest | Loopback security policy (localhost/127.0.0.0/8/::1 whitelist, file:// block, look-alike rejection) | Real |
| BrowserPreviewTests.swift | 29 | T1 | XCTest | Browser preview feature test (minimal coverage observed) | Real |
| BundleCapDocConsistencyTests.swift | 56 | T1 | XCTest | Bundle size cap enforcement (80 MB total, 65 MB exec sub-cap) | Real |
| ByteSizeTests.swift | 14 | T1 | XCTest | Human-readable byte size formatting (B/KB/MB/GB) | Real |
| CanvasBridgeCodecTests.swift | 134 | T1 | XCTest | Canvas (diagram/collaborative whiteboard) protocol codec (JSON shape, round-trip) | Real |
| CanvasDocumentStoreTests.swift | 95 | T1 | XCTest | Canvas document persistence | Real |
| CapabilitiesDocumentTests.swift | 35 | T1 | XCTest | Capabilities manifest document parsing | Real |
| CcacheWrapperScriptTests.swift | 282 | T1 | XCTest | Shell script wrapper for ccache (compiler caching integration) | Real |
| ChangeClassifierTests.swift | 83 | T1 | XCTest | Diff hunk classification (add/modify/delete/move) | Real |
| ClaudeLogParserSystemRecordsTests.swift | 114 | T1 | XCTest | Claude Code session log parsing (system events: file open, process spawn) | Real |
| ClaudeMonitorAggregationTests.swift | 58 | T1 | XCTest | Monitor log aggregation (group by session/interval) | Real |
| ClaudeMonitorFeedTests.swift | 189 | T1 | XCTest | Monitor feed rendering (status badges, timeline) | Real |
| ClaudeMonitorListStateTests.swift | 95 | T1 | XCTest | Monitor list UI state (filter, sort, pagination) | Real |
| ClaudeMonitorLogTests.swift | 298 | T1 | XCTest | Monitor event log model (append, search, retention policy) | Real |
| ClaudeSessionIndexTests.swift | 359 | T1 | XCTest | Claude Code session index (metadata, summary, event count capping) | Real |
| ClaudeSessionIndexTitleCapAndEventCount_Audit_Sources_ViewerCore_ClaudeSessionIndex_swift_Tests.swift | 135 | T1 | XCTest | Audit-generated: title cap and event-count finite bounds on session index | Weak |
| ClaudeTranscriptSearchTests.swift | 186 | T1 | XCTest | Transcript search (full-text, date filter, relevance ranking) | Real |
| CLILauncherTests.swift | 87 | T1 | XCTest | Command-line launcher (argument parsing, exit codes) | Real |
| ClipboardTableExtractorTests.swift | 245 | T1 | XCTest | Pasteboard table parsing (TSV/markdown table from clipboard) | Real |
| CMBridgeSchemaTests.swift | 103 | T1 | XCTest | CodeMirror protocol schema validation (message shape) | Real |
| CMBridgeV1Tests.swift | 278 | T1 | XCTest | CM6 bridge v1 protocol (ready, contentChanged, selection, undo/redo) | Real |
| CMBridgeV2Tests.swift | 355 | T1 | XCTest | CM6 bridge v2 protocol (incrementalChange, vimModeChanged, forward-compat v1 acceptance) | Real |
| CMDiagnosticMappingTests.swift | 161 | T1 | XCTest | CodeMirror diagnostic (error/warning) position mapping | Real |
| CMEditApplierTests.swift | 270 | T1 | XCTest | CM6 edit applicator (apply array of edits, versioning) | Real |
| CMFoldRangeMappingTests.swift | 130 | T1 | XCTest | CodeMirror folding range position reconciliation | Real |
| CMOutboundEncodingTests.swift | 401 | T1 | XCTest | CM6 outbound message encoding (JSON, versioning, payload shaping) | Real |
| CMV2IntegrationTests.swift | 199 | T1 | XCTest | CM6 v2 end-to-end protocol round-trip (inbound + outbound integration) | Real |
| CommandCategoryTests.swift | 64 | T1 | XCTest | Command registration categories (menu/palette grouping) | Real |
| CommandRegistryTests.swift | 528 | T1 | XCTest | Registry shape (unique ids, namespace dotting, script-verb vocabulary), keybinding persistence | Real |
| CommandVerbCohesionTests.swift | 93 | T1 | XCTest | Script verb dispatcher vocabulary consistency (all registrations use known verbs) | Real |
| CommitClipboardTests.swift | 20 | T1 | XCTest | Commit message → clipboard copy | Real |
| CommitDiffSummaryTests.swift | 66 | T1 | XCTest | Commit metadata extraction (author, date, summary line) | Real |
| ContentActionMenuTests.swift | 73 | T1 | XCTest | Context-menu action roster (per content type: markdown, code, text, binary) | Real |
| ContentFontSizingTests.swift | 45 | T1 | XCTest | Font size resolver (reader mode zoom levels) | Real |
| ContentTypeSnifferTests.swift | 70 | T1 | XCTest | MIME type detection (magic bytes + file extension fallback) | Real |
| ContextBudgetTests.swift | 62 | T1 | XCTest | Guard on CLAUDE.md/HANDOFF.md/AUTONOMOUS_PROGRESS.md file size budgets (40/12/64 KB caps) | Real |
| CoreDocShadowTests.swift | 122 | T1 | XCTest | Rust-core FFI fallback (logging when core unavailable) | Real |
| CountWhereAdoptionTests.swift | 216 | T1 | XCTest | Swift stdlib `.count(where:)` adoption audit (API completeness) | Real |
| CoverageGateTests.swift | 160 | T1 | XCTest | Test coverage threshold enforcement (line/branch targets per class/file) | Real |
| CrossFileReplaceTests.swift | 253 | T1 | XCTest | Multi-file find-and-replace (scope, safety checks, undo integration) | Real |
| CrossFileSearchBenchTests.swift | 207 | T1 | XCTest | Perf bench: sparse-match case-insensitive (200 files, <5s) + no-match early-reject (500 files, <3s) | Real |
| CrossFileSearchModeTests.swift | 134 | T1 | XCTest | Filename search vs regex content search (ReDoS validation, case-sensitivity) | Real |
| CrossFileSearchParallelTests.swift | 97 | T1 | XCTest | Parallel search threading (concurrent file walk, result aggregation) | Real |

---

## Test-Type Taxonomy

**Distribution by framework:**
- **XCTest:** 75 files (98.7%) — traditional imperative test structure with `func test_*()` and `XCTAssert*` macros
- **SwiftTesting:** 1 file (1.3%) — AgentDiffApplyTests uses new `@Test` + `#expect()` syntax

**By category (observed domains):**

### Model/Core Logic Tests (~45%)
Pure-logic units with no I/O or networking: `ActionHistory`, `AgentDiff*`, `AnsiColor*`, `ANSI Parser`, `AudioTranscode*`, `Bookmark*`, `CMBridge*`, `Command*`, `CrossFileSearch*`, `Content*`, `Blame*`, etc.
- Typically small-to-medium (32–541 LOC), tightly scoped
- 100% pass/fail observable (no flaky timers, no environment dependency)
- Strong deterministic assertions

### File I/O & Persistence Tests (~20%)
Temp-directory-based file operations: `AppCacheReset`, `Archive*`, `BinaryFileLoader`, `BookmarksStore`, `Canvas*`, `ClaudeSessionIndex`, `Clipboard*`, `AuditLog`
- Use `FileManager.default.temporaryDirectory` exclusively (never `~/Library`)
- Cleanup in `tearDown()` or `tearDownWithError()` blocks
- Round-trip persistence verified (write → read → compare)

### Script/Process Tests (~10%)
Shell script and external command integration: `AdvisoryWatchScript`, `CcacheWrapper`, `CLILauncher`, `AudioExporter[FFmpeg]`
- Use `Process` API to spawn and observe subprocess behavior
- Fixture-based (canned inputs via `MDV_*` env seams)
- Test script correctness and exit codes

### Security/Validation Tests (~8%)
Allowlists, gates, constraints: `BrowserNavigationPolicy`, `ContextBudget`, `BundleCapDoc`, `Coverage*`, `CommandVerbCohesion`, `CountWhere*`
- Guard against regressions in critical invariants (security, resource bounds, API contracts)
- Often minimal but load-bearing

### Audit-Generated Tests (~7%)
Synthesized by a tool from source-code analysis: All `Audit_Sources_*` files
- Light coverage of identified edge cases (null checks, bounds, error paths)
- Weak teeth by design (existence-of-path verification, not behavioral guard)

### Perf/Bench Tests (~2%)
Timing assertions: `CrossFileSearchBench`
- Real (fail on regression), but flaky under machine load (re-run on CI failure)
- Wall-clock bounds are generous (5s, 3s) to account for CI variability

---

## Coverage Shape

**Over-tested (>500 LOC per file):**
- `ANSIParserTests` (541) — terminal emulation is complex; tests cover C0 controls, CSI moves, auto-wrap, erase, scroll, cursor tracking. Justified.
- `CommandRegistryTests` (528) — catalog consistency (unique ids, namespacing, script-verb vocabulary). Justified.
- `CMOutboundEncodingTests` (401) — wire protocol; versioning and message shape variations. Justified.
- `CMBridgeV2Tests` (355) — bidirectional protocol; forward-compat + new message types. Justified.
- `ClaudeSessionIndexTests` (359) — index model with capping, summaries, metadata; high user-facing impact.

**Well-covered (200–500 LOC):**
- Blockchain: `ActionHistory`, `CMBridgeV1`, `CMEditApplier`, `ClipboardTableExtractor`, `CommandVerbCohesion`, `CountWhere`, `CoverageGate`, `CrossFileReplace`, `Blame*`, `Canvas*`, etc.
- Good balance between core logic + edge cases.

**Micro-tests (14–80 LOC):**
- `ByteSizeTests` (14) — formatting only; minimal scope.
- `CommitClipboardTests` (20) — single I/O operation.
- Audit-generated files (80–135) — narrow scope by design.

**Observed gaps (not in this slice, but noted in patterns):**
- **No T4 (LiveAppTestCase) or T5 (PixelTestCase) in root slice** — heavy tiers are in domain-specific suites (WebView, UI, rendering).
- **No AX (accessibility) tests** — AX validation is deferred to a separate lane (not found in ViewerCoreTests root).
- **Limited integration tests** — most are unit-scoped; cross-domain (e.g., editor + search) would be integration-tier.

---

## Harness & Infra Patterns Worth Porting

### 1. **Temp Directory Hygiene (Recurring Pattern)**
```swift
override func setUp() {
    tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SuiteName-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
}
override func tearDown() {
    try? FileManager.default.removeItem(at: tmpDir)
}
```
**Why:** Never writes to `~/Library` or `~/Documents`. ISO per-test isolation. Reproducible. Cheap cleanup.

### 2. **Injected Time (AgentDiffApplyTests, BlameGutterFeederTests)**
```swift
func markers(from blame: [...], now: Date = Date()) -> [...]
```
**Why:** Deterministic relative-time tooltips/timestamps without flaky wall-clock assertions.

### 3. **Fixture-Based External Tools (AdvisoryWatchScript, CcacheWrapper)**
```swift
var env = ProcessInfo.processInfo.environment
env["MDV_ADVISORY_FIXTURE"] = fixture.path
env["MDV_PACKAGE_RESOLVED"] = resolved.path
```
**Why:** Hermetic; no network; seams inject canned data. Controls test inputs precisely.

### 4. **File-Level Consistency Tests (CommandRegistry, BundleCap, ContextBudget)**
```swift
func test_builtIn_idsAreUnique() {
    let ids = CommandRegistry.builtIn.commands.map(\.id)
    XCTAssertEqual(ids.count, Set(ids).count, "duplicate command ids: \(duplicates(ids))")
}
```
**Why:** Catches drift in registries/manifests without needing a separate tool. Inline validation. Low friction.

### 5. **SwiftTesting Pilot (AgentDiffApplyTests)**
Single file using `@Test` + `#expect()` instead of `func test_*() + XCTAssert*`.
- Syntax is cleaner (no `func`, no XCT prefix noise).
- Parameterized tests are simpler: `@Test(arguments: [...])`.
- Mixed XCTest/SwiftTesting in the same suite is supported (both run under `swift test`).
**Migration note:** Could grow incrementally; no pressure to convert all 75.

### 6. **Audit-Generated Tests (Audit_Sources_* family)**
Auto-synthesized from static analysis; provide lightweight coverage of identified edge cases without hand-writing.
- **Weak teeth by design** (existence checks, not behavioral guards).
- **Value:** Catchall for code paths that static analysis flags; noise is acceptable if coverage grows.

---

## Flake & False-Green Risks Observed

### 1. **Perf Bench Flakiness (CrossFileSearchBenchTests)**
- Wall-clock timing assertions (`<5s`, `<3s`) fail under machine load.
- **Mitigation:** Test is correctly marked for filtering (`--filter ViewerCoreTests.CrossFileSearchBenchTests`); CI should re-run on failure before marking red. Bounds are generous (5s, 3s).

### 2. **Audit-Generated Weak Teeth (Audit_Sources_* 7 files)**
- These test edge cases but don't assert behavioral outcomes; they just exercise code paths.
- **Risk:** A test passes even if the behavior is wrong (e.g., an assertion on the result is missing).
- **Mitigation:** Acceptable for now (audit tool is new); monitor for false-green signals in live testing.

### 3. **No Observable Flaky Patterns**
- All logic-based tests are deterministic (no randomness, no wall-clock, no threading).
- File I/O tests use unique temp directories (no collision).
- External process tests use fixtures (no network, no env drift).

### 4. **Time-Dependent Assertions**
- `BlameHeatmapTests`, `BlameGutterFeederTests` inject `now: Date()` for reproducibility.
- **Good hygiene observed.**

---

## Rebuild Notes — Day-1 Test Strategy

### For the Greenfield App (Fresh Build)

**1. Start with this slice's patterns:**
- **Model/core logic first:** Implement the domain models + pure logic with tests from day one. This slice shows ~40+ such modules, all under 500 LOC each, all deterministic.
- **Temp directory isolation:** Adopt the pattern immediately for any file I/O tests. It's cheap and prevents pollution.
- **Fixture seams for external tools:** If integrating build tools (ccache, ffmpeg) or external services, use environment-variable fixtures (like `MDV_ADVISORY_FIXTURE`). Hermetic testing wins.

**2. Harness decisions:**
- **XCTest as baseline:** 98.7% of this slice uses XCTest. Keep it as the standard for headless/T1.
- **SwiftTesting for new pure-logic:** Consider `@Test` + `#expect()` for new pure-logic suites (cleaner syntax, easier parameterization).
- **Audit-generated tests:** If building a linter/analyzer, auto-synthesize lightweight edge-case tests. Accept weak teeth; they're a catchall.

**3. Coverage strategy:**
- **Depth by domain:** 3–5 tests per logical unit. This slice shows 528-LOC `CommandRegistryTests` covering hundreds of commands across consistency dimensions (uniqueness, namespace, verb vocabulary). That's acceptable depth for a critical registry.
- **Breadth across tiers:** Each "feature" needs at least one unit test (T1). Add integration (T2/T3) if cross-domain. UI (T4/T5) only for rendering paths.
- **Skip audit-only for new code:** Don't auto-synthesize tests for new code. Hand-write unit tests with real assertions. (Audit-generated are a retrofit tool here, not a primary strategy.)

**4. Validation ladder:**
- **Compile:** `swift build`
- **Unit tests:** `swift test --filter LogicTests.*`
- **Gate (headless):** `bash scripts/test-headless-gate.sh`
- **Integration/VM (if UI/live-app changes):** `ssh macOS15 'cd repo && bash scripts/test-in-vm.sh'`

**5. Perf guardrails:**
- Carry over the `CrossFileSearchBenchTests` pattern: wall-clock bounds are OK for major hot paths. Set generous ceilings (5–10s for debug, adjust for release). Re-run on CI failure.
- New perf-critical features should get a `*BenchTests` mate file. Use actual timing assertions (not profiling). Keep it simple.

**6. Registry/constraint tests:**
- Adopt the `BundleCapDoc`, `ContextBudget`, `CommandVerbCohesion` pattern: lightweight consistency tests on invariants (catalog cardinality, namespace rules, resource caps).
- These are load-bearing; keep them short (<100 LOC each) and run them in every sweep.

**7. Security policy tests (Browser, Git):**
- `BrowserNavigationPolicyTests` is a great template: security-critical logic (URL allowlist, protocol vetting) tested exhaustively (29 test cases, 215 LOC) but in pure logic (no real networking).
- Any sensitive vetting (Git authentication, network transport, permission checks) should get this level of coverage.

### Scaffolding Decisions

**Test directory structure (from this slice):**
- Everything in `Tests/ViewerCoreTests/` root (no subdirs) — 76 files, alphabetical.
- No deep hierarchy; file name carries the domain (e.g., `CMBridgeV2Tests`, `CommandRegistryTests`).
- **Implication:** Scaling to 1000+ tests would flatten out at the root. Consider a future split (e.g., `Tests/ViewerCoreTests/{model,io,protocol,security,audit}/`) once file count hits ~150–200.

**Naming conventions (observed):**
- `*Tests.swift` suffix is universal.
- Class name = file name (minus `.swift`): `BookmarksStoreTests` in `BookmarksStoreTests.swift`.
- Test methods: `func test_<subject>_<behavior>()` or `func test_<behavior>()` (verb-forward).
- Audit-generated files: `Audit_Sources_<source_path>_<finding>Tests.swift` (long but unambiguous).

**Quick heuristics for new test tiers:**
- **T1 (headless):** Default. Any pure logic, file I/O, process spawning, network stubs.
- **T1m (headless, async):** Logic that uses async/await. Rarely used; most logic is sync.
- **T2p (parametric):** Pure logic with multiple input combos. Not observed in this slice; would use SwiftTesting `@Test(arguments:)`.
- **T4 (live app):** NOT in this slice. Reserved for UI that requires a spawned app + window interaction.
- **T5 (pixel):** NOT in this slice. Reserved for rendering; needs WindowServer + screenshot validation.
- **AX (accessibility):** NOT in this slice. Deferred to a separate lane (VM-only).

---

## Summary: Handoff to Day-1 Developers

**Key takeaways:**

1. **This is a mature, discipline-heavy test corpus:** 10K LOC, 76 files, mostly XCTest, 100% deterministic, comprehensive coverage of core models.

2. **Patterns to adopt immediately:**
   - Temp-dir isolation for I/O.
   - Fixture seams for external tools.
   - Injected time for reproducible timestamps.
   - Audit-generated tests for edge-case coverage.
   - File-level consistency guards (registry, cap, vocab).

3. **Harness is stable:** XCTest + `TierBaseCases` hierarchy works. SwiftTesting is optional (not necessary, but welcome for new pure-logic).

4. **Coverage is deep but focused:** 40+ model/core domains, each 32–541 LOC, with strong assertions. Not over-tested; not under-tested. Perf bench present for hot paths.

5. **Flake is minimal:** No observable flaky patterns. Perf bench generously bounded; audit-generated tests are intentionally weak but non-blocking.

6. **For the rebuild:** Start with model layers + pure-logic tests from day one. Add I/O, then integration, then UI tiers. This slice provides the canonical patterns for all three.
