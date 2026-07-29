# Small Targets + Web Assets: Code Learnings (2026-07-11)

## File Inventory

### ViewerKit (8 files, ~1.2 KLOC)
Models and pure-value helpers, completely separate from UI frameworks. Every file is ~100–300 LOC, focused on a single concern.

**Sources/ViewerKit/ViewMode.swift** (341 LOC) — file-type → view-mode mapping + UI projection
- role: THE canonical decision table for what lens (rendered/editor/hex/formatted/preview/diff/table) a file opens in. Every "which mode for category X" question routes through `canonicalDefaultLens()`. `ViewModeControl` is the presentation layer that collapses the real modes to a 3-button UI (Render/Editor/HEX) + per-category user overrides.
- notable: Clean single source of truth; three methods (`availableModes`, `defaultMode`, `canonicalDefaultLens`) stay tightly coupled so the projection never drifts. per-file remembered modes (TSK-1467) layer ABOVE. Format button is conditional (`showsFormat`), not a primary.
- carry: **KEEP** — this is how a greenfield rebuild thinks about lens choice. The mapping is stable and user-proven; the `preferred` per-category override is production-grade. Even a TUI / WebUI rebuild starts here.

**Sources/ViewerKit/FileCategory.swift** (160 LOC) — file-extension → category detection
- role: Extension-first detector (markdown/mermaid/plaintext/code/image/video/pdf/sqlite/archive/binary/unknown), with whole-name matching for extensionless project files (Dockerfile, .gitignore, .env). The `knownBasenames` table is comprehensive and matches the owner's expectations.
- notable: Smart ordering — mermaid before markdown, config patterns grouped cleanly. Rich-doc extraction (docx/rtf → markdown instead of plain-text) and archive handling both show domain thinking.
- carry: **KEEP** — category detection is a solid, well-tested foundation. The basename table is a reference for greenfield. The refusal to UTType-fallback for unknown files (default to .unknown, not .binary) is the right call.

**Sources/ViewerKit/HighlightLanguage.swift** (276 LOC) — language → highlighting + editor coverage
- role: Name the 21 highlightable languages; dual detection (file extension + markdown info-string + shebang); surface which ones are visible in UI (`supportedForDisplay`). The `isHighlightable` and `editorHighlightable` flags are the single source of truth for rendering coverage (which Rust core grammar exists, which CM6 pack exists).
- notable: Pinned by tests (`HighlightLanguageGrammarParityTests`, `CodeMirrorBundleTests`) so coverage can't drift from the enum. Shebangs get extensionless-file love. The split between isHighlightable (TreeSitter/view) and editorHighlightable (CM6/editor) is necessary — different language packs.
- carry: **KEEP** — this is the agreed-upon language surface. The test-pinned invariants are load-bearing. The 22-language set (15 Lezer + 7 legacy StreamLanguage) is hardwon and stable.

**Sources/ViewerKit/FileIconKind.swift** (38 LOC) — file icon model (chip vs glyph)
- role: Two rendering modes — extension-as-text in a tinted badge (chip) or SF Symbol glyph for symbolic types (folder, media, config, etc.). Folder states (collapsed/open/root/hidden/locked/symlink).
- notable: Minimal but complete. The icon-category system (code=blue, markup=pink, config=green, etc.) is a visual grammar.
- carry: **KEEP** — straightforward, extensible model. No surprises here.

