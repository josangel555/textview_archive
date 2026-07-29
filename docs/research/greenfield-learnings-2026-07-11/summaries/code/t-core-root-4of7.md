# Test Batch 4/7: ViewerCoreTests (lines 229–304 of 457)

## File Enumeration

**Tests/ViewerCoreTests/HunkReviewStateTests.swift** (58 LOC) — tier: headless-unit · framework: SwiftTesting · pins: per-hunk approve/reject selection state model (TSK-941); toggling, resolve text, revert contracts · teeth: real

**Tests/ViewerCoreTests/ImageDrawOpsTests.swift** (242 LOC) — tier: headless-unit · framework: XCTest · pins: programmatic image rasterization (fill rect/ellipse/line/text); pixel sampling at top-left origin; color clamping; Codable round-trip · teeth: real

**Tests/ViewerCoreTests/ImageEditingTests.swift** (722 LOC) — tier: headless-unit · framework: XCTest · pins: image-editing engine spine; programmatic fixture drawing + pixel sampling; crop/rotate/flip ops; EXIF orientation; format normalization (premultiplied RGBA8 sRGB); temp-dir I/O · teeth: real

**Tests/ViewerCoreTests/ImageOrientationTests.swift** (225 LOC) — tier: headless-unit · framework: XCTest · pins: EXIF orientation group algebra + coalescing; render-equivalence property test (D4 group); normal form round-trip; eight-way orientation compose · teeth: real

**Tests/ViewerCoreTests/ImageResizeMathTests.swift** (32 LOC) — tier: headless-unit · framework: XCTest · pins: image resize math (percent scale + aspect-locked sizing); pixel floor to 1px minimum · teeth: real

**Tests/ViewerCoreTests/ImageViewportTests.swift** (84 LOC) — tier: headless-unit · framework: SwiftTesting · pins: viewport zoom/pan clamp + transformed rect; pixel-under-cursor mapping; grid/ruler geometry (TSK-1088/TSK-1441) · teeth: real

**Tests/ViewerCoreTests/IndentConverterTests.swift** (64 LOC) — tier: headless-unit · framework: XCTest · pins: indent conversion (tabs↔spaces); leading-only scan; CRLF preservation; round-trip (TSK-675) · teeth: real

**Tests/ViewerCoreTests/InFileCompletionTests.swift** (52 LOC) — tier: headless-unit · framework: XCTest · pins: zero-server completion ranking (frequency→length→alpha); identifier rules; cursor extraction; empty/no-match edges (TSK-1127) · teeth: real

