# ViewerCore: Automation, Commands, TaskRunner, Extensions, Observability, Diagnostics, Perf, Architecture, Security

**Batch scope:** 45 Swift files spanning the app's automation infrastructure, command/keybinding system, performance instrumentation, observability, diagnostics, and architectural boundaries. Total: ~4,800 LOC.

---

## File-by-File Inventory

### Architecture

**Sources/ViewerCore/Architecture/FeatureLocality.swift** (277 LOC) — Architectural tier enforcement for core/Swift split
- **Role:** Machine-checkable boundary catalog classifying every feature surface as `remoteableCore`, `hostOrchestrated`, or `localOnlySwift`, with dependency tracking to prevent uphill coupling.
- **Notable:** A brilliant constraints system that codifies the design doc rule "work flows downhill, never up" — a consistency check fails the host gate if a `remoteableCore` feature acquires an AppKit dependency, catching architectural skew before it ships.
- **Carry:** KEEP — the tier system is a production-grade pattern for enforcing architectural invariants; the rebuild should adopt it.

### Security

**Sources/ViewerCore/Security/RegexComplexityGuard.swift** (430 LOC) — ReDoS defense-in-depth for user-supplied regex
- **Role:** Two-layer regex safety: compile-time pattern rejection (nested quantifiers, overlapping alternation) + wall-clock deadline on match enumeration.
- **Notable:** The nested-quantifier heuristic is sophisticated — a tokenizing parser that correctly skips group modifiers (`(?:`, `(?<name>`, `(?P<name>`) so that `(?:a+)+` is caught (previously slipped through 2x). It's defense-in-depth: `reject()` catches the well-known shapes; `boundedMatches()` stops polynomial backtracking the heuristic misses.
- **Carry:** KEEP — the layered approach and the fixed tokenizer (now recognizes all group-modifier forms) are high-quality security code worth porting; document the false-negative risk (polynomial backtracking) for rebuild architects.

**Sources/ViewerCore/Security/URLSchemePolicy.swift** (81 LOC) — Path containment for custom URL scheme
- **Role:** Validates `markdownviewer://` scheme paths stay within `~` (home) or `/var/folders` (temp) to prevent "read arbitrary file" via URL scheme.
- **Notable:** Correctly resolves symlinks (physical-to-physical comparison) before the prefix check to prevent in-home symlinks pointing to `/etc`; existence-agnostic so probing for file existence doesn't leak via "did this open?".
- **Carry:** KEEP — the pattern is correct and tight; applies to any app with custom URL schemes.

### Observability

**Sources/ViewerCore/Observability/Obs.swift** (61 LOC) — Global observability sink access point
- **Role:** Process-wide singleton for emitting events to a pluggable sink; tests install a capturing sink, the app installs a ring-buffer sink, the default is a no-op.
- **Notable:** Thread-safe with a lock; uses `nonisolated(unsafe)` + `NSLock` (the Swift 6 dance) to provide a cheap reader path while still being auditable. Idempotent install + `installIfNeeded` so tests don't stomp app setup.
- **Carry:** KEEP — this is the canonical way to do a process-wide pluggable observability sink in Swift 6.

**Sources/ViewerCore/Observability/ObsEvent.swift** (144 LOC) — Event + metric value types
- **Role:** `ObsEvent` carries flat, `Sendable`, FFI-shaped observability records (timestamp as raw `UInt64 nanos`, level, subsystem, message, string-only tags). `ObsMetric` carries metric snapshots (name, kind, value, tags).
- **Notable:** Deliberately FFI-shaped (no Foundation reference types, no closures) so the shape survives when the core moves to Rust. The comment is explicit: "This is a one-way door — changing it later means touching every emit site AND the RPC schema."
- **Carry:** KEEP — the discipline of designing for eventual RPC crossing is sound and should be adopted project-wide.

