# One-way-door analysis — primed (knew the split plan)

I have everything verified. The MCP transport takes `FileHandle` inputs (injectable — not hard-coded to stdin), the AutomationHost conformance is a thin imperative mapping onto DocumentModel's existing verbs, and the command vocabulary is a `switch` over strings in `MCPToolCatalog`. Now I'll write the analysis.

# Pre-PoC one-way-door audit — ranked by migration risk

Verified against the codebase on `main` (2026-05-31). The architecture is in unusually good shape for a split: `ViewerCore` has **zero** `import SwiftUI` (`grep` clean), `TabsState`/`Tab`/`SessionSnapshot`/`AutomationState` are already `Sendable` value types, the MCP command vocabulary is a pure dispatch table, and the persistence layer is core-shaped. The traps below are where *naive* implementation of the priority-list items would weld new behavior to SwiftUI and turn the eventual Rust split into a rewrite rather than a re-host.

Risk legend: **D1** = true one-way door (irreversible / rewrite-to-fix). **D1.5** = reversible but expensive (multi-week untangle). **D2** = two-way door already, listed only to confirm "keep it this way."

---

## 1. Session/runtime-state model — **D1** (highest)

**The trap.** The *persisted* shape is clean (`SessionSnapshot` in `ViewerCore/Sessions/SessionSnapshot.swift:28`, `Sendable`/`Codable`, schema-versioned), but the **live runtime session state lives entirely inside `DocumentModel`** — a 125 KB / ~2900-LOC SwiftUI `ObservableObject` in `ViewerUI/DocumentModel.swift`. `SessionState` (`ViewerUI/Sessions/SessionState.swift:40`) is explicitly "Phase-1 façade … one `DocumentModel` per session" and its own doc-comment defers the real extraction: *"The deeper Phase-2 refactor extracts per-cluster child models onto this type."* The bridge between live and persisted is **lossy and one-directional**: `makeSnapshot()` (`SessionState.swift:104`) serializes only tabs (path + viewMode), sidebar root, zoom, wrap, theme — and hardcodes `sidebarExpandedPaths: nil, sidebarIncludeHidden: nil, splitURL: nil` even though the struct has those fields.

The priority list's **SESSION INDEPENDENCE** item ("everything in a session needs its own state — tabs, selections, tool-window states, scroll state") plus **SESSION TYPES** (Project / Code Review / Pipeline / Metrics) is the multiplier here. If each new piece of session state (tool-window open/closed, scroll positions, per-panel filters, code-review thread state, CI pipeline config) is added as another `@Published` on `DocumentModel`, then:
- The Rust core has no model of "a session" — it's an emergent property of a SwiftUI object graph. You cannot move it; you re-derive it by reverse-engineering 70+ `@Published` fields.
- The TUI/Web front-ends each re-implement session semantics from scratch because there's no authoritative core definition of what a session *is*.
- This is the owner's explicit "untangle now while it's still Swift" item, and it's correctly the #1 risk.

**Core-shaped mitigation (do now, sans-SwiftUI, in ViewerCore).** Promote `SessionSnapshot` from a *save-format* to the *authoritative runtime session model*, and make `DocumentModel` a *projection* of it rather than the owner:

