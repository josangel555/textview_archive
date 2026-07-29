# ViewerUI Root Files Analysis — Slice 1/4 (Alphabetically)

## File Inventory

### Small Foundation Views & Controllers

**Sources/ViewerUI/ActionHistoryView.swift** (130 LOC) — Read-only history list (TSK-703). Renders an ActionHistory log with category icons, labels, coalesced-count badges, and timestamps. 
- notable: Pure presentation model (`ActionHistoryRowModel`) separated from SwiftUI shell; host-tested formatting logic; undo/redo driven externally; minimal view state.
- carry: KEEP — excellent pattern of extracting presentation logic into testable models; accessibility IDs included; immaculate separation of concerns.

**Sources/ViewerUI/AnnotationsView.swift** (50 LOC) — Navigable list of TODO/FIXME/HACK/XXX/NOTE/BUG markers (from `SourceAnnotationScanner`). 
- notable: Minimal view shell; scan + jump model are host-tested; render/UI tail is VM-validated.
- carry: KEEP — thin, focused view with model logic entirely separated.

**Sources/ViewerUI/AppMenuActions.swift** (30 LOC) — Compile-checked Objective-C selector protocol for app-level menu/toolbar actions (`openDocument`, `openFolder`, `showSettings`).
- notable: Solves stringly-typed selector failures at build time via `#selector` verification; appends protocol conformance to AppDelegate for end-to-end checking.
- carry: KEEP — elegant compile-time safety pattern; eliminates silent selector-resolution failures.

**Sources/ViewerUI/AppResourceBundle+ViewerUI.swift** (11 LOC) — Resource bundle resolver for ViewerUI's assets (CodeMirror, mermaid, markdown.css), with fallback to `Bundle.module` under test.
- notable: Packaged app first, then `swift test` fallback via `ViewerCore.resolveResourceBundle`.
- carry: KEEP — simple, clear abstraction for test/prod bundle paths.

**Sources/ViewerUI/BodyProbe.swift** (40 LOC, DEBUG-only) — Body-evaluation counter for measuring re-evaluation widths (TSK-615). Records how many times each instrumented view's `body` runs per interaction.
- notable: O(1), allocation-free on happy path; disabled by default; commit-pinned bounds via `ChromeBodyEvalCountTests`; detect body-eval regressions early (view re-bodying on republish it used to skip).
- carry: KEEP — clever instrumentation pattern; extremely cheap; catches width-regressions the host gate would miss.

**Sources/ViewerUI/ChromeTheme.swift** (48 LOC) — Theme engine for chrome surfaces (textBackground, windowBackground, sidebarPanelBackground). Pre-resolves SwiftUI Colors once per theme change, avoiding per-call allocations.
- notable: Computed once at theme-change time; `Palette` accessors hand out pre-resolved `Color`s; degrades malformed theme slots to fallbacks, never crashes; semantic colors stay system-native.
- carry: KEEP — excellent perf-aware design; zero-allocation contract for per-cell builders.

**Sources/ViewerUI/CMOneShotRouting.swift** (90 LOC) — Routing + exactly-once guard for one-shot editor requests (TSK-1483; fixes fan-out bug where snippets/gotos fired on all mounted panes instead of target).
- notable: Pure routing logic (`paneMayApply`) vs. shared ledger (`CMOneShotLedger`); 512-entry bounded FIFO; kills stale-replay on warm-cache re-attach; both host-testable.
- carry: KEEP — excellent decomposition of routing decision (pure) from state guard (shared); pattern is reusable for other one-shot request classes.

### Medium Views — Single Responsibility Components

**Sources/ViewerUI/ContentView.swift** (2090 LOC, slice-1: 250 LOC shown) — Root composition view. Orchestrates tabs, sidebar, shoulder-rails, content/editor panes, terminal, and panel docking. Manages multiple coordinators (sidebar, find, panelLayout, terminalPane, tabCoordinator, sessions).
- notable: Multiple narrow `@ObservedObject` direct observations (sidebar, find, panelLayout, terminalPane, tabCoordinator) to avoid republish storms documented extensively in comments. Layout-priority + compositor-awareness (z-index rules, frame constraints) throughout. Walkthrough controller seeded as `StateObject` wrapping model singleton to guarantee correct lifecycle. **PERF #1 notes** explain why direct observation of these secondary coordinators is load-bearing.
- gotcha: `StateObject(wrappedValue: model.walkthroughController)` traps: if not seeded from model's existing singleton, the delegate captures a phantom instance and the strip's `if walkthrough.isActive` gate never re-renders.
- carry: KEEP — master pattern of observation discipline and multi-coordinator orchestration; comments are exceptionally clear about WHY each observation is necessary (the perf reasoning is non-obvious).

