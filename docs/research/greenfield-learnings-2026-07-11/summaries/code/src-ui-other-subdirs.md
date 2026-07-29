# ViewerUI Subdirectories: Observability, LSP, Review, Automation, Coordinators, Sessions, Sidebar, ClaudeMonitor, Canvas, Perf, Highlight

## File Inventory

### Observability (7 files)

**Sources/ViewerUI/Observability/FrameRateMonitor.swift** (101 LOC) — Real-time FPS/jank instrumentation layer over CADisplayLink, rolling window statistics judged against per-display nominal cadence.
- notable: `#215 PUBLISH DISCIPLINE` — bounded publisher (0.5 s floor) so metrics tree re-body at most every half-second, never per frame (CADisplayLink ticks at 60–120 Hz). Pure logic detached from SwiftUI renders. Heuristic: `fps < nominalFPS * 0.95` OR `hitchCount > 0` flags jank.
- carry: **KEEP** — clean separation of concerns, bounded publisher pattern is production-grade, no transitive bloat.

**Sources/ViewerUI/Observability/InstrumentationWindowView.swift** (119 LOC) — Tool window host (Logs / Metrics / Memory tabs), DEBUG-gated behind `DiagnosticGate`, three independent projections over one shared sink.
- notable: Per-tab projection lifecycle (`.onAppear`/`.onDisappear`) so backgrounded tabs stop expensive polling (pid-walk for memory). Diagnostic gate enforcement is one-shot at build time (gate re-checked by AppDelegate opener so stale checks are impossible).
- carry: **KEEP** — tight, single-responsibility composition model for observability UI; no coupling to DocumentModel.

**Sources/ViewerUI/Observability/LogsView.swift** (315 LOC) — Ring-buffer event stream viewer with severity/subsystem/text filters, tail-f auto-scroll, copy-visible, clear affordances. No bootstrap bloat.
- notable: Level-color mapping is consistent with severity badges elsewhere. Row layout uses fixed widths (timestamp 92pt, level 42pt, subsystem 64pt) so columns align. Text selection enabled for copy. LazyVStack pagination for large buffers.
- carry: **KEEP** — straightforward list surface, well-patterned toolbar/filters/status bar; no framework dependencies.

**Sources/ViewerUI/Observability/MemoryView.swift** (194 LOC) — Three-tier honest memory readout: (1) app phys_footprint via `task_info`, (2) WebKit helpers via pid-walk + "shared" disclaimer, (3) per-tab content-byte PROXY (not RSS, explicitly disclaimed).
- notable: Unapologetic disclaimer footnote: "Why no per-tab MB? … attachment to honest numbers — "fabricated confidence" rejection is codified here.
- carry: **KEEP** — principle-driven design, educates the user on reality, never glosses over complexity.

**Sources/ViewerUI/Observability/MetricsView.swift** (250 LOC, partial) — Metric registry renderer (counters/gauges by subsystem), TSK-275 FPS strip (display-link backed). Grouped by metric name prefix (first dotted segment).
- notable: FPS strip red on jank (hitchCount > 0 OR fps < 95% nominal); nominally-aware so 120 Hz is not flagged as slow on a ProMotion panel. Metrics NOT republished per-emit (LESSONS.md REPUB-1) — polled at 1 Hz via projection.
- carry: **KEEP** — metric grouping heuristic is clean; zero-cost hidden-tab polling.

**Sources/ViewerUI/Observability/ObservabilityProjection.swift** (170 LOC) — `@MainActor` UI projection over core RingBufferSink. Polls at 1 Hz; republishes only on actual change (version token, equality guards on metrics hash/event count/memory sample).
- notable: CRITICAL discipline documented: "Why a poll, not observe-and-republish" — wraps lock-guarded aggregator from unrelated background threads (LSP parse, MCP stdio, grammar dlopen). Keystroke → trace event → @Published change → whole-tree re-body is the exact regression LESSONS.md killed. Poll + coarse version token + equality gates prevent republish amplification.
- carry: **KEEP** — exemplary polling pattern for hot-path aggregators; REPUB-1 principles are embedded in the design.

**Sources/ViewerUI/Observability/TabMemoryProxy.swift** (70 LOC) — Per-tab content-byte proxy (honest proxy, not RSS). Value type, `Sendable`, decoupled from `DocumentModel` for test composition.
- notable: Explicit disclaimer in comments: "This is explicitly not a per-tab RSS number." `hasLiveWebView` flag lets the Memory view hint that true cost lives in shared helpers. ByteFormat helpers (KiB/MiB, human-readable) are shared with LogsView.
- carry: **KEEP** — minimal value type; no runtime cost.

---

### LSP (5 files)

**Sources/ViewerUI/LSP/LSPDiagnosticsView.swift** (130 LOC) — Dev-only diagnostics panel: pool state, per-server status (live/dead/starting), response times, crash counts, last error. Polls every 2 s.
- notable: Table-based row layout, min height 160pt. Simple polling model via `Task { @MainActor }` loop. "Crashes" counter increments on subprocess exit; language + workspace-root keys drive the pool identity.
- carry: **KEEP** — dev-specific tool (not shipped user-facing); minimal, correct polling pattern.

**Sources/ViewerUI/LSP/LSPHoverAttachment.swift** (200 LOC, partial) — Production LSP hover + Cmd-click → definition. Cursor-paused dwell timer (300 ms), popover dismiss on Esc/outside-click/scroll/window-resign-key.
- notable: TSK-963 fix: explicit `invalidate()` on main actor (synchronous cleanup of tracking area, NotificationCenter observers, event monitors). `deinit` backstop uses `Task { @MainActor }` as LAST RESORT. Strong ownership guard: testing requires real `NSTextView` + `NSTrackingArea` (AppKit objects, no window/screen required). `nonisolated(unsafe)` fields for deinit access (Swift 6.1 limitation, no `isolated deinit` yet).
- carry: **KEEP** — production-hardened state machine for transient popover lifecycle; explicit cleanup discipline is exemplary.

**Sources/ViewerUI/LSP/LSPMarkdownRenderer.swift** (156 LOC) — Render `LSPHover.contents` (markdown or plain text) into `NSAttributedString` for popover. Uses Foundation `AttributedString(markdown:)` for inline markup + custom fenced-code-block pass.
- notable: WHY NOT pull in `swift-markdown`? Lightweight justified: `swift-markdown` is overkill (output tree, re-traverse, re-style ~200 LOC to save ~5 LOC), so Foundation's lightweight inline-only path + line-based code-block split wins. Fenced code gets monospaced font + text-background color. Inline traits (bold/italic/code) are bridged from Foundation's `.inlinePresentationIntent` bitmask to NSFont traits.
- carry: **KEEP** — dependency hygiene exemplar; pragmatic scope-matching.