- Define a `SessionRuntimeState` value type (or expand `SessionSnapshot`) in ViewerCore that holds **all** session-scoped state as plain `Codable`/`Sendable` data: tab list (already `TabsState` — reuse it directly, it's in ViewerCore), per-tab view-mode/scroll/selection/cursor, sidebar expansion + filters, split layout, tool-window visibility (this is what `PanelVisibilityOverrides.swift` / `PanelLayoutStore` should feed), and a `SessionKind` enum for the four session types. The per-tab dicts currently scattered on `TabCoordinator` (`csvFilterStates`, `hexBytesPerRow`, `languageOverrides`, scroll/cursor in `EditorCoordinator`) are the leak — they should be keyed-into this value type, not held as `@Published` dicts on a UI coordinator.
- Keep `DocumentModel`/coordinators as the *SwiftUI binding layer* that reads from and writes back to `SessionRuntimeState`. The rule: **a front-end may render and mutate session state, but never *define* it.** Today the definition lives in SwiftUI; flip the ownership.
- The litmus test that proves the door stays open: you should be able to fully round-trip a live session through the core value type with **zero loss** — close the app mid-session and reopen to byte-identical state. The "after a crash the last state isn't restored" bug in the priority list is the same root cause (state only flushed at quit); fixing it *via the core value type* (continuous snapshot-to-core, core persists on a debounce) kills both birds and forces the untangle.
- `SessionKind` (Project/CodeReview/Pipeline/Metrics) must be a **core enum with per-kind state as associated value**, not a UI mode flag. Otherwise each front-end re-invents "what a Code Review session contains."

This is the load-bearing one. Everything below is cheaper if this is done first because session-scoped state gets a home.

---

## 2. Observability sink (system logs + metrics + profiling) — **D1**

**The trap.** There is **no observability sink today** — verified: `ViewerCore` has essentially zero structured logging (`GrammarLoader.swift:285` *deliberately avoids* `os_log`; `LSPWorkspaceOverrides.swift:244` notes "the LSP layer does not currently use OSLog"; `MCPServer.swift:324` has an optional logger that "routes to stderr"). The priority list wants **system logs + UI, system metrics + UI, profiling/capture**. The naive implementation is to sprinkle `os_log`/`Logger` calls through ViewerCore and build SwiftUI views that read them. That's a one-way door three ways:
1. `os.log`/`OSLog` is Apple-only — it does not exist on Linux/Windows, so every logging call site in ViewerCore becomes a porting edit when the core goes Rust.
2. If the "logs UI" and "metrics UI" read directly from an Apple log store (OSLogStore) or `task_info`/`mach_task_basic_info` for memory, the *data source* is platform-locked and the UI can't be reused by the Web/TUI front-ends.
3. Profiling via `os_signpost` (the obvious Apple choice) is likewise non-portable.

**Core-shaped mitigation.** Define a logging/metrics **facade in ViewerCore** that the rest of ViewerCore calls, with the Apple backend injected from the app layer:
- A `protocol DiagnosticSink` (or a struct of injected closures, matching the existing `EditorCoordinator` injected-effect-closure pattern in `EditorCoordinator.swift`) with `log(level:category:message:)`, `counter/gauge(name:value:)`, and `span(name:) -> Token`. ViewerCore code calls the facade; `MarkdownViewer` (the exe) wires the concrete `os_log`/`signpost`/`MetricKit` implementation. This is exactly the shape that translates to a Rust `tracing`-style facade later — the call sites don't change, only the backend.
- **Crucial:** the logs/metrics *UI* must read from an in-process **ring buffer of structured `LogRecord`/`MetricSample` value types** (Codable, in ViewerCore), NOT from OSLogStore. The Apple backend can *also* forward to `os_log`, but the front-end's data source is the core ring buffer. That makes the same logs/metrics panel renderable by the Web/TUI front-ends over the RPC channel.
- Memory metrics (`task_info`) belong behind the same facade as a `gauge`, sampled by an injected platform probe — never read inline in a SwiftUI view.

This pairs with the diagnostic window (#9) and per-tab memory (#7) — both consume this sink.

---

## 3. Scripting / customization surface — **D1**

**The trap.** The MCP automation surface (`MCPToolCatalog.swift`, `AutomationHost.swift`) is already the **best-shaped seam in the codebase** and is *the de-facto RPC contract* — a string-keyed dispatch table (`MCPToolCatalog.dispatch(name:args:host:)` at `MCPToolCatalog.swift:32`) over a protocol whose DTOs are all `Codable`/`Sendable`. The danger is in how the *customization/scripting* item gets built on top of it, and in how `AutomationHost` is *conformed*:
- `DocumentModel+AutomationHost.swift:14` conforms the SwiftUI god-object directly to `AutomationHost` and maps each verb to an imperative SwiftUI mutation (`automationOpenPath` → `openInNewTab`). That's fine as a *binding*, but it means the command vocabulary's semantics currently live in DocumentModel, not in the core. When the core goes Rust, the AutomationHost protocol can move, but its *implementation* (the actual open/select/find logic) is in ViewerUI.
- If the "customization/scripting" surface is built as a *new* mechanism (e.g. a JS bridge in a WKWebView, AppleScript/App Intents, or a bespoke DSL) rather than as **more verbs on the existing AutomationHost contract**, you fork the command surface. Two command vocabularies = two things to port = a one-way door.

**Core-shaped mitigation.**
- **Make `AutomationHost` the single command bus.** Scripting, customization actions, URL-scheme verbs (when re-scoped in), walkthrough steps, and MCP tools should all funnel through one core command vocabulary. The owner's locked direction is "compact binary RPC (rmp-serde), hand-C FFI" — the `MCP.Value` arg shape and the `AutomationState` DTO are the proto-RPC schema. Treat `AutomationHost` + the tool catalog as **the RPC IDL** and keep growing it, not forking it.
- Push verb *semantics* down: the logic behind `automationOpenPath`/`find`/`gotoLine` should increasingly live in core command-handlers operating on the `SessionRuntimeState` value type (#1), with `DocumentModel` just the thing that re-renders after a command applies. The goal: a command can be executed headlessly against core state with no SwiftUI present (the MCP tests already do a version of this with a fake host — extend that until the real handlers are core-side).
- **Do NOT build scripting as a WKWebView JS bridge or AppleScript-first.** Those are Apple-/web-locked and don't survive the split. A core command vocabulary + thin per-frontend adapters does.
- Security: keep the customization/scripting surface gated exactly as MCP is (`validatedExistingURL` home-containment in `MCPToolCatalog.swift:323`, `URLSchemePolicy` containment). Any new scripting verb inherits the same path-containment guard, in core.

---

## 4. Terminal tool-window backend (xterm.js chosen) — **D1.5**

**The trap (given the locked decision).** xterm.js is decided; a native PTY terminal is a *separate parallel effort*. Verified: **no terminal/PTY code exists yet** — greenfield. The one-way-door risk is NOT the renderer choice; it's letting the xterm.js implementation reach straight from a SwiftUI/WKWebView host into `Process`/`posix_spawn`/`forkpty` with the session-process lifecycle, env, cwd, and I/O pumping all living in the WebView coordinator. If you do that:
- The native-terminal team can't drop their backend in — there's no seam.
- The future TUI/Linux front-ends can't reuse the terminal session model.
- The terminal's per-tab session state can't participate in #1 (session independence).

**Core-shaped mitigation (make the backend swappable — the owner's explicit ask).**
- Define a `protocol TerminalBackend` in **ViewerCore** (sans-SwiftUI): `spawn(shell:cwd:env:) -> SessionID`, `write(SessionID, Data)`, an output stream (`AsyncStream<Data>` or a callback), `resize(SessionID, rows:cols:)`, `kill(SessionID)`. This is a byte-pipe + control-plane contract — deliberately renderer-agnostic. xterm.js consumes the output bytes; a native renderer or a ratatui TUI consumes the same bytes.
- The PTY/`Process` lifecycle goes behind the protocol, reusing `ProcessRunner.swift` (`ViewerCore/ProcessRunner.swift` — the canonical Process+Pipe+drain helper, with the >64 KB pipe-deadlock fix per LESSONS, and the new `ResourceLimits` setrlimit support). Do NOT reimplement spawn/drain in the WebView layer.
- The xterm.js side is a *frontend adapter* in ViewerUI: WKWebView ↔ `TerminalBackend` byte bridge, using the existing `JSStringEmbedding.sanitize` discipline (`ViewerCore/JSStringEmbedding.swift`) for any JSON crossing into `evaluateJavaScript` (this is a documented footgun — U+2028/2029).
- **Terminal session state is session-scoped** (priority list: tabs in the terminal window, and SESSION INDEPENDENCE). The terminal's `SessionID`/cwd/scrollback-cap belongs in the #1 runtime-state value type, so a session restore can re-spawn the terminal in the right cwd.
- Backend swappability test: the native-terminal effort should be able to provide a `TerminalBackend` conformer with zero changes to the xterm.js adapter. If that's not true, the seam is in the wrong place.

This is **D1.5 not D1** only because it's greenfield — get the protocol boundary right on first write and it's a two-way door for free; get it wrong and it's a contained-but-real rewrite.

---

## 5. Per-tab memory / profiling hooks (status bar per-tab + total) — **D1.5**

**The trap.** The status bar today (`StatusBar.swift:93` `private struct Metrics`, `:109` `currentMetrics`) computes *file* stats (size, line count) memoized per-render — it has no concept of memory. The priority-list item ("status bar shows total + per-tab memory usage") naively means: read `task_info`/`footprint` in a SwiftUI view and attribute bytes to a `Tab`. Two doors:
1. The memory-probe API (`mach_task_basic_info`, `phys_footprint`) is Apple-only → non-portable call sites if placed in core or read inline in the view.
2. **Per-tab memory attribution is architecturally meaningful** — it forces you to model "what does a tab own." If that ownership is implicit in the SwiftUI object graph (caches scattered across `TabCoordinator`, `HighlightCacheActor`, `renderedHTMLCache`, WKWebView WebContent XPC), you can't attribute it, and the eventual core can't either. As BACKLOG notes, Activity Monitor sums WebKit XPC helpers under the parent — so "per-tab" is already fuzzy.

**Core-shaped mitigation.**
- Memory sampling goes through the **#2 metrics facade** as a `gauge`, with the platform probe injected. Core stays clean; the Apple `task_info` call lives in the exe.
- For *attribution*, define a core `ResourceAccounting` notion keyed by tab id / session id: each subsystem that holds per-tab bytes (editor buffer size, cache entry bytes, file byte count) reports an *estimate* to a core accumulator. This is reusable by every front-end and is honest about what it can measure (estimate, not RSS). The per-tab dict-cleanup discipline already centralized in `TabCoordinator.cleanupAfterClose` (`TabCoordinator.swift:291`) is the model — the accounting registers/deregisters on the same close hook (`addCloseHook`, `:143`).
- Profiling capture (`os_signpost`) → facade `span` (#2), backend injected.

**D1.5:** the *display* is cosmetic and reversible, but the *attribution model* is the thing that's expensive to retrofit. Build the core accounting hook now; the exact UI can change.

---

## 6. Git file-history window (table + diffs) — **D1.5**

**The trap.** The priority item wants a structured UI table (changes/date/author), click-a-commit-for-state+delta, Cmd-click-two-for-diff. The git layer is already core-shaped and good (`ViewerCore/Git/GitClient.swift` via `ProcessRunner`, `DiffParser`, `GraphLayout`, `TrackedReposReducer`). The door risk: if the new history window's data model (commit list, selection-pair state, diff request) is assembled ad-hoc inside a SwiftUI view (like the existing git panel's `@State` caches), then the "history query → rows → selected-pair → diff" pipeline isn't a reusable core query — every front-end re-derives it.

**Core-shaped mitigation.** Add the file-history query as **core functions returning value types**: `fileHistory(path:) -> [CommitRow]` (CommitRow = `Codable` {sha, author, date, summary}), `commitState(sha:path:) -> Blob`, `diff(a:b:path:) -> Diff` (reuse `DiffParser`). The two-commit-selection is *view state* (fine in UI), but the *queries it issues* are core. This mirrors how `GitClient` already works — just don't let the new window grow its own git-shell-out or its own diff parsing. Two-way door if the query layer is core; expensive if the SwiftUI view becomes the only place that knows how to build a file history.

---

## 7. Compressed-files-as-folders & HTML rendering — **D2 leaning D1.5**

**Compressed files (click → becomes a folder).** The trap is treating it as a SwiftUI sidebar trick (synthesize child rows in `SidebarModel`). It's actually a **virtual-filesystem** concern: an archive should present as a `FileTreeService`-compatible node source. Mitigation: define an `ArchiveEntrySource` protocol in ViewerCore that the sidebar's tree consumes the same way it consumes a real directory (`FileTreeService.swift` is the existing seam). Then the same archive-browsing works in TUI/Web. Decompression itself is core (stream entries, don't unzip to disk). **D1.5** if you build it sidebar-first; **D2** if it's a tree-source from the start.

**HTML rendering.** Lower risk because there's already a sanitizer seam: `HTMLSanitizer.swift` + `HTMLRenderer.swift` in ViewerCore (allowlist, CSP). The door risk is rendering arbitrary user HTML in a WKWebView with JS enabled and without routing through `HTMLSanitizer` — that's a *security* one-way door (XSS/local-file-read surface) more than a portability one. Mitigation: any HTML-render path goes through `HTMLSanitizer` (already the documented invariant in DESIGN "Security model"); the WKWebView is the renderer, sanitization is core. The Web front-end reuses the same sanitizer.

---

## 8. PERF "work off main thread, proper loading/error states" — **D1.5**

**The trap.** This looks like pure polish but it's load-bearing for the split. Today `materializeIfNeeded` is synchronous on MainActor (BACKLOG "highest-leverage remaining UX win"; LESSONS confirms a 32 MB log freezes the UI). The naive fix wires `async`/`Task` directly into SwiftUI view bodies and `DocumentState`. If file-load orchestration lives in SwiftUI, the core can't drive loading and the front-ends each re-implement loading/error state machines.

**Core-shaped mitigation.** Model document load as a **core state machine**: extend the existing `DocumentState` (it already has `.empty`/`.loaded`/error cases per the lazy-restore design) with an explicit `.loading` case, and move the load orchestration into a core async function (`DocumentController.swift` is the existing seam — `ViewerCore/DocumentController.swift`). The view *observes* `DocumentState`; it doesn't *own* the load. That state machine is directly portable and every front-end renders the same loading/error/stale states — including the priority-list "show Modified in RED if file changed on disk and loaded copy is stale," which is a core-computed `isStale` flag on the document state (the `EditorBuffer` already does mtime/size fingerprinting at `EditorBuffer.swift:315` `statFingerprint` — lift that into the load state machine).

---

## 9. Diagnostic window (DocumentModel JSON / temp files / fds / ports) — **D2** (low stakes, per owner)

**Status: not a door, but confirm the security posture.** `DiagnosticDump.swift` already exists, is `@MainActor`, gated behind `--diagnose`/SIGUSR1, has a `redactContent` option (`:30`) so persisted dumps don't embed user content, and uses permission-free same-process `cacheDisplay` capture. Per owner's decision (curiosity/debug aid, NOT via MCP/scripting): 
- **Keep it out of the AutomationHost/MCP catalog** — verified it's *not* one of the 10 tools, good. Do not add it.
- It dumps the *NSView/CALayer tree* (inherently UI-layer, won't port — that's fine, it's a Mac-debug tool). The "DocumentModel as JSON" part overlaps with #1: if you build #1's `SessionRuntimeState`, a core `debugDescription`/`Codable` dump of *that* is the portable, non-UI diagnostic, and the NSView dump stays Mac-only. 
- Gate the temp-files/open-fds/ports enumeration behind `#if DEBUG` or a launch flag, never expose via scripting. Low priority, low stakes — no further core work warranted.

---

## 10. Walkthrough deeplinks (URL scheme) — **D2** (de-scoped, keep open)

**Status: do not build now (owner de-scoped), keep the door open.** The seam already exists and is well-contained: `URLSchemePolicy.containedPath` (`Security/URLSchemePolicy.swift:38`, home+tmpdir containment) and the handler in `main.swift:327` `application(_:open:)` routing `markdownviewer://` through it. The walkthrough *engine* is already core (`ViewerCore/Walkthrough/`). The only guidance: when deeplinks are eventually built, route the verb through the **#3 command bus** (AutomationHost), not a bespoke handler — so a `walkthrough://start?id=...` deeplink, an MCP `start_walkthrough` tool, and a UI button all execute the same core command. No work now.

---

## Items that are already two-way doors (confirming, no action)

- **Image fit/center/zoom/pan.** `ImageZoomState` (`ViewerKit/ImageZoomState.swift`) already has the zoom/pan math as a pure, testable, `Sendable` value type. The Cmd+Scroll/drag *gestures* are AppKit (`MediaPreviewView`), but the math is core. Keep it that way — gestures are inherently per-frontend; the state math is shared. 
- **Tooltips (title + description, status-bar description).** A title/description pair per interactive element is just data. If you model it as a core `ControlDescriptor {id, title, description}` registry it's reusable for Web tooltips; even if you don't, tooltip strings are trivially portable. Low risk — just don't hardcode them unstructured if you want the Web front-end's `title=`/`aria-describedby` to reuse them.
- **Tabs overflow/min-width/pin/dots, folder-stats slide-down, SQLite scaling, binary-file dropdown bugs.** All pure front-end rendering/layout or already-core logic (`SQLiteReader`, `FileCategory` for the binary-file type detection). The "blue dot if dirty / red dot if changed on disk" *signals* should be core flags on the document state (#8) — the *dot rendering* is per-frontend. The listed bugs ("closing with one tab reopening shows two," "shoulder buttons 4/5/6 do nothing," "row-count tool window can't be dismissed," "Open in New Session opens a dialog though we know the folder") are correctness bugs, not architecture doors — fix in place. Note: "Open in New Session opens the dialog" is wired at `main.swift:202` → `sessions.openFolder(url, forceNew: true)`; the bug is the call site passing through a picker instead of the known URL.

---

## One-paragraph summary for the orchestrator

The codebase is **well-positioned** for the Rust/multi-frontend split — ViewerCore is genuinely SwiftUI-free and the MCP/AutomationHost surface is an almost-ready RPC IDL. The genuine one-way doors are all variations of the same mistake: **letting new state or new logic accrete on the SwiftUI `DocumentModel` god-object instead of in a core value type.** The four must-do-now core-shaping tasks, in order: (1) lift the **runtime session model** out of `DocumentModel` into a `Sendable` core value type that `SessionSnapshot` round-trips losslessly (this also fixes the crash-restore bug); (2) build a **diagnostic/metrics facade** in ViewerCore with the Apple `os_log`/`signpost`/`task_info` backend injected, and a core ring-buffer the logs/metrics UI reads from; (3) treat **`AutomationHost` + the tool catalog as the one command bus** and grow scripting/customization/deeplinks onto it rather than forking a JS/AppleScript surface; (4) put the **terminal behind a `TerminalBackend` protocol** in ViewerCore (reusing `ProcessRunner`) so xterm.js is just a frontend adapter and the parallel native-terminal effort can drop in. Per-tab memory attribution (#5) and the document-load state machine (#8) are the two D1.5s worth doing alongside #1 because they share its state-ownership model.

Key files: `ViewerUI/DocumentModel.swift` (the god object to untangle), `ViewerUI/Sessions/SessionState.swift:104` (lossy `makeSnapshot`), `ViewerCore/Sessions/SessionSnapshot.swift:28` (the value type to promote), `ViewerCore/Automation/{AutomationHost,MCPToolCatalog}.swift` (the RPC seam to extend), `ViewerCore/ProcessRunner.swift` (terminal backend reuse), `ViewerUI/DiagnosticDump.swift` (keep debug-gated, out of MCP), `ViewerCore/Security/URLSchemePolicy.swift` (deeplink seam, leave dormant).