**Sources/ViewerUI/ConflictResolutionModel.swift** (57 LOC) — View model for 3-way merge (TSK-1171). Holds merge result, tracks per-conflict user choices, derives resolved text.
- notable: Pure logic; host-testable; choice bookkeeping independent of SwiftUI rendering; renders resolved text only when all conflicts resolved.
- carry: KEEP — textbook pure model/view separation.

**Sources/ViewerUI/ConflictResolutionView.swift** (135 LOC) — 3-pane conflict-resolution UI (base/ours/theirs picker).
- notable: Render shell over host-tested `ConflictResolutionModel`; model choice logic, render validation VM-only.
- carry: KEEP — clean thin view wrapper over pure model.

**Sources/ViewerUI/DiskConflictBanner.swift** (54 LOC) — Banner for disk-on-disk conflicts (file changed on disk while unsaved edits exist). Three intents: Keep Mine / Take Disk / Merge.
- notable: **Load-bearing `compositingGroup().zIndex(1)`**: opaque NSViewRepresentable (CM6 editor) composites over earlier-painted SwiftUI siblings, so banner needs its own layer + z-order everywhere it shares a container with the editor (TSK-960, LESSONS.md compositor-occlusion rule).
- carry: KEEP — critical compositor pattern documented and applied correctly.

**Sources/ViewerUI/ConvertImageView.swift** (78 LOC) — Image format/quality conversion dialog (TSK-1325). Format picker + quality slider (lossy only) + Convert/Cancel.
- notable: Async off-main conversion via ViewModel; error display; keyboard shortcuts for default/cancel actions.
- carry: KEEP — clean modal pattern; reusable template for other conversions.

**Sources/ViewerUI/ConvertImageViewModel.swift** (65 LOC) — Image conversion controller. Async host-tested `Exporter.convert` off main thread, temp file output.
- notable: Quality slider only for lossy formats; error descriptions per `ImageEditError` case; detached Task for CPU-bound work; temp file cleanup caller's responsibility.
- carry: KEEP — solid async off-main pattern; clean error mapping.

### Audio Feature Suite (5 files)

**Sources/ViewerUI/AudioConvertView.swift** (78 LOC) — Audio format conversion dialog (format + bit-rate pickers). Mirrors image-convert structure.
- notable: Format picker; bit-rate only for lossy formats; error display; disabled action when converting.
- carry: KEEP — consistent with image-convert; reusable modal template.

**Sources/ViewerUI/AudioConvertViewModel.swift** (66 LOC) — Audio transcoding model. Async ffmpeg wrapper with format/bitrate selection.
- notable: Bit-rate only for lossy; ffmpegOverride fallback (TSK-535 settings); detached Task for transcoding; error descriptions.
- carry: KEEP — solid async transcoding pattern.

**Sources/ViewerUI/AudioEditorView.swift** (394 LOC) — Waveform editor (TSK-534). Header + waveform pane + optional spectrum panel + edit bar + transport.
- notable: `StateObject<AudioEditorViewModel>`; waveform rendering via `WaveformView`; playhead tracking; trim + fade UI; spectrum on-demand; asyncload task gated on `url`.
- carry: KEEP — well-organized complex feature view; good task orchestration.

**Sources/ViewerUI/AudioEditorViewModel.swift** (293 LOC) — Audio editor state (TSK-534). Playback + trim/fade + spectrum computation + waveform display.
- notable: `@Published` properties for zoom, scroll, amplitude scale, trim/fade; `displayPeaks` memoization; playback via `AVAudioPlayer`; spectrum computed on playhead move when panel shown; source buffer is edits' non-destructive base.
- carry: KEEP — solid playback + editing model; good memoization discipline.