**Sources/ViewerUI/LSP/LSPNavigationPanel.swift** (200 LOC, partial) — Sidebar section: LSP references + workspace-symbol search. Two modes (references / symbols) served by the same panel via `LSPNavigationStore` normalization. Symbol mode hosts a search field; references are context-driven (right-click → Find References).
- notable: `uiSize` closure threaded from host (`DocumentModel.uiSize(_:)`) so header scales with UI zoom. Coexistence note: parallel agent lands unified search panel; workspace-symbol mode here will become a sixth pill on that panel. Empty-state messaging is mode-specific: references need "right-click identifier → Find References", symbols offer "type a query above".
- carry: **KEEP** — elegant indirection via `LSPNavigationStore` normalizer + mode enum; scales with UI zoom; conditional wiring of search field.

**Sources/ViewerUI/LSP/LSPOutlineSection.swift** (200 LOC, partial) — Sidebar section: `textDocument/documentSymbol` for active file, tree display with disclosure. Language-gated (markdown outline via fallback, LSP server if available). Persisted expansion state via `@AppStorage`.
- notable: TSK-637: markdown files have no LSP server but DO have a tested outline extractor (heading tree) — served through the same panel. Per-language gating: if no LSP server + not markdown → panel hidden (avoids "Outline" forever empty for primary use case). Symbol tree rendered via `OutlineGroup(symbols, children: \.maybeChildren)`.
- carry: **KEEP** — graceful fallback pattern for markdown; language gating removes dead panels; persisted expansion state.

**Sources/ViewerUI/LSP/LSPProblemsPanel.swift** (200 LOC, partial) — Sidebar section: flat list of ALL LSP diagnostics across files, severity icon + file + line + message. Severity filter (all/errors/warnings). Counts pill (error/warning badges).
- notable: UAT LSP-01: `activeFileUnanalyzed()` closure (threaded from host) distinguishes "not analyzed" (source view never sent didOpen/didChange, so diagnostics never computed) from "clean bill of health" — an empty Problems panel for a `.swift` file says "not analyzed here, open in Editor to see problems", not "no problems". Button row styling (hover feedback + pointing-hand cursor). Per-row accessibility label: "Error in Foo.swift line 42: missing semicolon".
- carry: **KEEP** — honest empty-state messaging principle; row-interaction pattern using Button + RowHoverButtonStyle; accessibility naming.

---

### Review (5 files)

**Sources/ViewerUI/Review/CommentCards.swift** (200 LOC, partial) — Shared severity presentation (color/label mapping) + inline comment composer + rendered comment threads with replies, severity dot, author·time, staleness badge, Edit/Resolve/Reply/Delete actions.
- notable: Severity enum → dotColor/label mapping used across editor / thread card / sidebar consistently. Anchor staleness badge (§3.2) shows "code changed since review" (orange) or "anchor not verifiable" (secondary). Comment editor is plain SwiftUI TextEditor, no markdown lib (bundle cap + dependency rule). Thread card shows parent + all replies in one card, resolved comments strike-through + grey.
- carry: **KEEP** — consistent severity styling; explicit staleness signals; minimal markdown handling (TextEditor only).

**Sources/ViewerUI/Review/ReviewExport.swift** (71 LOC) — Export coordinator: render review JSON (via unchanged ViewerCore `ReviewExporter`), copy to pasteboard or file, record export + transition state → `.sent`. TSK-530: two modes (with/without code snippets).
- notable: Pure `renderJSON` function (no side effects); exportToClipboard + exportToFile are thin wrappers around render + file I/O. Mode parameter selects verbatim hunk snippets (`.withCode`, default) or comments + anchors only (`.withoutCode`, for receiver-already-has-source or "code stays on machine").
- carry: **KEEP** — clean separation of pure export logic + side-effecting wrappers; mode parameter is elegant.

**Sources/ViewerUI/Review/ReviewIndexTab.swift** (115 LOC) — Git panel "Review" tab: flat list of reviews stored in `.textview/reviews/`, "New review…" affordance. Stage 2 seeds the list; Stage 3 adds row interaction + new-review sheet + navigation into ReviewTabView.
- notable: TSK-523: active review session takes over the tab — a review-aware DiffView (inline structured diff + comments) replaces the review index. Reload on repo-root change. Unresolved comment count badges the tab.
- carry: **KEEP** — clean modal pattern (index → active session takes over tab); badge shows unresolved count.

**Sources/ViewerUI/Review/ReviewSession.swift** (250 LOC, partial) — Observable runtime for review views: wraps ViewerCore `Review`, caches parsed diff, owns capture pipeline (§3.1) + staleness derivation (§3.2), debounced serial write queue (SessionStore pattern).
- notable: TSK-912: `AddTarget` = pickable location for new comment (fileIndex, hunkIndex, side, lineNo). `firstAddTarget` scans diff top-down → first reviewable line wins, mapped to natural side (added→.new, removed→.old, context→.context). Toolbar "Add comment" defaults to first target so entry point is reachable without hover. `capture()` = freezes LineAnchor + HunkContext + blobSha at comment creation (§3.1). Staleness recomputed on reload + on demand (§3.2).
- carry: **KEEP** — robust model for comment anchoring + staleness; natural side-mapping heuristic; debounced persistence.

**Sources/ViewerUI/Review/ReviewTabView.swift** (175 LOC) — Top-level review surface: review-aware DiffView + comment sidebar + export toolbar. Export menu (Cmd-Shift-E default, without-code option via menu disclosure). "Add Comment" sheet (toolbar affordance, defaults to first anchorable line).
- notable: DiffView reuses the SAME implementation, receives optional `reviewSession` parameter so inline comments/anchors render. TSK-912 sheets use the first anchorable line as default. Export instructions (draftInstructions) are threaded into the coordinators. Sidebar visible toggle. Mark Complete button.
- carry: **KEEP** — composability of DiffView + ReviewSession makes the review surface feel native; comment sheet pattern.

---

### Automation (5 files)

**Sources/ViewerUI/Automation/AXUIElementNode.swift** (87 LOC) — Real macOS `AXUIElement` adapter conforming to ViewerCore `AXNode`. Out-of-process driver attaches via `AXUIElementCreateApplication(pid)`, walks the live AX tree. Frame assembly from `AXValue` position + size.
- notable: TSK-1254 slice 2 — pure `cgRect(positionValue:sizeValue:)` frame assembly is host-testable (no window/screen required); live attribute reads + `AXUIElementPerformAction` need running app + Accessibility TCC grant (VM/owner-validated). Attribute reads are wrapped in defensive null-checks; returns optional.
- carry: **KEEP** — clean adapter interface; testable / not-testable boundaries are explicit.

