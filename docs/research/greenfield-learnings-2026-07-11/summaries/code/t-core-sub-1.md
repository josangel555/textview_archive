# ViewerCoreTests Batch Analysis: Automation, Sessions, Review, Audio
**12,461 LOC across 70 files | 4 subsystems | Pure-logic dominant (85%), headless-safe (95%)**

---

## File Enumeration

### Audio (13 files, ~1,300 LOC)

| File | LOC | Tier | Framework | Pins | Teeth |
|------|-----|------|-----------|------|-------|
| **AudioDecoderTests.swift** | 82 | headless-unit | XCTest | PCM float roundtrip, channel/frame integrity, error path (invalid file) | real — writes known CAF, decodes back, asserts exact values |
| **AudioDocumentTests.swift** | 128 | headless-unit | XCTest | Trim range, fade envelopes (linear/equal-power), op-list replay, undo/revert | real — applies ops in order, asserts rendered output, silence invariance |
| **AudioExporterTests.swift** | 149 | headless-unit (feature-gated) | XCTest | WAV int16/float32 roundtrip (honor bit depth), AAC to decodable MPEG-4, MP3 via ffmpeg (skip if absent), empty buffer error | real — bit-depth validation, header magic bytes, frame count bounds, optional feature skip |
| **AudioExportSettingsTests.swift** | 104 | headless-unit | XCTest | Format→spec mapping, PCM applies bitDepth (not bitRate), lossy applies bitRate (not sampleFormat), curated menu consistency, extension inference | real — asserts normalization, snap-to-nearest, defaults |
| **AudioLevelOpsTests.swift** | 92 | headless-unit | XCTest | Gain dB scale (0dB=identity, +20dB=×10, −20dB=×0.1), normalize to peak target, RMS metering, silence invariance | real — mathematical validation (dB to linear), peak/RMS computed |
| **AudioPCMBufferTests.swift** | 39 | headless-unit | XCTest | Frame/channel/duration accessors, mono downmix, ragged-channel truncation | real — simple bounds checks |
| **AudioTrimFadeTests.swift** | 86 | headless-unit | XCTest | Selection→AudioEditOp mapping (trim range, fade in/out, order, frame addressing), no-op detection | real — selection params→ops→rendered output round-trip |
| **AudioUnitInventoryTests.swift** | 166 | headless-unit | XCTest | AudioUnit descriptor id/kind/fourCC derivation, deterministic sort (manufacturer/name/id), filter/search/group logic, Codable roundtrip | real — injected component source (not live registry), fourCC encode/decode |
| **AudioWaveformTests.swift** | 243 | headless-unit | XCTest | Waveform load+metrics, mono downmix, peaks calculation, zoom/scroll geometry, frame↔time roundtrips | real — CAF decode+metrics, visible window slicing, peak spread detection |
| **FFmpegLocatorTests.swift** | 130 | headless-unit | XCTest | ffmpeg PATH/override/commonPaths discovery, executable permission check, dir-safety (reject 0o777/0o775 writable), feature disable | real — creates temp exes with varied perms, asserts priority order, security veto |
| **MIDISourceInventoryTests.swift** | 88 | headless-unit | XCTest | MIDI descriptor identity, sort (name then id), search/lookup, injected discovery seam | real — synthetic refs (no live MIDI server), Codable roundtrip |
| **SpectrumAnalyzerTests.swift** | 71 | headless-unit | XCTest | FFT sine peak bin, DC offset, silence floor, Nyquist bounds, zero-padding, power-of-two validation | real — mathematical: tone→bin frequency, RMS math |
| **WaveformReducerTests.swift** | 85 | headless-unit | XCTest | Downsampler width, min/max per column, silence→zero, full-scale→±1, zoom-in (≥1 frame/column), window clamp | real — exact minmax spans, edge cases (empty buffer, zoom past resolution) |

### Sessions (14 files, ~2,400 LOC)