**Sources/ViewerUI/AudioExportAccessory.swift** (169 LOC) — NSSavePanel accessory for audio export format/quality. Built in `buildUI()` manually.
- notable: Format menu disabled for MP3 when ffmpeg unavailable (TSK-535 guidance); quality popup syncs to format; manual AppKit UI construction (not SwiftUI).
- carry: KEEP — pragmatic AppKit integration; good UX for unavailable formats.

**Sources/ViewerUI/AudioPlaybackController.swift** (43 LOC) — App-level audio playback (TSK-1308). Persistent `AVPlayer` survives view/session-switch teardown.
- notable: Singleton shared instance; reuses player for same URL (no playback yank on re-mount); pauses old stream on new URL request; player retained by controller so it outlives requesting view.
- carry: KEEP — elegant solution to cross-session playback; reuse-vs-replace model is clean.

### Sidebar Panels & Sections (2 files)

**Sources/ViewerUI/BookmarksSection.swift** (375 LOC) — Collapsible sidebar bookmarks panel with filtering + sort (F/D/L toggles, recent/name/created sort, root-scope filter).
- notable: Filter chips mutable state; sort menu with "Remove Missing Bookmarks" bulk action (TSK-1464, undoable); height managed by parent via `@Environment(\.sidebarSectionBodyHeight)`; warning banner on open-failure (TOCTOU symlink swap, TSK-309); empty-state copy pinned via tests.
- carry: KEEP — excellent sidebar-section design with filtering UX; pinned empty copy is a useful pattern.

**Sources/ViewerUI/ClaudeTimelineSection.swift** (320 LOC) — Sidebar Claude activity timeline. Renders transcripts + optional monitor-log hook events (collapsed by default, persisted).
- notable: Two subsections (transcripts + hooks); reads live transcript files via `FileManager`; refresh on sidebar root URL change; hidden entirely when no activity (unlike sections with forced-show placeholders).
- carry: KEEP — good conditional-render pattern; ties UI visibility to real content availability.

### Specialized Panels & Tools (large)

**Sources/ViewerUI/BottomAttributesBar.swift** (290 LOC) — Bottom chrome for text attributes (wrap, special chars, JS toggle, preview metadata toggle).
- notable: Wrap + special-chars toggles visible for all text modes; HTML JS toggle **per-tab + default-deny** (SECURITY note), visible only for `.html` in rendered; preview metadata panel toggle (TSK-608); all toggles button-style mini with help text.
- carry: KEEP — clear security stance (default-deny JS); good per-tab scoping pattern; help text valuable.

**Sources/ViewerUI/CanvasWebViewHost.swift** (226 LOC) — Canvas WebView container (M0 Canvas epic). Loads bundled canvas.html, manages JS message routing, includes **negative control** for T5 visibility test (TSK-1134 pattern: `MDV_ENABLE_BROKEN_CANVAS_OVERLAY` env gate).
- notable: `WKWebView` in configuration-based setup; `MDVNegativeControl.isBroken("CANVAS_OVERLAY")` injects deliberate break at document-start for pixel-test teeth-proving; ready-recovery timeout; `evaluateJavaScript` error tracking for diagnosis.
- carry: KEEP — negative-control pattern should propagate to all hide-by-default UI components (proves guard actually works).

**Sources/ViewerUI/CodeActionPicker.swift** (100 LOC) — LSP code-actions picker (TSK-819). Presents applicable/preferred actions with wrench/star glyphs, disabled when no edits applicable.
- notable: Loading state; preferred actions starred; inapplicable actions tertiary (disabled click); fixed width 460; keyboard shortcuts for cancel/action.
- carry: KEEP — clean code-actions UX.

