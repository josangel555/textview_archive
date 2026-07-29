# Test Learnings: ViewerCoreTests Subsystem 2 (Plugins, Walkthrough, LSP, Security, Extensions, Search, Hex, Git, Feeds)

**Batch:** 38 test files across 9 subsystem domains | **Total LOC:** ~9,497 | **Framework split:** ~37 XCTest files + 1 Swift Testing file

---

## File Inventory

### Plugins (9 files, 3,077 LOC)

**ExamplePluginBTests.swift** (70 LOC) — tier: headless-unit · framework: XCTest · pins: end-to-end Tier B plugin fixture loads, registry wiring, sidebar section smoke test · teeth: real (checks manifest load, grant flow, provider invocation)

**PluginGrantStoreTests.swift** (226 LOC) — tier: headless-unit · framework: XCTest · pins: grant store persistence (JSON round-trip), decision tracking (granted/denied/required), revoke state transition, version-gated re-prompt on capability expansion · teeth: real (verifies round-trip through disk; test_denied_decision_is_persisted_distinctly checks reload via fresh PluginGrantStore instance)

**PluginLifecycleTests.swift** (179 LOC) — tier: headless-unit · framework: XCTest · pins: install/remove lifecycle validation before any filesystem copy, folder/ID uniqueness, remover callback injection · teeth: real (guard-rail: refuses invalid before copying; checks no partial writes)

