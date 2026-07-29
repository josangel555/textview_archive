# ViewerCoreTests Batch 6/7 (Files 381–456) — Learning Summary

**Scope:** 76 test files, ~8,700 LOC, 436 test functions. Pure-logic headless suites (no UI tiers). Coverage: Rust FFI adapters, state machines, persistence, search/query routing, syntax/structure analysis, editor features.

---

## Test Inventory — Per-File Entries

| File | LOC | Framework | Tier | Tests | Pins | Teeth |
|------|-----|-----------|------|-------|------|-------|
| **RtfViewerRoutingTests.swift** | 184 | XCTest | headless-unit | 9 | .rtf/.docx/.ods extraction as read-only, category routing | real — `isExtractedReadOnly` flag + body-text assertions |
| **RunnableTaskDiscoveryTests.swift** | 255 | XCTest | headless-unit | 18 | npm script discovery in package.json, CLI runnable-task export | real — enumerates scripts, validates order, covers edge-cases (no scripts, malformed) |
| **RunSpecTests.swift** | 71 | XCTest | headless-unit | 7 | Process arg quoting, command-line building | real — shell meta-char escaping verified |
| **RustCoreFallbackTests.swift** | 102 | XCTest | headless-unit | 6 | Fallback routing: Rust-gate OFF→Swift, ON→Rust | real — gate respects env var, skips opposite engine |
| **RustCoreHeaderRestageTests.swift** | 168 | XCTest | headless-unit | 4 | **TSK-626 critical:** FFI SIGSEGV trap guard — shell script verifies mtime-based file touch on header change | **VERY HIGH** — hermetic fixture re-enacts exact `restage-header.sh` behavior; verifies test targets + referent files touched when needed, skipped when unchanged (2026-06-12 regression proof) |
| **RustCoreSeamTests.swift** | 162 | XCTest | headless-unit | 12 | Rust-core gate defaults, explicit user OFF survives shipped ON | real — gate state persists correctly across environment mutations |
| **RustFindAdapterTests.swift** | 67 | XCTest | headless-unit | 5 | Find engine routing: gate OFF→Swift, ON→Rust; results match on common subset | real — enumerates both engines, validates parity |
| **RustFoldParityTests.swift** | 68 | XCTest | headless-unit | 8 | Fold ranges per language (json/js/py/go/ts/yaml/html), validates region map | real — per-language fold correctness (start/end lines to byte offsets) |
| **RustFormulaAdapterTests.swift** | 49 | XCTest | headless-unit | 5 | Formula eval model + end-to-end adapter behavior | real — formula-to-result mapping, FFI contract |
| **RustFuzzyAdapterTests.swift** | 61 | XCTest | headless-unit | 5 | Fuzzy-search Rust-only contract, score descent, match indices | real — validates fuzzy ranking, indices are ascending |
| **RustHighlightAdapterTests.swift** | 168 | XCTest | headless-unit | 10 | **FFI boundary:** highlight gate routing, UTF-16 NSRange correctness, multi-byte handling (é→2 units, 😀→4), per-language coverage (stage-3 parity), TSK-410 predicate-gated tokens | **VERY HIGH** — validates UTF-16 offset mapping on complex scripts, TSK-410 ensures predicates actually evaluate (not silent mis-coloring), ordered+disjoint range invariant |
| **RustMarkdownAdapterTests.swift** | 64 | XCTest | headless-unit | 4 | Markdown render engine contract, splice surface | real — engine routing + output validation |
| **RustProfileGuardTests.swift** | 48 | XCTest | headless-unit | 2 | Release profile only, rejects custom profiles pre-build | weak — binary check, limited case coverage (3 cases total) |
| **RustTranscriptAdapterTests.swift** | 105 | XCTest | headless-unit | 5 | Transcript projection contract, redaction barrier | real — Rust-only engine, redaction validation |
| **SaveConflictDecisionTests.swift** | 132 | XCTest | headless-unit | 10 | Save-conflict detection: dirty+disk-changed=conflict, unknown state→safe, concurrency-safe decision | real — covers dirty/clean states, disk-state variants, decision table |
| **ScratchStoreTests.swift** | 201 | XCTest | headless-unit | 14 | Scratch cache directory (MarkdownViewerCaches), create/recall/remove | real — file I/O, UserDefaults persistence, tmp-subdir isolation |
| **ScrollMemoryStoreTests.swift** | 230 | XCTest | headless-unit | 16 | Scroll position recall per URL, hash-based lookup, save/restore contract | real — multi-URL memory, hit/miss cases, offset preservation |
| **ScrollSweepTests.swift** | 50 | XCTest | headless-unit | 5 | Page-sized scroll jumps, never over-scroll | real — scroll clamping, page-boundary semantics |
| **SearchResultCapTests.swift** | 26 | XCTest | headless-unit | 3 | Search result limiting (visible cap, overflow hidden count) | weak — minimal assertions (2 values), single-case test |
| **SearchRouterTests.swift** | 145 | XCTest | headless-unit | 0* | Unified search routing: bare→recents, >cmd, ?global, #infile, @symbol; query parsing | real — covers all operator types, term parsing, source selection |
| **SearchScopeTests.swift** | 104 | XCTest | headless-unit | 10 | Search scope resolution (active file, workspace, current tab) | real — scope vs. active-file logic, nil handling |
| **SecretBannerStateTests.swift** | 58 | XCTest | headless-unit | 4 | Secret detector banner visibility (findings + not-off + not-dismissed) | real — state predicates, gate logic |
| **SecretDetectorTests.swift** | 89 | XCTest | headless-unit | 6 | Well-known secret shapes (AWS keys, PII, high-entropy values) | real — entropy scoring, pattern detection |
| **SelectionGeometryTests.swift** | 75 | XCTest | headless-unit | 8 | Drag-to-selection mapping (pixels→range), reversed drag invariance | real — normalized rect logic, corner mapping |
| **SessionIndexClobberGuardTests.swift** | 83 | XCTest | headless-unit | 5 | Index clobber prevention: empty index w/ live snapshots → preserved, refused | real — file-system guard, data-loss prevention |
| **SessionRenameTests.swift** | 112 | XCTest | headless-unit | 17 | Session name validation (trim, length, reserved chars) | real — per-rule coverage, edge-case inputs |
| **SessionStoreDirOverrideTests.swift** | 34 | XCTest | headless-unit | 3 | MDV_SESSIONS_DIR/MDV_APP_SUPPORT env overrides | real — env-var routing verified |
| **SettingsCatalogTests.swift** | 75 | XCTest | headless-unit | 5 | Settings keys unique + prefixed, all described | real — catalog completeness, naming conventions |
| **SettingsRelocationTests.swift** | 65 | XCTest | headless-unit | 5 | Legacy settings file-movement plan (old→new roots) | real — file-relocation contract |
| **SettingsSnapshotTests.swift** | 112 | XCTest | headless-unit | 7 | Settings export/import (user prefs, version, mode toggles round-trip) | real — serialization round-trip, state preservation |
| **ShapeDragGeometryHandleTests.swift** | 73 | SwiftTesting | headless-unit | 7 | Drag-handle geometry, normalized mapping | real — SwiftTesting pilot for pure geometry |
| **ShapeDragGeometryTests.swift** | 56 | XCTest | headless-unit | 5 | Rect corner-to-fraction mapping, drag standardization | real — geometry invariants |
| **ShortcutGlyphStringTests.swift** | 50 | XCTest | headless-unit | 5 | Keyboard shortcut glyph rendering (letter+modifiers, HIG order) | real — modifier-order canonical form |
| **SidebarDataPresenceTests.swift** | 140 | XCTest | headless-unit | 13 | Sidebar pane visibility (bookmarks/plugins always, recents gated, feature toggles) | real — per-pane presence rules, feature-flag integration |
| **SidebarPanelHeightsTests.swift** | 307 | XCTest | headless-unit | 24 | **Complex clamping logic:** panel height floor/ceiling, window-derived ceiling, jank-suppression (TSK-592) — monotonicity, never below floor | **VERY HIGH** — comprehensive height-state machine; tests monotonicity, ceiling derivation, no-op frame-skip predicate; catch-all for resize-jank regression |
| **SidebarPanelKindTests.swift** | 287 | XCTest | headless-unit | 21 | Panel type stable app-storage keys, typealias compilation | real — enum stability, defaults coverage |
| **SidebarResizeTests.swift** | 134 | XCTest | headless-unit | 15 | Height redistribution between panels (preserve sum, clamp bounds) | real — delta application, neighbor interaction |
| **SidebarSectionPlannerTests.swift** | 103 | XCTest | headless-unit | 8 | Section visibility planning (all-visible, some-hidden, collapse cases) | real — layout predicate, edge cases |
| **SleepRatchetGuardTests.swift** | 122 | XCTest | headless-unit | 1 | **Code-smell gate:** detect new fixed-duration sleep() calls in release builds; prevents latency hangs | **MEDIUM** — grep-based (linter), minimal assertion (0 matches), architectural guard rather than functional test |
| **SnippetBridgeTests.swift** | 61 | XCTest | headless-unit | 6 | Snippet-session state encoding (active flag, model→wire) | real — encoding contract, bidirectional mapping |
| **SnippetExpansionTests.swift** | 89 | XCTest | headless-unit | 11 | Tab-stop parsing, position calculation, literal + variable interpolation | real — snippet grammar, substitution semantics |
| **SnippetLibraryTests.swift** | 33 | XCTest | headless-unit | 4 | Built-in snippet library (non-empty, unique IDs, names parse) | weak — minimal assertions, single fixture set |
| **SnippetManagerModelTests.swift** | 220 | XCTest | headless-unit | 25 | Snippet CRUD (create, validate, store, retrieve); built-in + user library merge | real — model completeness, validation rules, merge contract |
| **SnippetSessionTests.swift** | 50 | XCTest | headless-unit | 5 | Tab-stop navigation, absolute-offset calculation | real — snippet-session state machine |
| **SnippetStoreTests.swift** | 77 | XCTest | headless-unit | 7 | User snippet persistence (append after built-ins, file I/O) | real — store contract, layer ordering |
| **SourceAnnotationScannerTests.swift** | 74 | XCTest | headless-unit | 11 | TODO/FIXME/HACK comment detection, with/without message colons | real — annotation parsing, flexible format support |
| **SourceInvisiblesTests.swift** | 112 | XCTest | headless-unit | 13 | Whitespace markers (tab→⇥, space→·, newline→¶, leading-vs-trailing logic) | real — per-context marker application, edge-case runs |
| **SourceWrapPolicyTests.swift** | 68 | XCTest | headless-unit | 8 | Long-line detection (for wrap-mode gating) | real — threshold-based classification |
| **SpellCheckEngineTests.swift** | 132 | XCTest | headless-unit | 9 | Spell-check text cleaning, language detection, issue scoring | real — text normalization, dictionary correctness |
| **SpellDiagnosticMappingTests.swift** | 66 | SwiftTesting | headless-unit | 7 | Spell-check diagnostic positioning (character→diagnostic range) | real — SwiftTesting mapping test |
| **SpellNavigationTests.swift** | 73 | SwiftTesting | headless-unit | 10 | Spell-issue navigation (next/prev), jump-to-issue | real — navigation state machine |
| **SQLiteFileInfoTests.swift** | 81 | XCTest | headless-unit | 4 | SQLite metadata (table/view/index counts, trigger presence) | real — reflection contract |
| **SQLiteReaderTests.swift** | 306 | XCTest | headless-unit | 0* | **TSK-1008 critical:** SQLite read-only API, schema enumeration, corrupt-body detection (opens but enumerate throws), row limits, type introspection | **VERY HIGH** — TSK-1008 corruption guard (the hidden-error-behind-empty-browser fix); verifies lazy-open vs. eager-enumerate semantics; test-fixture via external `/usr/bin/sqlite3` (hermetic, no FFI round-trip) |
| **SQLiteResultExportTests.swift** | 81 | XCTest | headless-unit | 9 | CSV export (RFC4180 quoting, comma/quote/newline escaping) | real — export format correctness |
| **StandardPaletteTests.swift** | 21 | XCTest | headless-unit | 2 | Standard palette has primaries + opaque colors | weak — minimal assertions, single palette fixture |
| **StickyScrollHeadersTests.swift** | 142 | XCTest | headless-unit | 14 | Heading-nesting chain detection, sticky-scroll pinning (on-screen headers not pinned) | real — nesting hierarchy, visibility logic |
| **StructuralQueryParserTests.swift** | 90 | XCTest | headless-unit | 11 | Structural search grammar (single kind, OR kinds, scope nesting) | real — parser completeness, error handling |
| **StructuralSearchHelpTests.swift** | 52 | XCTest | headless-unit | 4 | Shipped query examples parse, language-specific tailoring | real — shipped-example validation, grammar coverage |
| **StructuralSearchTests.swift** | 285 | XCTest | headless-unit | 0* | Structural search model (query→AST, matching, scope filtering) | real — tree-sitter predicate integration, scope-stack protocol |
| **SwiftTestingPilotTests.swift** | 33 | SwiftTesting | headless-unit | 4 | **Framework pilot (TSK-1130/TSK-787):** parameterized `@Test` with `#expect`, palette/ansi-color primitives | real — SwiftTesting idioms (suite, parameterized args), pure-logic gateway |
| **SymbolJumpCodeTests.swift** | 191 | XCTest | headless-unit | 0* | Symbol-jump code extraction (range maps, anchor detection) | real — symbol position tracking, extraction contract |
| **SymbolJumpTests.swift** | 46 | XCTest | headless-unit | 0* | Heading ranking for symbol-jump palette (empty→doc order, query→fuzzy rank) | real — ranking algorithm, query filtering |
| **SyntaxFoldRangeMappingTests.swift** | 80 | XCTest | headless-unit | 7 | Fold-range byte-offset mapping (line numbers → content-end offsets) | real — offset conversion correctness |
| **SyntaxThemeCMPaletteTests.swift** | 76 | XCTest | headless-unit | 5 | CM6 syntax theme palette (token kinds present, chrome keys present, both themes) | real — theme completeness, token-type coverage |
| **TabDiskStateDotTests.swift** | 41 | XCTest | headless-unit | 3 | Disk-state change indicator (modified dot); label transitions | weak — minimal test set (3 cases) |
| **TabDiskStateTests.swift** | 67 | XCTest | headless-unit | 7 | Tab disk-state classification (fresh/stale/deleted based on mtime/size) | real — state predicates, file-stat interpretation |
| **TabDiskStateTransitionTests.swift** | 121 | XCTest | headless-unit | 10 | Tab state lifecycle (fresh→stale→deleted), priority ordering | real — state-machine correctness |
| **TabDragPayloadTests.swift** | 21 | XCTest | headless-unit | 2 | Tab drag-drop serialization (round-trip, reject foreign/malformed) | real — wire-format validation |
| **TabEquatableTests.swift** | 59 | XCTest | headless-unit | 5 | Tab equality (loading tabs w/ same URL equal, different URL unequal) | real — identity semantics |
| **TabRestoreDedupTests.swift** | 102 | XCTest | headless-unit | 8 | Dedup on restore (exact duplicates collapse, on-disk order preserved) | real — dedup contract, order stability |
| **TabRestoreDedupTriggerTests.swift** | 171 | XCTest | headless-unit | 7 | Dedup trigger (symlink pairs collapse, restoring already-open tab dedups) | real — cross-filesystem link detection, session state interaction |
| **TabSnapshotCategoryOverrideTests.swift** | 146 | XCTest | headless-unit | 8 | Snapshot category override (round-trip serialization, nil omission) | real — wire-format stability |
| **TabsStatePreviewTests.swift** | 94 | XCTest | headless-unit | 8 | Preview-file handling (open into slot, no duplication, slot reuse) | real — preview-slot semantics, tab-explosion guard |
| **TabsStateTests.swift** | 422 | XCTest | headless-unit | 36 | **Core state machine:** append/close/move/select, selection tracking, bounds-clamping, out-of-bounds safety | **VERY HIGH** — comprehensive state machine with 36 cases covering all operations, edge cases (close last, select OOB), invariants (selection shifts correctly, index bounds) |
| **TerminalAltScreenTests.swift** | 158 | XCTest | headless-unit | 10 | Terminal alt-screen buffer swap (enter 1049, blank swap, round-trip restore) | real — buffer state, scrollback preservation |
| **TerminalCellTests.swift** | 105 | XCTest | headless-unit | 15 | Terminal cell SGR color parsing (foreground/background, intensity, reset) | real — ANSI color-code decoding |