**Sources/ViewerCore/Observability/ProcessMemory.swift** (237 LOC) — Honest process memory introspection
- **Role:** Exposes `appFootprintBytes` (main process `phys_footprint` via `task_info`) and `webKitHelperBytes` (best-effort sum of child `com.apple.WebKit.*` helper footprints) separately because "per-tab memory" is a fabricated lie when WebKit is XPC'd.
- **Notable:** Correctly documents why `phys_footprint` (not RSS/VSZ) matters for the app's code; enumerates pids checking parent/path to avoid misattributing unrelated apps' WebKit helpers; exposes a `complete` flag when the pid buffer caps out (lower-bound warning).
- **Carry:** KEEP — memory accounting is surprisingly subtle; this is the honest approach and should be the model for any rebuild.

### Diagnostics

**Sources/ViewerCore/Diagnostics/DiagnosticGate.swift** (77 LOC) — Build/opt-in gate + path redaction helper
- **Role:** Enables the diagnostic dump surface only in DEBUG builds OR when `MDV_ENABLE_DIAGNOSTICS=1`. `PathRedactor` collapses `/Users/<name>/…` to `<HOME>/…` for release-opt-in exports.
- **Notable:** Clean separation: the gate controls availability; path redaction is a separate concern applied at export time. Redacts home + temp dir prefixes; leaves relative suffixes so diagnostics remain useful ("which project subdir") without embedding PII.
- **Carry:** KEEP — the pattern is correct; applies to any app that exports diagnostics.

**Sources/ViewerCore/Diagnostics/DiagnosticSnapshot.swift** (300+ LOC, partial read) — Curated app-state snapshot for export
- **Role:** A hand-written snapshot of app state (tabs, sidebar, open fds, sockets, subprocesses, observability buffer status) with deliberately-NO file contents (sizes/line counts, not bytes). JSON-serializable for export.
- **Notable:** The design doc explicitly rejects auto-deriving `Codable` from the 2700-line `DocumentModel` god object; instead curates a flat snapshot so no internals leak. Addresses security: "This is the single most dangerous instrumentation surface" — carried unredacted it leaks every open file's path. Therefore: never in MCP, never auto-persisted, all paths redactable, socket addresses deliberately omitted.
- **Carry:** KEEP — the principle of *curating* a snapshot instead of serializing the live model wholesale is sound and should be applied to any dump-like feature.

**Sources/ViewerCore/Diagnostics/DiagnosticProbes.swift** + **DiagnosticDumpWriter.swift** (assumed present) — Runtime probes + structured export.

### Perf

**Sources/ViewerCore/Perf/PerfSignpost.swift** (155 LOC) — Instruments-visible performance signposts
- **Role:** Wraps `OSSignposter` for emitting named intervals + events on the open→categorize→load→materialize→highlight→render pipeline; gated on `MDV_SIGNPOSTS=1` env var so disabled builds have zero overhead.
- **Notable:** Caches the env-var read; per-stage `OSSignposter` is lazily built + keyed so each stage gets its own Instruments lane. When disabled, every API is branch-and-return (no signpost ID minted, no string formatted).
- **Carry:** KEEP — this is the right pattern for optional instrumentation without pulling async overhead into the hot path.

**Sources/ViewerCore/Perf/EditorPerfBench.swift**, **ResizeSweep.swift**, **ScrollSweep.swift** — Perf benchmarks (not read; assumed macro/interaction recording for profiling).

### Commands & Keybindings

**Sources/ViewerCore/Commands/Shortcut.swift** (186 LOC) — Keyboard shortcut model
- **Role:** Pure value type (no AppKit) representing a keystroke: base key (single char or symbolic name like `"escape"`) + modifiers (cmd/shift/option/control as a bitset).
- **Notable:** Parsing accepts multiple spellings (`cmd`/`command`/`meta`, `alt`/`opt`/`option`) and aliases non-canonical forms (`esc` → `escape`, `enter` → `return`) onto a canonical form. Rendering order is stable (ctrl, alt, shift, cmd) so round-trips are idempotent. `glyphString` generates macOS menu glyphs (⌃⌥⇧⌘) for help UI — pure, no AppKit needed.
- **Carry:** KEEP — the multi-spelling tolerance is a nice UX win; the canonical normalization and stable rendering order are correctness.

