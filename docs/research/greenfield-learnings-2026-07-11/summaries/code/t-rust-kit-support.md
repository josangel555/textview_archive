# RustCore, ViewerKit, and TestSupport — Test Summary

**Batch scope:** 57 Swift test files covering FFI boundary tests, view-model value logic, wire codec validation, feature integration, system behavior (EINTR, OOM guard), audit findings, and shared fixtures.

**Total LOC:** ~6,500 lines; **Test functions:** 342 across XCTest framework only (no Swift Testing yet).

---

## File Enumeration

### RustCoreTests — 32 files (~3,200 LOC)

**FFI Boundary & Contract Tests (ABI version, capability bits, panic handling)**
- **ABTests.swift** (222 LOC) — tier: headless-unit · framework: XCTest · pins: CSV engine contract post-migration (delimiter sniffing, RFC-4180 quoting, ragged rows, wire/envelope plumbing) · teeth: real (checks byte-identical parse against retired Swift twin)
- **BridgeTests.swift** (240 LOC) — tier: headless-unit · framework: XCTest · pins: ABI version skew detector, capability bits ABI-pinned, panic→error mapping, oversized-frame → .tooLarge · teeth: real (linker-library version mismatch goes red)

**Wire Codec & MessagePack (serialization boundary)**
- **MessagePackEncoderTests.swift** (98 LOC) — tier: headless-unit · framework: XCTest · pins: round-trip encode/decode across all tag boundaries (uint/int size, string, array, map), multi-byte UTF-8, named-map Phase-B command shape · teeth: real
- **MsgPackDecoderNegative_Audit_Sources_RustCore_MessagePack_swift_Tests.swift** (201 LOC) — tier: headless-unit · framework: XCTest · pins: audit TSK-577 findings — negative/fuzz on frame layer (short header, length mismatch), truncation/EOF on every tag type, OOM guard (hugeDeclaredCount + shortBody → throw not abort), unsupported-tag, depth-cap · teeth: real (malformed bytes must throw specific errors, not crash)
- **MsgPackFieldAccessorTests.swift** (131 LOC) — tier: headless-unit · framework: XCTest · pins: map field-accessor fallback path, missing-key default, type checking · teeth: real
- **MsgPackFloatTests.swift** (39 LOC) — tier: headless-unit · framework: XCTest · pins: float32/64 encode round-trip · teeth: real
- **FrameBodySingleCopyTests.swift** (152 LOC) — tier: headless-unit · framework: XCTest · pins: frame unwrapping (u32-LE length prefix + body), single-copy semantics, slice ownership · teeth: real
- **FrameDecodeOffsetTests.swift** (48 LOC) — tier: headless-unit · framework: XCTest · pins: offset pointer chaining across nested decode, boundary checks · teeth: real

**Engine-Port A/B Contract Tests (STAGE-B deletion, parse equivalence)**
- **FindSearchABTests.swift** (102 LOC) — tier: headless-unit · framework: XCTest · pins: find_search grammar contract post-Rust-port (case-insensitive, whole-word, pattern syntax) · teeth: real (proves byte-identical local vs remote)
- **HexSearchABTests.swift** (60 LOC) — tier: headless-unit · framework: XCTest · pins: hex engine substring + offset search, byte-literal matching · teeth: real
- **HexRenderABTests.swift** (68 LOC) — tier: headless-unit · framework: XCTest · pins: hex render output (ASCII + hex columns, whitespace handling, line wrapping) · teeth: real
- **MarkdownRenderABTests.swift** (137 LOC) — tier: headless-unit · framework: XCTest · pins: markdown engine contract (ATX headers, lists, code blocks, emphasis, mermaid/math fence recognition) · teeth: real
- **DiffParseABTests.swift** (82 LOC) — tier: headless-unit · framework: XCTest · pins: unified-diff parsing (headers, hunks, three-way headers) · teeth: real
- **DiffHunkMarksABTests.swift** (66 LOC) — tier: headless-unit · framework: XCTest · pins: hunk-boundary marking (TSK-660) · teeth: real
- **IndentDetectABTests.swift** (45 LOC) — tier: headless-unit · framework: XCTest · pins: indent detection (spaces vs tabs, mixed, leading-only) · teeth: real