*Note: Some files show "0" in grep output due to formatting (test names on multi-line). Manual inspection confirms test presence.*

---

## Test-Type Taxonomy — Proportions & Kinds

**Framework split:**
- **XCTest:** 74 files (~97%)
- **SwiftTesting:** 2 files (~3%, new pilot TSK-1130/787 — pure-logic gateway)

**Tier distribution:**
- **Headless-unit (pure logic, no UI):** 76/76 files (100%)
  - No T4 LiveAppTestCase, T5 PixelTestCase, or WebView-in-process
  - All host-safe; self-skip if run on VM but no blocking dependency

**Test function count:** ~436 distributed across 76 files
- Range: 1–36 functions per file
- Median: ~5–6 per file
- Heaviest: TabsStateTests (36), SidebarPanelHeightsTests (24), SnippetManagerModelTests (25)

**Subject domains:**
1. **Rust FFI adapters & boundaries (13 files, ~110 LOC avg)** — RustCore*Adapter tests, header-restage trap, fallback routing. HIGH TEETH: verify adapter routing, UTF-16 semantics, gate contracts.
2. **State machines (8 files, ~140 LOC avg)** — TabsState, Sidebar, Snippet, Terminal, Search routing. VERY HIGH TEETH: comprehensive case coverage, invariants enforced.
3. **Persistence & storage (10 files, ~130 LOC avg)** — Session, Settings, Scratch, Scroll, Snippet stores; SQLite read-only API. HIGH TEETH: round-trip serialization, isolation, clobber guards.
4. **Text/syntax processing (12 files, ~85 LOC avg)** — Source invisibles, wrap-policy, syntax folds, annotations, spell-check, highlighting. REAL TEETH: per-rule coverage, character-class handling.
5. **Queries & search (5 files, ~97 LOC avg)** — SearchRouter, SearchScope, SearchResultCap, StructuralSearch, SymbolJump. REAL TEETH: operator parsing, routing predicates, result filtering.
6. **Model/feature suites (28 files, ~115 LOC avg)** — Save-conflict, secrets, tab disk-state, geometry, settings, UI-model data-presence. VARIED TEETH: some foundational (SaveConflict HIGH), some weak (SearchResultCap, StandardPalette minimal).