**Tests/ViewerCoreTests/InFileSearchTests.swift** (61 LOC) — tier: headless-unit · framework: XCTest · pins: in-file text scan (# operator); 1-based line numbering; case-insensitive matching; CRLF handling (TSK-727) · teeth: real

**Tests/ViewerCoreTests/InfraInvariantTests.swift** (179 LOC) — tier: headless-unit · framework: XCTest · pins: CI/infra build invariants—WebView lane gating (nightly-only, not pr.yml), SwiftPM/Rust caching, supply-chain audit (cargo-deny/cargo-audit), smoke-gate opt-in, killall footgun guards (TSK-1231/TSK-170/TSK-975/TSK-171/TSK-625) · teeth: real

**Tests/ViewerCoreTests/InsertionOrderedCacheTests.swift** (74 LOC) — tier: headless-unit · framework: XCTest · pins: bounded cache eviction model; insertion order tracking; overflow-to-target (not wipe); newest-survives + mid-recent retention (TSK-591) · teeth: real

**Tests/ViewerCoreTests/InstallAppGuidanceGuardTests.swift** (67 LOC) — tier: headless-unit · framework: XCTest · pins: install-app.sh user-facing guidance (script guard); CFBundleName "TextView" not legacy "MarkdownViewer" (TSK-1498) · teeth: real

**Tests/ViewerCoreTests/InstanceRegistryTests.swift** (227 LOC) — tier: headless-unit · framework: XCTest · pins: CLI instance discovery (register→discover→prune-stale→select-newest); injectable directory + liveness probe; command-envelope round-trip (TSK-353) · teeth: real

**Tests/ViewerCoreTests/InteractionProfilerTests.swift** (137 LOC) — tier: headless-unit · framework: SwiftTesting · pins: per-interaction felt-perf measurement (percentile math, budget verdicts, profiler span bookkeeping, nearest-rank percentiles) (TSK-1488) · teeth: real

**Tests/ViewerCoreTests/JQRunnerTests.swift** (65 LOC) — tier: headless-unit · framework: XCTest · pins: jq subprocess invocation (filter identity, field access, array chaining); skips if jq unavailable · teeth: real

**Tests/ViewerCoreTests/JsonConvertTests.swift** (80 LOC) — tier: headless-unit · framework: XCTest · pins: JSON→CSV conversion (inverse of CsvConvert.toJSON); union of keys, missing cells empty, number/boolean/null handling, quoting (View ▸ Copy as CSV) · teeth: real

**Tests/ViewerCoreTests/JSONFileStoreTests.swift** (280 LOC) — tier: headless-unit · framework: XCTest · pins: file-persisted JSON store; Codable round-trip; write-read-delete; metadata update; temp-dir I/O · teeth: real

**Tests/ViewerCoreTests/JSONSyntaxCheckerTests.swift** (84 LOC) — tier: headless-unit · framework: XCTest · pins: JSON syntax-error locator with 1-based line:column reporting (TSK-513); valid/invalid edge cases; escaping coverage · teeth: real

**Tests/ViewerCoreTests/JSStringEmbeddingTests.swift** (74 LOC) — tier: headless-unit · framework: XCTest · pins: JS line-separator sanitization (U+2028/U+2029 escaping); JSONSerialization→JS embedding safety (S1-C); idempotence · teeth: real

**Tests/ViewerCoreTests/JSTransformTests.swift** (136 LOC) — tier: headless-unit · framework: XCTest · pins: JS-over-JSON transform engine (sandboxed JSContext); property access, $ alias, array map, object results, error handling (TSK-698 slice 1) · teeth: real

**Tests/ViewerCoreTests/JUnitConverterTests.swift** (89 LOC) — tier: headless-unit · framework: XCTest · pins: test-output XML→JUnit conversion; time/status; test count aggregation · teeth: real

**Tests/ViewerCoreTests/KeyboardShortcutsCatalogTests.swift** (112 LOC) — tier: headless-unit · framework: XCTest · pins: keyboard-shortcut catalog model; conflict detection; metadata round-trip · teeth: real

**Tests/ViewerCoreTests/LaunchArgsTests.swift** (68 LOC) — tier: headless-unit · framework: XCTest · pins: app launch-argument parsing (repl, lsp, instance, edit modes); URI decoding; switch validation · teeth: real

**Tests/ViewerCoreTests/LaunchpadModelTests.swift** (91 LOC) — tier: headless-unit · framework: SwiftTesting · pins: app-launch orchestration model; start sequencing; async/await coordination · teeth: real

**Tests/ViewerCoreTests/LayeredImageDocumentTests.swift** (292 LOC) — tier: headless-unit · framework: XCTest · pins: image document with edit-op history; layer composition; op coalescing; pristine state · teeth: real

**Tests/ViewerCoreTests/LineAgeColoringTests.swift** (66 LOC) — tier: headless-unit · framework: XCTest · pins: line age color mapping (git blame); time→color gradient; refresh threshold · teeth: real

**Tests/ViewerCoreTests/LineBookmarksTests.swift** (127 LOC) — tier: headless-unit · framework: XCTest · pins: line bookmark store (add/remove/toggle/query); sparse set; persistence roundtrip · teeth: real

**Tests/ViewerCoreTests/LineDiffTests.swift** (255 LOC) — tier: headless-unit · framework: XCTest · pins: line-level unified diff engine; hunk detection; context lines; edge cases (empty, single-line files, CRLF) · teeth: real

**Tests/ViewerCoreTests/LineEndingConverterTests.swift** (56 LOC) — tier: headless-unit · framework: XCTest · pins: line-ending normalization (CRLF↔LF); detection + conversion; empty lines · teeth: real

**Tests/ViewerCoreTests/LineEndingDetectorTests.swift** (80 LOC) — tier: headless-unit · framework: XCTest · pins: line-ending inference from content (CRLF/LF/mixed); empty-file handling; majority heuristic · teeth: real

**Tests/ViewerCoreTests/LineOpsTests.swift** (76 LOC) — tier: headless-unit · framework: XCTest · pins: line editing operations (insert, delete, move, duplicate); line-range validation · teeth: real

**Tests/ViewerCoreTests/LinksCodeSpanTests.swift** (33 LOC) — tier: headless-unit · framework: XCTest · pins: markdown link/code-span parsing; bracket/paren matching · teeth: real

**Tests/ViewerCoreTests/LocalHistoryPolicyTests.swift** (142 LOC) — tier: headless-unit · framework: XCTest · pins: local-history retention policy (age-based pruning, size caps); age computation; decision rules (TSK-301) · teeth: real

**Tests/ViewerCoreTests/LocalHistoryStoreBehaviorTests.swift** (145 LOC) — tier: headless-unit · framework: XCTest · pins: local-history storage behavior (snapshot/diff adaptation, text-only filter, secret exclusion, 20MB cap per file, anchor promotion) (TSK-301) · teeth: real

**Tests/ViewerCoreTests/LocalHistoryStoreTests.swift** (398 LOC) — tier: headless-unit · framework: XCTest · pins: LocalHistoryStore end-to-end (snapshot/list/restore, adaptive full-vs-diff, exact reconstruction, byte cap + anchor promotion, text-only + secret exclusion, default-ON, dedup, per-file isolation, diff API, path-hash stability); injected time (TSK-1103) · teeth: real

**Tests/ViewerCoreTests/LocalHistoryVersionSourceTests.swift** (167 LOC) — tier: headless-unit · framework: XCTest · pins: local-history version reading (snapshot/diff reconstruction); delta decompression; time injection (TSK-301) · teeth: real

**Tests/ViewerCoreTests/LogPatternClustererTests.swift** (229 LOC) — tier: headless-unit · framework: XCTest · pins: pattern-based log line clustering (group similar messages by wildcard); frequency ordering; dedup · teeth: real

**Tests/ViewerCoreTests/LSPBinaryTrustTests.swift** (74 LOC) — tier: headless-unit · framework: XCTest · pins: LSP server binary trust decision model; code-sign verification; cached verdicts · teeth: real

**Tests/ViewerCoreTests/LSPCancellationTokenTests.swift** (30 LOC) — tier: headless-unit · framework: XCTest · pins: LSP cancellation token model (pending/cancelled state); request abort · teeth: real

**Tests/ViewerCoreTests/LSPClientSmokeTests.swift** (102 LOC) — tier: headless-unit · framework: XCTest · pins: LSP client initialization handshake smoke test (not full protocol, not I/O) · teeth: weak

**Tests/ViewerCoreTests/LSPCompletionCapabilityTests.swift** (45 LOC) — tier: headless-unit · framework: XCTest · pins: LSP server completion capability parsing (kind encoding) · teeth: real

**Tests/ViewerCoreTests/LSPCompletionDecodeTests.swift** (207 LOC) — tier: headless-unit · framework: XCTest · pins: LSP completion response decoding (items, labels, sort/filter text, kind); JSON shape validation · teeth: real

**Tests/ViewerCoreTests/LSPConfigurationTests.swift** (181 LOC) — tier: headless-unit · framework: XCTest · pins: LSP server runtime configuration (workspace settings push); env merge; hot update · teeth: real

**Tests/ViewerCoreTests/LSPDiagnosticsStoreTests.swift** (101 LOC) — tier: headless-unit · framework: XCTest · pins: diagnostic storage (per-file, per-range publication); clear; query by severity · teeth: real

**Tests/ViewerCoreTests/LSPDiscoveryTests.swift** (395 LOC) — tier: headless-unit · framework: XCTest · pins: LSP server discovery (walk-up heuristic, config file search); JSON schema validation; per-workspace overrides (LSP_DESIGN.md §11) · teeth: real

**Tests/ViewerCoreTests/LSPDocumentSymbolDecodeTests.swift** (83 LOC) — tier: headless-unit · framework: XCTest · pins: LSP document symbol response decoding (outline symbols, ranges, kinds) · teeth: real

**Tests/ViewerCoreTests/LSPFramingTests.swift** (221 LOC) — tier: headless-unit · framework: XCTest · pins: LSP message framing (CRLF-delimited headers + body length, multipart recovery); round-trip on various payloads · teeth: real

**Tests/ViewerCoreTests/LSPInitializeParamsTests.swift** (50 LOC) — tier: headless-unit · framework: XCTest · pins: LSP initialize-request parameters; client info; capability encoding · teeth: real

**Tests/ViewerCoreTests/LSPLanguageRegistryTests.swift** (123 LOC) — tier: headless-unit · framework: XCTest · pins: language→LSP server registry mapping; per-lang server selection; discovery integration · teeth: real

**Tests/ViewerCoreTests/LSPLanguageStatusTests.swift** (40 LOC) — tier: headless-unit · framework: XCTest · pins: LSP language initialization status (initing/ready/failed states) · teeth: real

**Tests/ViewerCoreTests/LSPMultiLanguageSmokeTests.swift** (163 LOC) — tier: headless-unit · framework: XCTest · pins: LSP multi-language coordinator smoke test; parallel server spawn + shutdown · teeth: weak

**Tests/ViewerCoreTests/LSPNavigationStoreTests.swift** (94 LOC) — tier: headless-unit · framework: XCTest · pins: LSP go-to-definition/reference index (URI→line:col mapping); query API · teeth: real

**Tests/ViewerCoreTests/LSPOverrideWriteBackTests.swift** (83 LOC) — tier: headless-unit · framework: XCTest · pins: LSP override-file persistence and reload cycle · teeth: real

**Tests/ViewerCoreTests/LSPPoolRestartTests.swift** (77 LOC) — tier: headless-unit · framework: XCTest · pins: LSP server pool restart semantics (replace, state reset) · teeth: real

**Tests/ViewerCoreTests/LSPPoolSmokeTests.swift** (190 LOC) — tier: headless-unit · framework: XCTest · pins: LSP server pool lifecycle smoke test (spawn, track, query alive) · teeth: weak

**Tests/ViewerCoreTests/LSPPoolTests.swift** (154 LOC) — tier: headless-unit · framework: XCTest · pins: LSP server pool model (add, remove, query, subscriptions) · teeth: real

**Tests/ViewerCoreTests/LSPPositionConverterPerfTests.swift** (245 LOC) — tier: headless-unit · framework: XCTest · pins: LSP position (UTF-16 byte offset) ↔ editor (line:col) converter performance; large-file benchmarks · teeth: real

**Tests/ViewerCoreTests/LSPPositionConverterTests.swift** (113 LOC) — tier: headless-unit · framework: XCTest · pins: LSP position converter (UTF-16 byte offset ↔ line:col); multi-byte handling · teeth: real

**Tests/ViewerCoreTests/LSPPositionConverterUTF16Tests.swift** (125 LOC) — tier: headless-unit · framework: XCTest · pins: LSP position converter UTF-16 encoding edge cases; surrogate pairs; emoji · teeth: real

**Tests/ViewerCoreTests/LSPProblemsViewModelTests.swift** (293 LOC) — tier: headless-unit · framework: XCTest · pins: LSP problems panel model (diagnostics grouping by file, severity filtering, go-to actions) · teeth: real

**Tests/ViewerCoreTests/LSPProtocolDecodeTests.swift** (88 LOC) — tier: headless-unit · framework: XCTest · pins: LSP protocol JSON decoding (method dispatch, error responses, type shape validation) · teeth: real

**Tests/ViewerCoreTests/LSPRequestIDTests.swift** (81 LOC) — tier: headless-unit · framework: XCTest · pins: LSP request ID model (int/string union type); encoding round-trip · teeth: real

**Tests/ViewerCoreTests/LSPServiceTests.swift** (115 LOC) — tier: headless-unit · framework: XCTest · pins: LSP service command API (completion, hover, go-to-def, diagnostics) · teeth: real

**Tests/ViewerCoreTests/LSPStatusChipTests.swift** (187 LOC) — tier: headless-unit · framework: SwiftTesting · pins: LSP server status display model (initing→ready/error states, error detail accumulation) · teeth: real

**Tests/ViewerCoreTests/LSPTrustEnforcementTests.swift** (79 LOC) — tier: headless-unit · framework: XCTest · pins: LSP server binary trust enforcement (allow-list + user trust store); cache · teeth: real

**Tests/ViewerCoreTests/LSPTrustStoreTests.swift** (84 LOC) — tier: headless-unit · framework: SwiftTesting · pins: LSP server trust store (add trusted binary by hash, query, forget); persistence · teeth: real

**Tests/ViewerCoreTests/LSPVSCodeExtensionsTests.swift** (212 LOC) — tier: headless-unit · framework: XCTest · pins: VSCode extensions→LSP server registry (parse extensions.json, server activation) · teeth: real

**Tests/ViewerCoreTests/LSPWorkspaceOverridesTests.swift** (932 LOC) — tier: headless-unit · framework: XCTest · pins: per-workspace lsp.json override loader (schema validation, precedence, env merge, default-discovery fallback); comprehensive edge cases (TSK-1103) · teeth: real

**Tests/ViewerCoreTests/LSPWorkspaceSymbolDecodeTests.swift** (143 LOC) — tier: headless-unit · framework: XCTest · pins: LSP workspace symbol response decoding (global search results, kind/range mapping) · teeth: real

**Tests/ViewerCoreTests/MacroControllerTests.swift** (113 LOC) — tier: headless-unit · framework: XCTest · pins: macro/keystroke automation controller (record, replay, context capture) · teeth: real

**Tests/ViewerCoreTests/MacroRecorderTests.swift** (260 LOC) — tier: headless-unit · framework: XCTest · pins: macro event recording and keystroke sequence serialization; round-trip; context preservation · teeth: real

**Tests/ViewerCoreTests/MarkdownFrontmatterTests.swift** (43 LOC) — tier: headless-unit · framework: XCTest · pins: YAML frontmatter extraction and stripping · teeth: real

**Tests/ViewerCoreTests/MarkdownHeadingShiftTests.swift** (57 LOC) — tier: headless-unit · framework: XCTest · pins: markdown heading level shifting (increase/decrease/set); nesting validation · teeth: real

**Tests/ViewerCoreTests/MarkdownLinksTests.swift** (79 LOC) — tier: headless-unit · framework: XCTest · pins: markdown link parsing (reference/inline/autolink); URL extraction; reference resolution · teeth: real

**Tests/ViewerCoreTests/MarkdownLintTests.swift** (71 LOC) — tier: headless-unit · framework: XCTest · pins: markdown linting rules (style, structure); violation detection; message clarity · teeth: real

**Tests/ViewerCoreTests/MarkdownOutlineSymbolsTests.swift** (54 LOC) — tier: headless-unit · framework: XCTest · pins: markdown heading outline extraction (symbol tree, nesting) · teeth: real

## Test-Type Taxonomy

This slice is **overwhelmingly headless-unit** (pure-logic, host-testable, no rendering):

- **Image engines (5 files, ~1.5 KLOC):** DrawOps, Editing, Orientation, ResizeMath, Viewport — programmatic fixture generation via CGContext, pixel sampling at top-left origin, EXIF algebra, format normalization
- **Text/line operations (10 files, ~700 LOC):** IndentConverter, LineOpsTests, LineDiff, LineEnding*, LineAgeColoring, LineBookmarks, Links/CodeSpan — scalar string manipulation, diffing, metadata storage
- **LSP infrastructure (28 files, ~4.2 KLOC):** discovery, framing, protocol decode, position converters, trust, pool, service, workspace overrides, diagnostics, symbols — all JSON protocol parsing + coordination models, no I/O
- **File I/O & persistence (6 files, ~900 LOC):** JSONFileStore, LocalHistory (3 files), InstanceRegistry, LaunchArgs — temp-dir fixture usage, Codable round-trip
- **Utilities & conversion (10 files, ~700 LOC):** JsonConvert, JSTransform, JQRunner, JUnit, Keyboard, Macro*, JSON syntax, JS embedding — transformation engines, subprocess bridges, catalog models
- **CI/Infrastructure guards (2 files, ~250 LOC):** InfraInvariant, InstallAppGuidance — committed-script validation, no code execution

**Framework split:** 4 SwiftTesting (newer pilot), 72 XCTest (stable, majority). SwiftTesting files are all pure-logic unit tests with no tier mixing.

**Tier distribution:**
- **Headless-unit (T1/T1m):** 76/76 (100%)
- **Smoke tests (weak teeth):** LSPClientSmoke, LSPMultiLanguageSmoke, LSPPoolSmoke (3 files flagged but still host-runnable)
- **No T4/T5/WebView/AX:** this slice is entirely host-testable; render/interaction layers are elsewhere (ViewerUITests)

## Coverage Shape

**Over-tested:**
- LSP infrastructure is heavily instrumented (28 files, 4.2 KLOC) with granular protocol tests: per-request-type decoders, per-capability decoders, position converters (including perf bench), multi-language smoke, pool lifecycle, trust enforcement, discovery, workspace overrides (932 LOC alone). This reflects the LSP surface being large and the protocol being error-prone (UTF-16 offsets, JSON shape variability).
- LocalHistory storage (3 files, ~700 LOC combined) covers snapshot/diff adaptation, dedup, per-file isolation, byte caps — thorough end-to-end.
- Image editing (4 files, ~1.2 KLOC) has render-equivalence property tests and extensive pixel sampling.

**Under-tested (or weak teeth):**
- LSP smoke tests (ClientSmoke, MultiLanguageSmoke, PoolSmoke) are listed as "weak" because they exercise lifecycle but don't assert behavior—they just ensure initialization succeeds. No response validation, no actual LSP requests.
- Macro recording (260 LOC) covers serialization but not the wiring to actual event sources.
- Markdown parsing (heading shift, links, outline, lint) is present but modest (3–7 files, ~260 LOC combined). Grammar is now a Rust engine (not in this slice).
- In-file completion & search (2 small files, ~110 LOC) are minimal and host-only (no server fallback tested).

## Harness & Infra Patterns Worth Porting

### Base-class hierarchy
- **None visible in this slice.** Most files `final class X : XCTestCase`, one `@Suite struct` (SwiftTesting). Each test is isolated; minimal shared setup.

### Fixtures & temporary resources
- **Programmatic fixture generation (image tests):** `makeContext`, `solidImage`, `quadrantImage`, `sampleRGBA` helper chains — build images in-memory via CGContext, verify pixel-by-pixel. No committed test images. Generalizable pattern: avoid binary fixtures, derive them.
- **Temp directories (file I/O tests):** `FileManager.default.temporaryDirectory + UUID()` injected in `setUpWithError`, cleaned in `tearDownWithError`. Standard and safe.
- **Injected time (LocalHistory):** time parameter in public APIs allows deterministic test ordering without mocking the system clock. Clean abstraction.

### Negative controls & teeth validation
- **InsertionOrderedCacheTests** names the tooth explicitly: `overflow_isBoundedEviction_notWipe` — the test **documents** what regression it guards (a revert to `removeAll()` would make the test go RED). Well-commented.
- **LSPWorkspaceOverridesTests** (932 LOC) is comprehensive because the domain (JSON schema validation, env merge, precedence rules) is subtle; the size is justified.
- **InfraInvariantTests** reads committed scripts and assertions CI configuration (caching, supply-chain gates, WebView lane isolation). These are structural guards, not behavioral tests, but they catch silent CI regressions (e.g., a refactor that drops `MDV_RUN_WEBVIEW_TESTS` from nightly.yml).

### Error-path coverage
- **LSP tests** extensively decode invalid/malformed protocol responses: missing fields, wrong types, empty arrays.
- **JSON syntax checker** covers valid + all error classes with 1-based line:col reporting.
- **Line ending detector** handles mixed CRLF/LF, empty files.
- Strong pattern: error cases are as thoroughly covered as happy paths.

### Encapsulation & black-box testing
- **LSP tests avoid mocking protocol I/O.** They test the **model + decode logic**, not the socket layer (that's TSK-400, out of scope). Result: tests are fast and deterministic.
- **LocalHistory storage uses real temp dirs** but injects time, allowing full end-to-end behavior testing (snapshot/restore/dedup) without real-time flakes.

## Flake & False-Green Risks Observed

### Real risks
1. **LSP perf benchmarks (LSPPositionConverterPerfTests):** wall-clock assertions under machine load can flake. File comment notes this; CLAUDE.md re-run guidance covers it.
2. **JQRunnerTests:** entirely skipped if jq is unavailable (`XCTSkip`). A CI runner without jq silently passes these tests. Acceptable for optional tooling, but worth flagging.
3. **Smoke tests (weak teeth):** LSPClientSmoke, LSPMultiLanguageSmoke, LSPPoolSmoke just assert initialization succeeds, not behavior. A broken LSP service that doesn't crash on startup would still pass.

### Low risk
- **Temp-dir tests:** properly isolated by UUID + cleanup. No interference between runs.
- **Programmatic fixtures:** no test data to go stale. CGContext pixels are deterministic.
- **Time injection:** LocalHistory tests run in deterministic time, no flakes from system clock.

## Rebuild Notes

### What to keep
1. **Image pipeline pattern:** programmatic fixture generation + pixel sampling is portable and high-confidence. Replicate for the new build.
2. **LSP model-only testing:** avoid I/O in unit tests; test decode logic and state models separately from socket/process management.
3. **Temp-dir usage:** `FileManager.default.temporaryDirectory` is standard on all platforms. Replicate exactly.
4. **CI/infra guard tests (InfraInvariant pattern):** commit script validation is cheap, bites hard, and catches silent CI regressions. Add these early.
5. **Error-path coverage discipline:** this slice shows every error case is tested (malformed JSON, out-of-range indices, missing fields). Maintain this.

### What to redo
1. **Smoke tests need teeth.** If a smoke test is in the suite, it must assert behavior, not just "didn't crash." Either wire them to real assertions (e.g., "LSP initialization returned a valid response") or move them to integration/UAT (T4/T5).
2. **LSP perf tests (wall-clock assertions):** either gate them behind a flag (e.g., `MDV_RUN_PERF_TESTS`) and run separately, or switch to a simpler metric (instruction count, bytes allocated) that's stable across hardware.
3. **Macro/keystroke layer:** the recording serialization is tested, but the wiring to actual event sources (NSEvent, system accessibility) is not in this slice. Add event-source tests once the new input layer is built.

### Harness upgrades for greenfield
1. **Adopt SwiftTesting universally for new pure-logic suites.** 4 SwiftTesting files in this batch show a smooth migration path; the `@Test` + `#expect` syntax is cleaner than `func test_` + `XCTAssert*`.
2. **Fixture factories as standalone utilities.** Instead of private nested helpers, extract `ImageFixtures`, `JSONFixtures`, etc. into shared modules so tests don't repeat CGContext setup.
3. **Table-driven tests for edge cases.** LSP decoding, line-ending detection, and indent conversion all have many edge cases. SwiftTesting's `@Test(arguments:)` parameterization is cleaner than XCTest's loop-in-test pattern.
4. **Structured test names & tags.** Group tests by domain (e.g., `@Test(.tags(.lsp, .protocol))`) so CI can run subsets (e.g., "only LSP decode tests, skip perf").

### Coverage priorities for day-1
1. **File I/O & persistence** (LocalHistory, JSONFileStore pattern): essential for the new app. Replicate the temp-dir fixture + round-trip pattern immediately.
2. **Text / line operations** (diff, indent, line ending): core editing layer. No surprises; replicate as-is.
3. **LSP infrastructure** (protocol decode, discovery, position converters): large surface, error-prone. Start with decode tests + position converters (UTF-16 is a perennial footgun).
4. **Image pipeline** (crop, rotate, EXIF): if the new build includes image editing, replicate the CGContext+sampling pattern day-1.
5. **CI guards** (InfraInvariant shape): add early to catch silent regressions in workflows.