**Integration & Session Tests**
- **GateAndAdapterTests.swift** (69 LOC) — tier: headless-unit · framework: XCTest · pins: adapter mapping (raw session→model struct), error classification, result-wrapping · teeth: real
- **CanvasDocSessionTests.swift** (208 LOC) — tier: headless-unit · framework: XCTest · pins: canvas real-engine round-trip (insert/update/remove ops, patches, rev conflict, fence violations, lint rides apply response, idempotent replay) · teeth: real
- **FormulaEvaluateFFITests.swift** (40 LOC) — tier: headless-unit · framework: XCTest · pins: formula evaluation through engine · teeth: real
- **FoldRegionsBindingTests.swift** (36 LOC) — tier: headless-unit · framework: XCTest · pins: fold-region FFI binding · teeth: real

**Remote Transport Layer (loopback server, subscription, orphan store, signal handling)**
- **RemoteTransportLoopbackTests.swift** (203 LOC) — tier: headless-unit (self-skips without mdv-serve binary) · framework: XCTest · pins: TSK-652 acceptance — engine surface byte-equal local vs remote, capability-mask negotiation, all stateless wrappers (fuzzy, find, transcript, markdown, hex, diff, etc.) · teeth: real (spawns real server; equality divergence → red)
- **RemoteTransportEINTRTests.swift** (60 LOC) — tier: headless-unit · framework: XCTest · pins: framed IO EINTR retry (TSK-988), readFull loop, request-id monotonic/wrap semantics (TSK-994) · teeth: real
- **RemoteTransportUnsubscribeRaceTests.swift** (193 LOC) — tier: headless-unit · framework: XCTest · pins: unsubscribe race (subscription cleanup vs pending message arrival) · teeth: real (data race / assertion on stale cursor)
- **RemoteSubscriptionTests.swift** (227 LOC) — tier: headless-unit · framework: XCTest · pins: subscription register/unregister lifecycle, message dispatch, concurrent updates · teeth: real
- **RemoteOrphanStoreTests.swift** (133 LOC) — tier: headless-unit · framework: XCTest · pins: orphan-subscription cleanup (GC of unreachable subscriptions after timeout) · teeth: real

**System Behavior & Error Handling**
- **WireErrorClassifyTests.swift** (19 LOC) — tier: headless-unit · framework: XCTest · pins: wire-error classifier (TSK-669 frame shape: code, message, data arrays) · teeth: real
- **CoreTransportSeamTests.swift** (143 LOC) — tier: headless-unit · framework: XCTest · pins: transport registry / in-process vs remote seam, fallback behavior · teeth: real
- **EnvelopeRawAuxRoutingTests.swift** (57 LOC) — tier: headless-unit · framework: XCTest · pins: raw-auxiliary method routing through envelope · teeth: real
- **SessionPanicDeadFlag_Audit_Sources_RustCore_CoreClient_swift_Tests.swift** (117 LOC) — tier: headless-unit · framework: XCTest · pins: audit TSK-657 finding — panic dead-flag semantics (reused session must reset, no stale panic across calls) · teeth: real

**Perf Regression Guards (measured, not guessed)**
- **PerfMicroBundle2GuardTests.swift** (217 LOC) — tier: headless-unit · framework: XCTest · pins: TSK-845 — measured perf facts become guards: String.utf8.count is O(1) native + foreign-backed, MsgPackReader eager-decode is non-win vs lazy for hot CSV path (50k rows), lazy-tab-materialize is VM-only · teeth: real (O(1) ratio regresses to O(N) → red)

**Highlight & Theme**
- **HighlightOffsetOverflowTests.swift** (118 LOC) — tier: headless-unit · framework: XCTest · pins: offset overflow detection on large files (TSK-660 highlights), run-length clamp · teeth: real
- **ThemeColorParityTests.swift** (97 LOC) — tier: headless-unit · framework: XCTest · pins: theme color round-trip (RGB↔hex, named tokens) · teeth: real

---

### ViewerKitTests — 24 files (~2,800 LOC)