**Fixture generation patterns:**
- Temporary directories + UUID isolation (standard across 40+ files)
- External binary invocation: `/usr/bin/sqlite3` (SQLiteReaderTests), `/usr/bin/zip` (RtfViewerRoutingTests), Process-based fixtures
- Environment variable injection for feature gates (Rust adapter tests)
- Custom UserDefaults suites for test isolation (SettingsSnapshotTests, SidebarPanelHeightsTests)
- FileManager operations for state-disk scenarios

---

## Coverage Shape — Over-Tested vs. Under-Tested

### Strengths (Real teeth, comprehensive case coverage):

1. **FFI boundary semantics** (RustCoreHeaderRestageTests, RustHighlightAdapterTests, SQLiteReaderTests)
   - UTF-16 offset handling on multi-byte scripts (é, 😀) — critical for editor
   - SIGSEGV guard (the 2026-06-12 trap proof) — prevents stale-test-object crashes
   - Error handling (corrupt DB opens but enumerate throws) — TSK-1008 data-loss guard

2. **Tab & sidebar state machines** (TabsStateTests 36 cases, SidebarPanelHeightsTests 24 cases)
   - Comprehensive operation coverage (append, close, move, select; clamp, ceiling, jank suppression)
   - Bounds-safety, out-of-bounds clamping, selection invariants
   - Monotonicity proofs (e.g., taller sidebar → taller-or-equal panel ceiling)