**Sources/ViewerUI/ContentToolbar.swift** (342 LOC) — Content toolbar directly above editor (UX-A #224). Left: navigable breadcrumb; Right: view-mode (Render/Editor/HEX) + View Only + Format buttons.
- notable: Breadcrumb click reveals folder/file in sidebar; view-mode control routes through unchanged `setCurrentViewMode`; **observation discipline**: observes only `DocumentModel`, not per-scroll state (those ride `SourceViewChannel` / `TabCoordinator` with narrower observation in StatusBar/source subtree); BodyProbe instrumentation.
- carry: KEEP — excellent observation discipline documented; clean routing through existing mode-setting.

**Sources/ViewerUI/CrossSearchPanel.swift** (628 LOC) — Cross-file search + replace. Query/case/regex/filename-mode toggles, results list, replace preview + status.
- notable: Pure search + replace logic host-tested; UI shell renders results, routes clicks; regex error display; replace preview (before applying); progress tracking; scope presets (current file / project / selection).
- carry: KEEP — large but well-organized feature panel.

**Sources/ViewerUI/CSVTableView.swift** (1141 LOC) — CSV table editor/viewer. Parsed into rows/cells, in-cell editing, sort-by-column, row add/delete.
- notable: Render-as-table uses `LazyVGrid`; large file path through streaming parse; in-cell TextField editing; column-header click to sort; PERFORMANCE: virtualized render (LazyVStack + LazyVGrid to avoid rendering all cells).
- carry: KEEP — solid large-table virtualization; good column-sort UX.

**Sources/ViewerUI/DependencyGraphView.swift** (244 LOC) — Project dependency-graph visualization (TSK-280). File→file import edges or Package.swift deps. Canvas render of laid-out graph; pan/zoom via `DependencyGraphInteraction.Transform`.
- notable: Graph extraction + layout pure logic (ViewerCore, host-tested); render-only design via `Canvas`; node count cap (cap exceedance → placeholder); host-testable pan/zoom math; visual/interaction validation VM-only (can't validate pixels on host).
- carry: KEEP — good render-only design; pure layout math separated from view.

**Sources/ViewerUI/DiagnosticWindowView.swift** (301 LOC, DEBUG-only) — Diagnostic snapshot window (PRIORITIZED_PLAN #17). Document/tab state, temp files, open FDs, subprocesses (LSP).
- notable: Behind `DiagnosticGate.isEnabled` (DEBUG or `MDV_ENABLE_DIAGNOSTICS=1`); **never observes model** (captures snapshot on explicit Refresh or appear, preventing republish amplification); **never MCP-exported, never auto-persisted** (content/path exfil surface; export only via button with path redaction option); sections: State / Temp Files / Open FDs / Processes.
- carry: KEEP — excellent diagnostic-tool guardrails; the "never observe model" pattern could apply to other debug views.

**Sources/ViewerUI/DockedToolWindow.swift** (638 LOC) — Dockable tool window container (UX-E #227, bottom-docked panels). Resize handle, header bar, draggable content.
- notable: Resizable bottom band; fixed-height semantics; drag to move/undock; header with close button; coordinates with shoulder-rail docking zones.
- carry: KEEP — solid panel-docking implementation.

**Sources/ViewerUI/DiagnosticDump.swift** (415 LOC) — Diagnostic data formatter/renderer. Snapshot → structured display (state, files, FDs, processes).
- notable: Pure formatter (no state mutation); renders diagnostic categories as collapsible sections; path redaction on export.
- carry: KEEP — clean separation of snapshot (model) from display (view).

### DocumentModel & Extensions (12 files, covering ~4200 LOC)

**Sources/ViewerUI/DocumentModel.swift** (3586 LOC) — Root app-state coordinator. Massive "god object" pattern: tabs, editor state, find, sidebar, panels, theme, markdown rendering, autosave, LSP, git, audio, settings synchronization.
- notable: **60+ @Published properties** covering: window title, mounted panes, recents, bookmarks, UI toggles (wrap, invisible chars, vim mode, view-only), preview metadata, script console, search/replace, code actions, terminal command palette, audio conversion, image conversion, conflict resolution, disk conflict, terminal pane, theme, settings (font, zoom, indent guides), LSP rename prompt, cross-search state, git panel state, fold dispatch, PDF export, HTML JS opt-in per tab.
- gotcha: This is the **anti-pattern** of a greenfield rebuild — a single 3600+ line file holding all app state. Every feature adds another `@Published var` here. The alternating DocumentModel+Extensions files attempt to organize this but the sheer scope remains problematic.
- carry: REDO — this is the #1 architectural lesson: NEVER centralize all state in a god object, even incrementally. The rebuild should partition state by feature/domain from day one (separate coordinators for tab/editor, sidebar, panels, theme, find, LSP, git, audio, settings, etc.). Each coordinator owns its narrow @Published set and composition happens at the top level (like how find/sidebar/panelLayout are already separate). The current structure degrades maintainability, makes onboarding difficult, and couples unrelated features.

**DocumentModel+ActiveDocActions.swift** (166 LOC) — File-level actions (open, close, reload, save, revert, reveal, delete, move, duplicate, create folder).

**DocumentModel+ActiveFileDataConvert.swift** (78 LOC) — Data format conversion (hex ↔ base64, binary decode).

**DocumentModel+ActiveFileFormatConvert.swift** (99 LOC) — File format conversion (Markdown → HTML, etc.).

**DocumentModel+ActiveFileLSP.swift** (62 LOC) — LSP actions (go-to, hover, completion).

**DocumentModel+ActiveFileMarkdownExport.swift** (112 LOC) — Markdown export options (HTML, PDF, etc.).

**DocumentModel+ActiveFileMarkdownTransform.swift** (40 LOC) — Markdown text transforms (prettify, normalize).

**DocumentModel+ActiveFileTextTransforms.swift** (72 LOC) — Text transforms (sort lines, dedent, etc.).

**DocumentModel+AudioConvert.swift** (39 LOC) — Audio conversion coordination.

**DocumentModel+Bookmarks.swift** (183 LOC) — Bookmark add/remove/list/prune with warning handling.

**DocumentModel+Breadcrumb.swift** (84 LOC) — File path breadcrumb for toolbar.

**DocumentModel+CM6Completion.swift** (107 LOC) — CodeMirror completion request routing.

**DocumentModel+CM6Hover.swift** (61 LOC) — CodeMirror hover info request routing.

**DocumentModel+CommandRegistry.swift** (76 LOC) — Command palette registry (keyboard shortcuts, menu items).

**DocumentModel+ConvertImage.swift** (29 LOC) — Image conversion coordination.

**DocumentModel+CrossSearch.swift** (267 LOC) — Cross-file search + replace orchestration (regex compile, scope resolution, replace preview, batch apply).

**DocumentModel+Diagnostics.swift** (128 LOC) — Diagnostic snapshot builder (state dump, temp files, FDs, subprocesses).

**DocumentModel+DiskConflict.swift** (48 LOC) — Disk-on-disk conflict handling (keep/take/merge intents).

**DocumentModel+DisplayText.swift** (85 LOC) — Active file's display text projection (rendered/source/hex views read this).

- carry for DocumentModel suite: **REDO** — extensions are a code-organization bandage over the god-object problem. The rebuild needs separate coordinators from the start. That said, the **extension pattern itself is reasonable** as an interim taming tool; each extension groups related actions by domain (AudioConvert, Bookmarks, CrossSearch, etc.). The real fix is to extract each extension into its own @Observable coordinator object and compose at the top level.

### Document Model Extensions (continued, slice 1 ends here)

Slice 1/4 contains all of DocumentModel + 15 of its extensions, representing the architectural "god object" anti-pattern that dominates the codebase. The remaining extensions (DisplayText, DiskConflict, etc. through LSP, Markdown, Terminal, Walkthrough) continue this pattern through slice 2.

---

## Module Summary

**Slice 1/4 of ViewerUI root** is a mixed landscape:

1. **Excellent foundational patterns** (ActionHistoryView, AnnotationsView, AppMenuActions, ChromeTheme, CMOneShotRouting, BodyProbe): small, focused, immaculate separation of model and view logic. These exemplify the rebuild's target architecture.

2. **Solid mid-sized feature views** (audio suite, image conversion, bookmarks, side panels, dependency graph, diagnostic tools): well-scoped, with clear ViewModel patterns and good async orchestration. Each feature adds one ViewModel + one or two Views, which is the right grain.

3. **ContentView orchestration**: a 2090-LOC master composition that handles multiple narrow-observing coordinators, layout constraints, and compositor rules. The observation discipline is load-bearing and exceptionally well-documented (future-proofing against the "just add another `@ObservedObject`" trap).

4. **DocumentModel god object**: 3586 LOC + 15 extensions (12 shown, more in later slices) = a feature-accumulation pattern that is the anti-pattern of the rebuild. Every new feature (audio, image, cross-search, diagnostics, theme, etc.) adds another 30–200 line extension + another `@Published` var to the root model. The "extensions organize by domain" structure is a useful interim, but it does not solve the fundamental problem: centralized state + tight coupling.

**Net assessment**: Slice 1/4 is 50% "patterns to keep" and 50% "architectural problem to redesign." The patterns themselves are sound; the structure is not.

---

## Patterns Worth Porting

1. **Pure presentation models** (ActionHistoryRowModel, ConflictResolutionModel, etc.) — extract display logic into testable Swift structs with no SwiftUI dependencies. The view becomes a thin shell. **Cost**: one extra file per feature. **Payoff**: 80%+ host test coverage before UI tests.
   - Pointer: ActionHistoryView + ActionHistoryRowModel (ActionHistoryView.swift:95–130).

2. **Negative-control test pattern (TSK-1134)** — deliberate breaks behind `MDVNegativeControl.isBroken("<NAME>")` env gates prove that guards actually work. Committed code; proves test-coverage teeth.
   - Pointer: CanvasWebViewHost.swift:19–26 (MDV_ENABLE_BROKEN_CANVAS_OVERLAY).

3. **Narrow observation discipline** (ContentView + secondary coordinators) — observe only the narrowest @Published set needed, not the whole model. Avoids republish storms when unrelated state changes. Document WHY.
   - Pointer: ContentView.swift:1–50 (sidebar, find, panelLayout, terminalPane, tabCoordinator all separate observations; the comments are load-bearing).

4. **ViewModel off-main async pattern** (AudioEditorViewModel, ConvertImageViewModel) — @MainActor-decorated model, Task.detached for CPU/IO, defer-based cleanup, error mapping per domain.
   - Pointer: ConvertImageViewModel.swift:32–54 (convert method).

5. **Compositor safety rules applied consistently** (DiskConflictBanner) — opaque NSViewRepresentable occluding SwiftUI siblings? Add `.compositingGroup().zIndex(1)` to the SwiftUI layer + pin z-index in EVERY layout branch. Document the rule.
   - Pointer: DiskConflictBanner.swift:46–52.

6. **Sidebar section template** (BookmarksSection) — collapsible header with filter chips, sort menu, empty-state placeholder, height management via `@Environment`. Reusable scaffold for other sidebar panels.
   - Pointer: BookmarksSection.swift (entire file).

7. **Diagnostic/debug view guardrails** (DiagnosticWindowView) — never observe model (capture snapshot instead); never MCP-export; never auto-persist; require explicit user action (Export) to leave the process. Good security/stability pattern for any debug surface.
   - Pointer: DiagnosticWindowView.swift:1–45 (comments outlining gating + guardrails).

8. **Feature-modal template** (ConvertImageView + ConvertImageViewModel, AudioConvertView + AudioConvertViewModel) — format picker + quality/options slider + action button. Reusable structure for tool dialogs.
   - Pointer: ConvertImageView.swift, ConvertImageViewModel.swift.

---

## Anti-Patterns / Regrets

1. **DocumentModel god object** — single 3586 LOC file + 15 extension files (total ~4500 LOC) holding every app-state variable. Every feature lands another extension + another `@Published var` at the root. This is **the #1 architectural problem** to avoid in the rebuild.
   - Why it happens: incremental feature work; easy to add a var here; late coordination costs deferred.
   - Solution for rebuild: partition state by domain from day one (TabCoordinator, SidebarModel, PanelLayoutStore, TerminalPaneStore, ThemeStore, etc.); ContentView composes these narrowly via separate `@ObservedObject` declarations; no "one model to bind them all."
   - Cost: upfront design; more files; initial composition complexity (paid back in day 2).
   - Pointer: DocumentModel.swift:1–100 (just the @Published declarations show the scope).

2. **Undifferentiated observation of secondary coordinators** — DocumentModel used to (pre-refactor) forward `tabCoordinator.objectWillChange` + `sidebar.objectWillChange` + etc. into its own `objectWillChange`, causing republish storms. Partially fixed (sidebar, find, panelLayout, terminalPane, tabCoordinator are now separate observations in ContentView), but the root model is still a collection point.
   - Lesson: partition state from the start so there's no temptation to "just forward the whole coordinator's changes."
   - Pointer: ContentView.swift comments (PERF #1 notes).

3. **Monolithic extension files** — DocumentModel+DisplayText, DocumentModel+CrossSearch, etc. are better than nothing, but still create the illusion of organization around a fundamentally coupled structure. Each extension still touches the same god object.
   - Better: extract each extension into its own @Observable coordinator, composed in ContentView.
   - Pointer: All DocumentModel+*.swift files.

4. **Late introduction of narrow observation** — TabCoordinator, SidebarModel, etc. split out to separate coordinators to fix republish bugs, but it happened *after* the god-object pattern was established. The rebuild should start here.
   - Lesson: coordinate-from-the-start architecture design.

5. **Canvas/WebView hosting complexity** — CanvasWebViewHost manages JS routing, negative-control injection, ready-state recovery, all in a 226-LOC class. This is the price of WebView/JS bridging and is unavoidable, but worth budgeting up front in the rebuild.
   - Pointer: CanvasWebViewHost.swift.

---

## Gotchas & Surprises

1. **Walkthrough controller lifecycle trap** (ContentView.swift:90–92) — if `_walkthrough` is seeded incorrectly (not from model's existing singleton), the delegate captures a phantom instance off a not-yet-installed view struct, and the strip's `if walkthrough.isActive` gate never re-renders. Fix: seed `StateObject` wrappedValue from model's model-owned singleton *always*.

2. **Layout-priority + frame-constraint dance** (ContentView.swift:119–138) — chrome bars have fixed heights (TabBar 30, etc.) but VStack distributes under-shrink across all children. Solution: `layoutPriority(1)` on bars, center HStack `maxHeight:.infinity`, `fixedSize(vertical:)` on bars. If you get this wrong, bars compress when window shrinks.

3. **Terminal pane toggle regression** (ContentView.swift:186–195) — `terminalPane.height` is a fixed-size band, but if the terminal's interior `maxHeight:.infinity` steals the column on toggle, the terminal paints over the document. Fix: body row gets `layoutPriority(1)` + `maxHeight:.infinity` to win the flex; terminal is pinned `layoutPriority(0)`.

4. **Opaque NSViewRepresentable occlusion** — any layer-backed AppKit view (CM6 WebView, terminal surface, any NSView-based representable) composites over earlier-painted SwiftUI siblings, even if geometrically adjacent. Wrapping the SwiftUI view in `.compositingGroup().zIndex(1)` while the representable stays `.zIndex(0)` fixes it, but you must apply it in *every* layout branch.
   - Pointer: DiskConflictBanner.swift:46–52; ContentView.swift:243–250.

5. **Diagnostic/debug window exfil surface** — DiagnosticWindowView is live content and path dumping. It must never be MCP-exported (no automated access), never auto-persisted (no writing to disk), and require explicit Export action. The guardrails are documented but easy to miss.

6. **TextFormatter/DateFormatter test determinism** — ActionHistoryRowModel uses DateFormatter with explicit locale + timezone so tests get consistent timestamps. Without this, per-locale or per-run-timezone variance breaks host tests.

7. **CSV large-file streaming parse + rendering** — CSVTableView (1141 LOC) uses streaming parse to avoid loading entire CSV into memory, but rendering still virtual-scrolls (LazyVGrid/LazyVStack) to avoid rendering 100K rows. If you don't virtualize, UI freezes on open.

8. **Persistent audio playback across session switches** — AudioPlaybackController (singleton) reuses AVPlayer for same URL (no yank on re-mount); pauses old stream on new URL. Without this, session-switch tears down the view and kills playback. The pattern is simple but non-obvious (ownership at app scope, binding in view).

---

## Rebuild Notes — If Building This Capability Fresh

### Architecture (State Partition)

The #1 lesson is: **partition state by domain from day one**. Do not build a god object incrementally.

```
ContentView (root composition)
├── TabCoordinator (tabs, active tab, split)
├── SidebarModel (visibility, rootURL, panels)
├── PanelLayoutStore (shoulder-rail + bottom-dock per-panel edge)
├── TerminalPaneStore (visibility, height, edge, content)
├── FindCoordinator (query, case/regex, next nonce, results)
├── EditorCoordinator (one-shot gotos, inserts, selections)
├── ThemeStore (theme ID, chrome colors, syntax theme)
├── PreferencesStore (font, zoom, wrap, vim mode, etc.)
├── SessionsAppCoordinator (optional, for multi-session UI)
└── SourceViewChannel (editor model: buffer, caret, selection, scroll — NOT observed by ContentView, only by source subtree)
```

Each coordinator is a separate `@Observable` class (or SwiftUI 6 @Observable, pending adoption). ContentView does narrow, documented `@ObservedObject` observations of each + explicit `@Environment` for ones that don't need to re-render ContentView.

**No DocumentModel god object.** Kill it at the start.

### Observation Discipline

- Root composition (ContentView) observes only the top-level coordinators it needs to render.
- Each coordinator publishes only the `@Published` properties that affect *its consumers*.
- Secondary state (per-scroll caret updates, playhead frames, waveform peaks, etc.) rides separate objects observed only by the subtree that cares.
- **Document your observation design** in comments — future changes will be tempted to "just forward the whole model." Resistance requires clarity.

### Layout Safety

- **Compositor rules**: opaque NSViewRepresentable + `.compositingGroup().zIndex(1)` on SwiftUI siblings in the same container.
- **Frame constraints**: `maxWidth:.infinity, maxHeight:.infinity` on content panes so springs don't collapse; `frame(width:)` / `frame(height:)` only on fixed-size chrome (rails, headers).
- **Layout priority**: `layoutPriority(1)` on chrome bars so they don't compress when window shrinks; center content gets priority 0.
- **Document these rules** per layout (CHROME PIN comments). They are non-obvious and fragile.

### Feature Scaffolds (Reuse These)

1. **Sidebar section** (collapsible, filter chips, sort menu, empty-state, height-managed): BookmarksSection template.
2. **Feature modal** (format picker + options + action button): ConvertImageView + ViewModel template.
3. **Async off-main ViewModel** (detached Task, error mapping, cleanup): AudioEditorViewModel / ConvertImageViewModel template.
4. **Presentation model** (pure display logic, no SwiftUI, host-testable): ActionHistoryRowModel template.
5. **Small focused coordinator** (narrow @Published set, pure logic): CMOneShotRouting + CMOneShotLedger template (routing logic + shared state pattern).

### Testing Strategy

- **Host tiers** (T1/T2'): pure models, ViewModels, coordinators, routing logic. 80%+ of your logic can live here.
- **Headless UI tiers** (T1m): SwiftUI view construction + @Published observation chains (no rendering, just tree walk).
- **VM live-app tiers** (T4/T5): actual rendering + UI interactions. Run only on UTM VM (T4 LiveAppTestCase, T5 PixelTestCase). Never on Mac host.
- **Negative-control pattern (TSK-1134)** — commit `MDVNegativeControl.isBroken("<FEATURE>")` checks for any hide-by-default UI, and wire them into T5 pixel tests to prove the guard works.

### Specific Domains (Future Slices Will Cover)

- **Document/file model** (buffer, history, metadata): should be a pure, host-testable struct (not SwiftUI dependent) with a thin coordinator wrapper.
- **CM6 editor bridging** (CodeMirrorEditorView + coordinator): massive file, but the dispatch/routing core is host-testable; render tail is separate.
- **LSP integration** (completion, hover, go-to): separate coordinator from the main model; route events, cache results, handle errors.
- **Git/terminal integration** (subprocess spawning, output streaming): should be purely functional (detached Tasks, signal-based cleanup), not baked into DocumentModel.
- **Audio playback/editing**: good pattern already (separate controllers + ViewModels). Keep the AudioPlaybackController singleton + reuse-on-same-URL approach.

### Documentation & Guardrails

- **Observation discipline**: comment every `@ObservedObject` var explaining why that observation is necessary and what it triggers.
- **Compositor rules**: inline comment on EVERY zIndex/compositingGroup/frame constraint explaining the problem (TSK-960, LESSONS.md rule, etc.).
- **Debug/diagnostic surfaces**: comment guardrails (never observe, never export, never persist, explicit-action-only) at the type definition.
- **Feature scaffolds**: keep example/template files (`BookmarksSection`, `ConvertImageView`, etc.) in the codebase as reference implementations.