**Sources/ViewerCore/Commands/CommandRegistry.swift** (242 LOC) — Command catalog + override merge
- **Role:** Registry of ~150 `CommandDescriptor` entries (id, title, category, default shortcut, script-verb token, replayability). Supports override merge from `KeybindingConfig` so `keybinding.json` rebinds commands.
- **Notable:** Indexes by id and by script-verb so reverse lookup (verb → descriptor) works in O(1) for the macro recorder. `shortcutMap` builds the keystroke→command-id routing map with last-wins conflict resolution (reported via callback for logging).
- **Carry:** KEEP — the dual indexing + conflict reporting pattern is solid.

**Sources/ViewerCore/Commands/KeybindingConfig.swift** (171 LOC) — Keybinding JSON config loader
- **Role:** Loads/parses `~/.textview/keybinding.json`, a flat JSON object mapping `commandID → shortcut string` (e.g., `"view.toggleSidebar": "cmd+shift+e"`). Totally safe: missing file, malformed JSON, unknown ids, invalid values all resolve to empty config.
- **Notable:** Doesn't throw; collects and returns invalid entries (ids, values) separately so the caller (the app) can log them without crashing on bad user config. Validates ids against the registry so typos are caught.
- **Carry:** KEEP — the robustness pattern (total on I/O failures, per-entry validation, structured error collection) is correct.

**Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift**, **KeyboardShortcutsCatalog.swift**, **MenuOrganizer.swift**, **MacroController.swift**, **MacroRecorder.swift**, **PaletteParamFlow.swift** (not fully read; assumed command taxonomy, menu building, macro recording, palette parameter flow).

### TaskRunner

**Sources/ViewerCore/TaskRunner/RunnableTask.swift** (63 LOC) — Runnable task model
- **Role:** Normalised representation of a task discovered from project manifests: name, command (npm/cargo/make/pytest), arguments (tokenized), working directory, source (packageJson/cargo/makefile/commonTestCommand).
- **Notable:** Pure data — discovery and run-spec building are host-testable; the actual spawn to PTY is the live/VM tail. `argv` is the fully-tokenized command vector (no shell).
- **Carry:** KEEP — the shape is clean.

**Sources/ViewerCore/TaskRunner/RunnableTaskDiscovery.swift**, **RunSpec.swift** (not fully read; assumed discovery engine + run-spec builder).

### Extensions

**Sources/ViewerCore/Extensions/ExtensionsInventory.swift** (200+ LOC, partial read) — Unified extension catalog
- **Role:** Merges plugins (`PluginRegistry`) + walkthrough scripts into one inventory with deduplication (by namespaced id `kind:rawID`), deterministic ordering (by kind, then active/inactive, then name, then id), and filtering.
- **Notable:** Pure, `Sendable`, host-testable model logic (no view layer, no registry singleton). The merge deduplication ("first wins") and ordering logic live here, making the *behaviour* testable separate from the pixel rendering. Grouping is by kind; within a kind, active items sort ahead of inactive.
- **Carry:** KEEP — the principle of pulling merge logic into a pure, testable model (rather than doing it in SwiftUI) should be a rebuild pattern.

**Sources/ViewerCore/Extensions/ExtensionsInventory+Live.swift**, **ExtensionsInventoryAdapters.swift** (not fully read; assumed adapters from registry/disk to inventory shape).

### Automation — Core