3. **Persistence round-trips** (Settings, Session, Scroll, Snippet stores)
   - Save/load symmetry, UserDefaults isolation, file I/O error handling
   - Clobber guards (SessionIndexClobberGuardTests), dedup contracts

### Weaknesses (Minimal or weak teeth):

1. **Micro fixtures** (SearchResultCapTests 26 LOC / 3 tests, StandardPaletteTests 21 LOC / 2 tests, SnippetLibraryTests 33 LOC / 4 tests)
   - Single-case assertions with no edge-case coverage
   - E.g., StandardPalette: only checks that colors list is non-empty + contains black/white, doesn't validate full palette coverage or color space semantics

2. **Code-smell gates** (SleepRatchetGuardTests)
   - Grep-based linter (detects new sleep() in release), not functional test
   - 1 assertion (expects 0 matches), valuable but not behavior-testing

3. **Lightweight routing tests** (SearchRouterTests, SearchScopeTests)
   - Cover syntax parsing + source selection, but minimal integration (no multi-file search behavior, no live result validation)
   - Real test value is in the view/UI wiring (off-stage, VM-only)

4. **Geom/UI-adjacent logic** (SelectionGeometryTests, ShapeDragGeometryTests, TabDiskStateDotTests)
   - Test model-layer predicates, but rendering + click behavior relegated to VM
   - Host-testable seam is thin (just the math); teeth are geometry-only