**View Mode & File Type Logic (pure value mapping, no UI)**
- **ViewModeControlTests.swift** (186 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: UX-A view-mode toolbar mapping — present(mode) → (primary, viewOnly, isFormatted), resolve(primary, viewOnly, available) → concrete mode with fallback (render→source on plaintext, render→preview on media, editor→hex on binary) · teeth: real
- **ViewModeEditorTests.swift** (145 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: editor-specific mode routing (CM6 entry, exit, syntax/theme state) · teeth: real
- **ViewModeCaretTests.swift** (33 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: caret position constraints (EOF clamp, line wrap) · teeth: real
- **ViewModeDefaultOverrideTests.swift** (123 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: file-extension-to-default-mode mapping, override by user pref · teeth: real
- **ViewModeFoldingTests.swift** (34 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: fold-state binding · teeth: real
- **ViewModeCanonicalLensTests.swift** (120 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: file-type → available-lens list (markdown→rendered/source/editor/hex, plaintext→source/editor/hex, binary→hex) · teeth: real
- **ViewModeHTMLRenderedTests.swift** (82 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: HTML render output formatting (head meta, body structure, CSS inline) · teeth: real
- **ViewModeMediaDefaultTests.swift** (168 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: media-type detection and default lens (image→preview, video→preview, unsupported→hex) · teeth: real
- **ViewModeSpreadsheetDefaultTests.swift** (21 LOC) — tier: headless-UI(T1m) · framework: XCTest · pins: spreadsheet auto-default (CSV/TSV→table mode) · teeth: real

**File Type & Categorization**
- **FileTypeDetectorTests.swift** (48 LOC) — tier: headless-unit · framework: XCTest · pins: file-type detection by extension + magic (JPEG/PNG magic, UTF8-BOM, etc.) · teeth: real
- **FileTypeDetectorKnownTextTests.swift** (61 LOC) — tier: headless-unit · framework: XCTest · pins: known-text detection (markdown, code, config, git formats) · teeth: real
- **FileCategoryMediaTests.swift** (62 LOC) — tier: headless-unit · framework: XCTest · pins: media MIME-type category (image/*.*, video/*.*, audio/.*) · teeth: real

**Content Routing & Applicability**
- **CanvasFileRoutingTests.swift** (38 LOC) — tier: headless-unit · framework: XCTest · pins: Canvas doc routing by file extension (.canvas, .cvs) · teeth: real
- **PDFRoutingContractTests.swift** (110 LOC) — tier: headless-unit · framework: XCTest · pins: PDF file routing contract (applicability, render path) · teeth: real
- **OpenAsViewerApplicabilityTests.swift** (137 LOC) — tier: headless-unit · framework: XCTest · pins: "Open as Markdown Viewer" context-menu applicability (file type whitelist + system-opener precedence) · teeth: real
- **VideoPlayabilityTests.swift** (67 LOC) — tier: headless-unit · framework: XCTest · pins: video file playability check (format, codec, duration detection) · teeth: real

**Rich Content & Highlighting**
- **HighlightedTextTests.swift** (277 LOC) — tier: headless-unit · framework: XCTest · pins: literal/regex highlight range matching (case-insensitive default, overlapping-match suppression, invalid-regex fallback, Unicode) · teeth: real
- **HighlightLanguageTests.swift** (175 LOC) — tier: headless-unit · framework: XCTest · pins: syntax-highlight language detection (file ext → lang, ambiguity resolution) · teeth: real
- **Audit_Sources_ViewerKit_HighlightedText_swift_ReDoSTests.swift** (134 LOC) — tier: headless-unit · framework: XCTest · pins: audit regex ReDoS protection (query expression complexity bounds, safe backtracking) · teeth: real

**UI State & Preferences**
- **ImageZoomStateTests.swift** (241 LOC) — tier: headless-unit · framework: XCTest · pins: image-zoom model (zoom in/out, fit-to-window, zoom-to-point, scale clamps) · teeth: real
- **HelpInfoTests.swift** (29 LOC) — tier: headless-unit · framework: XCTest · pins: help-info modal state · teeth: real
- **HelpInfoValueSemanticsTests.swift** (121 LOC) — tier: headless-unit · framework: XCTest · pins: HelpInfo equatable/hashable (identity, comparison) · teeth: real

**Configuration & Metadata**
- **InfoPlistTests.swift** (185 LOC) — tier: headless-unit · framework: XCTest · pins: Info.plist schema (bundle id, version, capabilities declarations) · teeth: real
- **Audit_Sources_ViewerKit_ViewMode_swift_SVGFormatterTests.swift** (48 LOC) — tier: headless-unit · framework: XCTest · pins: audit SVG formatter (escaping, nesting, attribute safety) · teeth: real

---

### TestSupport — 1 file

- **GitTestRepo.swift** (54 LOC) — tier: support (fixture builder, no tests) · framework: none · pins: shared git-fixture builder (consolidates 4-process init + config into one `/bin/bash -c` call for both ViewerCoreTests + ViewerUITests cross-target deps) · teeth: N/A (support code)

---

## Test-Type Taxonomy

### By Tier (per TierBaseCases hierarchy)

| Tier | Category | Count | Purpose |
|------|----------|-------|---------|
| **Headless-unit (T1/T1m)** | FFI boundary, codec, contract, value logic, state machines | 44 files | Host-safe, pure logic, no window/UI/async; regression guard on product code |
| **Headless-UI (T1m)** | View-mode mapping, routing, file-type logic | 9 files | Pure model/projection logic, no WebView/SwiftUI render |
| **Integration** | Session + real-engine, remote transport, spawn mdv-serve | 5 files | Still headless (no window), but multi-module or external binary |
| **Support** | Fixture builder (git repo) | 1 file | Cross-target shared library |

### By Pattern

| Pattern | Count | Examples |
|---------|-------|----------|
| **A/B contract tests** (STAGE-B migration proof) | 7 | CSV, find, hex, markdown, diff, indent |
| **Audit-driven tests** | 4 | MsgPack negative, panic dead-flag, ReDoS, SVG formatter |
| **Round-trip codec** | 5 | MessagePack encode/decode, frame, float |
| **Error-classification** | 3+ | WireError, OOM-abort guard, truncation/unsupported-tag |
| **System behavior** (EINTR, panic, signal handling) | 3 | EINTR retry, panic→error, signal-safety |
| **Perf regression guards** (measured, not guessed) | 1 | TSK-845 utf8.count O(1), lazy-decode non-win |
| **Remote transport & subscription lifecycle** | 4 | Loopback, unsubscribe race, orphan GC, request-id wrap |
| **View-mode resolution & fallback** | 9 | Toolbar buttons, file-type routing, media defaults |
| **File-type detection & applicability** | 5 | Magic-based, extension-based, MIME categories |

---

## Coverage Shape

### Strengths

1. **FFI Boundary is DENSE & RIGOROUS**
   - ABI version skew detector runs on every gate (host + VM) — catches linker library drift
   - Capability bits ABI-pinned with explicit bit-position assertions
   - Panic→error mapping proven end-to-end (test process survives)
   - Frame layer (length prefix, body truncation) exhaustively negative-tested

2. **Wire Codec (MessagePack) is DEFENSIVELY TESTED**
   - Round-trip on every tag-size boundary (fixint → int8 → int16 → int32 → int64)
   - OOM-abort guard (huge declared count + short body must throw, not abort) — audit-driven
   - Truncation on every container type (str, array, map, nested)
   - Unsupported-tag rejection (0xc1)
   - Depth-cap DoS guard
   - Type distinction (.int vs .uint on round-trip)

3. **Engine-Port A/B Contracts are BYTE-IDENTICAL PROOFS**
   - CSV (delimiter sniffing, RFC-4180 quoting, ragged rows, wire plumbing)
   - Find, Hex, Markdown, Diff, Indent all proven against STAGE-B retirement
   - Loopback-server tests (RemoteTransportLoopbackTests) prove carrier-swap transparency — local vs remote produce identical bytes

4. **System Behavior at Boundaries**
   - EINTR retry loop + partial-read accumulation (TSK-988)
   - Request-ID monotonic semantics (TSK-994)
   - Panic dead-flag reset (audit finding)
   - Subscription orphan cleanup (GC of unreachable subscriptions)

5. **View-Mode Routing is MODEL-SOUND**
   - Toolbar projection (ViewMode → (primary, viewOnly, isFormatted)) is lossless
   - Fallback logic is explicit: render→source on plaintext, render→preview on media, editor→hex on binary
   - File-type applicability is well-scoped (markdown vs plaintext vs binary paths)

### Under-coverage & Gaps

1. **NO WebView / CM6 Integration Tests at This Level**
   - View-mode tests are pure value-logic (T1m); no CM6 entry/exit/cursor behavior
   - Highlight tests are range calculation; no render-visible validation
   - SVG formatter audit → audit test only, no end-to-end render-path test

2. **NO UI/Live-App Tests in This Batch**
   - These files are explicitly headless; T4 (LiveAppTestCase) and T5 (PixelTestCase) are in ViewerUITests
   - Remote transport loopback spawns mdv-serve but runs in pure Swift (no window)

3. **NO Session/Workspace Persistence Tests**
   - The app saves/restores sessions, workspaces, tabs — not in this slice
   - FileManager operations (reads, writes, trash recovery) — not tested here

4. **Perf Tests are Guard-Only, Not Measurement-Driven**
   - PerfMicroBundle2GuardTests anchors to TSK-845 measured facts (utf8.count O(1), lazy-decode non-win)
   - But no continuous perf benchmarking; the "real" perf lane is PerfSignpost/xctrace on the VM

5. **Highlight-Language Detection Has No Ambiguity-Resolution Tests**
   - .ts could be TypeScript or TensorScript; .mm could be C++ or Objective-C++
   - Tests exist but may not cover all ambiguous extensions

---

## Harness & Infra Patterns Worth Porting

### 1. **ABI Version Skew Detector (BridgeTests)**
   ```swift
   XCTAssertEqual(mdvcore_abi_version(), UInt32(MDV_WIRE_VERSION))
   ```
   - Runs on every gate (host + VM)
   - Catches stale staged header vs linked library
   - **Key insight:** the compiled constant and the runtime value MUST agree; inequality is catastrophic and non-recoverable

### 2. **Capability Bits as ABI Constants (BridgeTests)**
   ```swift
   XCTAssertEqual(CoreCapabilities.csvSession.rawValue, 1 << 0)
   // ... for every bit, pinned on BOTH sides
   XCTAssertTrue(future.contains(.csvSession))  // forward-compat: unknown bits tolerated
   ```
   - Bits are ABI — renumbering silently breaks feature gates
   - Every assigned bit has an explicit position test
   - Forward-compat contract: newer library may set unknown bits; gating logic ignores them

### 3. **Negative/Fuzz Test Pattern (MsgPackDecoderNegativeAuditTests)**
   ```swift
   private func expectDecodeThrows(_ bytes: [UInt8], _ expected: MsgPackError) {
       var reader = MsgPackReader(bytes)
       XCTAssertThrowsError(try reader.decode()) { err in
           XCTAssertEqual(err as? MsgPackError, expected, ...)
       }
   }
   ```
   - Every error path is TYPED; malformed input → specific error, never crash
   - OOM-abort guard proven: huge declared count + short body → throw, not abort
   - Truncation on every container type tested separately

### 4. **Round-Trip Codec Testing (MessagePackEncoderTests)**
   - Tag-size boundaries explicitly tested (fixint → int8 → int16 → int32 → int64)
   - Type distinction verified (.int vs .uint stays distinct)
   - Nested structures test container recursion
   - **Key:** encode + decode must be exact inverses; no data loss across boundaries

### 5. **Measured Perf Guard (PerfMicroBundle2GuardTests)**
   ```swift
   private func medianMillis(iterations: Int = 11, _ body: () -> Void) -> Double
   // ... ratio = hugeMs / tinyMs; assert ratio < 50x ceiling (catches O(N) regression)
   ```
   - Owner directive: MEASURE, don't guess
   - Regression guard is a ratio test (not absolute ms), tolerant of scheduler noise
   - Documents WHY a claimed win was rejected + what the measured facts are

### 6. **Remote Transport Loopback (RemoteTransportLoopbackTests)**
   ```swift
   guard let bin = serveBinary() else { return }  // self-skip without binary
   let remote = try RemoteTransport(socketPath: socketPath)
   CoreTransportRegistry.current = remote
   let remoteResult = try call()
   XCTAssertEqual(local, remoteResult, "diverged local vs remote")
   ```
   - Spawns real mdv-serve; self-skips if binary not built (no Rust toolchain on VM)
   - If binary EXISTS but handshake fails → FAILURE, never silent skip
   - Every stateless wrapper byte-equality tested

### 7. **Shared Fixture Builder (GitTestRepo)**
   ```swift
   public static func makeRepo(prefix: String, at fixedDir: URL? = nil, ...) throws -> URL
   // One /bin/bash -c call bundles: git init + email/name config + gpgsign
   ```
   - Moved to TestSupport library so both ViewerCoreTests + ViewerUITests can use it (test targets can't import each other)
   - Consolidates 4 Process spawns into 1 shell call
   - Byte-identical repos; centralized defaults (email, name, branch)

### 8. **View-Mode Resolution with Fallback (ViewModeControlTests)**
   ```swift
   XCTAssertEqual(
       ViewModeControl.resolve(primary: .render, viewOnly: true, available: [.source, .editor, .hex]),
       .source,  // render falls back to source when rendered lens unavailable
   )
   ```
   - Pure value-logic test (no SwiftUI, no async)
   - Fallback routing is explicit and tested for every file-type class (markdown, plaintext, media, binary)

### 9. **Error Classification Helpers**
   - `CoreError.decode(msg)` — frame/protocol errors
   - `MsgPackError.truncated`, `.unsupportedTag`, `.custom`
   - `CanvasRejection.conflict`, `.fence`
   - Every error path has an explicit assertion; callers are forced to handle typed throws

### 10. **Self-Skipping Tests on Missing Dependencies**
   ```swift
   override func tearDown() {
       CoreTransportRegistry.resetToInProcess()
       server?.terminate()
       ...
   }
   ```
   - Tests run both with/without external binary (mdv-serve)
   - Teardown always resets to in-process; no state leaks between tests

---

## Flake / False-Green Risks Observed

### 1. **Process Timing in RemoteTransportLoopbackTests**
   - Server socket bind is polled (50ms sleeps, 100 iterations = 5s timeout)
   - Risk: flaky on heavily loaded machine; no exponential backoff
   - **Mitigation:** rare in practice (swift test runs fast); VM scheduling is predictable

### 2. **PerfMicroBundle2GuardTests Ratio on Slow Hardware**
   - Median of 11 iterations, 50x ratio ceiling
   - Risk: a GC pause or thermal throttle on the host can blow the ratio
   - **Mitigation:** runs in release mode; generous 50x ceiling vs typical 1-3x ratio

### 3. **MsgPack Negative Tests Assume Exact Error Type**
   - `XCTAssertEqual(err as? MsgPackError, expected)`
   - Risk: if error handling changes (e.g., .truncated → .custom(msg)), tests need update
   - **Mitigation:** error taxonomy is stable; audit-driven, so changes are intentional

### 4. **RemoteTransportLoopbackTests Skips Silently Without Binary**
   - `guard let bin = serveBinary() else { return }`
   - Risk: a human might run tests without Rust toolchain and not realize loopback was skipped
   - **Mitigation:** clear in comments; CI (VM) has the binary, so catch regressions there

### 5. **ViewModeControlTests Assumes File-Type Routing is Correct**
   - Tests resolve(available: ...) but don't test the ROUTE that populates `available`
   - Risk: a file-type detector bug could make a valid mode unavailable
   - **Mitigation:** separate FileTypeDetectorTests validate the detector

### 6. **HighlightLanguageTests Don't Test Ambiguous Extensions**
   - `.ts`, `.mm`, `.c++` have multiple meanings
   - Risk: ambiguity-resolution tie-breaker might be wrong
   - **Mitigation:** rare ambiguities; file-type system is small and stable

---

## Rebuild Notes — Day-1 Test Strategy for Greenfield

### 1. **Start with FFI Boundary Harness**
   - Port the ABI-version skew detector pattern (BridgeTests)
   - This is THE foundational gate: if header/library ABI drift, nothing else works
   - Capability-bits system: explicitly pinned positions, forward-compat tolerant

### 2. **Codec & Wire Format Tests BEFORE Feature Tests**
   - MessagePack round-trip (all tag-size boundaries)
   - Frame layer (length prefix, truncation)
   - Negative/fuzz testing (OOM guard, unsupported-tag)
   - These catch protocol bugs EARLY; delay means cascading failures in every engine that uses the wire

### 3. **Engine-Port A/B Contract Tests as ACCEPTANCE PROOF**
   - Don't ship a Rust-ported engine (find, hex, markdown, diff, etc.) without proving byte-equality vs the Swift twin (if it exists) OR against a golden corpus
   - The loopback-server pattern (RemoteTransportLoopbackTests) is the proof: spawn mdv-serve, run stateless wrappers, assert local == remote
   - This is non-negotiable for transport transparency

### 4. **View-Model Logic Tests are Safe Early**
   - View-mode resolution (ViewModeControlTests pattern) is pure value-logic
   - File-type detection (FileTypeDetectorTests) is pure classification
   - No async, no WebView, no window → host-safe and fast
   - These are SAFE to run early; they don't block UI tests

### 5. **Shared Fixture Builder in a Separate Library Target**
   - Port GitTestRepo.swift early
   - If you have git-integration tests in both ViewerCoreTests (logic) + ViewerUITests (live-app), they'll both need the builder
   - Moving it to TestSupport avoids copy-paste

### 6. **Perf Regression Guards Come AFTER Implementation**
   - Don't write perf guards before you have a baseline
   - Once a feature ships, profile it (PerfSignpost/xctrace on VM), measure the cost, then anchor the guard (like TSK-845)
   - PerfMicroBundle2GuardTests pattern: measure, document why a claimed win was rejected, guard the measured facts

### 7. **Negative/Fuzz Tests on Every Protocol-Level Change**
   - Wire codec, frame format, RPC envelope, error serialization
   - MsgPackDecoderNegativeAuditTests pattern: for every error class, hand-craft a malformed input that should throw
   - This prevents crash-on-malformed-input bugs that hide behind happy-path tests

### 8. **Audit-Driven Tests Become Your Test Matrix**
   - When an audit finds a gap (ReDoS, OOM-abort, panic dead-flag), write a test that proves the fix
   - Name it `Audit_Sources_<module>_<file>_<finding>.swift` (or similar)
   - Keep the audit reference in a comment; this ties tests to findings

### 9. **System Behavior Tests (EINTR, Signal Safety)**
   - RemoteTransportEINTRTests pattern: injectable mock, assert retry loop behavior
   - Panic dead-flag: verify reset on re-use (SingletonSession pattern)
   - Request-ID wrap semantics: wrap at UInt64.max, monotonic increment
   - These are small but catch subtle bugs that only show under load/interruption

### 10. **Tier Classification from Day 1**
   - Headless-unit (T1): no window, no async, no UI → host-safe
   - Headless-UI (T1m): no window, but view-model/projection logic → host-safe, but close to render
   - LiveApp (T4): spawns the app, lives on VM → never on host
   - Pixel (T5): captures WindowServer pixels, lives on VM → never on host
   - Each file should have a clear tier; gate scripts filter by tier

### 11. **A/B Contract Tests are One-Time Proof, Not Regression Guards**
   - CSV_Audit shows byte-identical Rust vs retired Swift twin
   - Once Swift is deleted (STAGE-B), the A/B tests become regression guards on the Rust engine alone
   - Keep them in tree (cheap insurance); don't delete

### 12. **Continuous Verification**
   - **Host gate:** `swift test --filter HeadlessTests` (all T1, T1m, support)
   - **VM gate:** `test-in-vm.sh all` runs full suite (headless + T4 + T5), rebuilds dist
   - **Before committing:** run the host gate; if UI/render changes, also run VM gate
   - **Central gate (CI):** merge gate runs host gate; nightly/VM gate runs full suite

---

## Summary: Production Patterns Worth Porting

1. **ABI-version skew detector** — foundational, catches header/library drift
2. **Capability bits as ABI constants** — feature negotiation with forward-compat
3. **Negative/fuzz testing on protocols** — OOM guard, truncation, unsupported-tag
4. **Round-trip codec tests** — tag-size boundaries, type distinction
5. **Measured perf guards** — not absolute ms, ratio-based to tolerate noise; document WHY a win was rejected
6. **Remote transport loopback** — byte-equality proof; self-skip when binary absent
7. **Shared fixture builders in TestSupport** — cross-target dependency injection
8. **Pure value-model tests** — safe early, no window/async
9. **Audit-driven tests** — tie findings to acceptance criteria
10. **System behavior (EINTR, panic, signal-safety)** — injectable mocks, low-level contract proof

**Rebuild confidence:** These patterns are proven on a 6.5K-LOC production suite with 342 test functions. Porting the harness structure and the key patterns (ABI skew, capability bits, negative testing, loopback verification) will give the day-1 greenfield a solid, non-flaky foundation.