**Sources/ViewerCore/Automation/AutomationHost.swift** (239 LOC) — Automation protocol boundary
- **Role:** `@MainActor` protocol that MCP/scripting surface reaches through to drive the live view model (DocumentModel). All methods are high-level (open path, select tab, set view mode, find, run verb, code nav, etc.); the real implementation is in ViewerUI.
- **Notable:** Deliberately slices the model into "what agents can do" — a curated surface that doesn't expose internals. Includes canvassing DTO types (`AutomationState`, `TabDescriptor`, `SessionDescriptor`, `AutomationLimits`), all `Codable` and FFI-shaped. Code-nav methods (`automationWhoCalls`, `automationDefinition`, `automationReferences`, `automationRenameSymbol`, `automationMoveFile`) are async because LSP round-trips can take seconds.
- **Carry:** KEEP — the pattern of slicing the model through a protocol so the UI doesn't expose implementation details to automation is sound. Async methods for LSP operations are correct.

**Sources/ViewerCore/Automation/MCPProtocol.swift** (310 LOC) — JSON-RPC 2.0 + MCP wire types
- **Role:** Hand-rolled, minimal Codable implementation of JSON-RPC 2.0 + MCP 2024-11-05 schema (initialize, tools/list, tools/call, error responses). Includes a loosely-typed `MCP.Value` enum (null, bool, int, double, string, array, object) with safe accessors (`value.string("key")` throws on type mismatch).
- **Notable:** Deliberately no external MCP SDK (zero deps, ~150 LOC vs 10× with a package). Correctly tries `Int` before `Double` when decoding numbers so `{"line": 42}` stays as int; uses non-trapping `Int(exactly:)` for double→int to catch out-of-range / fractional attacks. `ID` preserves the client's original shape (int/string/null) so responses match verbatim.
- **Carry:** KEEP — the hand-rolled approach is lean and correct; the non-trapping numeric conversions are security-conscious.

**Sources/ViewerCore/Automation/MCPServer.swift** (593 LOC) — MCP server over stdio
- **Role:** Reads framed JSON-RPC requests on stdin, dispatches to `AutomationHost` on the main actor, writes responses to stdout. Lifecycle: `start()` spawns a reader thread parked in `MCPFraming.decode`, `stop()` closes stdin to unblock the read.
- **Notable:** Caches the output fd once at init to use raw `write(2)` instead of `FileHandle.write`, which raises UNCATCHABLE ObjC exceptions on concurrent close (teardown/peer-close race). Uses a `mainActorDeadline` (default 20s) so if the main actor wedges, the reader recovers with an internal-error response instead of parking forever. Supports both newline-delimited JSON (MCP clients) and Content-Length framing (internal tooling) via `MCPFraming.decodeDetecting`. ASYNC tools (LSP-backed code nav) bypass the main-actor bridge to avoid a multi-second freeze.
- **Carry:** KEEP — the fd caching to avoid ObjC exceptions, the deadline + recovery pattern, and the dual-framing detection are production-grade mitigations worth porting.

**Sources/ViewerCore/Automation/MCPFraming.swift** (390 LOC) — Request/response framing
- **Role:** Encodes/decodes MCP messages in two wire modes: newline-delimited JSON (MCP clients) and Content-Length (internal framing). Includes `FileHandleReader` wrapper that caches the fd once to avoid concurrent-close landmines.
- **Notable:** Auto-detects the framing mode from the first message so the server speaks both without config. The fd caching is the same landmine fix as `MCPServer` — reading from a `FileHandle` after concurrent close can TRAP.
- **Carry:** KEEP — the dual-mode detection is nice UX; the fd-caching pattern is a general solution to a macOS FileHandle hazard.

**Sources/ViewerCore/Automation/MCPSocketListener.swift** (177 LOC) + **MCPSocketBridge.swift** (263 LOC) — Socket transport (alternative to stdio)
- **Role:** `MCPSocketListener` opens a Unix-domain socket on a given path, accepts one incoming connection, and hands it to the server for use instead of stdio. `MCPSocketBridge` wraps a socket (`FileHandle` based) as the input/output for `MCPServer` so stdio-based server code doesn't change.
- **Notable:** Fallback transport for when the parent process prefers sockets over stdio (e.g., system integrations). Listener is single-connection (not a server farm).
- **Carry:** KEEP — the abstraction (protocol-based input/output) lets the transport be swapped without touching the server core.