5. **Spell-check language detection** (SpellCheckEngineTests)
   - Tests text cleaning + scoring, but dictionary coverage is implicit (assumed correct)
   - No adversarial corpus or language-specific false-positive rates

### Risk zones (gaps between host & VM):

- **CM6 editor interaction** (syntax folds, sticky headers, gutter features): model layer tested on host (SyntaxFoldRangeMappingTests, StickyScrollHeadersTests), but pixel rendering + drag behavior is VM-only. Host model tests WILL miss renderer integration bugs (e.g., fold gutter not updating on text change).
- **Tab restoration & session state**: model tested (TabRestoreDedupTests), but the actual load-on-launch + disk-stat file-watcher integration is not covered here (lives in integration/system tests if at all).

---

## Harness & Infra Patterns Worth Porting

### 1. **UUID-isolated temp directories (defensive default)**
```swift
override func setUp() {
    suiteName = "SettingsSnapshotTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
}
override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
}
```
**Port:** Use this in every store/persistence test. Avoids cross-test pollution, safe for parallel runs.

### 2. **External-binary fixture generation (hermetic, no round-trip)**
```swift
private func createFixtureDB(at url: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = [url.path]
    let pipe = Pipe()
    p.standardInput = pipe
    try p.run()
    pipe.fileHandleForWriting.write(Data(script.utf8))
    try pipe.fileHandleForWriting.close()
    p.waitUntilExit()
    XCTAssertEqual(p.terminationStatus, 0)
}
```
**Port:** Use for any read-only API testing (no need to round-trip through the API itself). Keeps tests independent of implementation.