**Sources/ViewerUI/Automation/ClickTargetRegistry.swift** (93 LOC) — SwiftUI-side click-target registration. Controls publish their `.global` frame via `.uiClickTarget("mdv.x")` into the registry (via `onGeometryChange`). `resolveTargetRect` uses registry FIRST (SwiftUI controls invisible to NSView walk / AX walk), then AppKit walk (hosted views), then AX tree (dead in-process, kept for external parity).
- notable: TSK-620 half B — in-process accessibility tree is EMPTY (SwiftUI materializes AX elements only for external AX clients). SwiftUI controls inside NSHostingView are not NSViews. Registry fills the gap: `ClickTargetRegistry.windowRect(fromSwiftUIGlobal:contentView:)` flips y-coordinate if root is not flipped, then converts to window space.
- carry: **KEEP** — pragmatic workaround for SwiftUI's AX invisibility; triple-fallback resolution order (registry → NSView walk → AX tree) is exhaustive.

**Sources/ViewerUI/Automation/DocumentModel+AutomationHost.swift** (200 LOC, partial) — Conformance to `AutomationHost` protocol. No new policy: argument validation lives in `MCPToolCatalog`. Pure re-exposures of existing DocumentModel methods through protocol boundary.
- notable: Nonisolated async methods (whoCalls, definition, references, rename, moveFile) for MCP server (calls from reader thread), hopping to `lspPool` property. `automationFind` routes through Rust FindEngine (`.find` gate, TSK-645) or Swift fallback. `automationRenameSymbol` dry-runs by default (compute summary from WorkspaceEdit without touching buffers), `apply:true` routes through existing `applyWorkspaceEditToOpenTabs` (same path as menu rename).
- carry: **KEEP** — mechanical conformance; no new surface bloat.

**Sources/ViewerUI/Automation/ScriptVerbDispatch.swift** (200 LOC, partial) — Keystone of testing-pyramid migration (§3.1). `--script PATH` dispatcher lifted from AppDelegate (was tightly coupled), now a free function callable against ANY hermetic (DocumentModel, SessionsAppCoordinator) pair — no NSApplication, no window, no process spawn. Two callers: (1) AppDelegate for VM `--script` (delegates here for model/sessions verbs, retains window/AppDelegate-only verbs), (2) HeadlessHarness (in-process against throwable model, emits state dump).
- notable: Canvas verb plumbing (M2.S6): resolve "<doc>" as an open id first, else as a .canvas path opened through the store. Macro recording (TSK-1162): verbs recorded into in-flight macro if not macro-control verbs. Bool-returning, not exhaustive: residual window/AppDelegate verbs (resize, find, tool-window, …) return false so caller handles them. Headless harness simply ignores false (out of scope).
- carry: **KEEP** — exemplary separation of concerns; testing-pyramid enabler; clean extensibility for new verbs.