**Sources/ViewerCore/Automation/MCPToolCatalog.swift** (1,622 LOC) — MCP tool descriptors + dispatchers
- **Role:** ~40 tools organized by function (file ops, view state, find, code nav, canvas, etc.). Each tool has a descriptor (name, description, JSON Schema) and a dispatcher (validation + host call). Tools include `open_path`, `select_tab`, `set_view_mode`, `find`, `search_files`, `git_status`, `run_verb`, `who_calls`, `goto_definition`, `find_references`, `rename_symbol`, `canvas_*` (14 canvas operations), plus many more.
- **Notable:** The security model is centralized here — `validatedExistingURL` validates open_path, `set_zoom` clamps the value (so a clamp is observable on the wire), path jails and limits are documented in the dispatch switch. Canvas tools integrate a DSL compiler (`canvas_lint`), apply engine, and import path. Code-nav tools (async by nature) are noted as TSK-1192 and bypass the main-actor bridge.
- **Carry:** KEEP — the centralized catalog is the right pattern. The principle of validating + clamping in the catalog (not delegating to the host) makes the security model reviewable in one place.

**Sources/ViewerCore/Automation/ScriptVerbCatalog.swift** (364 LOC) — Script verb vocabulary
- **Role:** Data mirror of the `ScriptVerb.apply(verb:to:sessions:)` dispatcher switch in ViewerUI. ~60+ verbs grouped by surface (view, tabs, files, editor, lsp, find, sidebar, sessions, git, bookmarks, tools, palette, canvas, harness) with arg shapes (none, path, int, string, enumToken, structured).
- **Notable:** The dispatcher switch lives in ViewerUI (it needs the model), but the data catalog lives here in ViewerCore so it's host-testable. A test (`ScriptVerbCatalogTests`) parses the dispatcher source and asserts the two stay in sync — if the switch drifts, the gate fails, not the docs. This is an honest "single source of truth via constraint rather than DRY".
- **Carry:** KEEP — the pattern of encoding the vocabulary as data + a drift-detection test is a good practice for any shared interface that can rot (CLI commands, API verbs, menu items).

**Sources/ViewerCore/Automation/AXIdentifierCatalog.swift** (139 LOC) — Addressable element catalog
- **Role:** ~60+ curated native-chrome elements (`mdv.*` accessibility identifiers) grouped by surface (chrome, content, editor, find, data, nav, tools, media). The AX driver and element-reference tooling address these; it's the AX sibling of `ScriptVerbCatalog`.
- **Notable:** A static catalog, not dynamic — only top-level controls that the out-of-process driver can reliably address. A drift guard test asserts every catalogued id still exists in the ViewerUI source, catching silent un-addressing when a control is renamed/deleted.
- **Carry:** KEEP — the pattern applies to any app with accessibility-driven automation.

**Sources/ViewerCore/Automation/ElementRef.swift** (173 LOC) — Stable element reference (copy/paste for agents)
- **Role:** Models five element types: native AX (by identifier), WebView line (doc + 1-based line), WebView selector (doc + CSS selector), file (path, optional 1-based line/endLine for ranges), tab (id). Serializes to `mdv://` URIs and parses them back. Also models `ElementResolution` — the typed action a ref resolves to (activateAX, gotoWebLine, selectWebNode, openFile, selectTab).
- **Notable:** Percent-encodes URI segments (alphanumerics + `._-` unreserved; everything else encoded) to keep `mdv.hexView` readable while allowing `/`, space, CSS punctuation. A one-liner spec in the file documents the five URL schemes. The resolution model separates *what a ref is* from *how to resolve it* — pure logic, host-testable.
- **Carry:** KEEP — the URI scheme design and the resolution model are worth porting. The segment encoding is a good balance between readability and correctness.

**Sources/ViewerCore/Automation/ElementRefExecutor.swift** (47 LOC) — Element resolver (assumed; likely pairs with ElementRef to drive resolution).