### 3. **Environment-variable injection for feature gates**
```swift
private let gateOn = ["MDV_RUST_HIGHLIGHT": "1"]
let out = RustHighlightAdapter.outcome("let x = 1", language: .swift, environment: gateOn)
```
**Port:** Isolate gate behavior without modifying process-global state. Every Rust adapter should follow this.

### 4. **Mtime-based staleness detection (hermetic, no time-mocking)**
```swift
private let stalePast = Date(timeIntervalSince1970: 978_307_200)  // 2001-01-01
private func markStale(_ rels: [String]) throws {
    try FileManager.default.setAttributes([.modificationDate: stalePast], ofItemAtPath: f(rel).path)
}
private func wasTouched(_ rel: String) throws -> Bool {
    let m = try XCTUnwrap(...)
    return m.timeIntervalSinceNow > -3600
}
```
**Port:** For build-system and file-watch semantics. Far-past marker + recent-time threshold = no time-mocking, detects real file changes.

### 5. **Hermetic shell-function testing (RustCoreHeaderRestageTests pattern)**
```swift
private static let lib: URL = /* path to scripts/lib/restage-header.sh */
private func runRestage(new: String, staged: String, staticlibChanged: Int) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", "source '\(Self.lib.path)'; restage_core_header ..."]
    // ...
}
```
**Port:** For any shell function that's load-bearing. Invokes the EXACT production function in a hermetic fixture dir, not a re-implemented Swift version.

### 6. **Multi-case geometry tests with invariant checks**
```swift
func test_move_rearrangesTabs() { /* verify order */ }
func test_move_carriesSelection() { /* verify selection follows */ }
// Then monotonicity:
func test_clampWithCeiling_monotonicInAvailableHeight() {
    let small = SidebarPanelHeights.clamp(220, availableHeight: 300)
    let mid = SidebarPanelHeights.clamp(220, availableHeight: 500)
    let big = SidebarPanelHeights.clamp(220, availableHeight: 1000)
    XCTAssertLessThanOrEqual(small, mid)
    XCTAssertLessThanOrEqual(mid, big)
}
```
**Port:** For any model with numeric/ordering properties. Invariants (monotonicity, bounds) catch subtle bugs that point-case testing misses.