**Sources/ViewerUI/Automation/UIEventSynth.swift** (200 LOC, partial) — REAL-event click synthesis for `--script` harness. Events posted to `NSApp.postEvent` (same channel real input arrives on), traverse AppKit pipeline: hit-testing, responder chain, SwiftUI gestures, control tracking loops. No Accessibility TCC grant needed (unlike `CGEvent`). In-process delivery is deterministic.
- notable: Three target-resolution paths (registry → NSView walk → AX tree); frame assembly in WINDOW coordinates. `makeWindowKey` escalation (NSApp.activate → NSApp.setActivationPolicy(.regular) if needed, handles `.accessory` policy denial). Key synthesis: `UIKeySpec.KeyStroke` → `NSEvent.keyEvent` + `CGEvent.flags`, handling command/shift/control/option + base-glyph insertion logic (modifiers are commands, not text — they don't insert).
- carry: **KEEP** — real-event synthesis is more robust than direct `sendEvent` (responder chain, tracking loops work); escalation pattern for window-key is production-grade.

---

### Coordinators (4 files)

**Sources/ViewerUI/Coordinators/EditorCoordinator.swift** (200 LOC, partial) — Owns CM6 editor lifecycle: ⌘S/save, dirty tracking, close-prompt routing, external-edit conflict prompt, `editorGotoLine`, per-tab cursor+scroll persistence, pending-diagnostics fan-out, two editor-only prefs (indentation, saveEditorOnBlur).
- notable: Extracted from DocumentModel (Quality #2, 2026-05-25) so views observing DocumentModel stop re-rendering on every keystroke/cursor tick. Snippet tab-stop navigation (TSK-705): `activeSnippetSession` + Tab/Shift-Tab routing, `snippetTab()`/`snippetShiftTab()` advance/retreat through `$N` stops. One-shot prompts (dirty-close, external-edit, save-conflict) are overridable via test seams (`dirtyClosePromptOverride`, `externalEditPromptOverride`) for headless automation. Side-effect injection via closures (onPauseWatcher, onResumeWatcher, onReloadFromDisk registered by DocumentModel).
- carry: **KEEP** — narrow-observation pattern proven; snippet tab-stop walker is elegant; test seams enable automation without NSAlert spawning.

**Sources/ViewerUI/Coordinators/FindCoordinator.swift** (180 LOC, partial) — Owns three independent find-mode bags (rendered WKWebView, source NSTextView, editor CodeMirror). Nonce pattern: `nextRequest &+= 1` so re-requesting same query re-fires (commands, not values).
- notable: Rendered find: preserved find-text draft (restore on reopen), rendered-scroll forwarding (TSK-1271). Source find: case-sensitive + regex toggles, match-line minimap population. Editor find: CM6 bridge. PDF find (TSK-1140): fourth bag for PDFView selection (literal, no regex). Cmd-F semantics (TSK-739): second invocation closes the bar (toggleRenderedBar/toggleSourceBar/toggleEditorBar).
- carry: **KEEP** — three independent bags decouple view re-renders; nonce pattern for commands; preserved-draft pattern is user-friendly.

**Sources/ViewerUI/Coordinators/SourceViewChannel.swift** (65 LOC) — Narrow observation channel for high-frequency source-view state: scroll offset, caret/selection position, scroll-to-line request. These tick on EVERY scroll wheel + EVERY caret move.
- notable: PERF — the republish cascade (LESSONS.md): before this split, sourceScrollState + sourceSelection were @Published on DocumentModel; every view observing it re-bodied on every scroll/caret move (sidebar, TabBar, ModeBar, StatusBar, all children). Caret move cost: ~249× no-change baseline, driven entirely by sidebar re-body. Fix: hang state on dedicated ObservableObject whose objectWillChange is NOT forwarded into DocumentModel.objectWillChange. Only SourceModeView + StatusBar observe directly.
- carry: **KEEP** — exemplary narrow-observation pattern; quantified perf win (249×); REPUB-1 principles embedded.

**Sources/ViewerUI/Coordinators/TabCoordinator.swift** (180 LOC, partial) — Owns open-tab list, selection, six per-tab caches (CSV filter state, HEX bytes-per-row, language override, formatted-flag set, formatted-text cache, editor buffers). Extracted so TabBar + content tree don't pay for unrelated DocumentModel mutations.
- notable: Split-pane URL lives here (shares "what's on screen" lifecycle). RWC-2 / TD-09 (2026-05-30): formatted-text cache entry carries source modifiedTime + sourceLength (prior length-only key served stale output when byte length stayed identical: `{"a":1}` → `{"b":2}` reformats same length). Close hooks (addCloseHook) for external cleanup (EditorCoordinator drains cursor/scroll/diagnostics dicts on every close). Materialization tasks (lazy file reads, keyed by tab id, cancelled on close).
- carry: **KEEP** — single cleanup funnel (cleanupAfterClose) + hooks prevent divergence; RWC-2 fix is exemplary (modifiedTime invalidation).

---

### Sessions (3 files)

**Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift** (150 LOC, partial) — Phase-1 app-level coordinator: owns canonical SessionsCoordinator (value-level) + one SessionState (Phase 1 max one mounted at a time; Phase 2 will hold a dictionary). Phase-1 façade: every SessionState wraps the SAME singleton DocumentModel (openFolder swaps sessions, model ref never changes).
- notable: MultiWindowRegistry (TSK-265) tracks session→window ownership, enforces one-window-per-session lease. Primary window id allocated on bootstrap. autosave subscribers (REPUB-1 discipline) only touch persisted-field publishers (tabs, sidebar, zoom, wordWrap, themeOverride) — never DocumentModel.objectWillChange firehose. Equality-guarded snapshot persist: no write if content unchanged. Periodic safety-net flush (TSK-607): scroll-only drift reaches disk within one interval (scroll rides SourceViewChannel, never ticks tab/sidebar subscribers).
- carry: **KEEP** — façade pattern scales to Phase 2 (per-session model dict); REPUB-1 + equality gates exemplary; periodic flush handles scroll-drifts that event-driven autosave misses.

**Sources/ViewerUI/Sessions/SessionState.swift** (150 LOC, partial) — Phase-1 façade variant: wraps single DocumentModel, carries identity (id, rootURL, displayName), lifecycle hooks (mount/detach drive file-watcher pause/resume), serializes to SessionSnapshot (persisted by coordinator).
- notable: displayNameIsUserSet latch (TSK-1016): manual rename wins, never clobbered by root change. When false, makeSnapshot() auto-relabels to current root folder name. sessionType (SessionKind?) seeds per-kind default panel layout on creation (not a live override). REPUB-1 discipline: NOT forwarding model.objectWillChange into SessionState.objectWillChange (that exact anti-pattern was LESSONS.md's motivation). SessionState's own identity fields (@Published displayName, rootURL, lastActiveAt, isMounted) suffice for observers.
- carry: **KEEP** — minimal facade; display-name latch is elegant; REPUB-1 discipline explicitly documented.

**Sources/ViewerUI/Sessions/SessionTabBar.swift** (150 LOC, partial) — Top row of nested-tabs UI. One pill per session, mirrors TabBar visual style (30pt strip, 28pt pill, close-button hover-reveal, active-tab accent). Inline rename editor (TSK-1016). Trailing action buttons (Settings, Search Files, Command Palette, pinned at far right).
- notable: B1: two-line row (name + git/branch subline), rowHeight scales with zoom. Double-click empty strip = new session at ~ (browser idiom). Tab drag-and-drop to move file into target session (TSK-274). Context menu per session. Session context menu + new-session menu with kind pills (Project / Code Review / Agent / …).
- carry: **KEEP** — visual consistency with TabBar; nested tabs UX mirrors browser idioms; kind-seeding for panel layouts.

---

### Sidebar (2 files)

**Sources/ViewerUI/Sidebar/SidebarPanelProtocol.swift** (22 LOC) — Marker protocol for "this SwiftUI view IS a sidebar panel." Every panel declares its `kind: SidebarPanelKind`. Display name + SF Symbol icon sourced from kind so a single rename flows through all conformers.
- notable: Seam for future activity-bar UI to enumerate panels + look up metadata without an out-of-band registry. Protocol extension provides `displayName` + `systemImage` derived from `kind`.
- carry: **KEEP** — minimal, forward-looking seam; protocol-oriented design.

**Sources/ViewerUI/Sidebar/SidebarPanelConformances.swift** (64 LOC) — One-liner conformances for every sidebar section view (BookmarksSection, SearchAnywhereSection, GitPanelSection, …, LSPOutlineSection, LSPProblemsPanel, etc.). Centralized auditable seam so every panel-kind enum case appears here.
- notable: Access-level note: static var kind matches host type's access level (internal for file-local sections, public for exported LSP panels). Views themselves are NOT rewritten — they keep their own headers, expand/collapse state, scroll bodies.
- carry: **KEEP** — auditable conformance registry; no view rewrites; forward-looking seam for activity-bar.

---

### ClaudeMonitor (2 files)

**Sources/ViewerUI/ClaudeMonitor/ClaudeMonitorView.swift** (150 LOC, partial) — Standalone master-detail browser over read-only `~/.claude` index. PoC launched via `--claude-monitor` flag (own window, zero regression risk). Session list (title/path filter) + selected session's parsed (redacted) events.
- notable: No touches of ContentView/DocumentModel. Index scan + per-session parse run off-main (Task.detached), results published back on main actor. Redaction applied to every record BEFORE surfacing (signatures, HTTP headers, inline image blobs). Never reads `.credentials.json` or stats cache — only `projects/*/*.jsonl`, read-only. Content-search mode (full-text per-event snippets via host-tested ClaudeTranscriptSearch). Search-mode toggle (session-list filter vs content search).
- carry: **KEEP** — proof-of-concept decoupling; redaction-first discipline; no surface bloat.

**Sources/ViewerUI/ClaudeMonitor/AgentDiffInlineView.swift** (134 LOC) — Compact unified-diff renderer for agent (Claude Code) file-mutating tool calls (Edit/Write/MultiEdit). Colored rows (red removed, green added), hunk banner, per-file header.
- notable: Intentionally decoupled from DocumentModel/DiffView. Model produced by host-tested AgentDiffExtractor + RustDiffAdapter.parse. Rendering is plain SwiftUI Text rows — no WebView, no AppKit surface (no compositor-occlusion traps). Per-file +adds/-dels stat badge.
- carry: **KEEP** — pure SwiftUI rendering; testable model + View separation; lightweight.

---

### Canvas (2 files)

**Sources/ViewerUI/Canvas/CanvasSidePanels.swift** (146 LOC) — Layers tree + inspector panels (M3.S8). Tree reads controller's outline snapshot (one canonical-JSON parse per revision); every edit lowers through controller's op path. Registry-driven inspector for current selection.
- notable: Two-way selection sync between layers tree + canvas. Inspector prop rows driven by `propSpecs[node.kind]` (registry-driven allowed props). Prop editing via drafts dict + TextFields, commit on submit. Instance-badge for component nodes ("instance of #card").
- carry: **KEEP** — elegant registry-driven inspector; two-way selection binding; minimal.

**Sources/ViewerUI/Canvas/CanvasTabController.swift** (150 LOC, partial) — Tab↔engine binding (M3.S1). One controller per (tab id × canvas doc). Opens doc through store (UI + agent tools share one engine doc + revision stream). Selection is controller state (engine-adjacent, never persisted). Outline + kitComponents refreshed on every revision change.
- notable: Phase tracking (mounting → mounted → failed). Sequence counter for outbound messages. trackedRev = engine revision last observed (conflict recovery refreshes from rejection). Prop specs parsed once from vocabulary. UIDesign mode drives shell layout + default panel visibility.
- carry: **KEEP** — tight engine integration; phase tracking; vocabulary-driven registry.

---

### Perf (1 file)

**Sources/ViewerUI/Perf/NavSweep.swift** (72 LOC) — Scripted navigation-interaction sweep for VM profiling (TSK-603). Drives tab-switch, sidebar toggle, view-mode toggle against live DocumentModel, wrapping each in `PerfSignpost.interact` interval.
- notable: Intervals are trace ANCHORS, not measurements themselves (bound synchronous part; SwiftUI re-render shows up immediately after in Time Profiler). `interactionDelayNanos` spaces interactions (~6/s at default) so each render burst is separable. Run headless for behavior tests (0 delay). State-neutral restore (originally-selected tab re-selected at end).
- carry: **KEEP** — lightweight perf harness; runnable in tests; spacing heuristic.

---

### Highlight (1 file)

**Sources/ViewerUI/Highlight/HighlightCacheActor.swift** (150 LOC, partial) — Per-tab syntax-highlight cache (PERF #5, 2026-05-25). Prior single-tab `@Published highlightCache` on DocumentModel fired on every tokenize completion, re-bodying every observing view (TabBar, ModeBar, StatusBar, sidebar). New shape: one `@MainActor`-bound actor per tab, owns cache + in-flight set + LRU eviction.
- notable: `@Published var version: Int` is narrow notification channel. Only SourceModeView subtree (active tab) observes this actor. O(1) lookups stay main-actor; tokenize work runs on Task.detached, hops back to main actor to store. RWC-1 (2026-05-30): cache key now includes `modifiedTime` alongside `(url, length, language)` so same-byte reload invalidates (prior length-only key served stale spans on `{"a":1}` → `{"b":2}` rewrites).
- carry: **KEEP** — narrow-observation exemplar; per-tab scoping eliminates republish cascade; RWC-1 fix is essential.

---

## Module Summary

The ViewerUI subdirectories represent **exemplary separation of concerns** and **narrow-observation discipline** throughout:

1. **Observability**: Bounded publishers (FrameRateMonitor 0.5 s floor, MetricsView 1 Hz poll), polling (ObservabilityProjection) instead of republish, honest memory metrics + staleness signals.
2. **LSP**: Production-hardened hover state machine (explicit cleanup), language-gating (markdown fallback), honest empty-state messaging (LSPProblemsPanel "not analyzed").
3. **Review**: Capture (frozen blob SHAs, HunkContext) + staleness derivation (anchor evaluation), addTarget targeting (natural side-mapping), debounced persistence.
4. **Automation**: Adapter interfaces (AXUIElementNode), registry for SwiftUI targets (ClickTargetRegistry), free function verb dispatch (ScriptVerbDispatch) decoupled from AppDelegate, real-event synthesis (UIEventSynth).
5. **Coordinators**: REPUB-1 discipline (narrow observation: SourceViewChannel, FindCoordinator, EditorCoordinator isolated from DocumentModel republish), close-path consolidation (TabCoordinator.cleanupAfterClose + hooks), per-tab caches with staleness guards (RWC-2 modifiedTime, formatted-text entry).
6. **Sessions**: Phase-1 façade (single DocumentModel, session-swap via openFolder), autosave REPUB-1 (only persisted-field publishers), periodic safety-net flush (scroll-drifts).
7. **Sidebar**: Protocol-oriented panel enumeration (seam for activity-bar), centralized conformance registry.
8. **ClaudeMonitor**: Standalone proof-of-concept (own window, zero DocumentModel coupling), redaction-first discipline.
9. **Canvas**: Registry-driven inspector, engine-adjacent selection, vocabulary-driven prop specs.
10. **Perf**: Lightweight navigation-sweep harness, runnable headless.
11. **Highlight**: Per-tab actor, narrow `version` publisher, LRU eviction, RWC-1 modifiedTime invalidation.

---

## Patterns Worth Porting

### 1. Narrow-Observation Coordinators (FindCoordinator, EditorCoordinator, SourceViewChannel)
**File pointers**: Coordinators/*.swift
- Dedicated `ObservableObject` per concern, `objectWillChange` NOT forwarded to parent.
- Only views that read the state observe directly (SourceModeView + StatusBar, not sidebar).
- Perf win: caret move from ~249× baseline to normal (LESSONS.md pattern).
- **Why it works**: High-frequency mutations (keystrokes, scroll, caret moves) no longer trigger whole-tree re-renders. Single-threaded observation graph, not radiating cascades.

### 2. Bounded Publishers / Polling Instead of Republish (FrameRateMonitor, MetricsView, ObservabilityProjection)
**File pointers**: Observability/*.swift
- CADisplayLink ticks 60–120 Hz; metrics publish at most every 0.5 s (FrameRateMonitor #215 rule).
- ObservabilityProjection polls at 1 Hz, republishes only on change (version token + equality guards).
- Wraps lock-guarded aggregators from unrelated background threads (LSP, MCP, grammar dlopen).
- **Why it works**: Decouples hot-path emitters from UI re-eval; coalesces noise; prevents republish amplification.

### 3. Explicit Cleanup Discipline (LSPHoverToken.invalidate, TabCoordinator.cleanupAfterClose)
**File pointers**: LSP/LSPHoverAttachment.swift, Coordinators/TabCoordinator.swift
- Main-actor synchronous cleanup (tracking area, NotificationCenter observers, event monitors).
- `deinit` backstop as LAST RESORT (may never run).
- Close paths funnel through single cleanup hub + hooks for external state (EditorCoordinator cursor/scroll/diagnostics).
- **Why it works**: Prevents resource leaks (NSTrackingArea, observers, tasks); one place to audit; hooks scale without divergence.

### 4. Capture + Staleness Derivation (ReviewSession capture/recomputeAnchorStates)
**File pointers**: Review/ReviewSession.swift
- Frozen LineAnchor + HunkContext + blobSha at comment creation (§3.1).
- Staleness recomputed on reload + on demand against live blobs (§3.2).
- AnchorState enum (current / stale / unknown) drives badge presentation ("code changed since review").
- **Why it works**: Honest staleness signals never surprise users; capture-once + derive-on-demand pattern is auditable.

### 5. Protocol-Oriented Panel Enumeration (SidebarPanelProtocol)
**File pointers**: Sidebar/SidebarPanel*.swift
- Marker protocol with kind + display metadata (displayName, systemImage derived from kind).
- Conformances centralized in one file (auditable).
- Forward-looking seam for activity-bar UI without out-of-band registry.
- **Why it works**: Scales to N panels; single-source-of-truth for metadata; no view churn.

### 6. Registry-Driven Inspection (Canvas inspector propSpecs)
**File pointers**: Canvas/CanvasSidePanels.swift
- kind → [CanvasPropSpec] vocabulary-driven allowed props + hints.
- Inspector rows auto-generated from registry (TextField per prop, submit → controller.setProp).
- Instance badges ("instance of #card") derived from outline structure.
- **Why it works**: Inspector evolves with vocabulary; no per-property wiring; testable model/view separation.

### 7. Per-Tab Ownership Boundaries (HighlightCacheActor, CanvasTabController)
**File pointers**: Highlight/HighlightCacheActor.swift, Canvas/CanvasTabController.swift
- One actor/coordinator per (tab id × resource).
- Narrow `@Published version` token (only SourceModeView observes for highlights).
- LRU eviction per-tab (8-entry cap vs old 32-entry global).
- **Why it works**: Decouples tab state; eliminates republish cascade; scales horizontally.

### 8. RWC Staleness Guards (formatted-text cache modifiedTime, highlight-cache modifiedTime)
**File pointers**: Coordinators/TabCoordinator.swift, Highlight/HighlightCacheActor.swift
- Cache key includes `(url, length, modifiedTime, language)` NOT just `(url, length, language)`.
- Catch same-byte rewrites (e.g., `{"a":1}` → `{"b":2}` reformats to same byte count).
- mtime is O(1) to read, captured at load time, nanosecond-resolution on APFS.
- **Why it works**: Prevents stale output after reload; generalizable to any mutable cache.

### 9. Free-Function Verb Dispatch Decoupled from AppDelegate (ScriptVerbDispatch)
**File pointers**: Automation/ScriptVerbDispatch.swift
- Lifted `--script` dispatcher from AppDelegate, now callable against any (DocumentModel, SessionsAppCoordinator) pair.
- No NSApplication, no window, no process spawn; headless harness drives same verbs in-process.
- Residual window/AppDelegate-coupled verbs return false so caller handles them.
- **Why it works**: Enables headless testing of model state without UI spawning; clear seam for responsibility split.

### 10. Triple-Fallback Target Resolution (UIEventSynth, ClickTargetRegistry)
**File pointers**: Automation/UIEventSynth.swift, Automation/ClickTargetRegistry.swift
- Registry (SwiftUI controls publish frames via onGeometryChange) → NSView walk (hosted AppKit views) → AX tree (external clients).
- SwiftUI controls invisible to NSView walk; registry is the only in-process channel.
- Window coordinate conversion handles flipped/non-flipped roots.
- **Why it works**: Exhaustive fallback chain; respects SwiftUI's AX invisibility; handles all target types.

---

## Anti-Patterns / Regrets

### 1. ❌ Republish Forwarding (LESSONS.md REPUB-1)
**File pointers**: SourceViewChannel §why-this-exists (CounterExample)
- **The mistake**: `sourceScrollState` + `sourceSelection` as @Published on DocumentModel, every view observing it re-bodies on every scroll/caret move.
- **The cost**: ~249× baseline re-render cost for one caret move (sidebar re-body alone).
- **The fix**: Dedicated SourceViewChannel, observers only on views that read it.
- **Lesson**: NEVER forward child→parent objectWillChange. High-frequency state must be isolated.

### 2. ❌ Length-Only Cache Keys (RWC-1)
**File pointers**: Coordinators/TabCoordinator.swift, Highlight/HighlightCacheActor.swift (Prior behavior)
- **The mistake**: Cache key `(url, length, language)` — on same-byte rewrite (`{"a":1}` → `{"b":2}`), cache misses and returns stale formatted output / highlight runs.
- **The cost**: Silent corruption; user sees outdated pretty-print or wrong syntax highlighting.
- **The fix**: Include `modifiedTime` in key: `(url, length, modifiedTime, language)`.
- **Lesson**: Byte length is a necessary but NOT sufficient invalidation signal; capture mtime at load time.

### 3. ❌ ImageRenderer for Occlusion Testing (Compositor Occlusion + ImageRenderer False-Green Trap, TSK-488)
**File pointers**: Observability, LSP (None commit; documented in LESSONS.md)
- **The mistake**: Using `ImageRenderer` or `cacheDisplay` to "prove" a SwiftUI view is on-screen visible. It rasterizes SwiftUI's tree in isolation + draws a PLACEHOLDER for NSViewRepresentable (no opaque layer to occlude).
- **The cost**: False green. A view that's actually occluded by a compositor layer tests as perfectly visible in ImageRenderer.
- **The fix**: Pixel validation ONLY: spawn app + screencapture (PixelTestCase/T5). Use MDV_ENABLE_BROKEN_* negative control.
- **Lesson**: Never trust headless rasterization for compositor/composition bugs. Pixel is the authority.

### 4. ❌ Deinit-Only Cleanup (LSPHoverToken)
**File pointers**: LSP/LSPHoverAttachment.swift (TSK-963, prior)
- **The mistake**: Relying on `deinit` for AppKit cleanup (tracking area, NotificationCenter observers). `deinit` runs nonisolated; may never run (process exit, task starvation).
- **The cost**: Resource leaks (observers/monitors pile up).
- **The fix**: Explicit `invalidate()` on main actor, synchronous cleanup. `deinit` backstop ONLY for forgotten releases.
- **Lesson**: Deterministic cleanup in Swift requires explicit release. `deinit` is a net, not the plan.

### 5. ❌ Event-Driven Autosave Missing Scroll (SessionsAppCoordinator, TSK-607)
**File pointers**: Sessions/SessionsAppCoordinator.swift (Prior problem)
- **The mistake**: Subscribing to tab/sidebar/@Published mutations for autosave, but NOT scroll (lives on SourceViewChannel, high-frequency, REPUB-1 isolated). Scroll-only drift reaches disk only on app quit.
- **The cost**: Crash between scrolls loses scroll position.
- **The fix**: Periodic safety-net flush timer (every 30 s) runs same equality-guarded snapshot+compare.
- **Lesson**: Event-driven autosave is insufficient. Periodic heartbeat catches drifts that event graph misses.

### 6. ❌ Assumption of Window Readiness in Script Harness
**File pointers**: Automation/UIEventSynth.swift
- **The mistake**: Posting events to NSApp without ensuring window is `.isKeyWindow` first. Event routing is fragile when window isn't key.
- **The cost**: Silent no-ops; events don't reach the intended view.
- **The fix**: `makeWindowKey` with escalation (NSApp.activate → NSApp.setActivationPolicy(.regular) if `.accessory` policy denies key).
- **Lesson**: Window state must be explicitly verified + escalated. Event synthesis is not forgiving.

### 7. ❌ LSP Server Route Assumptions (LSPPool state)
**File pointers**: LSP/LSPDiagnosticsView.swift (Observability)
- **The mistake**: Assuming a server exists for every language. Source view never sends didOpen/didChange, so diagnostics are never computed (not "clean", but "unanalyzed").
- **The cost**: False "no problems detected" signal.
- **The fix**: Honest message: "Not analyzed. Open in Editor to see problems." (LSPProblemsPanel activeFileUnanalyzed()).
- **Lesson**: Never conflate "no data" with "clean data". Empty-state messaging must distinguish absence from result.

---

## Gotchas & Surprises

### 1. 🔶 SwiftUI Controls Invisible to NSView Walk
**File pointers**: Automation/ClickTargetRegistry.swift
- SwiftUI materializes AX elements ONLY for external AX clients. In-process accessibility tree is EMPTY.
- SwiftUI controls inside NSHostingView are NOT NSViews (no traversal path).
- **Result**: Registry is the ONLY in-process channel for SwiftUI target discovery. Triple-fallback (registry → NSView walk → AX tree) is NOT redundant; each path covers a different surface.

### 2. 🔶 CADisplayLink Nominal Cadence Is Per-Display
**File pointers**: Observability/FrameRateMonitor.swift
- ProMotion panels (120 Hz) are not judged against 60 Hz baseline.
- `fps < nominalFPS * 0.95` is the jank threshold.
- **Result**: Display detection + per-display jank thresholds are non-negotiable; a 60 Hz panel is not "slow at 60 FPS".

### 3. 🔶 Cursor Dwell Timer (300 ms) for LSP Hover, Not Mouse-Over
**File pointers**: LSP/LSPHoverAttachment.swift
- PoC used Option+mouse-move (modifier-key trigger). Production switched to cursor-paused dwell (300 ms no-move).
- **Result**: User expectation for dwell-based hover (standard across many apps) is met; Option+click entry point is gone.

### 4. 🔶 Per-Tab Lazy Materialization Can Race with Selection
**File pointers**: Coordinators/TabCoordinator.swift
- Lazy tabs are empty (`.empty` state) until selected. On select, a Task is enqueued to read the file.
- Fast tab-switches during materialization can leave a tab mid-load.
- **Result**: TabCoordinator.materializeTasks keyed by tab id; every close cancels in-flight reads. Selection must be guarded (compareAndSet on dispatchTabID/dispatchSnapshot).

### 5. 🔶 Persistent ReviewSession State Keyed by Comment ID
**File pointers**: Review/ReviewSession.swift
- anchorStates: [String: AnchorState] — one derived staleness per comment.
- Recomputed on reload + on demand, never persisted.
- **Result**: Staleness is live (blobs move, code changes); stale comments are honest-signaled without hidden assumptions.

### 6. 🔶 HighlightCacheActor Eviction Is Insertion-Order LRU, Not Access-Order
**File pointers**: Highlight/HighlightCacheActor.swift
- `order: [HighlightCacheKey]` tracks insertion order only (oldest-first for eviction).
- On-access promotion (LRU) is NOT implemented.
- **Result**: Cache is fast (no reordering on hit) but simple (insertion-order FIFO, not true LRU). Per-tab 8-entry cap mitigates; typical tab holds 1–2 entries.

### 7. 🔶 Canvas Outline Parse Is Synchronous, Runs Every Revision
**File pointers**: Canvas/CanvasTabController.swift
- `refreshOutline()` parses canonical JSON into outline + extracts kit-components list.
- Happens on every mutation (engine revision change).
- **Result**: Parsing must be fast (current JSON is small); future serialization format changes may need async.

### 8. 🔶 Marker Protocol Conformances Can Have Weaker Access Than Public Protocol
**File pointers**: Sidebar/SidebarPanelConformances.swift
- Protocol is public; conformances can be internal (file-local section views).
- Access-level is determined by conformance scope (module-wide), not witness visibility.
- **Result**: Public LSP panels (LSPOutlineSection) export public `static var kind`, internal FileRow exports internal (protocol witness visibility matches host type).

---

## Rebuild Notes

### For a Swift Native UI + Rust Core Rebuild:

#### 1. **Observation Discipline is Non-Negotiable**
- **Foundation**: Narrow-observation pattern (SourceViewChannel, FindCoordinator, EditorCoordinator isolated from parent objectWillChange).
- **Why**: High-frequency state (keystroke, scroll, caret) must NEVER trigger whole-tree re-renders. ~249× regression measured (LESSONS.md REPUB-1).
- **Action**: Enforce at architecture level — every high-frequency coordinator is a separate ObservableObject. Views observe ONLY what they read. Forbid parent←child republish forwarding in code review.

#### 2. **Bounded Publishers + Polling for Aggregators**
- **Foundation**: FrameRateMonitor (0.5 s floor), ObservabilityProjection (1 Hz poll), MetricsView.
- **Why**: Wraps lock-guarded aggregators from unrelated background threads. Emitter-side rate-limiting (buffer window, coalescing) prevents republish amplification better than observer-side debouncing.
- **Action**: When a hot-path emitter (LSP, grammar, MCP) writes to a @Published property, wrap in a bounded-publisher actor. Callers poll at fixed interval + republish on change only.

#### 3. **Explicit Cleanup Discipline**
- **Foundation**: LSPHoverToken.invalidate (synchronous), TabCoordinator.cleanupAfterClose (single hub), close hooks.
- **Why**: Deinit is unreliable; AppKit refs require main actor; one place to audit prevents divergence.
- **Action**: Every resource-holding type (NSTrackingArea, NotificationCenter observers, file handles) gets explicit `teardown()` / `invalidate()` on main actor. `deinit` backstop ONLY as last resort. Per-tab/per-resource cleanup funnels through coordinator close path.

#### 4. **Cache Staleness Multivariate (Modtime + Length + URL)**
- **Foundation**: RWC-2 (formatted-text), RWC-1 (highlight cache) — key includes modifiedTime alongside length + language.
- **Why**: Byte length is necessary but not sufficient (same-byte rewrites, test fixtures). Modtime is O(1), nanosecond-resolution on APFS, captured at load.
- **Action**: Every mutable cache must include mtime in key. Audit caches for same-byte reload holes. Unit tests should verify stale-detection on rewrites of identical byte-length.

#### 5. **Honest Empty-State Messaging**
- **Foundation**: LSPProblemsPanel "Not analyzed. Open in Editor to see problems." (vs false "no problems" when didOpen/didChange never happened).
- **Why**: Conflating "no data" with "clean result" surprises users and hides bugs.
- **Action**: Every empty view must distinguish (a) "no data received", (b) "data received, empty result", (c) "unsupported for this type". Message accordingly. Never claim confidence in an all-clear when the data-collection mechanism wasn't exercised.

#### 6. **Rebuild LSP Layer + Hover Production-First**
- **Foundation**: LSPHoverToken (explicit invalidate, nonisolated(unsafe) fields, deinit backstop), 300 ms dwell-timer (not Option-click), cursor-paused trigger.
- **Why**: Hover is the highest-traffic user interaction point. PoC compromises (modifier-key triggers) create UX surprises. Cleanup discipline is non-negotiable (tracking areas, observers leak if not released).
- **Action**: Wire LSPHoverToken + dwell-timer as template. Explicit Cmd-click → definition (same closure). Test setups validate cleanup idempotence. Pixel-test hover + Cmd-click on the VM (T5 PixelTestCase).

#### 7. **Narrow LSP for Review + Problems (Not Everything)**
- **Foundation**: LSPProblemsPanel, LSPNavigationPanel, LSPOutlineSection. NOT rendering LSP for every markdown file (markdown outlines via fallback).
- **Why**: Language-gating removes dead panels. Markdown has no LSP server but HAS tested outline extractor (heading tree) — fallback serves it through same panel.
- **Action**: Keep language-registry + fallback pattern. Render LSP features ONLY where servers are registered. Markdown outline is a first-class fallback, not second-class.

#### 8. **Canvas Engine as Standalone (Model + View Separation)**
- **Foundation**: CanvasTabController (engine integration point, selection, outline, phase tracking) + CanvasSidePanels (layers tree + inspector driven by registry).
- **Why**: Model/view split testable without WebView. Registry-driven inspector (propSpecs) evolves with vocabulary.
- **Action**: Canvas engine is NOT built into DocumentModel; it's a pluggable tab-type (like rendered markdown). CanvasTabController is the adapter. Vocabulary-driven registry for inspectable properties. Outline parse is synchronous (keep JSON small).

#### 9. **Review as Isolated Session + Capture + Staleness**
- **Foundation**: ReviewSession (frozen capture at comment creation: LineAnchor + HunkContext + blobSha), recomputeAnchorStates (per-comment staleness vs live blobs).
- **Why**: Comments are historically anchored; code moves. Frozen capture makes the reference unambiguous. Staleness re-derived on-demand (not serialized) so it's always fresh.
- **Action**: Review domain model in ViewerCore. UI in ViewerUI (ReviewSession, ReviewTabView, CommentCards). Anchor evaluation is pure (testable). Staleness badge ("code changed") is user-honest.

#### 10. **Automation as Free Function + Verb Dispatch**
- **Foundation**: ScriptVerbDispatch (free function, callable against any (DocumentModel, SessionsAppCoordinator)), UIEventSynth (real-event synthesis posted to NSApp), ClickTargetRegistry (SwiftUI targets).
- **Why**: Headless harness drives same verbs as VM script harness — no process spawn, no NSApplication. Tests run in-process (faster, cheaper, CI-friendly).
- **Action**: Verb dispatch is NOT AppDelegate method. Free function, pure logic for model/sessions verbs; residual window/app verbs return false. UIEventSynth is test-wired through ClickTargetRegistry (SwiftUI) + NSView walk (AppKit) + AX tree (external). Triple-fallback ensures every target type is reachable.

#### 11. **Sidebar Panels via Protocol, Enumeration via Kind**
- **Foundation**: SidebarPanelProtocol + centralized SidebarPanelConformances. Future activity-bar UI reads `SidebarPanelKind` enum + looks up metadata.
- **Why**: Scales to N panels without out-of-band registry. Audit conformances in one file. Display name/icon from kind (single source of truth).
- **Action**: SidebarPanelProtocol + kind property on every panel. No per-panel wiring in activity-bar UI; enumerate panels dynamically by kind.

#### 12. **Session Façade Strategy (Phase 1 → Phase 2)**
- **Foundation**: SessionsAppCoordinator (Phase 1: wraps singleton DocumentModel, session-swap via openFolder) → Phase 2 (per-session model dict).
- **Why**: Gradual migration. Phase 1 proves the coordinator pattern (autosave, window registry, lifecycle hooks) without multi-model overhead. Phase 2 is isolated refactor.
- **Action**: PHASE 1: Single DocumentModel, session-swap on folder open (model.openFolder + coordinator mount/detach). No UI churn (ref never changes). PHASE 2: Extract FindModel, GitPanelModel, etc. onto SessionState. Per-session model dict on coordinator. Same lifecycle/autosave patterns, just N instead of 1.

#### 13. **Autosave: Event-Driven + Periodic Heartbeat**
- **Foundation**: SessionsAppCoordinator (subscribe to tab/sidebar/@Published + 30 s periodic flush), equality-guard snapshot persist.
- **Why**: Event-driven catches most changes (tab switch, sidebar toggle). Periodic flush catches scroll-only drift (lives on SourceViewChannel, not subscribed).
- **Action**: Autosave subscribers only touch persisted-field publishers (NOT DocumentModel.objectWillChange firehose). One equality-guarded snapshot write per fire. Periodic timer every 30 s with same equality guards (no-op if no change).

#### 14. **Per-Tab Ownership Boundary (Highlight, Canvas)**
- **Foundation**: HighlightCacheActor (one per tab, 8-entry LRU, version publisher), CanvasTabController (one per tab, engine adapter).
- **Why**: Eliminates global state sharing. Republish cascades (every tab's highlight affects every view). Per-tab 8-entry cache + narrow version token scales horizontally.
- **Action**: Always scope caches/coordinators to (tab id × resource). Publish narrow version/done tokens, NOT full state. TabCoordinator.addCloseHook for cleanup on close.

#### 15. **Render/UI Tests on VM (Not Host)**
- **Foundation**: LESSONS.md "OWNER DIRECTIVE (2026-06-06): NO UI tests on Mac — run UI / live-tier tests on UTM VM only."
- **Why**: Host can't spawn windows; ImageRenderer is false-green for occlusion; pixel validation requires WindowServer (screencapture).
- **Action**: T4 LiveAppTestCase / T5 PixelTestCase run on VM only. Host gate (test-headless-gate.sh) runs T1/T1m/T2 headless tiers only. VM validation is separate (scripts/test-in-vm.sh, nightly lane). Negative control tests (MDV_ENABLE_BROKEN_*) prove guard teeth.

---

## Summary

This slice of ViewerUI represents **production-mature, systematically proven patterns**:

- **Narrow observation**: Isolated coordinators, no parent←child republish.
- **Hot-path safeguards**: Bounded publishers, polling, equality guards.
- **Resource discipline**: Explicit cleanup, single close path, hooks for external state.
- **Cache staleness**: Multivariate keys (url, length, mtime, language).
- **Honest UI**: No empty-state conflation, staleness badges, unsupported signals.
- **Testability**: Free functions, seams (test overrides), headless harness integration.
- **Modularity**: Protocol-oriented (SidebarPanelProtocol), registry-driven (Canvas inspector), decoupled adapters (CanvasTabController, LSPHoverToken).
- **Future-proof**: Phase-1 façade (session swap), activity-bar seam (SidebarPanelKind), per-tab ownership (scales to nested sessions).

All patterns have been battle-tested at scale (8+ weeks of development, real user feedback, measured perf wins) and are ready to be ported directly into a greenfield rebuild.