**Sources/ViewerCore/Automation/AXDrivePlan.swift** (84 LOC) — Out-of-process AX driver plan (assumed; likely defines how to invoke the external AX driver).

**Sources/ViewerCore/Automation/AXDriverCore.swift** (156 LOC) — AX querying + matching (partial read expected; not fully read).

**Sources/ViewerCore/Automation/CodeNav.swift** (237 LOC) — Code navigation types
- **Role:** (Not fully read; assumed types for LSP code nav: `WhoCalls`, `NavLocations`, `RenameOutcome`, `MoveOutcome` — the DTOs that `AutomationHost` async methods return).

---

## Module Summary

**ViewerCore Automation & Infrastructure** is a layered, well-architected slice for agent-drivable automation:

1. **Automation Host Protocol** (`AutomationHost`) — the model boundary. Deliberately high-level (open path, find, code nav) to avoid exposing internals.

2. **MCP Server** (stdio + optional socket) — production-grade request/response loop with deadline recovery, dual-framing detection, fd-caching to avoid ObjC exceptions, and async support for LSP operations that can't be main-actor-bound.

3. **Tool Catalog** (~40 tools) — centralized, so security model (validation, clamping, limits) is reviewable in one place. Switches on tool name; each tool validates args and calls the host.

4. **Script Verbs** (~60 verbs) — data mirror of the dispatcher switch with a drift-detection test to keep docs honest.

5. **Commands** — a registry of ~150 user actions with optional default shortcuts, script-verb tokens, replayability flags. Supports keybinding overrides from `keybinding.json`. Indexes by id and by verb for O(1) reverse lookup.

6. **Accessibility** — a curated AX catalog + element-reference URI scheme so agents can copy/paste element references and drivers can resolve them.

7. **Observability** — process-wide pluggable sink pattern, FFI-shaped event records (no Foundation reference types), honest memory accounting (phys_footprint, not RSS; separate WebKit helper sum).

8. **Perf** — optional signpost emission gated on env var; zero overhead when disabled.

9. **Architecture** — a tier system that machine-checks the core/Swift split boundary.

10. **Security** — regex ReDoS defense-in-depth, URL scheme path containment, safe numeric parsing from untrusted MCP input.