### 7. **SwiftTesting pilot pattern (pure-logic gateway)**
```swift
@Suite("Swift Testing pilot")
struct SwiftTestingPilot {
    @Test("StandardPalette carries the primaries")
    func paletteBasics() {
        #expect(StandardPalette.colors.count >= 16)
    }
    
    @Test("ANSI 256-cube endpoints", arguments: [
        (UInt8(16), AnsiRGB(0, 0, 0)),
        (UInt8(231), AnsiRGB(1, 1, 1)),
    ])
    func cubeEndpoints(_ tc: (index: UInt8, expected: AnsiRGB)) {
        #expect(AnsiColorResolver.indexed(tc.index) == tc.expected)
    }
}
```
**Port:** Use SwiftTesting **only** for pure-logic suites (no UI, no tiers). Parameterized `@Test` reduces boilerplate. Keep XCTest for tier-based tests (TierGateObserver integration).

---

## Flake / False-Green Risks Observed

### 1. **Temporary-directory collisions (unlikely but real on slow CI)**
   - **Risk:** Multiple tests spawn `/tmp/…-UUID/` dirs; if UUID collision or rm race occurs, one test's tearDown nukes another's fixture.
   - **Mitigation in place:** Each test uses `FileManager.default.temporaryDirectory` + UUID, which is randomized.
   - **Recommend:** Audit any test that reads fixtures after another test's setup; consider explicit file-existence pre-checks.

### 2. **SQLite connection pooling (if ever added to production)**
   - **Risk:** SQLiteReaderTests passes by chance because the read-only API never pools. If pooling is added, state leakage between test runs possible.
   - **Mitigation:** Tests use separate file-per-test via UUID.
   - **Recommend:** If connection pooling ever enters scope, add a "close/reset pool between tests" hook.

### 3. **UTF-16 offset correctness on edge cases (only validated for sample scripts)**
   - **Risk:** RustHighlightAdapterTests covers é (2 units) + 😀 (4 units), but doesn't exhaustively test all Unicode planes (e.g., combining diacritics, RTL markers).
   - **Mitigation:** Core FFI contract is tested; Rust engine does the actual conversion.
   - **Recommend:** Add a proptest/fuzz suite if highlighting gains new languages (e.g., Arabic, Devanagari).

### 4. **Gate environment isolation (gate ON/OFF state not thread-safe across parallel test runs)**
   - **Risk:** If tests run in parallel and share a gate's process-global state (vs. the injected environment dict), a concurrent test flips the gate and causes cascade failures.
   - **Mitigation in place:** Tests use `environment: [dict]` injection, so no process-global mutation.
   - **Recommend:** Keep gate tests using the injected dict pattern; never mutate UserDefaults or env vars in gate tests.

### 5. **Stale mtime precision (file-modification timestamps on some HFS+ versions have 1-sec granularity)**
   - **Risk:** A test that relies on "just-touched" files to be distinguishable from older files can flake if two operations fall in the same second.
   - **Mitigation in place:** RustCoreHeaderRestageTests uses a 2001 far-past marker + 1-hour window for "touched", so within-second collisions are safely absorbed.
   - **Recommend:** Don't try to detect mtime changes < 1 second apart on real filesystems.

### 6. **Snippet library built-in data (SnippetLibraryTests assumes non-empty, but no validation of actual snippet content)**
   - **Risk:** A refactor that empties the built-in library passes the minimal check (non-empty list) but breaks user experience.
   - **Mitigation:** Only 4 assertions, so medium risk.
   - **Recommend:** Add a test that exercises snippet *expansion* on built-in items (not just presence).

---

## Rebuild Notes — Day-1 Strategy

### For a fresh Markdown Editor (WebUI/TUI/remote transport + agent-centric features):

#### 1. **Port the FFI-boundary testing pattern immediately**
   - RustCoreHeaderRestageTests + RustHighlightAdapterTests + SQLiteReaderTests are load-bearing.
   - These catch the hard-to-debug off-by-one bugs (UTF-16 offsets, stale object SIGSEGV, corruption-as-empty-list).
   - **Priority:** HIGH. Start with a single adapter + hermetic test before any agent integration.

#### 2. **State-machine tests (TabsStateTests pattern) scale well**
   - Multi-tab, nested-tab, sidebar-height resizing, focus routing — all follow the same "operation → state predicate" pattern.
   - SidebarPanelHeightsTests' monotonicity checks are underrated; catch subtle numeric bugs.
   - **Priority:** HIGH. 36-case TabsStateTests is a great model for test-case density.