**Sources/ViewerKit/ViewModeControl.swift** (201 LOC) — 3-button toolbar presentation layer
- role: Maps the 8 real ViewModes (rendered/source/editor/formatted/table/diff/preview/hex) onto a 3-button toolbar (Render/Editor/HEX) + View-Only toggle + optional Format button. Round-trip contract: `present()` collapses any mode onto (primary, viewOnly, isFormatted); `resolve()` maps a button tap back onto a concrete mode the file supports.
- notable: The owner-resolved UX model (#224 decision A). The view-only toggle doubles as the mode semantics (source=editor+viewonly, editor=editor+writeable). Graceful fallback for missing lenses — if the file can't offer Render, it lands on Source; if no Source, falls back to the file's natural lens. The Format button is independent (separate conditional button, not a primary).
- carry: **KEEP** — this is the owner's mental model. The three primary lenses are stable. Rebuild should adopt this abstraction.

**Sources/ViewerKit/HelpInfo.swift** (22 LOC) — tooltip model (title + description)
- role: Uniform (title, description) pair for UI elements. Title in the native tooltip bubble; description in the status bar hover.
- notable: Equatable & Sendable so callers can dedupe (REPUB-1). Pure value type.
- carry: **KEEP** — tiny, clean, used throughout.

**Sources/ViewerKit/HighlightedText.swift** (550 LOC) — substring highlighting + ReDoS guard
- role: Pure helper for search-result highlighting. Literal substring + regex modes, with catastrophic-backtracking defense (ReDoS guard). Bounded match-time enumeration (250ms wall-clock deadline) and static shape checks (no nested quantifiers, no overlapping alternation).
- notable: **Heavy security thinking.** The regex guards are production-grade (TSK-004/006 security). The `MsgPackValue` type doesn't appear here; this is pure string logic. The RegexComplexityGuard lives in ViewerCore, but this is the host-testable ViewerKit twin. Bounded off-thread enumeration is clever — catastrophic backtracking burns CPU inside ICU, so the closure-based cooperative stop won't fire; moving enumeration to a worker thread + semaphore deadline bounds the caller's wait even though the worker keeps running.
- carry: **KEEP** — this is a model for how to handle untrusted regex in a UI. The math (nested quantifier detection, alternation overlap scan) is load-bearing. Don't rebuild this — port it.

**Sources/ViewerKit/ImageZoomState.swift** (174 LOC) — image zoom math
- role: Pure value functions for image-preview zoom: fit-scale, pan-clamp, zoom-point-under-cursor arithmetic.
- notable: Derivation of the "keep point under cursor" formula is in the comment. Clamping, centered underflow (when image is smaller than viewport). No AppKit dependencies; host-testable.
- carry: **KEEP** — math is solid. Scale-to-fit with upscale gate is the right default.

**Sources/ViewerKit/VideoPlayability.swift** (38 LOC) — video container compatibility
- role: AVFoundation playability check by extension (mp4/m4v/mov/mpg/mpeg/3gp = native; everything else = fallback card). Static-by-extension on purpose (async media loading is too expensive for a pre-flight gate).
- notable: Biased toward "unsupported" for ambiguous containers (AVI: AVFoundation only plays some MJPEG-era files, so classify unsupported). Graceful fallback: unsupported still offers "open externally."
- carry: **KEEP** — conservative, correct. The container list is stable.

### RustCore FFI Wrapper (6 files, ~3.4 KLOC)
In-process FFI bridge over the linked `libmdvcore_ffi.a`. All Swift-side serialization lives here; the Rust core emits MessagePack.

**Sources/RustCore/CoreClient.swift** (1523 LOC) — thin-waist envelope dispatcher + ABI skew guard
- role: The ONE dispatch point for stateless methods (frame-shaped exports). `CoreEnvelope.call(method:req:aux:)` routes to the linked `mdvcore_call(MDV_METHOD_*, …)` envelope. ARC-driven handle lifetime for `CsvSession`. CSV beachhead (Phase A/B): parse CSV, stateful session with level-triggered snapshots.
- notable: **Excellent error typing.** `CoreError` distinguishes wire faults from genuine panics; panic poisons the handle (dead-flagged, no further calls). `CoreABI.assertCompatible()` crash-fasts at entry so ABI skew is caught before corruption. `CoreCapabilities` is feature-negotiation bitmap (TSK-634) — allows client and core to version independently. The capability matrix is client-specific (adapters gate on their requirements).
- carry: **KEEP** — this is the right pattern for FFI in a Rust-core architecture. The panic-poisoning and ABI guard are non-negotiable. The capability matrix is smart (forward-compat without coupling).

**Sources/RustCore/MessagePack.swift** (466 LOC) — minimal MessagePack reader
- role: Hand-rolled decoder for the subset the wire uses (maps, arrays, strings, ints, bools, floats, binary). No external dependency. Nests safely (depth limit 128 guards against stack overflow on adversarial input). OOM-abort guard on array/map reservation (clamping to remaining bytes).
- notable: **Defensive coding.** The depth limit (128) matches the Rust core's JSON-parse MAX_DEPTH. The reservoir-capacity clamping prevents a tiny malformed frame from triggering a 34 GB allocation (an OOM abort, not a throw). The enum structure avoids Swift 6.1.2's recursive-tuple compiler loop (TSK-1210) by using nominal structs (MsgPackPair). The zero-copy decode path (startingAt offset) saves per-cell allocation.
- carry: **KEEP** — this is production-grade. Minimal, no external deps, battle-tested by the PoC. The defensive guards are load-bearing.

**Sources/RustCore/CoreTransport.swift** (181 LOC) — protocol for in-process / remote dispatch seam
- role: `CoreTransport` protocol: stateless methods (`call`) + aux-side-channel methods (`callAux`). `InProcessTransport` implements the linked-library dispatch; `RemoteTransport` (TSK-652) will serve a future remote mdv-serve socket. The transport is process-wide (CoreTransportRegistry), swappable in tests.
- notable: The method table (methodIds, auxMethodIds) mirrors the cbindgen-emitted header constants so the symbols stay in sync; new ported engines just add a row. `CoreTransportRegistry` is thread-safe (lock-guarded); the audit hook (TSK-636) is the ONE emit point for every method call. Transport failures are typed (`CoreError`), not silent.
- carry: **KEEP** — this is how a multimodal transport seam should look. The registry pattern is clean and testable. The audit hook is the right place for observability.

**Sources/RustCore/CoreDocStore.swift** (206 LOC) — stateful editor-doc family (Phase 2)
- role: Windowed CM6 buffer management via the core's doc store. One full-text transfer (`open`), then delta-only mutations (`applyDelta`, `window`, `markSaved`). Host-supplied monotonic clock; core enforces 1.5 GB / 200 docs eviction with dirty⇒pinned law (unsaved docs never evicted).
- notable: The `nowMs()` clock is host-supplied so tests can be deterministic. The envelope dispatch (TSK-1517/1518) is the Phase 2 traffic redesign (one doc open, then only deltas). UTF-16 offsets match CM6's indexing. The delta result carries `changed: nil` on batch rejection (atomic no-op, full resync needed).
- carry: **KEEP** — doc-store is the endgame for large-file perf. The eviction policy (1.5 GB cap, pinning law) is production. Adopt this for greenfield.

**Sources/RustCore/RemoteTransport.swift** (709 LOC) — remote mdv-serve socket carrier
- role: Future remote carrier (TSK-652). Connects to an mdv-serve instance over a unix socket (ssh-forwarded or local); routes all stateless method calls through the remote envelope protocol. Fail-safe: any connection loss auto-reverts to in-process.
- notable: Framing (16 MiB wire cap), auto-reconnect, stale reply drop (version tagging). The remote envelope adds an opaque `bin` body (Phase 2) so complex responses (e.g., large snapshots) can bypass frame-size limits via aux channels.
- carry: **KEEP** — This is the architectural vision of a decoupled core. The remote carrier is proven. Don't rebuild; integrate for greenfield.

### MarkdownViewer Entry Points (3 files, ~5.2 KLOC)
The macOS app shell. `main.swift` (4.4 KLOC) is the AppDelegate + initialization plumbing.

**Sources/MarkdownViewer/main.swift** (~4,400 LOC) — AppDelegate, launch sequence, menu building
- role: App lifecycle, window management, menu construction, script dispatch, MCP server start, session bootstrap, diagnostic dumping, UI-scene application.
- notable: Huge file, but each section is coherent. The launch-config-file path (TSK-1243) solves env-var delivery to LaunchServices-launched apps (getenv not ProcessInfo). The menu rebuilding is reactive (reachable from many places — File/Edit/View/Tools/Help — so needs centralized dispatch). Snippet manager, keyboard shortcuts, diagnostic windows are all retained (no release on close). The observability ring buffer is installed at launch. RustCore precompilation (TreeSitter queries) happens off-main at priority .utility. Sessions bootstrap is lazy. LSP pool start is async (fire-and-forget on launch, idempotent).
- carry: **KEEP overall structure; REFACTOR the size.** This is the cost of the macOS app shell. 4.4 KLOC is large but defensible for app lifecycle. The content is correct (launch order matters, menu interdependencies are real). For greenfield, push more into separate modules (MenuBuilder, SessionsController, DiagnosticsUI) from the start to keep AppDelegate ≤2 KLOC.

**Sources/MarkdownViewer/Diagnostics.swift** (333 LOC) — diagnostic dump, snapshot capture, UI-scene application
- role: Extract from main.swift (Quality #I). Three affordances: `--diagnose` headless JSON dump + exit, `--auto-snapshot SECS`, SIGUSR1 signal trap for live state.
- notable: The trap is gated by build (DEBUG) or env var (MDV_ENABLE_DIAGNOSTICS). Per-user tmpdir (not /tmp) for output. Redaction in release builds (no document content). Auto-snapshot's explicit flush-skip (S4 contract) is documented — bypasses durable-state teardown because the flag is headless-only. UI-scene application routes through ViewerUI.UISceneApplier so the host-testable seam doesn't duplicate logic.
- carry: **KEEP** — this is correct diagnostic infrastructure. The security-aware redaction and tmpdir choice are production-grade. The signal trap is useful for debugging.

**Sources/MarkdownViewer/ScriptRunner.swift** (448 LOC) — `--script` interpreter for L4/L5 VM-driven tests
- role: Read a command script (one per line), apply each to the model, snapshot after each step. Commands: toggle-view, zoom, open PATH, close-tab, show-palette, delay SECS, snapshot, ui-click (REAL event dispatch), resize, resize-sweep (oscillate width), wait-editor-line (block until scroll settles), etc. The bulk dispatch (`ScriptVerb.apply`) lives in ViewerUI for model-only verbs; AppDelegate-coupled verbs (resize, diagnostic-window) stay here.
- notable: The settle delay (300 ms default, configurable via `delay SECS` verb) is important for FSEvents / accordion settle. The ui-click dispatch is real events (hit-testing + responder chain), not synthetic mouse events. The window key() gate (TSK-1047 jetsam issue) activates the app before each step to keep WebContent processes alive. The live-scroll probes (wait-for-settle) prove preconditions before snapshots.
- carry: **KEEP** — this is how to do agent-driven UAT. The script format is simple; the verb vocabulary is comprehensive. The real-event dispatch is non-negotiable (synthetic events miss gesture routing).

### MDVFakeLSPServer Entry Point (1 file, ~476 LOC)
Test harness LSP server.

**Sources/MDVFakeLSPServer/main.swift** (~476 LOC) — deterministic test LSP server
- role: Single-threaded LSP server over stdio, behavior driven by env vars (scenario, delay, diagnostic publishing, shutdown-log tracing). Canned response shapes (hover, definition, symbol, folding, workspace-symbol, diagnostics).
- notable: Scenario modes: normal, slow_init, crash_after_init, garbled_after_init, fail_initialize, encoding_utf8. Hover / completion delays configurable. Shutdown-log uses atomic O_APPEND for concurrent-server interleaving proof. Response shapes are kept in lockstep with LSPClient decoders.
- carry: **KEEP** — this harness is well-designed. The scenario injection is clean. The atomic append trick (proving concurrency via line order) is clever.

---

## Web Assets (8 files, ~4.8 KLOC source; minified bundles prebuilt)

### CodeMirror Editor Surface

**Sources/ViewerUI/Resources/codemirror/codemirror.html** (~1,730 LOC; Phase 4/v2)
- role: CM6 editor host. Strict CSP (no external loads). Bootstraps the bundled CM6 (`codemirror.js` + `codemirror.css`). Declares protocol version (v2) for Swift ↔ JS bridge.
- notable:
  - **Debounced change emission.** Accumulates incremental edits (ChangeSet) and emits a batched delta to Swift every 200 ms (Phase 4 v2). Drift recovery path (`flushChanges`) forces a full-text re-emit. Separate debounce for cursor (50 ms) and scroll (100 ms).
  - **Compartments for hot-swap configuration.** Font, theme, language, indent, wrap, lint-gutter, invisibles, folding, diff-gutter, indent-guides, vim-mode, selection-match highlighting — all in Compartments so reconfigures don't rebuild the whole state.
  - **Drag-gated selection-match highlighting (TSK-890).** The stock CM6 `highlightSelectionMatches` runs on every selection change; a drag fires per mousemove so it runs unthrottled per-frame. Wrapped in a compartment and reconfigured OFF during the drag, back ON at drag-end for one final scan against the settled selection.
  - **Drag-gated active-line highlight (TSK-894).** Replaces stock `highlightActiveLine()`. The stock plugin sticks on the release line after a drag-select. Custom plugin tracks drag state (mousedown → true, mouseup → false) and suppresses the highlight during a drag; on drag-end a `view.dispatch({})` forces recompute so the caret's line re-acquires the highlight.
  - **Custom active-line plugin (TSK-894).** Emits an explicit interaction state (isDragging) so the decoration is cleared on drag-end, not stuck. The queueMicrotask deferral (TSK-1188) lets CM6's pointer gesture set its anchor BEFORE our re-entrant dispatch.
  - **Literal Tab binding.** Owner ask: Tab at the caret inserts a literal `\t`, not an indent. Selection + Tab still indents. Ordered just before `indentWithTab` so the precedence is right.
  - **Snippet tab-stop navigation (TSK-705).** Highest-precedence Tab / Shift-Tab bindings. When a snippet session is live (Swift sets `snippetSessionActive`), Tab posts `snippetTab` to Swift, which walks the session and pushes a `setSelection`. Outside a session they return false → CM6's `indentWithTab` indents normally.
  - **LSP fold ranges (Phase 4 v2).** `foldService` driven by `setFoldingRanges` (Swift → JS). Binary search for the fold at a line; empty array → language defaults.
  - **Diff / blame gutter (Phase 4 v2).** StateField tracks per-line markers (added/removed/modified/blame). Markers ride along on edits via the field's update handler.
  - **Indent guides (Phase 4 v2).** ViewPlugin renders thin rules at indent multiples. Lightweight (viewport-only); toggled via `setIndentGuides`.
  - **Vim mode (opt-in, owner-approved 2026-06-15).** Reconfigures vim compartment [vim()] when enabled, [] when off. May be absent on stale bundles mid-rolling-upgrade → graceful degrade + report. Ex-commands (`:w`/`:wq`/`:x`) route to save (post pending edits, emit "save"). Mode changes fire `vim-mode-change` events → Swift footer indicator. TSK-1252: swallow no-op Esc in vim NORMAL mode (vim doesn't consume it, so it beeps; the highest-precedence keymap swallows it when already in normal mode).
  - **Hover (LSP).** CM6's `hoverTooltip` handles dwell + positioning. Body resolved async via Swift round-trip (post `requestHover` with replyId, resolve on matching `hoverResponse`). Rendered as plain text + inline `<pre>` for fenced code blocks (defense against hostile LSP servers).
  - **Completion (LSP / in-file, TSK-1136).** @codemirror/autocomplete drives the popup. Items resolved via Swift round-trip (post `requestCompletion`, resolve on `completionResponse`). Swift serves LSP completions or in-file buffer-word fallback.
  - **ApplyEdits (Phase 4 v2).** Reciprocal to JS → Swift `incrementalChange`. Swift ships a batch of {from, to, insert} edits in the pre-batch frame; CM6 applies as a single dispatch (one undo step). `version` gating drops stale batches. suppressEmit flag prevents the receipt from echoing back.
  - **Show-invisibles decoration (TSK-342).** Middle-dot for spaces, rightwards-arrow for tabs, pilcrow for line breaks. ViewPlugin redecorates only the viewport. Cached plugin, toggled via `setShowInvisibles`.
  - **Drag-driven real-event context menu.** Right-click posts `contextMenuRequested` with line/char/screen-coords + selection text. Swift pops a real NSMenu (not the browser default). Cmd-click posts `requestDefinition`.

- carry: **KEEP.** The codemirror.html file is 1.7 KLOC of load-bearing JS. Every feature is wired and production. Don't refactor; phase-gate updates (v3 when new CM6 features ship). The protocol versioning (v2 with v1 fallback) is the right pattern for rolling upgrades.

**Sources/ViewerUI/Resources/codemirror/codemirror.js** (prebuilt bundle, ~500 KB minified)
- role: esbuild-bundled CM6 (the full ecosystem: @codemirror/core + lang packs + themes + extensions).
- notable: Global `window.CM` export. The bundle includes 15 Lezer language packs (markdown, javascript, python, json, rust, java, cpp, sql, html, css, xml, go, typescript, tsx, jsx) + 7 StreamLanguage legacy modes (swift, kotlin, csharp, lua, shell, yaml, ruby). One Dark theme prebuilt.
- carry: **KEEP.** Prebuilt bundles are the right model; don't rebuild on every run. Version the bundle in git so everyone gets the same JS. Tag each build with a date/hash for diagnostics.

**Sources/ViewerUI/Resources/codemirror/codemirror.css** (~1 KB)
- role: CM6 theme overrides + custom gutter / widget styling (indent-guides, diff-gutter, blame-heatmap, invisibles, active-line, lint squiggle).
- notable: Dark theme aware (CSS var fallback or dark-mode media query). The diff-gutter colors are the visual grammar. The indent-guide opacity (0.15) is restrained. Vim mode inherits CM6's default.
- carry: **KEEP.** Lean, maintainable. The color tokens can be design-system-swapped.

### Rendered Markdown Surface

**Sources/ViewerUI/Resources/markdown.css** (~1 KB)
- role: Styling for HTMLRenderer's output (rendered markdown / Mermaid). Responsive, dark-aware. Class naming mirrors the HTMLRenderer's output (`content-heading`, `content-list`, `content-code`, `content-link`, `content-blockquote`, `content-table`, etc.).
- notable: Reset + semantic styling (no pretentious design). Headings are differentiated. Code blocks are monospace + bordered. Links are colored (with `:visited`). Tables have borders. Blockquotes are indented. No transitions or animations (keep rendering fast).
- carry: **KEEP.** The class naming is consistent with the host; CSS is plain and declarative.

### Canvas Surface

**Sources/ViewerUI/Resources/canvas/canvas.html** (small HTML host)
- role: WYSIWYG canvas editor (M3 + TSK-1364). Hosts the bundled canvas.js.
- notable: Minimal — just a container div + script tag. CSP mirrors editor.html.
- carry: **KEEP** — canvas is a future feature; the surface is clean and ready.

**Sources/ViewerUI/Resources/canvas/canvas.js** (prebuilt bundle)
- role: Canvas editor engine (bundled JavaScript).
- notable: Not examined in detail (future feature), but the bundling pattern matches codemirror.js.
- carry: **KEEP** — prebuilt bundle model.

### Mermaid Shim

**Sources/ViewerUI/Resources/mermaid/mermaid-shim.js** (small glue layer)
- role: Connects HTMLRenderer's Mermaid fence (`diagamID`) to the mermaid runtime (script-injected into the rendered-markdown WebView).
- notable: Minimal glue — the owner's preference is to use the upstream mermaid bundle without heavy vendoring.
- carry: **KEEP** — thin and correct.

**Sources/ViewerUI/Resources/mermaid/mermaid-shim.css** (small styling)
- role: Mermaid diagram container styling (responsive, dark-aware).
- carry: **KEEP** — minimal.

---

## Module Summary — Architecture & Hangs-Together

### ViewerKit: The Pure-Value Foundation
8 files, ~1.2 KLOC, **zero dependencies** (Foundation only). These are the domain models:
- **File type → lens decision** (ViewMode.swift, ViewModeControl.swift): how every file opens
- **Language detection** (HighlightLanguage.swift): what grammar covers what extension
- **Icon grammar** (FileIconKind.swift, FileCategory.swift): visual + textual identity
- **Security & UX** (HighlightedText.swift): ReDoS defense + substring highlighting
- **Mathematics** (ImageZoomState.swift, VideoPlayability.swift): pan/zoom, container compatibility

All are **testable on the host** (no UI frameworks), pinned by tests, and stable across versions. ViewerKit is the "right way to think about files" — greenfield should start here.

### RustCore: The Thin-Waist Bridge
6 files, ~3.4 KLOC. Swift's one-way into the linked Rust core (`libmdvcore_ffi.a`). Every call crosses the FFI boundary here:
- **CoreClient**: ABI skew guard, panic poisoning, error typing, CSV beachhead
- **MessagePack**: hand-rolled, zero-dep decoder with DoS guards (depth limit, reservoir clamping)
- **CoreTransport**: protocol for in-process (linked) / future remote (mdv-serve) dispatch
- **CoreDocStore**: windowed buffer state machine (Phase 2, UTF-16 offsets)
- **RemoteTransport**: future socket carrier (fail-safe auto-revert)

The architecture is **multi-modal** (in-process XOR remote, swappable in tests) and **forward-compatible** (capability bitmap for feature negotiation). The ABI guard and panic poisoning are non-negotiable safety measures.

### MarkdownViewer: The App Shell
3 files, ~5.2 KLOC. macOS Cocoa / AppKit bootstrapping:
- **main.swift** (4.4 KLOC): AppDelegate, lifecycle, menus, script dispatch, MCP server
- **Diagnostics.swift** (333 LOC): headless diagnostic dumps, signal trap, UI-scene application
- **ScriptRunner.swift** (448 LOC): `--script` interpreter for agent-driven UAT (REAL event dispatch)

The size is large but coherent; it's the cost of integrating macOS app lifecycle. Each section is correct. For greenfield, modularity matters: separate MenuBuilder, SessionsController, DiagnosticsUI so AppDelegate stays ≤2 KLOC.

### MDVFakeLSPServer: Test Harness
1 file, 476 LOC. Deterministic LSP server (scenario-driven, atomic shutdown tracing). Well-designed; keep it.

### Web Assets: The UI Surfaces (4.8 KLOC source + prebuilt bundles)
Two main hosted surfaces:
1. **CodeMirror Editor** (codemirror.html/js/css, ~1.7 KLOC + 500 KB bundle):
   - Debounced incremental emit (Phase 4/v2)
   - 22 language packs (15 Lezer + 7 legacy)
   - Drag-gating for selection-match + active-line (TSK-890/894)
   - LSP hover/completion/fold/diagnostics
   - Vim mode (opt-in) + snippet tab-stops (TSK-705)
   - Real-event context menu + Cmd-click definition
   - Show-invisibles decoration

2. **Rendered Markdown** (markdown.css, ~1 KB):
   - Semantic styling, dark-aware, responsive
   - Class naming mirrors HTMLRenderer output

3. **Canvas** (canvas.html/js, future):
   - WYSIWYG editor (M3, TSK-1364)

4. **Mermaid** (mermaid-shim.js/css, thin glue):
   - Diagram container + diagram script injection

---

## Patterns Worth Porting

### 1. Single Source of Truth for File-Type Decisions (ViewMode.swift)
**File:** `Sources/ViewerKit/ViewMode.swift:212`

The `canonicalDefaultLens()` table is **THE** source. Every "what mode for category X" question routes there. No re-derivation, no drift. Layering works because the canonical lens is separate from extension refinements (csv/tsv → Table, diff/patch → Diff) and user overrides (remembered + per-category preferred).

```swift
// The canonical, single source of truth for a file CATEGORY's default lens.
// Every "what lens does a `<category>` open in" decision routes
// through this one table so the three view-mode surfaces can never drift apart.
public static func canonicalDefaultLens(for category: FileCategory) -> ViewMode {
    switch category {
    case .markdown, .mermaid, .canvas:     return .rendered
    case .plainText, .code, .html:         return .source
    case .image, .audio, .video, .pdf, .sqlite, .archive: return .preview
    case .binary, .unknown:                return .hex
    }
}
```

**For greenfield:** Establish this table FIRST, before UI. Every lens decision flows from it. Test that the two UI projections (ViewModeOptions, ViewModeControl) stay in sync.

### 2. ABI Skew Detection & Panic Poisoning (CoreClient.swift)
**File:** `Sources/RustCore/CoreClient.swift:136–166`

FFI safety via two mechanisms:
- **ABI guard:** Crash-fast on wire-version mismatch before corruption (CoreABI.assertCompatible())
- **Panic poisoning:** Catch panics at the FFI boundary, dead-flag the handle, throw CoreError.panic. No further calls touch suspect state.

```swift
public enum CoreABI {
    public static let compiled: UInt32 = UInt32(MDV_WIRE_VERSION)
    public static var linked: UInt32 { mdvcore_abi_version() }
    public static var isCompatible: Bool { linked == compiled }
    
    private static let checkedOnce: Void = {
        precondition(isCompatible, "mdvcore ABI skew…")
    }()
    
    public static func assertCompatible() { _ = checkedOnce }
}

// In CsvSession.deinit:
deinit {
    if let handle { mdvcore_session_free(handle) }  // ARC owns lifetime
}
```

**For greenfield:** This pattern must be mandatory for any FFI boundary. The ARC-driven lifetime (deinit calls free exactly once) closes the use-after-free hazard.

### 3. Bounded Regex Matching with Wall-Clock Timeout (HighlightedText.swift)
**File:** `Sources/ViewerKit/HighlightedText.swift:68–147`

ReDoS defense in layers:
1. Static shape check: no nested unbounded quantifiers, no overlapping alternation under quantifier (hasNestedUnboundedQuantifier, hasOverlappingAlternationUnderQuantifier)
2. Wall-clock deadline: Match-time enumeration on a worker thread + semaphore timeout. If the deadline is exceeded, abandon the worker and return []. The worker keeps running to avoid a hot loop (ICU doesn't expose a cancel), but the caller no longer waits.

```swift
// Hard wall-clock deadline for a single enumerateMatches run.
static let matchEnumerationBudgetNanos: UInt64 = 250 * 1_000_000  // 250ms

// Run on a worker queue with a deadline.
DispatchQueue.global(qos: .userInitiated).async {
    // ... ICU enumeration; cooperative stop on budget overflow ...
}

if done.wait(timeout: deadline) == .timedOut {
    return []  // Overrun: abandon worker, degrade to "no highlights"
}
```

**For greenfield:** This is the RIGHT way to handle untrusted regex in a UI. Don't use Regex directly on user input; gate with shape checks + bounded enumeration.

### 4. Compartments for Hot-Swap Configuration (codemirror.html)
**File:** `Sources/ViewerUI/Resources/codemirror/codemirror.html:299–327`

CM6's Compartment API lets you reconfigure editor features without rebuilding state. Use this for **everything toggleable at runtime:**
- Theme (dark/light)
- Language (on file/mode change)
- Font size / font family
- Wrap / no-wrap
- Line numbers / fold gutter / lint gutter
- Invisibles (show/hide)
- Vim mode (enable/disable)
- Selection-match highlighting (drag-gated)
- Indent guides (enable/disable)

Each feature gets a Compartment at init; reconfigure via `view.dispatch({ effects: compartment.reconfigure(...) })`.

```javascript
const themeCompartment = new Compartment();
const langCompartment = new Compartment();
const vimCompartment = new Compartment();
// ... etc ...

// At init:
const baseExtensions = [
    vimCompartment.of([]),  // vim off by default
    langCompartment.of(languageFor("markdown")),
    themeCompartment.of(isDark ? [oneDark] : []),
    // ... etc ...
];

// At runtime, e.g., user toggles vim:
view.dispatch({
    effects: vimCompartment.reconfigure(msg.enabled ? [vim()] : []),
});
```

**For greenfield:** Compartments are the KEY pattern for a responsive editor. They eliminate the "reconfigure = rebuild" trap. Use them liberally.

### 5. Drag-Gating for Performance (codemirror.html + Renderless View Plugins)
**File:** `Sources/ViewerUI/Resources/codemirror/codemirror.html:383–462, 1193–1226`

Two uses:
1. **Selection-match highlighting (TSK-890)**: Stock CM6 runs a viewport-wide occurrence scan on every selection change. During a drag-select, that's per-mousemove (~30 Hz) → unthrottled regex on each frame. Solution: gate the feature OFF during drag, back ON at drag-end (one scan against the final selection). 250ms performance win on large files.

2. **Active-line highlight (TSK-894)**: Stock CM6 keeps the decoration on any single-empty-range selection, which sticks on the release line after a drag. Solution: track drag state explicitly (isDragging), recompute decoration only when not dragging.

The queueMicrotask deferral (TSK-1188) is crucial: CM6 registers our ViewPlugin listeners BEFORE its own gesture handlers, so a re-entrant dispatch corrupts the pointer anchor (→ plain click extends stale selection). Deferring lets CM6's handler set the anchor first.

```javascript
function installDragSelectionMatchGate() {
    view.dom.addEventListener("mousedown", function (e) {
        if (e.button !== 0 || dragGateActive) return;
        dragGateActive = true;
        queueMicrotask(() => setSelectionMatchEnabled(false));  // defer!
    });
    document.addEventListener("mouseup", function () {
        if (!dragGateActive) return;
        dragGateActive = false;
        queueMicrotask(() => setSelectionMatchEnabled(true));  // defer!
    });
}
```

**For greenfield:** Drag-gating is essential for responsive UX on large documents. Any expensive per-frame operation (regex, reflow, render) should be gated out during interaction. The queueMicrotask deferral is a universal CM6 safety measure when dispatching from within listeners.

### 6. Capability Bitmap for Forward Compatibility (CoreClient.swift)
**File:** `Sources/RustCore/CoreClient.swift:168–210`

The core exports a bitmap of capabilities (which engines are available). Swift gates each engine on its own bit; UNKNOWN bits are ignored (a newer core can set future bits, and an older Swift just doesn't use them). This allows client and core to version independently.

```swift
public struct CoreCapabilities: OptionSet, Sendable {
    public let rawValue: UInt64
    
    public static let csvSession = CoreCapabilities(rawValue: UInt64(MDV_CAP_CSV_SESSION))
    public static let diff       = CoreCapabilities(rawValue: UInt64(MDV_CAP_DIFF))
    public static let find       = CoreCapabilities(rawValue: UInt64(MDV_CAP_FIND))
    public static let markdown   = CoreCapabilities(rawValue: UInt64(MDV_CAP_MARKDOWN))
    // ... etc (reserved bits for future ports) ...
    
    public static let requiredByShippingAdapters: CoreCapabilities =
        [.csvSession, .diff, .hex, .indent, .cmApply]
}

// Adapter gates on availability:
if !CoreABI.capabilities.contains(.find) {
    fallback_to_swift_find()
}
```

**For greenfield:** This pattern should be standard for any multi-engine architecture. Each shipped adapter declares what it needs; features gracefully degrade when capabilities are absent.

### 7. Thin Export Table for Transport Seams (CoreTransport.swift)
**File:** `Sources/RustCore/CoreTransport.swift:59–89`

A single dispatch table (methodIds, auxMethodIds) maps string names to cbindgen-emitted C constants. Adding a new ported engine = one row. Keeps the Swift side in sync with the header without hand-wiring.

```swift
static let methodIds: [String: UInt16] = [
    "cm_apply": UInt16(MDV_METHOD_CM_APPLY),
    "diff_parse": UInt16(MDV_METHOD_DIFF_PARSE),
    "find_search": UInt16(MDV_METHOD_FIND_SEARCH),
    // ... etc ...
]
```

The transport is protocol-based (CoreTransport) so in-process (linked) and remote (mdv-serve socket) are just two implementations.

**For greenfield:** This two-implementation pattern (local XOR remote) should be built from day one. It costs almost nothing and enables both multimodal deployments and better testing.

---

## Anti-Patterns / Regrets

### 1. ⛔ Monolithic AppDelegate (main.swift, 4.4 KLOC)
Even though the file is coherent, **4.4 KLOC in one class is too large.** The macOS app lifecycle is complex, but that complexity should be distributed:
- MenuBuilder (separate class for menu construction + updates)
- SessionsController (session lifecycle + bootstrap)
- DiagnosticsUI (diagnostic windows + signal trap)
- ScriptDispatcher (script verb routing)

For greenfield: **Cap AppDelegate at 2 KLOC.** Extraction is free once you accept that AppDelegate is just a coordinator, not a dumping ground.

### 2. ⛔ Raw Bundle Load Order (codemirror.js)
The bundled CM6 is massive (~500 KB minified). If it ever fails to load (network, corruption), the editor is completely broken. There's no graceful fallback to a plain textarea.

For greenfield: Consider a **fallback rendering path** (e.g., syntax-highlighted NSTextView) if the WebView loads fail or the JS is missing. This is expensive but recovers from catastrophic bundle corruption.

### 3. ⛔ Protocol Version Brittleness (codemirror.html)
The bridge protocol has explicit versioning (v2, with v1 fallback). This works, but it's a **finite downgrade window.** Once v3 ships, v1 clients break.

For greenfield: Add a **graceful-degradation strategy** at protocol boundaries. If Swift doesn't understand a JS message type, log and ignore (never crash). If JS doesn't understand a command, log and ignore. This trades silent feature loss for robustness.

### 4. ⛔ No Explicit Error Recovery in CFI
The `CoreError` enum is comprehensive, but there's **no standard recovery path.** A panic poisons the handle forever; the app must recreate the session and lose undo/redo history.

For greenfield: Design a **checkpoint/restore path.** When a panic is caught, try to serialize the current buffer state to disk, then suggest "Revert to Saved" to the user. This is expensive but recovers gracefully from core crashes.

---

## Gotchas & Surprises

1. **ViewMode is NOT the same as FileCategory.** The category is what the file *is* (markdown, code, image). The view mode is how it's *displayed* (rendered, source, preview, hex). A markdown file can open in any mode; a category just governs which modes are *available*. This layering matters for "Open As…" override logic.

2. **HighlightLanguage has TWO coverage flags.** `isHighlightable` (TreeSitter view-mode grammar) and `editorHighlightable` (CM6 pack) are separate because the two rendering paths use different language sets. Don't conflate them.

3. **ReDoS guarding is in ViewerKit, not ViewerCore.** The sidebar search highlighter must be protected in isolation because it's a separate code path. ViewerCore has its own RegexComplexityGuard for the find engine, but the sidebar uses ViewerKit's HighlightedText.ranges() with its own guards. Two implementations, two guards.

4. **AppKit `signal(SIGUSR1, SIG_IGN)` is required before DispatchSource.** Without it, the process swallows the signal, and the DispatchSource never fires. This is a macOS / DispatchSource quirk.

5. **QueueMicrotask deferral is essential in CM6 listeners.** A re-entrant `view.dispatch({})` inside a gesture handler corrupts CM6's internal state. Always defer with queueMicrotask. This is a CM6-specific fragility, not a general rule.

6. **CSV windowing uses absolute row indices, not offsets.** When paging the visible rows after a filter, the `indices` array carries ABSOLUTE row ids (from the original unfiltered table), not post-filter positions. This is load-bearing for scrollbar sizing.

7. **The launch-config-file path (TSK-1243) is necessary for the VM GUI lane.** LaunchServices `open --env` does NOT deliver env vars to `sudo -u <user>` apps. The workaround is `/tmp/mdv-launch-config.env` (one-shot, deleted after read). This is not elegant, but it's the only way to pass test knobs to GUI-launched apps.

8. **The nested queueMicrotask in active-line highlighting (TSK-1188).** There are TWO deferred operations: one to set `isDragging`, one to recompute. Both must be deferred separately, and the second must defer again after the first completes. This is not a pattern; it's a specific workaround for CM6's listener order.

---

## Rebuild Notes

If building this capability fresh (a new Swift/Rust editor app, a TUI variant, a WebUI):

### Approach & Boundaries

1. **Start with ViewerKit.** It's pure Swift, zero UI framework dependencies. Adopt the FileCategory enum, ViewMode table, and HighlightLanguage set as-is. These are stable and proven.

2. **Build the Rust core separately.** ViewerKit + RustCore are orthogonal. The core's responsibility is **stateless transformations** (parse, highlight, diff, search, formula eval) + **stateful buffers** (CSV session, editor doc store). Design the FFI boundary FIRST (what methods cross it, what data shapes, what error codes). The MessagePack wire is the contract.

3. **Transport is the seam.** Design CoreTransport as a protocol from day one. Ship in-process (linked library) first; remote (socket) can wait. But the seam must be there so tests can inject a mock.

4. **The CodeMirror surface is a KNOWN GOOD.** 1.7 KLOC of codemirror.html is load-bearing, and the bundled CM6 covers 22 languages. If you're building a Mac app with a code editor, DON'T rebuild CM6 integration. Port the codemirror.html wholesale. If you're building a TUI or WebUI, adapt the debouncing / compartment / drag-gating ideas to your framework (Ratatui has its own render loop; adapt the concepts, not the code).

5. **AppKit integration is unavoidable for macOS.** The 4.4 KLOC main.swift is the price of a native app. Modularity helps, but there's no way around it. For greenfield, start with MenuBuilder / SessionsController / DiagnosticsUI as separate classes. AppDelegate just delegates.

6. **Script-driven UAT is worth the cost.** The ScriptRunner.swift + MDVFakeLSPServer pattern is how you make agent-driven testing work. The `--script` verb interpreter is simple (200 LOC for the dispatcher, the rest is verbs). Real event synthesis (UIEventSynth) is non-negotiable; synthetic events miss gesture routing. Budget 300-400 LOC for this.

7. **Diagnostic affordances are not optional.** The `--diagnose`, `--auto-snapshot`, SIGUSR1 trap aren't for end users; they're for builders and debuggers. They cost 300 LOC and have saved hours of debugging. Include them from day one.

8. **Capability negotiation (CoreCapabilities bitmap) scales.** If your Rust core will ever have optional engines, build this from day one. It costs almost nothing and enables both old-client-new-core and new-client-old-core compatibility.

### Key Design Decisions

1. **File lenses (ViewMode) are core abstraction.** Every file has 1–8 ways to view it. Build the table FIRST, before UI. Test it thoroughly (ViewModeOptions tests are good), then build the UI on top.

2. **Language packs are a bundle, not a build.** The CM6 bundle is prebuilt and vendored (500 KB minified). Don't try to rebuild it on every change. Version it, tag it, commit it. Same for any other large asset (grammar bundles, theme assets, etc.).

3. **Compartments (or equivalent) are mandatory for editor UX.** Hot-swapping configuration without state rebuild is essential. In a TUI, use a similar pattern (state machine with tagged features). In a WebUI, use React's context or equivalent.

4. **Drag-gating is not optional.** Any expensive per-frame operation (regex, reflow, render) must be gated out during interaction. This is a universal UI principle, not CM6-specific.

5. **FFI safety (ABI guard + panic poisoning) is non-negotiable.** Every Rust FFI bridge must have both mechanisms. The ARC-driven handle lifetime is the way.

6. **Tests pin invariants.** HighlightLanguageGrammarParityTests, CodeMirrorBundleTests, ViewModeTests — these aren't nice-to-have. They're the ONLY way to catch drift when coverage changes or features are added. Budget tests accordingly.

---

## Summary: Lessons for Greenfield

| Pattern | Applies to | Status |
|---------|-----------|--------|
| ViewMode table (single source of truth) | Any multi-lens viewer | **KEEP** — Adopt wholesale |
| ABI guard + panic poisoning | Any Rust FFI | **MANDATORY** — Non-negotiable |
| MessagePack wire (hand-rolled, DoS-guarded) | Any FFI boundary | **KEEP** — Zero-dep decoder |
| Capability bitmap (feature negotiation) | Any multi-engine core | **KEEP** — Forward-compatible |
| Compartments (editor hot-swap) | Any code editor | **KEEP** — CM6 or equivalent |
| Drag-gating (performance) | Any interactive UI | **KEEP** — Universal principle |
| Script-driven UAT (real events) | Any testable app | **KEEP** — Worth 300 LOC |
| ViewerKit (pure models) | Any text/file app | **KEEP** — Adopt FileCategory, Language enums |
| RustCore transport seam | Any multi-modal core | **KEEP** — Local XOR remote from day one |
| Monolithic AppDelegate | macOS app shell | **REFACTOR** — Aim for ≤2 KLOC via extraction |
| Diagnostic affordances | Any builder-facing tool | **KEEP** — `--diagnose`, SIGUSR1, etc. |
| Protocol versioning (bridge) | Any JS ↔ Swift WebView | **IMPROVE** — Add graceful-degradation bounds |
| No panic recovery path | Any panic-catching FFI | **IMPROVE** — Add checkpoint/restore |