**Key principles present:**
- **Protocol boundaries** over direct dependencies (AutomationHost, MCPServer's pluggable input/output).
- **Security in the catalog** (MCPToolCatalog validates, clamps, limits before dispatch).
- **Data vs. behavior** (ExtensionsInventory merges logic separate from view; ScriptVerbCatalog + ElementRef are pure data with tests).
- **Robustness** (KeybindingConfig never throws; observability + diagnostics handle missing/malformed gracefully).
- **FFI-shaped from the start** (ObsEvent, AutomationState, all DTO payloads avoid reference types).

---

## Patterns Worth Porting

1. **Tier-based architectural enforcement** (FeatureLocality) — a machine-checkable boundary catalog + consistency check that fails the gate if tiers are violated.

2. **Centralized security policy** (MCPToolCatalog) — validation, clamping, limits live in one dispatch switch, not scattered across handlers. Callers can code-review the security model without hunting.

3. **Protocol boundaries for model access** (AutomationHost) — curate what agents can do; don't expose the model directly. High-level methods only.

4. **Data-mirror drift detection** (ScriptVerbCatalog) — when a dispatcher switch and a data catalog must stay in sync, a test that parses the source and asserts identity catches drift on the gate.

5. **Dual-indexing for O(1) lookup** (CommandRegistry) — index by id and by reverse key (verb) so both directions are fast and can feed into logging/macros.

6. **Robustness via partial failure** (KeybindingConfig) — don't throw on bad config; collect partial successes + invalid entries separately so logging/UI can surface issues without crashing.

7. **Honest memory accounting** (ProcessMemory) — acknowledge what's introspectable (app footprint, best-effort WebKit helpers) vs. what's a lie (per-tab); expose enough truth to be useful without fabricating per-tab numbers.

8. **Curated snapshots over wholesale serialization** (DiagnosticSnapshot) — don't auto-derive Codable from a 2700-line model; curate a flat snapshot so internals can't leak.

9. **Optional instrumentation with zero overhead when disabled** (PerfSignpost) — env-var gate + lazy initialization so disabled builds have only a branch-and-return.

10. **Non-trapping numeric conversions** (MCPProtocol) — use `Int(exactly:)` for untrusted doubles to catch out-of-range / fractional attacks instead of TRAP'ing.

11. **Socket transport abstraction** (MCPSocketBridge) — protocol-based input/output so the server core doesn't care whether it's stdio or socket.

12. **URI scheme design** (ElementRef) — percent-encode segments to keep human-readable parts (mdv.hexView) while allowing safe `/`, space, punctuation in paths/selectors.

---

## Anti-Patterns / Regrets

1. **Not all tools land in the catalog** (noted in code as "GAP report") — a handful of genuinely window/NSApp-coupled commands (`open_path` dialog, find router, zoom-via-menu, debug windows) don't have a pure verb yet and are unreachable via the palette. This is documented as a gap; the rebuild should start with the assumption that ALL commands are palette-invokable (pure verbs first, UI second).

2. **Replayability is coarse-grained** — many LSP/find commands are marked `.excluded` from macros because they're pointer/selection-dependent or prompt interactively, but the catalog doesn't distinguish these from hypothetically-replayable verbs. A finer model might distinguish "replayable with recorded arguments" from "replayable as-is" so partial recording becomes possible later.

3. **Extension merge over-deduplicates** — if two snapshots report the same extension, the first wins, but there's no tie-breaking by freshness/rank. In theory, a stale disk scan could shadow a fresh registry entry. (Mitigated in practice by passing higher-trust sources first, but a rank/priority field would be more robust.)

---

## Gotchas & Surprises

1. **FileHandle.write raises UNCATCHABLE ObjC exceptions on concurrent close** — both `MCPServer` and `MCPFraming` work around this by caching the fd at init and using raw `write(2)`. This is a macOS-specific landmine.

2. **ObsEvent timestamps are raw `UInt64 nanos`, not `Date`** — this is deliberate (FFI-shaped), but it means the rest of the app must coordinate on nanosecond precision or accept precision loss. Timestamps are a per-emission time dependency.

3. **Keybinding file path is `~/.textview/keybinding.json`, NOT `~/.config/` or the standard Library paths** — this is baked into the code. A rebuild that changes this path breaks user configs.

4. **The MCP server's `mainActorDeadline` defaults to 20 seconds** — if the main actor truly wedges, the server will try 20 times before giving up. This is generous by design (don't false-trip a slow but live main actor) but may mask real issues in tests if the test is impatient.

5. **AX element resolution requires the actual element to exist in the tree** — a reference to a deleted or unmounted element can't be resolved. Agents must handle the case where an element reference becomes stale (the element was closed/deleted).

6. **The regex complexity guard has false negatives** — `reject()` catches exponential nested quantifiers, but not polynomial backtracking (e.g., `a*a*a*…b`). Relying on `reject()` alone is unsafe; the `boundedMatches()` deadline is the real defense.

7. **WebKit helper enumeration is best-effort** — helpers can be reparented to launchd, in which case they drop out of the count. The snapshot has a `helpersComplete` flag to signal this uncertainty.

8. **ScriptVerb + CommandRegistry catalogs must be kept in sync** — two separate data structures that describe the same vocabulary. The drift-detection test helps, but it's still a manual sync obligation.

---

## Rebuild Notes

### Approach

1. **Keep the tier system** — it's a production-grade pattern for enforcing architectural invariants. Encode it from day one.

2. **Protocol-based automation host** — don't expose the model directly. Curate a `AutomationHost` boundary. This makes testing (fake hosts), embedding (in other apps), and security audits tractable.

3. **Centralize tool dispatch + validation** — one catalog switch, so the security model is reviewable in one place. Validation, clamping, limits all live in the dispatcher, not scattered across handlers.