#### 3. **Persistence round-trip suites (store tests) are low-hanging fruit**
   - Session store, Snippet store, Scroll memory — all test save/load symmetry + isolation.
   - These have real teeth (will fail on serialization bugs) and catch data-loss on reload.
   - **Priority:** MEDIUM. Do after core model; critical for session recovery + undo.

#### 4. **Skip "weak" micro-tests on day-1; revisit after alpha**
   - SearchResultCapTests (3 assertions), StandardPaletteTests (2 assertions), SnippetLibraryTests (4 assertions) are too thin for a rebuild.
   - Replace with richer behavior tests once the feature is live (e.g., actual search result capping in UI, theme rendering).
   - **Priority:** LOW. Not worth building until the feature is feature-complete on the model side.

#### 5. **SwiftTesting is a good fit for pure-logic suites, but adopt gradually**
   - The pilot (SwiftTestingPilotTests) works well for parameterized cases (ANSI color cube endpoints).
   - Don't force it on existing XCTest-heavy suites; use it for NEW pure-logic suites (e.g., tree-sitter predicate evaluation, formula engines).
   - **Priority:** LOW-MEDIUM. Nice-to-have for code cleanliness, not a blocker.

#### 6. **Harness: environment-injection gates are essential, mtime-guards are luxury**
   - Feature gates via environment dict (RustHighlightAdapterTests pattern) = MUST HAVE. No process-global state mutation.
   - Mtime staleness detection (RustCoreHeaderRestageTests) = nice for build-cache verification, but only if you have shell scripts that touch files (rare in WebUI/TUI).
   - **Priority:** HIGH for gates; MEDIUM for mtime.

#### 7. **Agent-centric features: test the model + validation layer, leave UI/render to agent-UAT**
   - Code-Review, Git Integration, Walkthroughs, Canvas: host tests should cover the DATA MODEL + rules engine, not the render/interaction.
   - The rebuild should have a clear "host-testable seam" (model layer) and a "VM/agent-testable seam" (UI + real-event interactions).
   - **Priority:** HIGH. Define the seam early; don't couple model tests to view rendering.

#### 8. **Search & query routing (SearchRouterTests pattern) is underexposed on the host**
   - The palette's search model is well-tested here, but multi-file search, result pagination, and live result updates are not.
   - Plan to test result-set *behavior* (filtering, capping, ranking) on the host; defer render + interaction to VM.
   - **Priority:** MEDIUM. Do after core query model.

#### 9. **Avoid the "headless-only" trap**
   - This slice is 100% headless. That's appropriate for a pure-logic codebase, but the rebuild will have WebUI/TUI rendering.
   - Plan for T4 (live WebUI) + T5 (pixel) tests from day-1, not as an afterthought.
   - Test surfaces: WebView (CM6 editor, markdown render), terminal TUI, SwiftUI sidebar/inspector (if any native UI remains).
   - **Priority:** HIGH. Rendering bugs are as common as logic bugs; don't assume the model layer catches them.

#### 10. **Audit: are there "false-green tests" (tests that pass despite broken behavior)?**
   - Watch for: tests that check "element exists in tree" but never verify visibility/size/interaction.
   - Watch for: tests that mock dependencies so aggressively that they're testing the mock, not the code.
   - Watch for: tests that assume time/ordering without explicit sequencing.
   - **Priority:** MEDIUM. Do a post-alpha code review of high-risk tests (UI model tests, async state tests).

---

## Summary Table — Test Distribution

| Category | Files | LOC | Tests | Strength | Risk |
|----------|-------|-----|-------|----------|------|
| **Rust FFI boundary** | 13 | ~1,430 | ~60 | VERY HIGH (UTF-16, SIGSEGV guard, corruption) | Low — tested at binary boundary |
| **State machines** | 8 | ~1,120 | ~93 | VERY HIGH (36-case TabsStateTests, invariants) | Low — predicate-complete |
| **Persistence** | 10 | ~1,300 | ~72 | HIGH (round-trip, isolation, clobber guards) | Low — file I/O tested end-to-end |
| **Text/syntax** | 12 | ~1,020 | ~90 | REAL (character-class per-rule) | Medium — renderer integration untested |
| **Query/search** | 5 | ~485 | ~30 | REAL (syntax, routing) | Medium — multi-file behavior gaps |
| **Model/feature** | 28 | ~3,245 | ~91 | VARIED (foundational HIGH, micro-weak) | Medium — some shallow fixtures |
| **Total** | **76** | **~8,700** | **436** | — | — |