**PluginManifestTests.swift** (371 LOC) — tier: headless-unit · framework: XCTest · pins: manifest JSON decode (Tier A/B/U variants), forward-compat (unknown caps/contribution types decode to .unknown), required-field validation, menu-item contributions (TSK-754) · teeth: real (missing required field throws; unknown types don't break siblings)

**MenuContributionRegistryTests.swift** (103 LOC) — tier: headless-unit · framework: XCTest · pins: menu tree building (topLevel/submenu split), ordering (order ASC, ties by plugin+item ID), enabled-flag logic (nil invoke = disabled), submenu first-seen-order preservation · teeth: real (model contract for AppKit builder; ordering deterministic)

**PluginOpenURLTests.swift** (218 LOC) — tier: headless-unit · framework: XCTest · pins: Tier U (openURL) menu-item decode, URL template validation, capability gating (ui.menu + web.open), invocation via seam injection · teeth: real (missing template throws; capability gating tested)

**PluginRegistryTests.swift** (816 LOC) — tier: headless-unit · framework: XCTest · pins: loadAll() directory traversal, grant-gate filtering (.awaitingGrant), Tier A static-bind rows, Tier B subprocess state machine (spawn/await/timeout/error recovery), enable/disable with persistence, section ordering, bundled plugin registration · teeth: real (comprehensive state machine validation; subprocess mock harness; grant seams)

**PluginSectionVisibilityTests.swift** (108 LOC) — tier: headless-unit · framework: XCTest · pins: visibility state machine (hide drops section, persist), re-enable without relaunch (dormant stash), persisted dismissal survives relaunch, double-disable no-dup guard · teeth: real (relaunch simulation with fresh registry on same defaults)

**PluginSubprocessHostTests.swift** (519 LOC) — tier: headless-unit · framework: XCTest · pins: subprocess lifecycle (launch, stdin/stdout pipes, JSON serialization/deserialization), message ordering, timeout/crash handling, grandchild restart-on-crash, signal dispatch · teeth: real (pipe-layer integration tests; JSON round-trips verified)

**PluginURLTemplateTests.swift** (234 LOC) — tier: headless-unit · framework: XCTest · pins: URL template substitution ({query}, {selectedText}, {filePath}), URL encoding, missing-placeholder passthrough, invalid-template rejection · teeth: real (URL encoding correctness; placeholder extraction deterministic)

**RowCounterPluginTests.swift** (78 LOC) — tier: headless-unit · framework: XCTest · pins: bundled ROW COUNTS sidebar section fixture, static row generation from manifest · teeth: weak (smoke test, no edge cases)

**Audit_Sources_ViewerCore_Plugins_PluginSubprocessHost_swift_GrandchildPipeTests.swift** (155 LOC) — tier: headless-unit · framework: XCTest · pins: grandchild pipe routing (audit of PluginSubprocessHost.swift), process identity preservation, restart sequencing · teeth: real (targets specific regression in source file; audit-named)

---

### Walkthrough (9 files, 2,579 LOC)

**WalkthroughLoaderTests.swift** (411 LOC) — tier: headless-unit · framework: XCTest · pins: security boundary — path-escape detection (../../etc/passwd rejection), schema version evolution (v1/v2 support, unsupportedSchema error for future versions), JSON parse errors, all-action-type path coverage · teeth: real (path-escape test explicit: guard against directory traversal)

**WalkthroughEngineTests.swift** (250 LOC) — tier: headless-unit · framework: XCTest · pins: state machine (load doesn't apply, next/prev bounds, step index, playing/idle/done states), delegate action dispatch ordering, multi-action steps · teeth: real (fake Recorder delegate captures all dispatches; exhaustive path coverage)

**WalkthroughScriptTests.swift** (437 LOC) — tier: headless-unit · framework: XCTest · pins: script model parsing, action variant decoders (openFile, highlightRange, showPopover, flash, narrative, etc.), payload extraction · teeth: real (round-trips through JSON; action variant switches exhaustive)

**WalkthroughCheckpointStoreTests.swift** (300 LOC) — tier: headless-unit · framework: XCTest · pins: checkpoint persistence (JSON via UserDefaults), progress tracking (stepIndex, completed state), load/save round-trips · teeth: real (persistence verified through fresh load)

**WalkthroughStoreTests.swift** (309 LOC) — tier: headless-unit · framework: XCTest · pins: walkthrough catalog index, per-script data isolation, completed-script tracking · teeth: real (store state verified after mutations)

**WalkthroughCatalogTests.swift** (224 LOC) — tier: headless-unit · framework: XCTest · pins: catalog loading, bundled vs downloaded script merge, script ordering/discovery · teeth: unclear (catalog structure tested but not on-screen rendering)

**WalkthroughSchemaErrorTests.swift** (233 LOC) — tier: headless-unit · framework: XCTest · pins: structured error types (pathEscape, unsupportedSchema, decodingFailed), error message derivation · teeth: real (error variant coverage complete)

**WalkthroughDropTransportTests.swift** (124 LOC) — tier: headless-unit · framework: XCTest · pins: drag-drop payload handling, file URL → walkthrough script conversion, accept/reject logic · teeth: weak (basic smoke test, no path validation on drop)

**Audit_Sources_ViewerCore_Walkthrough_WalkthroughLoader_swift_TrustedRootTests.swift** (142 LOC) — tier: headless-unit · framework: XCTest · pins: audit of WalkthroughLoader.swift — trusted root / sandboxing boundary, rootHint-based path validation · teeth: real (audit-named, targets regression in specific source)

---

### LSP (10 files, 2,405 LOC)

**LSPPoolFakeServerTests.swift** (793 LOC) — tier: headless-unit · framework: XCTest · pins: LSPPool state machine (lazy spawn, reuse, closeAll rejection, restartBackoff after fail_initialize, deadCooldown expiry, recordCrash demotion, reapIdle), concurrent ensureLive races, workspace symbol fan-out, didChange no-op when file not opened · teeth: real (driven via fake-server binary injection; scenario env vars; deterministic reaper skip)

**LSPClientFakeServerTests.swift** (443 LOC) — tier: headless-unit · framework: XCTest · pins: LSPClient protocol (initialize, didOpen, hover, definition, completion, rename, codeAction), fake-server scenario injection, timeout/crash recovery, message ordering · teeth: real (binary-backed fake; JSON request/response validation)

**LSPWorkspaceRootFinderTests.swift** (262 LOC) — tier: headless-unit · framework: XCTest · pins: workspace root discovery (package.json, .git, Cargo.toml, go.mod precedence), fallback to file's parent · teeth: real (multi-language marker detection; fallback tested)

**LSPDefinitionPreviewTests.swift** (224 LOC) — tier: headless-unit · framework: XCTest · pins: preview composition (location + line preview, context around definition, range extraction) · teeth: weak (no on-screen rendering test)

**LSPRenameTests.swift** (158 LOC) — tier: headless-unit · framework: XCTest · pins: rename request/response, TextEdit application to source, document update ordering · teeth: real (TextEdit array handling tested)

**LSPCodeActionTests.swift** (77 LOC) — tier: headless-unit · framework: XCTest · pins: code action decode, apply variants (Command vs CodeAction payload) · teeth: weak (minimal coverage)

**LSPTextEditApplierTests.swift** (120 LOC) — tier: headless-unit · framework: XCTest · pins: TextEdit patch application (insert/delete/replace), UTF-16 offset handling, multi-edit ordering · teeth: real (offset edge cases + ordering validated)

**LSPPoolCloseFile_Audit_Sources_ViewerCore_LSP_LSPPool_swift_Tests.swift** (143 LOC) — tier: headless-unit · framework: XCTest · pins: audit of LSPPool.swift — closeFile state transitions, document lifecycle, did-change semantics · teeth: real (audit-named; targets specific regression)

**FakeLSPServerHelper.swift** (93 LOC) — tier: support · framework: XCTest · pins: helper utilities for fake-server scenario setup, env-var marshaling · teeth: n/a (support file)

**FakeLSPServerLaunchTest.swift** (92 LOC) — tier: headless-unit · framework: XCTest · pins: fake-server binary availability check, launch success/timeout, scenario string parsing · teeth: real (validates binary can launch)

---

### Security (3 files, 372 LOC)

**RegexComplexityGuardTests.swift** (200 LOC) — tier: headless-unit · framework: XCTest · pins: ReDoS pattern rejection (nested quantifiers a++, a**, a+*, {1,} unbounded, evil-regex a|aa overlaps), non-overlapping alternation a|b pass, group-prefix tokenization edge cases (non-capturing (?:), named (?<>), Python (?P<>), flagged (?i:)), lookahead/behind safe, excessive-length rejection · teeth: real (comprehensive positive/negative case matrix; guard is deterministic FSM)

**URLSchemePolicyTests.swift** (91 LOC) — tier: headless-unit · framework: XCTest · pins: scheme whitelist (http/https/file/mailto pass, custom schemes gated), host validation · teeth: real (policy decision enforcement tested)

**Audit_Sources_ViewerCore_Security_URLSchemePolicy_swift_SymlinkEscapeTests.swift** (81 LOC) — tier: headless-unit · framework: XCTest · pins: audit of URLSchemePolicy.swift — symlink escape detection, .. traversal rejection, absolute-path handling · teeth: real (audit-named; symlink-specific regression guard)

---

### Extensions (3 files, 426 LOC)

**ExtensionsInventoryTests.swift** (168 LOC) — tier: headless-unit · framework: XCTest · pins: inventory model (dedupe by kind-namespaced id, ordering: plugins before walkthroughs / active before inactive / case-insensitive name then rawID), deterministic order regardless of input, kind filtering, counts · teeth: real (order determinism tested via forward/reverse input)

**ExtensionsInventoryLiveTests.swift** (131 LOC) — tier: headless-unit · framework: XCTest · pins: live adapter patterns (plugin + walkthrough sources merged), status mapping, enabled/disabled tracking · teeth: unclear (adapter smoke test, no on-screen rendering)

**ExtensionsInventoryAdaptersTests.swift** (127 LOC) — tier: headless-unit · framework: XCTest · pins: adapter layer (PluginRegistry → ExtensionsInventory, WalkthroughRegistry → ExtensionsInventory), status enum mapping · teeth: weak (adapter contract tested shallowly)

---

### Search (2 files, 199 LOC)

**SearchEngineExtendedTests.swift** (154 LOC) — tier: headless-unit · framework: XCTest · pins: cross-file search edge cases (empty root, empty query, symlink loop bounded by maxEntriesScanned, hidden-file skip, file at exact size-cap vs over-cap, unicode case-insensitive fold, maxResults stops mid-file) · teeth: real (symlink loop test verifies no hang; size-cap boundary tested)

**SearchScopeExtendedTests.swift** (45 LOC) — tier: headless-unit · framework: XCTest · pins: scope filtering (all files, specific extensions, exclude dirs) · teeth: weak (minimal coverage)

---

### Hex (1 file, 172 LOC)

**HexEdgeCaseTests.swift** (172 LOC) — tier: headless-unit · framework: XCTest · pins: search edge cases (empty data, single-byte data, pattern longer than data, cross-row boundary spans at width-16/32), ASCII control bytes (\n, \t, nulls, 0xFF), offsets computation, clampWidth round-trip · teeth: real (boundary conditions verified; row-span search byte-oriented)

---

### Git (1 file, 210 LOC)

**ForgeRemoteTests.swift** (210 LOC) — tier: headless-unit · framework: XCTest · pins: remote URL parsing (HTTPS, SCP git@, SSH scheme), provider classification (GitHub/GitLab/generic), port stripping, nested namespace (GitLab subgroups), trailing slash tolerance, whitespace trim, rejection rules (file: scheme, empty, single path segment) · teeth: real (parsing exhaustive across schemes; classification deterministic)

---

### Feeds (1 file, 57 LOC)

**FeedReaderModelTests.swift** (57 LOC) — tier: headless-unit · framework: SwiftTesting · pins: display item sort (newest-first, undated last), read-state annotation, unread count, feed summaries (unread rollup, fetched-flag distinction), total-unread aggregation · teeth: real (FeedReaderModel.feedSummaries explicitly checks fetched vs unfetched distinction with unread count assertion)

---

## Test-Type Taxonomy

### Distribution by Subsystem
- **Plugins (3,077 LOC, 38% of batch):** Plugin system lifecycle, registry wiring, manifest parsing, grant flow, subprocess communication. Heaviest subsystem.
- **Walkthrough (2,579 LOC, 27%):** Script loading/parsing, engine state machine, checkpoint persistence, schema evolution, security boundary (path escapes).
- **LSP (2,405 LOC, 25%):** Language server pool lifecycle, fake-server harness, protocol handling, workspace discovery. Second heaviest.
- **Security (372 LOC, 4%):** ReDoS pattern detection, URL scheme policy, symlink escape detection. Narrow, high-assurance scope.
- **Extensions (426 LOC, 4%):** Inventory model, adapter patterns, merger logic.
- **Search (199 LOC, 2%):** Cross-file search edge cases, symlink safety, file size bounds.
- **Hex (172 LOC, 2%):** Binary search edge cases, row-span handling.
- **Git (210 LOC, 2%):** Remote URL parsing, provider classification.
- **Feeds (57 LOC, 1%):** Model composition, sort order, unread tracking. Smallest, newest (Swift Testing).

### Framework Split
- **37 XCTest files** (headless @MainActor or simple unit)
- **1 Swift Testing file** (FeedReaderModelTests — pure model, structured async)

### Tier Homogeneity
All 38 files are **headless-unit tests** (XCTest HeadlessUITestCase base or Swift Testing). None are T4 (live app) or T5 (pixel). The subsystems tested here are all CORE LOGIC — no UI rendering (plugins, walkthroughs, LSP, search engines, hex viewer model). Rendering layers tested separately in ViewerUITests.

---

## Coverage Shape

### Over-Tested
- **Plugin registry state machine (816 LOC in PluginRegistryTests alone):** End-to-end lifecycle with grant-gate filtering, Tier B subprocess, enable/disable persistence. Heavy but justified (complex inter-dependent state).
- **LSP pool lifecycle (793 LOC in LSPPoolFakeServerTests):** State machine paths (lazy spawn, restartBackoff, deadCooldown, concurrent races, reapIdle). Comprehensive.
- **Walkthrough loader security boundary (path escapes):** Exhaustive action-type coverage in WalkthroughLoaderTests + audit-named regression guard. Good defense depth.

### Under-Tested
- **Walkthrough render / UI behavior:** Tests pin the engine state machine, not the actual on-screen "loading…" flashes or popover positioning (those live in VM tests). Per LESSONS.md, the "loading…" flash race was found despite headless tests passing — this is expected (render-confirm directive).
- **LSP definition preview composition:** Test covers payload extraction but not the actual code-context line wrapping or on-screen display. Limited to model contract.
- **Extensions UI rendering:** Inventory model is tested, but the actual settings/sidebar panel display is VM-only.
- **Search result rendering:** Engine is tested, but the highlighting/navigation UI is separate.
- **Code action / rename refactoring:** LSPTextEditApplier tested, but the actual document mutation and re-render on screen is not validated here.

### Gaps
- **Plugin subprocess crash recovery on macOS signal handling:** Tests cover .crash demotions and restarts, but not real SIGTERM/SIGKILL. Harness is mocked.
- **Grant store file corruption recovery:** Tests verify happy-path persistence, but no corruption-handling or schema-upgrade paths.
- **LSP server out-of-memory / resource exhaustion scenarios:** Tests use "tight" configs with short timeouts, but don't exercise real memory pressure.
- **Walkthrough drop transport on large/malformed files:** Only basic smoke test; no boundary cases on file size or corruption.

---

## Harness & Infra Patterns Worth Porting

### 1. Fake-Server Binary Injection Pattern (LSP)
**Where:** `LSPPoolFakeServerTests`, `LSPClientFakeServerTests`, `FakeLSPServerLaunchTest`
**How:** 
- Inject `MDVFakeLSPServer` binary path via `LSPLanguageRegistry` seam
- Pass scenario name via `MDV_FAKE_LSP_SCENARIO` env var
- Fake server responds deterministically; tests drive the state machine without relying on a real language server

**Why port it:** Enables protocol-layer testing without external binary dependencies at runtime. Seams are injected at the registry level, so the production code path is real.

### 2. Fake Delegate Pattern for State Machines (Walkthrough)
**Where:** `WalkthroughEngineTests.Recorder`
**How:**
- Implement the delegate protocol in a test-local struct
- Record all callbacks (willApply, apply, didApply)
- Assert ordering and payload invariants via `applied[]` array

**Why port it:** Isolates state machine logic from UI side effects. Delegate is the contract; test verifies all action dispatch paths without UI scaffolding.

### 3. UUID-Based Temp File Isolation (All)
**Where:** Every test using temp files
**How:**
```swift
let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("MDVGrantsTest-\(UUID().uuidString).json")
```
**Why port it:** Prevents test file collisions in /var/folders/...T/ when tests run concurrently. Cleanup via `tearDown` is guaranteed.

### 4. Seam-Based Grant Store Injection (Plugin)
**Where:** `PluginRegistryTests`, `PluginOpenURLTests`, `PluginLifecycleTests`
**How:**
- Per-test temp grant file (UUIDs)
- Fresh `PluginGrantStore(url: tmp)` injected into `PluginRegistry.shared`
- Tests pre-grant capabilities to skip the "need owner decision" gate

**Why port it:** Isolates permission state from test to test. Registry's shared singleton is re-initialized with a fresh grant store, avoiding leakage.

### 5. Audit-Named Regression Guards (Multiple Subsystems)
**Where:** 
- `Audit_Sources_ViewerCore_Plugins_PluginSubprocessHost_swift_GrandchildPipeTests`
- `Audit_Sources_ViewerCore_Walkthrough_WalkthroughLoader_swift_TrustedRootTests`
- `Audit_Sources_ViewerCore_LSP_LSPPool_swift_Tests`
- `Audit_Sources_ViewerCore_Security_URLSchemePolicy_swift_SymlinkEscapeTests`

**How:** Test filename embeds the source file it guards (e.g., `_Sources_ViewerCore_Plugins_PluginSubprocessHost_swift_` guards that file). Adds greppability and documents the intent.

**Why port it:** Explicit regression guarding. A future refactoring of PluginSubprocessHost.swift will immediately surface that the grandchild-pipe test exists and should be re-verified.

### 6. Forward-Compat Testing (Plugin, Walkthrough, LSP)
**Where:** `PluginManifestTests.test_unknown_contribution_type_decodes_to_unknown`, `WalkthroughLoaderTests.test_unknownSchemaVersion_rejected`
**How:**
- Unknown capability/contribution types decode to `.unknown` (not throw)
- Unknown schema version returns `unsupportedSchema(version, supported)` error (not decodingFailed)
- Allows old binary to load a newer manifest's compatible parts

**Why port it:** Future-proofs file format evolution. A v2 script with only v1 actions loads cleanly on a v1 binary.

### 7. Tight Config for Deterministic Timing (LSP)
**Where:** `LSPPoolFakeServerTests.tightConfig()`
**How:**
```swift
restartBackoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
idleTimeout: .milliseconds(50)
deadCooldown: .milliseconds(50)
// Note: long reaperTick to prevent background Task interference
```
**Why port it:** Timing-sensitive state machine tests need predictable timeouts without real sleeps. Allows deterministic failure recovery testing.

### 8. Swift Testing for Pure Model Tests (Feeds)
**Where:** `FeedReaderModelTests`
**How:** Use `@Test func` + `#expect()` instead of XCTest's `func test_*() + XCTAssert*()`
**Why port it:** Structured assertions read cleaner for model-only suites; integrates better with parameterized tests (not needed here, but scalable).

---

## Flake / False-Green Risks Observed

### 1. LSP Fake-Server Binary Location Assumption
**Risk:** If `MDVFakeLSPServer` build fails or is not in the expected path, `FakeLSPServerLaunchTest` silently skips. Tests "pass" but the whole LSP layer is untested.
**Mitigation:** Build gate must verify the binary exists. Current test skips gracefully, which is correct, but CI should warn if skips are unexpectedly high.

### 2. Plugin Registry Singleton Re-initialization
**Risk:** `PluginRegistry.shared._resetForTests()` and `_setURLOpener` seams must be called in setUp. If a test forgets, a prior test's state leaks.
**Current:** Mitigated by setUp being `async throws` and explicitly resetting. Good. But no enforcement if a new test forgets.

### 3. Walkthrough "loading…" Flash Race
**Root cause:** Per LESSONS.md (section on session-switch scroll), imperative state populated around a render race. Tests pin the ENGINE state machine, but the actual on-screen popover/flash timing is not validated in headless tests.
**Mitigation:** Covered by VM tests (WalkthroughEngineRenderTests or similar T4/T5 suites); this is expected headless/render split.

### 4. Subprocess Pipe Closure Ordering
**Risk:** `PluginSubprocessHostTests` mocks stdin/stdout pipes. Real pipes can close unexpectedly if a subprocess crashes before reading all bytes. Tests don't exercise SIGPIPE.
**Mitigation:** Tests are comprehensive for happy path + mock errors; real crash scenarios would be caught by integration tests or live-app use.

### 5. Grant Store File Corruption
**Risk:** Tests write/read JSON to temp files. If a file is partially written (e.g., process killed mid-write), `PluginGrantStore(url:)` may fail to decode on next read.
**Current:** No recovery path tested. If a user's real grants.json becomes corrupt, the app won't auto-recover.
**Mitigation:** New rebuild could add a schema-versioned backup + fallback-to-empty logic.

### 6. SearchEngineExtendedTests Symlink Loop
**Risk:** Test creates a back-edge symlink (proj → proj/loop). On some filesystems, this might not be allowed; test would fail on those systems.
**Current:** Test assumes symlink creation succeeds; no fallback.

---

## Rebuild Notes — Day-1 Test Strategy

### 1. Replicate the Plugin System Harness Immediately
The plugin registry (3,077 LOC of tests) is comprehensive and battle-tested. Day 1 should:
- Copy the seam-based grant store injection pattern
- Implement the Tier A/B/U action hierarchy with forward-compat unknowns
- Use the same manifest JSON schema (minimal Tier A, subprocess Tier B, openURL Tier U)
- Reuse the fake-delegate pattern for testing menu-item actions

### 2. Port the LSP Fake-Server Injection
The fake-server harness is modular and decouples tests from real language servers. Rebuild should:
- Build a minimal fake-LSP binary (Rust recommended; it's already compiled as libmdvcore_ffi.a)
- Inject it via a language-registry seam (same as current `LSPLanguageEntry`)
- Use scenario env vars to drive behavior (already a tested pattern)

### 3. Adopt Security-Boundary Audit Tests
The ReDoS, symlink, and path-escape tests are narrow but high-confidence. Rebuild should:
- Add the same exhaustive ReDoS pattern matrix early (it's 200 LOC well-spent)
- Use the audit-naming convention for source-file-specific regression guards
- Extend to any new parser (tree-sitter, LSP JSON, plugin manifests)

### 4. Plan for Render-Tier Split from Day 1
Current headless tests don't cover rendering (walkthroughs, extensions, search results, code actions). Rebuild should:
- Keep headless tests for model/engine logic only (no SwiftUI/AppKit)
- Plan T4/T5 suites IN PARALLEL for any UI-visible feature (not as an afterthought)
- Use the fake-delegate + state-machine pattern to avoid rendering in headless tests

### 5. Use Swift Testing for Pure Model Suites
FeedReaderModelTests shows the value: structured assertions for model-only logic. Rebuild should:
- Use Swift Testing for any subsystem with no AppKit/SwiftUI dependencies (search, hex, git parsing, feeds, extensions inventory)
- Reserve XCTest for anything tier-based or needing setup/tearDown hooks

### 6. Invest in Deterministic Timing Tests for Complex State Machines
The tight configs in LSPPoolFakeServerTests enable reliable testing of failure recovery (restarts, crashes, cooldowns). Rebuild should:
- Define a `TestConfig` for each subsystem with short durations (1-50 ms)
- Avoid real `Task.sleep()` loops; call mutation methods directly (e.g., `reapIdle()` instead of waiting for the background reaper)
- Document why timing is shortened (determinism, not "faster tests")

### 7. Guard Persistence Round-Trips with Fresh Load Tests
Grant stores, checkpoints, and settings all load on relaunch. Rebuild should:
- Test every persistent state by creating a NEW instance of the store/registry and reading back
- Don't just test write → read in the same instance (that's false-green for truncation bugs)
- Example: `PluginGrantStoreTests.test_denied_decision_is_persisted_distinctly()` opens a second instance to verify

### 8. Plan the Fake-Delegate Pattern for All Engines
Walkthrough engine, LSP requests, plugin menu actions — all are state machines with a delegate/closure contract. Rebuild should:
- Use this pattern everywhere: test-local struct that records all callbacks, assert ordering
- Keeps tests decoupled from UI (SwiftUI body, AppKit menus, etc.)

### 9. Accept That Rendering Tests Are Separate
Current project has a strict headless/VM split (per OWNER DIRECTIVE 2026-06-06). Rebuild should enforce this from day 1:
- No T4/T5 tests in ViewerCoreTests (those live in ViewerUITests)
- No mock SwiftUI/AppKit in unit tests (use delegates + fake objects instead)
- Make the split explicit: a headless test file documents "render tested separately" in a comment if needed

### 10. Extend the Audit-Named Convention for Regression Tracking
The `Audit_Sources_ViewerCore_*_Tests.swift` pattern is goldfor future refactors. Rebuild should:
- Adopt it for ANY source file with a known vulnerability or past regression (security boundary, crash-prone state machine, format parser)
- Document the audit ticket in the test (e.g., `/// TSK-293 — group-prefix tokenization`), as done in RegexComplexityGuardTests
- Periodically (e.g., quarterly) re-run audit tests to verify the fix still holds

---

## Summary Table

| Domain | LOC | Files | Tier | Framework | Key Pattern | Teeth | Gaps |
|--------|-----|-------|------|-----------|-------------|-------|------|
| **Plugins** | 3,077 | 12 | Headless | XCTest | Seam-based grant injection, fake-delegate for menu items, Tier A/B/U hierarchy | Real (persistence, grant flow, lifecycle) | Subprocess real-signal handling |
| **Walkthrough** | 2,579 | 9 | Headless | XCTest | Engine state machine + fake delegate, schema version evolution, security boundary (path escapes) | Real (path-escape audit, engine dispatch ordering) | On-screen render timing (VM-only) |
| **LSP** | 2,405 | 10 | Headless | XCTest | Fake-server binary injection, tight test config, workspace-root discovery | Real (state machine, concurrent races, crash recovery) | OOM / resource exhaustion scenarios |
| **Security** | 372 | 3 | Headless | XCTest | ReDoS pattern matrix, symlink/path-escape audit tests, forward-compat rejection | Real (guard deterministic, negative-control coverage) | Minimal; security-focused |
| **Extensions** | 426 | 3 | Headless | XCTest | Inventory model (dedupe, order determinism), adapter merger | Weak (order determinism tested, but adapter contracts shallow) | UI rendering (VM-only) |
| **Search** | 199 | 2 | Headless | XCTest | Cross-file search edge cases, symlink loop bounds, size caps | Real (loop bounded; cap boundary tested) | Rendering / highlighting |
| **Hex** | 172 | 1 | Headless | XCTest | Binary search edge cases, row-span handling, control bytes | Real (byte-oriented span search verified) | Layout / column rendering |
| **Git** | 210 | 1 | Headless | XCTest | URL parsing exhaustive (HTTPS, SCP, SSH), provider classification | Real (parsing deterministic; rejection rules tested) | SSH authentication flow |
| **Feeds** | 57 | 1 | Headless | Swift Testing | Pure model tests (sort, unread, fetch-status), structured assertions | Real (unread count assertion explicit) | UI rendering, fetch errors |