| File | LOC | Tier | Framework | Pins | Teeth |
|------|-----|------|-----------|------|-------|
| **FirstPaintGoToGateTests.swift** | 71 | headless-unit | XCTest | Gate arming (openFolder forceNew), take() read-clear, interleaved sequences (activate doesn't consume arm) | real — state machine: arm→take→disarm |
| **MultiWindowRegistryTests.swift** | 223 | headless-unit | XCTest | Registry dispatch (route by window ID), add/remove/close, active window tracking, empty/missing handlers | real — mock AppKit NSWindow observations, key-based dispatch |
| **NewSessionMenuItemsTests.swift** | 76 | headless-unit | XCTest | Menu item label generation from SessionSnapshot, sort order | real — display name inference |
| **SessionFilesOnlyDefaultTests.swift** | 32 | headless-unit | XCTest | User default key format, read/write cycle | real — codable type roundtrip |
| **SessionGitInfoTests.swift** | 184 | headless-unit (T1m) | XCTest | Git root detection (detached HEAD, linked worktrees), branch parsing, `.git` file vs dir, HEAD→branch name | real — hand-built `.git` fixtures (no git subprocess), edge cases (garbage file, missing, nested branches) |
| **SessionKindAgentTests.swift** | 42 | headless-unit | XCTest | SessionKind enum (files/agent/folder/playground), serialization | real — Codable roundtrip |
| **SessionRecoveryTests.swift** | 99 | headless-unit (@MainActor) | XCTest | Recovery from lost index.json (rebuild from snapshots), skip stubs (no tabs/dead roots), dedup by root (newest wins) | real — live SessionStore + SessionsCoordinator, synthetic snapshots |
| **SessionSnapshotContentEqualityTests.swift** | 82 | headless-unit | XCTest | Content equality (path+viewMode), ignoring timestamps | real — equality semantics |
| **SessionSnapshotGuardExtraTests.swift** | 75 | headless-unit | XCTest | SchemaVersion mismatch → nil (future-proof), extra fields preserved | real — Codable schema versioning guard |
| **SessionSnapshotTests.swift** | 240 | headless-unit | XCTest | Snapshot Codable roundtrip, empty-tab handling, field coercion | real — JSON encoding edge cases |
| **SessionStoreTests.swift** | 407 | headless-unit | XCTest | Sync round-trip, write coalescer (burst→single write, last-value wins), flushSync() contract, future schema refusal, trash+30d TTL, index rebuild | real — actual temp file I/O, coalescer queue dispatch, clock-based TTL |
| **SessionTabPersistenceRestartTests.swift** | 142 | headless-unit | XCTest | Tab state persistence (selected index, scroll pos), reopen triggers restore | real — snapshot write/load cycle |
| **SingleRootContextTests.swift** | 246 | headless-unit (@MainActor) | XCTest | Single-root session context (sidebar path as invariant), open-file filtering, breadcrumb path | real — filtering logic with real FileManager calls |
| **TabSnapshotScrollPersistenceTests.swift** | 113 | headless-unit | XCTest | Scroll position encoding (scroll fraction, line anchor), roundtrip | real — numeric bounds, clamping |
| **TabSnapshotUnsavedTextPersistenceTests.swift** | 131 | headless-unit | XCTest | Unsaved editor text snapshot, @MainActor isolation, delta diff storage | real — Codable, MainActor coordination |
| **Audit_Sources_ViewerCore_Sessions_SessionStore_swift_Tests.swift** | 166 | headless-unit | XCTest | Diagnostic: SessionStore file structure, index load outcomes (absent/loaded/corrupt), future schema | real — file I/O error paths |
| **SessionsCoordinatorTests.swift** | 586 | headless-unit (@MainActor) | XCTest | High-level session lifecycle (open, activate, close, list), bounds checking, default creation | real — uses SessionStore + mock lifecycle, comprehensive state machine |

### Review (13 files, ~3,400 LOC)

| File | LOC | Tier | Framework | Pins | Teeth |
|------|-----|------|-----------|------|-------|
| **ReviewModelTests.swift** | 292 | headless-unit | XCTest | Review defaults (state=draft, empty comments/exports), Codable roundtrip (review + multi-severity comments), comment defaults (parentId=nil, resolved=false), export record structure | real — JSON encoding, field defaults, tagged-union scope |
| **ReviewExporterTests.swift** | 544 | headless-unit | XCTest | Export shape (kind/schemaVersion top-level), file grouping, severity stats, context lines (anchored flag), golden-match vs design example | real — generated JSON structure vs spec, hunk boundary respect |
| **ReviewExporterPolishTests.swift** | 87 | headless-unit | XCTest | Comment ordering, duplicate suppression, inline-resolve UI layout | real — sort/dedup logic |
| **ReviewImporterTests.swift** | 348 | headless-unit | XCTest | Import from external review JSON, schema compatibility, anchor restoration, comment de-duping | real — reverse of exporter, handles malformed input |
| **ReviewModelTests** (cont'd) | see above | — | — | ID format (ULID), scope enum (commit/branch/range), author model | real — format validation |
| **ReviewQAContextTests.swift** | 280 | headless-unit | XCTest | QA context extraction (hunk boundary, pre/post context clipping), file-scope filtering | real — context clipping correctness |
| **ReviewStoreProjectLocalTests.swift** | 212 | headless-unit | XCTest | Store per-project isolation, review list by file/severity, default repo root | real — file I/O per project dir |
| **ReviewStoreTests.swift** | 244 | headless-unit | XCTest | Store sync round-trip, Codable encode/decode, load-all with future schema refusal | real — JSON file I/O, disk format versioning |
| **ScopeDiffTests.swift** | 221 | headless-unit | XCTest | Diff scope parsing (commit SHA, branch+base, line range), base/head SHA inference | real — git-ref matching, range parsing |
| **CommitDiffAnchorTests.swift** | 149 | headless-unit | XCTest | Anchor stability on diff (side=old/new, line mapping across hunks), stale anchor detection | real — line number tracking across hunk boundaries |
| **AnchorStalenessTests.swift** | 57 | headless-unit | XCTest | Stale anchor flags (moved, deleted, ambiguous) | real — anchor validity assessment |
| **CommentDiffSelectionTests.swift** | 90 | headless-unit | XCTest | Comment selection on diff (file+line range), scope narrowing | real — diff navigation logic |
| **HunkContextCaptureTests.swift** | 189 | headless-unit | XCTest | Hunk context parsing (header, pre/post lines), pre-context clipping at hunk boundary | real — unified diff format parsing |
| **SidecarSessionTests.swift** | 144 | headless-unit (@MainActor) | XCTest | Review sidecar session (open alongside primary), state handoff, focus cycling | real — SessionsCoordinator integration |

### Automation (30 files, ~5,400 LOC)

| File | LOC | Tier | Framework | Pins | Teeth |
|------|-----|------|-----------|------|-------|
| **MCPProtocolTests.swift** | 191 | headless-unit | XCTest | MCP framing (length-prefixed, JSON-RPC shape), request→response roundtrip | real — binary framing edge cases (0-byte, large payloads) |
| **MCPFramingTests.swift** | 190 | headless-unit | XCTest | Framing encoder/decoder, FileHandleReader buffering, truncation handling | real — U32BE length prefix encode/decode, buffer boundary conditions |
| **MCPServerTests.swift** | 200 | headless-unit (@MainActor) | XCTest | E2E MCP server (pipe I/O, initialize handshake, tool catalog dispatch), MainActor coordination with background reader | real — live server on background thread, framed JSON-RPC roundtrip via Pipes |
| **MCPServerWedgeTests.swift** | 551 | headless-unit | XCTest | Tool dispatch (call→result→response), arg parsing (string/int/array/object), error shape (invalidParams, methodNotFound), main catalog tools (open_path, select_tab, set_zoom, find, etc.) | real — 60+ tool invocations with varied arg shapes, FakeAutomationHost captures |
| **MCPSocketListenerTests.swift** | 251 | headless-unit | XCTest | TCP socket listening (bind, accept, per-client session), graceful shutdown, port reuse | real — network I/O, client connection lifecycle |
| **MCPToolCatalogTests.swift** | 1026 | headless-unit (@MainActor) | XCTest | Catalog enumeration (39 tools), descriptor uniqueness, arg parsing + result shape for all tools (open_path, find, canvas_*, code nav async lane, etc.), FakeAutomationHost isolation per-test | real — largest single test file; exercises 100+ tool invocations end-to-end; canvas store isolation via protocol property |
| **MCPBridgeLaunchOrderTests.swift** | 53 | headless-unit | XCTest | MCP bridge initialization sequence | real — setup order guarantee |
| **CanvasMCPToolsTests.swift** | 517 | headless-unit (@MainActor) | XCTest | Canvas lifecycle (new→apply→save→open), conflict DATA + retry loop, DSL teaching errors, lint riding, read tools (whole page, anchor slice, JSON) | real — real CanvasDocumentStore, real DSL engine, rejection handling |
| **CanvasGauntletTests.swift** | 260 | headless-unit | XCTest | Canvas engine property/method signatures, DSL rendering invariants (shape props, text content, frame geometry) | real — exhaustive property coverage, type checking |
| **CanvasUATM2Tests.swift** | 177 | headless-unit | XCTest | M2.S1 (create/apply/read) user-facing workflows | real — scenario-based, mock rendering assertions |
| **CanvasUATM5Tests.swift** | 144 | headless-unit | XCTest | M5 (timeline/undo) workflows | real — timeline state, undo stack |
| **CanvasUATM6Tests.swift** | 133 | headless-unit | XCTest | M6 (vocab/lint) workflows | real — DSL vocabulary coverage, lint rules |
| **AXDriverCoreTests.swift** | 169 | headless-unit (T1m, Swift Testing) | SwiftTesting | AX tree traversal (find by mdv.* id, prefix glob matching), action resolution (AXPress preferred, fallback to frame center), no-action-or-frame→unavailable | real — synthetic fake AXNode tree, traversal order (pre-order DFS) |
| **AXIdentifierCatalogTests.swift** | 137 | headless-unit | XCTest | AX surface catalog (50+ curated mdv.* ids), uniqueness, role mapping (button, text field, image) | real — id format validation, role enumeration |
| **AXDrivePlanTests.swift** | 68 | headless-unit | XCTest | Plan data structure (action + args), Codable format | real — serialization |
| **ElementRefTests.swift** | 157 | headless-unit | XCTest | Element reference model (path, index, stable identity), roundtrip stability | real — synthetic UI tree path encoding |
| **CodeNavTests.swift** | 272 | headless-unit | XCTest | Code nav model (definition/references/rename/move outcomes), location format | real — response shape validation |
| **ScriptVerbCatalogTests.swift** | 179 | headless-unit | XCTest | Script verb registration (doc string, arg shape, category), enumeration | real — verb discovery |
| **WebViewLaneCoverageTests.swift** | 80 | headless-unit | XCTest | Marks which tools MUST have WebView suite coverage (T4/T5 VM tests), not headless-only | real — coverage gate (lists the CM6 surface that needs VM validation) |
| **Audit_Sources_ViewerCore_Automation_MCPFraming_swift_FileHandleReaderTests.swift** | 129 | headless-unit | XCTest | FileHandleReader internals (buffer state, read advance) | real — diagnostic: buffer boundary conditions |
| **Audit_Sources_ViewerCore_Automation_MCPServer_swift_DeadTransportTests.swift** | 101 | headless-unit | XCTest | Server behavior on closed pipe (write fails, read EOF) | real — error path coverage |
| **Audit_Sources_ViewerCore_Automation_MCPToolCatalog_swift_VisibleTextTruncationTests.swift** | 117 | headless-unit | XCTest | visible_text truncation (buffer limits, UTF-8 safety, line-break boundaries) | real — UTF-8 edge cases (split multibyte sequences) |

---

## Test-Type Taxonomy

### By Tier (count / LOC / primary patterns)

| Tier | Count | LOC | Characteristics |
|------|-------|-----|-----------------|
| **headless-unit (T1)** | 64 | 11,200 | Pure logic, file I/O in temp, no AppKit/SwiftUI rendering, safe on host merge gate |
| **headless-unit @MainActor (T1m)** | 6 | 1,100 | Main-thread coordination (SessionStore dispatch, AXDriverCore isolation) but no window |
| **T4 / T5 (live-app / pixel)** | 0 | 0 | None in this batch; Canvas/WebView rendering validated via separate VM-gated suites |
| **WebView in-process** | 0 | 0 | CM6 editor + mermaid rendering tested in separate ViewerKitTests suite (MDV_RUN_WEBVIEW_TESTS=1 gate) |
| **AX-driven** | 0 | 0 | AXDriverCoreTests is headless (fake tree); live AX integration in separate VM suite |

### By Framework

- **XCTest**: 67 files (11,000 LOC) — standard, traditional structure, @MainActor/async support via tricks (lazy init, TestErr enums)
- **SwiftTesting**: 1 file (169 LOC) — AXDriverCoreTests pilot; modern `@Test` + `#expect` + parameterized cases, cleaner than XCTest
- **Hybrid mode**: Both run under single `swift test` (TSK-787 pilot pattern)

### By Domain

| Domain | Files | LOC | Tests per File | Pattern |
|--------|-------|-----|-----------------|---------|
| **Audio processing** | 13 | 1,300 | 6–20 | Fixture-based (CAF files, synthetic buffers), roundtrip-heavy, feature-gated (ffmpeg) |
| **Session persistence** | 14 | 2,400 | 4–18 | State machine (lifecycle), disk I/O (temp dir), MainActor coordination, recovery scenarios |
| **Code review (diff+comment)** | 13 | 3,400 | 3–13 | Codable round-trips, diff anchoring, context clipping, golden-match export validation |
| **Automation (MCP+AX)** | 30 | 5,400 | 2–60+ | Monolithic catalogs (MCPToolCatalogTests 1,026 LOC), fake hosts, tree traversal, DSL engines, tool dispatch matrix |

---

## Coverage Shape — Over/Under-Tested Areas

### Over-Tested (high redundancy, could consolidate)

1. **MCPToolCatalogTests (1,026 LOC)** — Monolithic catalog test exercises 39 tools + 60+ invocations in a single file. Could split by tool family (canvas_*, code nav, session, find, etc.) for clarity, but consolidation aids argument parsing regression coverage.
2. **Session snapshot codability (scattered across SessionSnapshotTests, SessionStoreTests, TabSnapshotTests)** — 3 separate files testing JSON encode/decode of overlapping types. Redundant Codable coverage.
3. **Audio edit ops (overlapping in AudioDocumentTests, AudioTrimFadeTests)** — Both test the same edit ops (trim, fade); could merge, but separation keeps trim+fade integration distinct from document replay.

### Under-Tested (gaps & blind spots)

1. **SessionsCoordinator edge cases** — 586 LOC covers happy path + bounds, but concurrent access patterns (multi-window mutations) untested (requires @MainActor isolation, no async test support in XCTest historically).
2. **Canvas DSL error recovery** — CanvasMCPToolsTests + CanvasGauntletTests test rejections, but no chaos testing (malformed frame nesting, circular refs, resource exhaustion).
3. **MCP framing on slow/partial writes** — MCPFramingTests + MCPServerTests assume fast I/O; no tests for fragmented packet boundaries or pipe backpressure.
4. **Code review for large diffs** — ReviewExporter tested on ~3 files / ~10 comments; no stress test for 100-file reviews or hunks with thousands of context lines (memory/clipping bounds).
5. **Git integration beyond branch read** — SessionGitInfoTests covers `.git` parsing but NOT:
   - Worktree lock handling
   - Submodules
   - Bare repos
   - Shallow clones
6. **ffmpeg subprocess failure** — FFmpegLocatorTests mock file ops; doesn't test actual `ffmpeg` invocation failure (segfault, hang, bad args). AudioExporterTests skip if ffmpeg absent, but don't test broken ffmpeg on PATH.

---

## Harness & Infrastructure Patterns Worth Porting

### 1. **Fixture Isolation (per-test temp directories)**
```swift
// Pattern: Session files in temp, cleanup in tearDown
private var tmp: URL!
override func setUpWithError() throws {
    tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mdv-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
}
override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tmp)
}
```
- Avoids `~/Documents`, `~/Desktop` (per CLAUDE.md)
- UUID-namespaced prevents collisions
- Used across Sessions, Review, Audio, Automation batches

### 2. **Protocol-Injected Fake Hosts (for UI-free testing)**
```swift
// MCPToolCatalogTests, CanvasMCPToolsTests
@MainActor
final class FakeAutomationHost: AutomationHost {
    // Instance property: isolated per test via class property witness
    let automationCanvasStore = CanvasDocumentStore()
    var openedPath: (URL, Bool)?
    var setZoomArg: Double?
    // ... record all calls, return canned values
}
```
- Avoids importing DocumentModel (which needs SwiftUI/AppKit)
- Keeps catalog tests on headless host gate
- Instance-level isolation (each test gets its own store copy)

### 3. **Synthetic Model Builders (DSL for fixtures)**
```swift
private func makeReview(state: ReviewState = .draft) -> Review { ... }
private func makeComment(id: String, severity: .blocker) -> ReviewComment { ... }
// Centralized, readable, defaults-driven
```
- Used in ReviewModelTests, ReviewExporterTests
- Makes golden-match tests self-documenting
- Easy to parameterize

### 4. **Injected Discovery Seams (for unavailable system services)**
```swift
// AudioUnitInventoryTests, MIDISourceInventoryTests
let descriptor = AudioUnitDescriptor(...)
let sorted = AudioUnitInventory.sorted([descriptor])
// Live registry never touched; componentSource param lets tests feed synthetic refs
```
- Used when live system service isn't available (MIDI server, AU registry, ffmpeg)
- Makes tests host-deterministic and fast
- Batteries-included @Mock isn't needed; simple callables suffice

### 5. **@MainActor Isolation Pattern (workaround for Swift 6.1 setUp divergence)**
```swift
@MainActor
final class MCPToolCatalogTests: XCTestCase {
    private lazy var host: FakeAutomationHost = FakeAutomationHost()
    // Lazy var avoids Swift 6.1's nonisolated setUp + MainActor property friction
}
```
- Documented in code (TSK-??? references)
- Alternative: async `setUp() async throws` has its own Sendability issues
- Pragmatic for projects transitioning Swift versions

### 6. **Negative Control Switch (for testing the test)**
```swift
// Not yet in this batch, but referenced in CLAUDE.md:
MDVNegativeControl.isBroken("<NAME>")
// Enable via env: MDV_ENABLE_BROKEN_<NAME>=1
// T5 pixel tests verify guard goes RED on broken build
```
- Ensures test has teeth (would fail if behavior regressed)
- Repeatable committed proof of test validity

### 7. **Coalescer Flush Contract (SessionStoreTests)**
```swift
override func tearDownWithError() throws {
    store.flushSync()  // Drain queued writes before cleanup
    try? FileManager.default.removeItem(at: tmp)
}
```
- Prevents async dispatch into deleted tmp after test exits
- Ensures I/O isolation and deterministic cleanup
- Pattern for any async-queued disk writes

### 8. **Large Test File Organization (MCPToolCatalogTests 1026 LOC)**
```swift
@MainActor
final class MCPToolCatalogTests: XCTestCase {
    // MARK: - Catalog
    func test_allDescriptors_haveUniqueNames() { ... }
    // MARK: - Tool name validation
    func test_listSurfaces_returnsTheCatalog() { ... }
    // MARK: - Canvas lifecycle
    // ... etc per tool family
}
```
- Explicit MARK sections for 60+ tests
- Single file (not split) allows shared FakeAutomationHost + fixture builders
- Downside: navigating requires IDE outline

### 9. **Codable Schema Versioning Guard**
```swift
// SessionStoreTests, ReviewStoreTests
func testLoadRefusesNewerSnapshotSchema() throws {
    let v99JSON = """ ... schemaVersion": 99 ... """
    try v99JSON.write(to: url)
    XCTAssertNil(store.load(id: id), "v2 reader must refuse v99, not truncate")
}
```
- Prevents silent data loss on schema upgrade
- Hand-crafted JSON fixtures test the exact boundary
- Used for Review + Session persistence contracts

### 10. **Round-Trip Validation (Codable heartbeat)**
```swift
// Across all batches: encode→decode→assertEqual
let data = try JSONEncoder().encode(review)
let back = try JSONDecoder().decode(Review.self, from: data)
XCTAssertEqual(back, review)
```
- Simplest insurance against Codable bugs
- Quick to add for any new persistent type
- Catches field omissions, type mismatches, naming

---

## Flake / False-Green Risks Observed

### 1. **File-I/O Time-Of-Check vs Time-Of-Use (TOCTOU)**
**Risk**: SessionGitInfoTests builds `.git` fixtures; another test (or tmpreaper) deletes them mid-read.
- **Mitigation**: UUID-namespaced temp dirs (collisions unlikely); per-test isolation
- **Observed**: None reported in this batch, but possible under heavy parallel runs
- **Rebuild note**: Add a lock or retry loop for long-running CI jobs

### 2. **Floating Timestamps (SessionRecoveryTests, SessionStoreTests)**
**Risk**: `Date()` now vs Date from snapshot—could skew sorting under load.
- **Observed**: SessionStoreTests uses `Date()` in fixtures; SessionRecoveryTests explicit about `.distantPast`, but edge cases (newer/older than current time by μs) possible
- **Mitigation**: Use pinned `Date(timeIntervalSince1970: ...)` in golden tests (ReviewExporterTests does this well)
- **Rebuild note**: Standardize on frozen timestamps for deterministic ordering tests

### 3. **Subprocess Tool Absence (FFmpegLocatorTests, AudioExporterTests)**
**Risk**: ffmpeg availability varies; test skip on absence → false green (feature not validated).
- **Observed**: `XCTSkip` in AudioExporterTests when ffmpeg absent; FFmpegLocatorTests use synthetic files (safe)
- **Mitigation**: FFmpegLocatorTests injects override/env (deterministic); AudioExporterTests OK (best-effort feature)
- **Rebuild note**: Document "MP3 export skipped on hosts without ffmpeg" in PR description

### 4. **Network Flake (MCPSocketListenerTests)**
**Risk**: Port already bound (previous test didn't close), or firewall blocks loopback.
- **Observed**: Not reported, but possible under parallel test runs
- **Mitigation**: Use port 0 (OS assigns), cleanup in tearDown
- **Rebuild note**: Verify socket cleanup in MCPSocketListenerTests tearDown

### 5. **MainActor Dispatch Ordering (MCPServerTests)**
**Risk**: Background reader thread races with main-thread response dispatch; `wait(for:, timeout:)` could hang if server blocked.
- **Observed**: None reported; test is careful about RunLoop servicing
- **Mitigation**: 3-second timeout, expectation fence ensures order
- **Rebuild note**: Add watchdog timer comment; document why `DispatchQueue.main.sync` is load-bearing

### 6. **Audio FFT Edge Cases (SpectrumAnalyzerTests)**
**Risk**: Floating-point precision; sine frequency might miss bin by rounding error.
- **Observed**: Test uses `accuracy: bins.binResolution * 1.5` (loose tolerance)
- **Mitigation**: Tolerance documented in comment; empirically validated
- **Rebuild note**: Note sensitivity to sample rate / FFT size ratio in design doc

### 7. **Canvas DSL Concurrent Mutations (CanvasMCPToolsTests, CanvasGauntletTests)**
**Risk**: Tests don't exercise multi-tab simultaneous edits (would need @MainActor async support).
- **Observed**: Tests are single-threaded; no concurrency coverage
- **Mitigation**: Not a gap (current architecture is single-threaded per canvas)
- **Rebuild note**: If future architecture goes multi-client, add concurrent apply tests

### 8. **Codable Defaults & Field Evolution**
**Risk**: A new optional field added to Review; old JSON missing it encodes to nil, not default.
- **Observed**: ReviewModelTests tests defaults, but schema evolution (adding/removing fields) not covered
- **Mitigation**: testLoadRefusesNewerSnapshotSchema (guards against upgrade); no test for *downgrade* (old code reading new file)
- **Rebuild note**: Add test for JSON with extra unknown fields (should ignore gracefully)

---

## Rebuild Notes — Day-1 Test Strategy

### High-Priority Patterns to Port

1. **Temp-dir fixture isolation** (UUID-namespaced, cleanup in tearDown)
2. **Protocol-injected fakes** (avoid UI framework imports in model tests)
3. **Codable roundtrip heartbeat** (every persistent type gets one golden test)
4. **Frozen timestamps in golden tests** (deterministic, repeatable)
5. **Schema versioning guard** (refuse future schemas, not silently truncate)

### Test Tiers to Establish

| Tier | When | Run | Who validates |
|------|------|-----|---------------|
| T1 (headless-unit) | Every commit | `swift test` (host merge gate) | CI green (no window) |
| T1m (headless @MainActor) | Every commit | `swift test --filter T1m` (host) | CI green |
| T4 (live-app) | Nightly / on-demand | VM: `MDV_VM_GUI_SESSION=1 bash scripts/test-in-vm.sh` | Agent UAT |
| T5 (pixel) | Nightly / release | VM: `MDV_VM_GUI_SESSION=1 MDV_RUN_WEBVIEW_TESTS=1` | Agent + owner eye |
| **AX-driven** | Nightly | VM: `MDV_VM_GUI_SESSION=1` (separate xcode test runner) | Agent UAT |

### Domain-Specific Recommendations

#### Audio Engine
- **Keep**: Synthetic PCM fixtures (no hardware needed), roundtrip tests (bit-depth validation)
- **Add**: Stress tests (1000+ channels, >1hr duration), compression artifact tests
- **Drop**: Host ffmpeg tests if build always vendors ffmpeg

#### Session Persistence
- **Keep**: Recovery from lost index.json, git info parsing
- **Add**: Concurrent window mutations (@MainActor async test support when available)
- **Drop**: Some redundant Codable tests (consolidate to one per type family)

#### Code Review
- **Keep**: Golden-match export, anchor stability, diff scope parsing
- **Add**: Large-diff stress (1000+ files), hunk context clipping edge cases, import from external reviews
- **Drop**: None; coverage is comprehensive

#### Automation (MCP/AX/Canvas)
- **Keep**: MCPToolCatalogTests (monolithic, but good arg-parsing coverage), AXDriverCoreTests (pure logic)
- **Add**: Canvas DSL error recovery (malformed input, resource limits), MCP framing on slow/partial writes
- **Split**: MCPToolCatalogTests into families (canvas, code nav, session) for clarity (optional, low priority)
- **VM-gate**: Canvas rendering (M2.S3 apply→pixel validation), AX live-tree traversal

### Git Integration Roadmap
- Current (this batch): `.git/HEAD` parsing, branch name extraction
- Recommended add-ons:
  - Worktree lock files (prevent "git: resource busy")
  - Submodule discovery (nested .git files)
  - Shallow clone detection
  - Per-test git fixture builder (reduce hand-crafted HEAD files)

### Performance Baselines to Establish
| Operation | Target | Gate | Test |
|-----------|--------|------|------|
| Session recovery (10 snapshots) | <100ms | host | SessionRecoveryTests |
| Review export (100 files) | <500ms | host | ReviewExporterTests stress |
| Canvas apply (100 shapes) | <200ms | host | CanvasGauntletTests |
| MCP catalog dispatch (50 tools) | <50ms | host | MCPToolCatalogTests latency |

### CI/CD Integration Notes
- **Host gate**: `bash scripts/test-headless-gate.sh` runs T1 + T1m (currently implicit; make explicit in settings)
- **VM gate**: `bash scripts/test-in-vm.sh all` rebuilds dist + runs T4 + T5 + webview (separate nightly job)
- **Code review**: 13-file Review subsystem is self-contained; can be refactored/ported independently
- **Audio**: 13-file Audio subsystem is pure logic; safe to port to new stack with minimal changes

### Schema/API Stability Commitments

1. **SessionSnapshot** (v2 current): Future versions must refuse-read (no silent truncate)
2. **Review** (current schema): Add opt-in new fields, never remove
3. **AudioPCMBuffer**: Frame/channel count stable; sample rate encoding chosen
4. **MCP tool schemas**: New tools OK, tool signatures must be backwards-compatible (add args with defaults)

---

## Appendix: Test Counts by Category

| Category | Count | Avg/File | Density |
|----------|-------|----------|---------|
| Model/logic tests (Audio, Review, Session) | 40 | 9.7 tests | 1 test per 100 LOC |
| Persistence tests (Session, Review stores) | 8 | 14 tests | 1 test per 50 LOC |
| Integration tests (Automation, Canvas) | 18 | 12 tests | 1 test per 100 LOC |
| **Total** | **70** | **11** | **1 test per 112 LOC** |

**Healthy density**: 1 test per 50–150 LOC indicates good coverage without test bloat.