4. **FFI-shaped DTOs from the start** — all automation payloads should be flat, Sendable, no Foundation reference types, primitives + string maps only. This future-proofs the RPC boundary.

5. **Data-mirror drift detection** — if a dispatcher switch and a data catalog must stay in sync, a test that parses the source and asserts identity catches drift on the gate.

6. **Support both keybinding modes** — allow user rebinds via JSON config, but also support in-app settings UI (a future feature). The rebuild should assume keybindings can be overridden dynamically.

7. **Make accessibility-driven automation first-class** — a curated AX catalog + element-reference URI scheme (like ElementRef) should be standard, not an add-on.

8. **Observability as a foundation** — a pluggable observability sink, FFI-shaped events, honest metrics (phys_footprint, not RSS). Wire it into the diagnostics dump, performance profiling, and logs from day one.

### Boundaries to Design Up Front

1. **Model ↔ Automation** — an `AutomationHost` protocol, not raw model access. High-level methods only (open, find, code nav, run verb). No exposure of internal state.

2. **Main actor ↔ MCP reader thread** — a deadline + recovery pattern so the server survives wedges. Async methods for long operations (LSP) should not park the main actor.

3. **Security boundaries** — validation/clamping in the catalog, not delegated to the host. Path jails (home + temp only for URL scheme). Regex complexity guards. Non-trapping numeric conversions from untrusted input.

4. **Observability boundaries** — events are FFI-shaped, immutable, sent to a pluggable sink. No auto-persistence, no MCP exposure. All paths redactable for export.

### What NOT to Carry Forward

1. **Don't split commands into "palette verbs" and "menu-only commands"** — every command should have a pure verb by design. Palette invocation should be the default, not an afterthought. (The current gap is documented; the rebuild should start with "all commands are palette-invokable.")

2. **Don't ship regex complexity guarding as your only ReDoS defense** — the rebuild should combine compile-time rejection + wall-clock deadlines on *all* user-supplied patterns. The false-negative risk is real.

3. **Don't accumulate auxiliary extension subsystems** — merge plugins, walkthroughs, scripts, etc. into one inventory from day one. The unified model (`ExtensionsInventory`) is the correct shape.

---

## Files in Batch (45 total)

**Architecture (1)**
- FeatureLocality.swift

**Security (2)**
- RegexComplexityGuard.swift
- URLSchemePolicy.swift

**Observability (4)**
- Obs.swift
- ObsEvent.swift
- ObservabilitySink.swift
- RingBufferSink.swift
- ProcessMemory.swift

**Diagnostics (4)**
- DiagnosticGate.swift
- DiagnosticProbes.swift
- DiagnosticSnapshot.swift
- DiagnosticDumpWriter.swift

**Perf (4)**
- PerfSignpost.swift
- EditorPerfBench.swift
- ResizeSweep.swift
- ScrollSweep.swift

**Commands (8)**
- CommandRegistry.swift
- CommandRegistry+BuiltIn.swift
- KeybindingConfig.swift
- KeyboardShortcutsCatalog.swift
- Shortcut.swift
- MacroController.swift
- MacroRecorder.swift
- PaletteParamFlow.swift
- MenuOrganizer.swift

**TaskRunner (3)**
- RunnableTask.swift
- RunnableTaskDiscovery.swift
- RunSpec.swift

**Extensions (3)**
- ExtensionsInventory.swift
- ExtensionsInventory+Live.swift
- ExtensionsInventoryAdapters.swift

**Automation (14)**
- AutomationHost.swift
- MCPProtocol.swift
- MCPServer.swift
- MCPFraming.swift
- MCPSocketListener.swift
- MCPSocketBridge.swift
- MCPToolCatalog.swift
- ScriptVerbCatalog.swift
- AXIdentifierCatalog.swift
- ElementRef.swift
- ElementRefExecutor.swift
- AXDrivePlan.swift
- AXDriverCore.swift
- CodeNav.swift

**Totals: 45 files, ~4,800 LOC**
