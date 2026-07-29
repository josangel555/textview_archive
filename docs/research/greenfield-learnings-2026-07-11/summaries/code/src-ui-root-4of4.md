# Sources/ViewerUI Root Files — Batch 4/4 (Items 159–210)

## File Catalog

**Sources/ViewerUI/PluginSidebarSections.swift** (146 LOC) — Renders every registered plugin sidebar section above FILES tree. Registry-driven, no observation of PluginRegistry (intentional design to avoid premature republish widening).
- notable: Mirrors toggle state per section ID; TSK-614 hides plugin sections w/ context menu; Snapshot-based row wiring to capture open files.
- carry: KEEP — principled architecture of plugin integration, with clear separation between static registry view and persisted UI state.

**Sources/ViewerUI/PluginsSettingsView.swift** (235 LOC) — Settings → Plugins pane. Lists installed plugins, toggles enable/disable, revokes grants. TSK-1478 slice: install/remove lifecycle with banner feedback. Bundled plugins re-enable path lives here.
- notable: Read-only + toggle + revoke only in v1; install/uninstall/drag-drop is Phase 2. Banner state `@State`, tick-driven refresh. Grant-store integration clean. TSK-1478 install validates + copies + loads into running registry.
- carry: KEEP — good separation of concerns (manifest → UI rendering, lifecycle API calls isolated), validation-before-copy pattern sound.

**Sources/ViewerUI/RecentChangesSection.swift** (229 LOC) — Sidebar widget showing files changed in current git repo's working tree. Calls `git status --porcelain` on demand, not background daemon. Hidden when sidebar root isn't in a repo. DEPRECATED for panel use (GitPanelSection now multi-repo); survives for unit tests + RecentChangeRow.
- notable: Runs git off-main via Task.detached. Shows status badges (M/A/D/R/C/?), file icons, optional diff button. Diff opens temp file in new tab (cache dir + hash for uniqueness). TSK-763 parent-folder hint disambiguates same-named recents.
- carry: KEEP (infrastructure) but REDO (multi-repo split) — the single-repo discovery is replaced; the diff + status badge patterns are reusable.

**Sources/ViewerUI/RecentlyOpenedSection.swift** (132 LOC) — Collapsible "Recent" sidebar panel. Lists recently-opened files/folders newest-first from global `HistoryStore` (model.recents). TSK-1464 cleanup menu removes missing entries. Mirrors BookmarksSectionemplate chrome.
- notable: Static placeholder message pinned by BookmarksSectionEmptyTests. Drag support for TSK-327 (drag-to-snap). Parent-folder label (tertiary) for disambiguation. No expansion state persistence (always starts expanded).
- carry: KEEP — lightweight, reusable recents widget; cleanup menu is UX win.

**Sources/ViewerUI/RecoverDeletedFileView.swift** (111 LOC) — TSK-1500 "Recover Deleted File" picker: lists recently-opened files gone from disk but with Local History versions. Recreates latest version (atomic, never-overwrite `FileResurrection`). Version menu per file shows date + size. Host-tested enumeration + recreate on DocumentModel; shell view only.
- notable: Non-modal sheet. Dropdown menu for per-version restore (latest by default). Tooltip versionLabel formats ("Jul 9, 2026 at 2:34 PM · 1.2 KB"). Safe to call repeatedly (re-lists on every open).
- carry: KEEP — hot-exit data-loss prevention is critical; well-factored model/view split.

**Sources/ViewerUI/ResizableSectionDivider.swift** (210 LOC) — 1-px hairline resize handle (TSK-440). Cursor push/pop for resizeUpDown + drag. No-animation `Transaction` suppresses jank on deltas. Sum-preserving redistribution (pair drag) or legacy clamp (above-only). Wiring probe validates presence.
- notable: `dragStartAbove`/`dragStartBelow` capture origins; `apply(delta:)` is testable by direct call. `SidebarResize.redistribute` + `SidebarPanelHeights.clamp` handle math. Unbalanced `NSCursor.push/pop` risk documented + guarded by `pushedResizeCursor` state.
- carry: KEEP — exemplary cursor-state discipline; resizable-panel pattern is solid. Epsilon-gating on `@AppStorage` writes eliminates unnecessary UserDefaults flushes.

**Sources/ViewerUI/RichTextReadOnlyView.swift** (151 LOC) — TSK-706 foundation slice: read-only render of restricted RichText IR vocabulary. Pure SwiftUI (no AppKit, no compositor risk). Gated by `RichTextFeatureFlag` (off by default). Skeleton for later slices (editing, toolbar).
- notable: Parsing + layout for all IR types (heading, para, lists, blockquote, code, table). Glyph rendering as Text primitives (no custom layout). Link underline + accent-color (navigation is a later slice). Table rows tab-separated fallback (WIP, flag-gated).
- carry: KEEP — low-risk foundation; the flag-gated shadow growth pattern keeps it safe until ready.

**Sources/ViewerUI/RowHoverButtonStyle.swift** (271 LOC) — Two shared hover/press affordances: (1) `RowHoverButtonStyle` for list rows (sidebar, palette, bookmarks, git, LSP), (2) `IconHoverButtonStyle` for icon/chip buttons. Cursor push/pop balanced per view + cleanup on disappear. Scale ≤2% on icon hover (Reduce Motion aware). MotionGate handles accessibility.
- notable: TSK-728/730/1280 — sidebar key monitor yields to text editors + ALL live CM6 editors (not just current()). Rich pattern for reducing-motion support: `MotionGate.animation(_:reduceMotion:)` returns nil on accessibility pref. VoiceOver announcement helper for transient status.
- carry: KEEP — this is exemplary SwiftUI affordance design. The cursor-stack discipline, accessibility integration, and scale deltas set the standard.

**Sources/ViewerUI/ScriptConsoleView.swift** (89 LOC) — TSK-698 slice 3b: Script Console panel. Query/transform over active buffer (JSON / log lines / CSV). JS expression (`input` / `$` = parsed buffer). Runs off-main w/ soft timeout. Pretty JSON output or one-line error. "Apply →" hands result to presenter (new tab).
- notable: Input-format picker (segmented). Run button (disabled if query empty). Apply button (disabled if output empty or no sink). Empty state + error display. Host-tested view-model drives logic; this is pure render.
- carry: KEEP — clean separation; extensible for future formats.

**Sources/ViewerUI/ScriptConsoleViewModel.swift** (78 LOC) — TSK-698 host-tested core: JS transform controller. `run(timeout:)` async, publishes output / errorMessage / isRunning. Error descriptions (invalidJSON, jsException, unserializableResult, timedOut) tailored for UI. Default input format from file extension (.csv/.log → auto-select mode).
- notable: Off-main via `JSTransform.runAsync` (bounded, soft timeout). @Published @MainActor. Error formatter is smart (e.g., "Try Lines format for logs"). Sendable-aware result tuple.
- carry: KEEP — solid async model, reusable in multiple contexts.

**Sources/ViewerUI/SearchAnywhereSection.swift** (387 LOC) — Sidebar search across every file under root. Mode A (visible-rows fuzzy narrowing) wired; Mode B (global find) design is TSK-666 (deferred). Debounced search + RustFuzzyAdapter ranking. Scope picker (active folder / pick folder). Result cap (design rule 4). Zero inner Divider() enforced by layout test.
- notable: Render-cap logic (`SearchResultCap.visible/overflow`) prevents jank on huge match lists. Match highlighting uses `FuzzyHighlight.attributed` (shared w/ command palette). Scope resolver fallback logic. Line-number jumps w/ `openPath(_:atLine:)`.
- carry: KEEP — solid integration of search engine; the divider audit is a template for layout discipline. Mode B skeleton ready for expansion.

**Sources/ViewerUI/SecretWarningBanner.swift** (105 LOC) — TSK-1496 credential warn-badge. Non-modal banner when viewed document contains detected secrets. Redacted previews only (never renders secret values). Scan runs off-main, keyed on content. Gating/labelling host-tested (`SecretBannerState`). Settings toggle controls treatment (default: warn badge).
- notable: ZStack with always-present Color.clear frame so `.task` fires even on first (clean) render. Details popover lists findings (line, kind, redacted preview). Dismissed by user or auto-hidden if scan disabled.
- carry: KEEP — zero-knowledge display of sensitive data is exemplary; off-main scan + caching by content-hash is smart.

**Sources/ViewerUI/SelectionHighlightEngine.swift** (122 LOC) — Pure value type: "highlight all occurrences of selected text" (VSCode/Sublime pattern). Size-cap + selection-shape policy (host-testable without NSTextView). Skips multi-MB files (perf bound). Word-like check + min/max length. Returns OTHER occurrences (excluding active selection).
- notable: Policy struct for tuning (defaults match VSCode). `otherOccurrences(in:selection:haystackByteCount:)` returns NSRange array. Byte count is cached by caller so no per-selection UTF-8 walk. Whitespace filter (bordering chars test).
- carry: KEEP — clean, reusable perf-aware primitive. The policy struct pattern is excellent for parameterization.

**Sources/ViewerUI/SettingsView.swift** (250+ LOC, sampled) — Kitchen-sink Settings page (no tabs yet). Appearance (font picker, theme picker, VS Code importer), Editor, Languages, Terminal, Viewer, File Associations, Audio, Privacy, Plugins, Extensions, LSP, Advanced. NavigationStack for sub-pages (Plugins, LSP Diagnostics). Resizable window.
- notable: Per-section layout with Divider separators. LSP statuses loaded off-main (languageStatuses() shells out). Default-app statuses cached + refreshed after toggles. Walkthrough inventory loaded off-main (TSK-1206). Per-language LSP server availability shown w/ install hints.
- carry: KEEP — flat, discoverable settings hierarchy; off-main loading prevents UI freeze.

**Sources/ViewerUI/ShapeSelectionHandlesView.swift** (53 LOC) — TSK-1168 selection outline + eight resize handles for vector shape editing (image canvas `.editShapes` tool). Pure SwiftUI Canvas (no NSViewRepresentable). Dashed outline in accent color; filled/stroked handle squares. Geometry from host-tested `ShapeDragGeometry.handlePoints`.
- notable: Coordinate mapping for normalized `0...1` frame → image rect. Drawn OVER `VectorOverlayView`. Interactive drag consumed in `ImageEditorView` + validated on VM/AX lane.
- carry: KEEP — simple, compositor-safe rendering of interactive geometry.

**Sources/ViewerUI/SidebarConstants.swift** (197 LOC) — Shared layout constants across sidebar sections (Bookmarks, Search, Git, Claude, FILES). `sectionBodyHeight` default (220 pt). Environment-value key + extension for `.sidebarSectionBodyHeight` override (per-section via resizable dividers). Header metrics (chevron frame 10 pt, label 10 pt, padding 10 pt H / 4 pt V). Section-container chrome (bg + outer padding).
- notable: `SidebarSectionHeaderLabel` unifies chevron + label rendering + drag handles (TSK-327 panel-drag-to-snap). `sidebarHeaderRow()` modifier applies standard padding. `SidebarEmptyPlaceholder` centralizes empty-state text. Consistency enforced by one-liner adoption in every section.
- carry: KEEP — exemplary design-system approach. Concentrating Chrome in one place eliminates drift.

**Sources/ViewerUI/SidebarFilter.swift** (134 LOC) — TSK-282 Mode A: fuzzy-narrow visible file-nav rows as user types (matched-glyph highlighting). Router to `RustFuzzyAdapter` (rust by default; Swift twin deprecated). `SidebarFilterMatch` struct (display, secondary, indices). Result cap (500). `FuzzyHighlight.attributed` shared w/ command palette. `FileDragProvider` for drag-out (NSItemProvider + NSFileURL).
- notable: Two modes: Mode A (visible rows), Mode B (global descendant index, deferred TSK-666). Match indices are character positions (FuzzyMatcher contract; adapter documents grapheme divergence). Highlight path centralized for consistency.
- carry: KEEP (infrastructure) but REDO (Mode B) — the visible-row filter is solid; global index is the follow-on expansion.

**Sources/ViewerUI/SidebarKeyMonitor.swift** (153 LOC) — NSEvent local monitor for arrow/Enter keys while sidebar visible. Intercepts only when first responder is NOT text editor (NSText, NSSearchField, NSTextField) + NOT custom raw-key view (terminal, `SidebarKeyMonitorExempt`). CRITICAL (TSK-1280): yields to ALL live CM6 editors (not just current()).
- notable: Pure yield decision (host-testable) examines modifiers, responder type, editor views. No blocking if Cmd/Opt/Ctrl held. Multi-pane fix: checks liveWebViews (all mounted editors), not just current(). Balanced push/pop for cursor.
- carry: KEEP — tight integration point; the multi-pane detection prevents enter-from-sidebar eating focus from editor.

**Sources/ViewerUI/SidebarModel.swift** (250+ LOC, sampled) — Observable file-tree state. Lazy-caches per-directory children. Global-find descendant cache (TSK-666, deferred Mode B). Expansion state, selected URL (keyboard nav). Recency-version bump for stripe invalidation (RWC-3). FSEvents watcher on root. Per-root git-repo discovery cached. Claude-transcript presence flag. LRU children-cache w/ order tracking (RWC-5).
- notable: Descendant walk skips `.git`, `node_modules`, `.build`, `.swiftpm`, `dist` (heavyweight trees). Cap 50k candidates. Generation token guards stale builds. `revealAncestors(of:)` auto-expands for filter hits (Mode B). Git repo root memoized per root.
- carry: KEEP — solid caching strategy with LRU hygiene and generation tokens. Descendant index is well-designed for future global-find feature.

**Sources/ViewerUI/SidebarPanelBody.swift** (132 LOC) — Shared body factory for sidebar/tool-window panels. One @ViewBuilder, NOT a View (observation discipline). Renders content for `.bookmarks`, `.searchAnywhere`, `.git`, `.claudeTimeline`, `.lspOutline`, `.markdownOutline`, `.lspNavigation`, `.lspProblems`, `.recentlyOpened`, `.pluginSections`. Returns EmptyView for `.files` (flex-fill, not dockable).
- notable: Injects `bodyHeight` via environment so docked tool windows override accordion clamp. Workspace-symbol dispatch lifted to reuse accordion + docked panels identically (TSK-1319 dynamic menu model).
- carry: KEEP — excellent pattern for factoring duplicate panel logic. The environment injection keeps observation clean.

**Sources/ViewerUI/SidebarView.swift** (250+ LOC, sampled) — Main sidebar orchestrator. Accordion layout: FILES (flex-fill) + resizable panels (Bookmarks, Search, Git, Claude, LSP, plugins). P1 bounding: measured content height (non-layout-driving GeometryReader) clamps per-panel bodies. BoundedAccordionScroll wraps panels so they never overflow chrome. FILES↔accordion divider (TSK-440). Recency-mode dropdown. Fuzzy filter @State (debounced copy drives ranking).
- notable: `filesPanelVisible` heuristic. `filesBoundaryPlan` drives divider presence. Per-panel height @AppStorage (SidebarPanelKind constants). Measurement epsilon (0.5 pt) suppresses jitter. Divider wiring complex (three routes: pair/above-only/boundary). Tab-strip drag-to-snap via `SidebarSectionHeaderLabel`.
- carry: KEEP (with refinements) — P1 bounding + epsilon-gated measurement are sophisticated. The accordion-scroll wrapping solves the overflow-chrome blocker. Divider wiring is complex; document it well.

**Sources/ViewerUI/SnippetManagerView.swift** (250+ LOC, sampled) — Snippet management (TSK-705, UX pass TSK-1461). Left: search + list + Insert button. Right: form + live preview. Host-tested model layer (`SnippetManagerModel`); this is render + binds. Double-click or Return inserts; single-click selects. Form: id, name, body. Tab-stop syntax validation. Built-in read-only unless overridden.
- notable: Search filters by name/id/body. Edit-in-place vs new-snippet mode. Built-in badge + override label. Insert-candidate logic (selected row if matches, else first filtered). Validation message (orange text). List column + form column HSplitView.
- carry: KEEP — solid snippet workflow; the form layout is ergonomic.

**Sources/ViewerUI/SourceControllerCache.swift** (240 LOC) — TSK-889 warm-source-view LRU. Preserves laid-out NSTextView across tab deactivations (switch-back is cheap: no re-typeset). Keyed by tab UUID. Two independent caps: count (4) + byte budget (64 MiB). MRU-first eviction. `teardownStorage()` on eviction + purge only (never on acquire). Opt-in via `MDV_PRESERVE_RECENT_SOURCE_VIEWS`.
- notable: Host-tested LRU state machine (pure, no AppKit). `acquire`/`store`/`touch`/`purge` API. Entry removal on hit (take-once). Byte-budget guards against huge-file stack-up. Disabled-run behavior identical to pre-cache (always teardown on dismantle). DEBUG probes (stashes, hits, misses, evictions).
- carry: KEEP — exemplary perf optimization with bulletproof correctness. The two-cap strategy (count + bytes) is smart.

**Sources/ViewerUI/SourceGutterView.swift** (317 LOC, sampled) — Line-number gutter for read-only source view. Observes scroll state (offset, line count, line height). Supports word-wrap (visual-row counting). Clipped Canvas, not NSRulerView (LESSONS.md compositor-occlusion trap). Sticky first visible line (at top-inset) on narrow viewports (UX-E). Clickable line numbers for selection + scroll anchor.
- notable: Visual-row geometry w/ wrap support. Visible-line range clamp. Fixed-pitch font advance lookup. Scroll-state-driven layout (no NSScrollView.tile() involvement). Hover + click + context menu (goto line, show reveal, mark). Accessibility labels.
- carry: KEEP — the compositor-safe Canvas approach is the standard template. Wrap support future-ready.

**Sources/ViewerUI/SplitPaneView.swift** (232 LOC) — HSplitView wrapper for resizable source↔preview split (TSK-1061). Drags handle to resize. Persists width via @AppStorage. Proportional calc for flex-fill vs fixed panels. Horizontal scroll sync (TSK-867). Hot-swap pane content via `ContentBuilder` (no re-init on toggle).
- notable: Proportional width calc keeps flex panel responsive. ContentBuilder pattern avoids re-create churn. `.onAppear` seeds scroll sync. Split-specific keyboard shortcuts (Cmd+4/5 for balance/cycle). Accessibility identifiers.
- carry: KEEP — solid split-pane pattern. The proportional width + hot-swap design are reusable.

**Sources/ViewerUI/SpreadsheetView.swift** (73 LOC) — TSK-1141 slice 3: multi-sheet `.xlsx` tab strip above CSVTableView grid. Shown only when file carries >1 sheet. Tab click re-derives grid text via `TextFile.withActiveSheet(_:)` (file.contents updates). Both strip + grid are SwiftUI (no compositor concern).
- notable: Sheet names fallback ("Sheet 1" if empty). Tab-selection highlighting w/ .selectedContentBackgroundColor. Clamped active-sheet index (defensive). Horizontal scroll (no scrollbars). ScrollView + HStack layout.
- carry: KEEP — lightweight, clean integration of multisheet support.

**Sources/ViewerUI/SQLiteBrowserView.swift** (250+ LOC, sampled) — Read-only SQLite browser. Three panes: schema sidebar (tables/views/indexes/triggers), SQL editor + results panel, schema inspector. Wraps `SQLiteReader` (opens READONLY). Query execution off-main w/ cancel option (TSK-1439). Result export (CSV/Markdown/JSON). Host-tested `SQLiteBrowserModel`; this is render.
- notable: Query editor w/ Run + Cancel buttons (swap while running). Export menu (copy to clipboard / save file). Results grid via `ResultTableView`. Error display + loading state. Scope sidebar w/ icons + selection highlight. Syntax highlighting (placeholder for future).
- carry: KEEP — solid UI over read-only database inspection. Export feature + cancel hook are production-grade.

**Sources/ViewerUI/StatusBar.swift** (250+ LOC, sampled) — Bottom status bar: file path (abbreviated) + git chip (repo · branch) + vim-mode chip + macro-recording + LSP status + metrics (line/char/size/encoding) + memory chip. Hover-description slot (0c). Path breadcrumb w/ right-click menu (TSK-933/934). ViewThatFits fallback when narrow (metrics-only, no dates).
- notable: Multiple independent observations (model, tabCoordinator, sourceView, helpSink) for fine-grained re-body. Git branch enumeration deferred to Menu content (off-main cache via gitChipStore, TSK-734). Path breadcrumb segments are clickable (reveal in sidebar). Per-segment context menu (TSK-934 open/copy/terminal verbs).
- carry: KEEP — excellent modular observation discipline. The git-chip deferral prevents layout-path subprocess calls. Breadcrumb context menu is a UX win.

**Sources/ViewerUI/StatusBarMemory.swift** (145 LOC) — TSK-366 memory readout (pure formatter) + `StatusBarMemorySampler` (cheap 1.5s sampler of app phys_footprint). Per-tab content-byte proxy (tooltip only, not bar label). Sampler is own view so 1.5s tick re-bodies only the chip, never whole StatusBar. Change-gated publish (Equatable gate on ingest). Deinit backstop for timer invalidation (L-mem trap).
- notable: Honest metrics (phys_footprint syscall, no pid-walk). Sampler owns Timer, weak-self capture prevents leak. Shared vs per-tab metric split clear. Tooltip educates user ("WKWebView app has no honest per-tab RSS"). Test seam: timerForTesting.
- carry: KEEP — exemplary performance-aware sampling. The deinit timer cleanup is a pattern for background tasks.

**Sources/ViewerUI/StructuralSearchView.swift** (137 LOC) — TSK-1161 panel over tree-sitter DSL engine. Query field + Search button. Examples popover (language-tailored, TSK-1476). Live under-field validation (StructuralSearchHelp). Results list (kind + source snippet, 2 lines). Jump-on-click to match range. Host-tested StructuralSearchViewModel; this is render.
- notable: Syntax error display (live vs run-time). Match snippets truncated to first line. Empty state ("no matches" vs "run a query"). Examples popover insertable.
- carry: KEEP — clean integration of structural search. Live validation + examples are good UX.

**Sources/ViewerUI/StructuralSearchViewModel.swift** (57 LOC) — TSK-1161 host-tested core: structural search controller. @Published query, inputText, language. Synchronous run (bounded). Error message or matches list. Query parser error handling. Language-aware node kinds.
- notable: Direct `TreeSitterEngine.structuralSearch` call (host-testable because engine is pure + deterministic). StructuralQueryParser.ParseError rich messages.
- carry: KEEP — clean model layer.

**Sources/ViewerUI/TabBar.swift** (535 LOC, sampled) — Tab strip orchestrator. Rendered via `LazyVStack` with per-tab `TabView` controls + tab-close buttons (dirty dot shows unsaved state). Drag-drop reorder via `moveTab(_:beforeTab:)`. Quick-open via tab-switcher menu. Preview tabs (ephemeral, italic). Keyboard shortcuts (Cmd+Shift+T restore-closed).
- notable: Tab title styling (italic for preview, bold for active normal). Per-tab menu: Pin/unpin, New/Restore. Unsaved indicator (dirty dot) via `TabCoordinator` observation (not DocumentModel). Intrinsic-size-safe width measurement (non-layout-driving GeometryReader). TabBar constraints: min 100, ideal 150.
- carry: KEEP — sophisticated tab management with drag-drop + unsaved tracking. The dirty-dot via TabCoordinator observation is a clean pattern. Preview-tab styling is VSCode-aligned.

**Sources/ViewerUI/TabTitleStyle.swift** (23 LOC) — Pure decision: tab title emphasis (italic=preview, bold=active-normal). Italic alone when preview+selected (TSK-902, don't double-tint).
- carry: KEEP — hostable test helper, clean predicate logic.

**Sources/ViewerUI/TaskRunnerView.swift** (95 LOC) — TSK-1160 panel: lists runnable tasks (package.json / Cargo / Makefile), runs selected one off-main w/ bounded output capture, shows output/error. Header w/ Run button + keyboard shortcut (Cmd+Return). Task list w/ selection. Output area w/ empty state. Host-tested TaskRunnerViewModel; this is render.
- notable: Empty state when no tasks discovered. Output + error split display. Output capped at 1 MiB. Runs via ProcessRunner (timeout + resource limits). Off-main so UI stays responsive.
- carry: KEEP — solid task runner UI.

**Sources/ViewerUI/TaskRunnerViewModel.swift** (76 LOC) — TSK-1160 host-tested core: task runner controller. Discovers tasks via `RunnableTaskDiscovery`. `run(_:timeout:)` async via ProcessRunner. Publishes output/error/isRunning. Error surfaces non-zero exit + timeout.
- carry: KEEP — clean task model layer.

**Sources/ViewerUI/TerminalCommandPaletteView.swift** (76 LOC) — TSK-1176 command palette for terminal: query field + results list (favorites first, de-duplicated). Star/clock badges. Command + display-label. Submit (Return) inserts into PTY prompt. Host-tested TerminalCommandPaletteViewModel; this is render.
- carry: KEEP — clean command-palette UI over history + favorites search.

**Sources/ViewerUI/TerminalCommandPaletteViewModel.swift** (47 LOC) — TSK-1176 host-tested core: command palette controller. Unified results (`TerminalCommandSearch.unified`) for favorites-first query. Keyboard navigation (moveSelection wraps). `selectedCommand` property.
- carry: KEEP — clean model layer.

**Sources/ViewerUI/TerminalFavoritesEditor.swift** (97 LOC) — TSK-1475 favorites management: rename (inline textfield), reorder (up/down), remove. Filter box narrows list. Shows count. Bound to `TerminalFavoritesEditorModel`.
- carry: KEEP — clean CRUD UI for favorites.

**Sources/ViewerUI/TerminalFavoritesEditorModel.swift** (75 LOC) — TSK-1475 host-tested core: favorites editor model. Delegation to `TerminalFavoritesStore` (rename/move/remove). Filtered rows by query. Built-in vs user snippets logic.
- carry: KEEP — clean model layer.

**Sources/ViewerUI/TextDisplayView.swift** (1538 LOC, sampled) — Main source-view representable. Hosts NSTextView wrapped in NSScrollView. State channels: scroll (SourceScrollState), caret (SourceViewChannel), selection-highlight (SelectionHighlightEngine output). Warm-cache integration (SourceControllerCache + WarmEditorWebViewCache for editors). Applies syntax highlighting, current-line bg, selection/hover overlays (SwiftUI Canvas siblings). Rich edit menu (cut/copy/paste/find/replace/etc). Keyboard shortcut wiring. Line-ending + encoding indicators. Invisibles overlay (SourceInvisiblesView).
- notable: TSK-889 warm-source preservation across tab switches (saves re-layout). Compositor-occlusion discipline (overlays as Canvas siblings, not NSRulerView). Multiple state channels prevent model-wide republish. SourceScrollState bridges NSScrollView geometry to SwiftUI observation. RichTextReadOnlyView + HTMLRenderedView integrated for non-editor rendering slices.
- carry: KEEP (with refinements) — the integration of AppKit NSTextView + SwiftUI overlays is the gold standard for this pattern. Warm-cache integration is exemplary perf. State-channel separation is excellent.

**Sources/ViewerUI/ToastCenter.swift** (217 LOC) — TSK-1436 app-wide toast + long-operation progress model. Value-type Toast (id, kind, message, detail, actionLabel, expiresAtNanos). OperationProgress (id, title, fraction, isCancellable). Observable state (toasts, operations). Post/dismiss/sweep API. Self-scheduled expiry Tasks (no view-side timer). Action + cancel-handler closures keyed by id (non-Equatable, stored separately).
- notable: Kind-based TTL (error 8s, success/info 4s). Max 5 visible toasts (FIFO cap). `sweep(now:)` prunes expired (injectable clock for host tests). ObsEvent emitted for error toast (durable Logs record). OperationOutcome enum (success/failure/cancelled).
- carry: KEEP — exemplary toast/notification model. The injectable clock + self-scheduled expiry are production patterns.

**Sources/ViewerUI/ToastOverlayView.swift** (120 LOC) — TSK-1436 render of ToastCenter over content pane (bottom-trailing). In-flight operation rows (spinner/bar + Cancel button). Transient toast capsules (kind icon, message, detail, action button, dismiss). Animation on toast/operation list changes. Mounted once in ContentView w/ `.compositingGroup().zIndex()` per compositor rule (LESSONS.md).
- notable: No-op hit-testing when empty. Icon/color per toast kind (info/success/error). OperationProgress determinate (value) vs indeterminate (spinner). Toast self-dismisses (Esc key shortcut). Accessibility element wrapping.
- carry: KEEP — clean, accessible notification render.

**Sources/ViewerUI/ToolResultsPanel.swift** (117 LOC) — TSK-1434 shared tool-results panel (non-modal palette). Severity dot + optional line badge (click → goto, panel stays) + rule tag + Copy-all + Esc/✕ dismiss. Replaces four modal alerts. Mounted floating, bottom-trailing.
- notable: Click jumps to line via model callback. Copy exports plainText. Color + icon per severity (info/warning/error). Row dividers.
- carry: KEEP — unified result-display pattern beats scattered modals.

**Sources/ViewerUI/UISceneApplier.swift** (591 LOC, sampled) — Scene-setup orchestration. Applies saved window frame + sidebar width + pane mount state + UI zoom to the live app. Restores tab state (persisted snapshot → fresh session). Runs gear-up code on launch (@.instantiate in DocumentModel). Wires keyboard shortcuts (Cmd+comma→Settings, Cmd+1/2/3→panes, Cmd+f→find, Cmd+k→command palette, Cmd+opt+→terminal, etc). Handles file-open requests (Finder drag, command-line, URL schemes). Session persistence + recovery. ContentView assembly.
- notable: `@Scene` -> WindowGroup. ScenePhase observer (.active / .inactive). Window frame restoration via NSScreen unsafe. Sidebar width + pane mounts stored per-session. Tab snapshot round-trips via FileSystemSnapshot. URL scheme handler for mdv:// references. File-open coerces to markdown view mode. Walkthrough integration. Orchestrates DocumentModel creation + restoration.
- carry: KEEP (with refinements) — scene orchestration is complex but essential. The multi-faceted restoration (window / sidebar / tabs / panes / zoom) is thorough. URL-scheme handler is extensible for future agent integrations.

**Sources/ViewerUI/VectorOverlayView.swift** (136 LOC) — TSK-287 vector annotations for image editor. Pure SwiftUI Canvas (no NSViewRepresentable). Draws `VectorOverlay` (rectangles, ellipses, lines, arrows, text). Normalized `0...1` frame → displayed image rect mapping. Back-to-front z-order (index 0 back, last front). Rotation support (TSK-1321). Fill + stroke styling. Arrow geometry (barbs at angle).
- notable: Shape.kind enum (rect, ellipse, roundedRect, line, arrow, text). Text labels w/ fontSize % of image height. Rotation angle + center calculation. Coordinate mapping functions. Allowable hit-testing false (overlay only, no interaction here).
- carry: KEEP — clean, compositor-safe drawing of annotations.

**Sources/ViewerUI/VimModeKind.swift** (34 LOC) — TSK-679 vim-mode classifier. Parses raw CM6 mode string → enum (normal, insert, visual, replace, other). Prefix-matches ("VISUAL LINE" → .visual). Per-mode color (accent / green / orange / red / secondary). Host-testable classifier, render tail wires the color.
- carry: KEEP — clean state machine for vim mode.

**Sources/ViewerUI/WarmEditorWebViewCache.swift** (197 LOC) — TSK-1047 warm-editor-WebView cache (twin of `WarmWebViewCache`). Survives session/tab switch. Re-attaches with loaded CM6 document + undo history + caret + SCROLL intact (fixes editor-scroll-reset-on-switch bug). Stashes `parkedText` (the live-state consistency guard: re-attach only when parked text == expected text, otherwise drop). Take-once LRU. Bounded (4, matching MountedPanesLRU).
- notable: Text-consistency guard prevents resurrecting stale text + masks in-progress edits. DEBUG probes (stashes, hits, misses, textRejections, evictions). Parented-WebView defensive check. Main-actor singleton.
- carry: KEEP — exemplary perf + correctness pattern. The text-consistency guard is crucial for live-document safety.

**Sources/ViewerUI/WarmHTMLWebViewCache.swift** (157 LOC) — Twin of `WarmWebViewCache` for raw-HTML render pane (TSK-1190). Separate cache so markdown WebView can never collide with raw-HTML WebView (security envelope preserved). Fixes Editor↔Render mode-toggle reloads on multi-MB documents. Identical correctness invariants (take-once, no-parent, bounded, path-keyed).
- notable: Separate coordinator type (HTMLRenderedView.Coordinator vs MarkdownRenderedView.Coordinator). Different security posture (raw-HTML default-DENY JS vs markdown enabled). Prevents cross-contamination.
- carry: KEEP — exemplary perf pattern for toggle-heavy workflows. The separate cache for security boundary preservation is smart.

**Sources/ViewerUI/WarmWebViewCache.swift** (161 LOC) — Perf P1 (TSK-1042) warm-WKWebView cache. Survives session switch (re-attach existing WebView instead of rebuild, which re-pays ~94% of open cost). Keyed by file path (stable across fresh Tab.ids). Stashes WebView + coordinator state on dismantle. Re-uses on make if cached. Lazy adoption (lastHTML == html gate → no reload). LRU bounded (4 entries max, 64 MiB byte budget).
- notable: Take-once (remove on retrieve). No-parent guard (reject still-superview'd WebView). Byte-budget + count caps (evict LRU tail). DEBUG probes (stashes, hits, misses, evictions). Main-actor singleton.
- carry: KEEP — exemplary session-switch perf optimization. The dual-cap strategy (count + bytes) + take-once semantics are the pattern.

---

## Module Summary

Batch 4 spans **52 files** covering the UI layer's **chrome, panels, state management, and render integrations**:

1. **Sidebar ecosystem** (PluginSidebarSections, RecentChangesSection, RecentlyOpenedSection, SearchAnywhereSection, SidebarConstants, SidebarFilter, SidebarKeyMonitor, SidebarModel, SidebarPanelBody, SidebarView, ResizableSectionDivider): Accordion-based left panel with per-section resizable dividers. Dynamic content menus, plugin integration, multi-repo git tracking, fuzzy filtering, keyboard nav. P1 bounding prevents panel overflow. Excellent pattern for modular panel architecture.

2. **Settings + configuration** (SettingsView, PluginsSettingsView, TerminalFavoritesEditor, TerminalFavoritesEditorModel): Flat, discoverable settings. Plugin lifecycle (install/remove/toggle/revoke). Terminal favorites curation. Off-main loading prevents freezes.

3. **Search + discovery** (SearchAnywhereSection, StructuralSearchView, StructuralSearchViewModel): Cross-file full-text search, structural DSL search, task discovery, terminal command history. Debounced, debounced rendering (result caps), language-tailored help.

4. **File operations + recovery** (RecentlyOpenedSection, RecoverDeletedFileView, SidebarFilter): Recent files, file recovery from Local History (version menu), fuzzy sidebar filtering. TSK-1464/1500 UX wins.

5. **Status bar + chrome** (StatusBar, StatusBarMemory, VimModeKind, TabBar, TabTitleStyle, ToolResultsPanel, ToastCenter, ToastOverlayView): Bottom metrics, memory sampling (cheap phys_footprint), tab management, vim-mode state, notification toasts + progress ops. Multiple independent observation channels (no model-wide republish on status-only changes).

6. **Editor integration** (TextDisplayView, SourceControllerCache, SourceGutterView, SourceHoverHighlight, SourceInvisiblesView, SelectionHighlightEngine): NSTextView + SwiftUI overlay chimera. Warm-cache preservation across tab switches. Compositor-occlusion discipline (Canvas siblings, not NSRulerView). Rich edit menu, syntax highlighting, selection highlight, hover line, invisibles overlay. State-channel decoupling.

7. **Render panes** (MarkdownRenderedView, HTMLRenderedView, SpreadsheetView, SQLiteBrowserView): Multi-slice render surfaces (markdown, raw HTML, spreadsheet, SQLite query browser). Warm WebView caches (WarmWebViewCache, WarmHTMLWebViewCache, WarmEditorWebViewCache) survive mode toggles + session switches.

8. **Input panels** (ScriptConsoleView, ScriptConsoleViewModel, TaskRunnerView, TaskRunnerViewModel, TerminalCommandPaletteView, TerminalCommandPaletteViewModel): Query/transform (JSON/CSV/log), task runner, command palette. Off-main execution, soft timeouts, bounded output capture, cancellation support.

9. **Overlays + affordances** (RowHoverButtonStyle, IconHoverButtonStyle, VectorOverlayView, ShapeSelectionHandlesView, SecretWarningBanner, SplitPaneView, ShoulderRailView, UISceneApplier): Shared hover/press affordances, vector annotation rendering, secret-credential warning, resizable split pane, shoulder rail (docked tool windows), scene setup + window restoration.

10. **State management** (SidebarModel, TabCoordinator, ToastCenter, SourceViewChannel, SourceControllerCache): Multi-axis observation to prevent model-wide republish (git, sidebar, tabs, memory, source position all have independent channels). Change-gated publishing (Equatable gates).

**Architectural patterns:**
- **Modular observation**: Independent channels (model, sidebar, tabCoordinator, sourceView, git, lsp, memory) avoid cascading re-body.
- **Compositor safety**: Canvas overlays (not NSRulerView/NSViewRepresentable) eliminate layer-ordering risk (TSK-488).
- **Warm caches**: Session-switch perf via WebView + source-controller LRU (three separate caches, keyed by path or tab UUID).
- **Environment injection**: Panel body height, sidebar dimensions, UI zoom threaded via environment values + @AppStorage.
- **Resizable sections**: Sum-preserving redistribution (TSK-440), epsilon-gated measurement, non-layout-driving GeometryReader.
- **Off-main execution**: Git ops, search, task discovery, memory sampling, LSP queries run async to keep UI responsive.
- **State-channel decoupling**: Scroll, caret, selection-highlight, git status, LSP diagnostics each own published state (not threaded through model).

---

## Patterns Worth Porting

1. **Modular observation** (SourceViewChannel, TrackedReposChannel, SidebarModel, TabCoordinator): Each distinct data axis is independently @Published + @ObservedObject. A caret move touches only StatusBar + source pane, never sidebar. Cuts re-body overhead. See SidebarView + StatusBar.

2. **Compositor-safe overlays** (SourceHoverHighlight, SourceInvisiblesView, SecretWarningBanner, ToastOverlayView, VectorOverlayView): Canvas siblings, not NSViewRepresentable subclasses. Eliminates opaque-layer occlusion trap (LESSONS.md TSK-488). Coordinate geometry from published state, not view measurements.

3. **Warm caches** (WarmWebViewCache, WarmHTMLWebViewCache, WarmEditorWebViewCache, SourceControllerCache): Session/tab-switch perf via LRU. Path-keyed (stable across fresh Tab.ids). Take-once + bounded (dual-cap: count + bytes for source, count only for WebViews). DEBUG probes for host testing. See WarmWebViewCache for the template.

4. **Environment + @AppStorage binding adapter** (SidebarView.heightBinding): Thread @AppStorage Double through Binding<CGFloat>, clamping on both sides. Resizable sections use this to persist per-panel height.

5. **Result cap + match highlighting** (SearchAnywhereSection, SnippetManagerView): Debounced search, 500-result cap (design rule 4 — unbounded lists jank). FuzzyHighlight.attributed shared w/ command palette. HighlightedText.ranges for fuzzy match indices.

6. **Off-main discovery + async update** (SidebarModel.ensureDescendantsCache, SettingsView.lspSection): Off-main work (walk, subprocess, query) via `Task.detached(priority: .utility)`. Generation token guards stale builds. Main-actor @Published result bump drives view re-body only on fresh data.

7. **Keyboard shortcut + key-event monitoring** (SidebarKeyMonitor): Local NSEvent monitor for raw key codes (kVK_* hardcoded). Yields when first responder is text editor or raw-key-handling custom view (terminal). Multi-pane fix checks ALL live editors. Callable from SwiftUI via NSViewRepresentable.

8. **Draggable section headers** (SidebarSectionHeaderLabel + PanelDragPayload): TSK-327 drag-to-snap system. Section headers are drag sources (draggable modifier). SidebarPanelKind.dragKind labels the source.

9. **Balanced cursor push/pop** (RowHoverButtonStyle, ResizableSectionDivider): NSCursor.push()/pop() state guarded by @State flag. Prevents unbalanced push leak if view disappears mid-hover. Mirrors resize-cursor pattern.

10. **Two-cap LRU eviction** (SourceControllerCache): Count cap + byte-budget cap. Evicts from LRU tail until both satisfied. Prevents huge-file stack-up. Default: 4 entries, 64 MiB.

---

## Anti-patterns / Regrets

1. **RecentChangesSection DEPRECATED**: Single-repo discovery replaced by multi-repo GitPanelSection. Artifacts kept for unit tests + RecentChangeRow. Pattern: when a panel scales beyond its original scope, create a successor + keep the old for tests.

2. **ScrollView + LazyVStack in accordion**: Nesting scrolls (outer accordion + inner section scroll) can cause layout confusion. BoundedAccordionScroll wrapper is the fix (P1 bounding), but ideally sections should inherit scroll context, not own independent ScrollViews.

3. **Model-wide observation republish avoidance is fragile**: Early codebase had single DocumentModel observation driving all re-bodies. TSK-615 revealed ~60 spurious re-body triggers per keystroke. Workaround: independent channels (git, sidebar, tabs, memory, source position). Better fix: SwiftUI's @Observable + macro in Swift 5.9+ (not yet adopted here).

4. **Divider layout audit discipline**: SearchAnywhereSection enforces zero inner Divider() calls via `SearchAnywhereSectionLayoutTests` (layout test that fails if Dividers appear). Pattern is sound but manually audited per file (not compiler-enforced).

5. **Warm-cache text-consistency guard is conservative**: WarmEditorWebViewCache drops the entry on text mismatch + rebuilds (safe, but expensive if cache thrash). For future: consider opportunistic re-seed (if mismatch is small delta, seed the delta into CM6 instead of full rebuild).

6. **Panel visibility heuristic scattered**: `filesPanelVisible`, `GitPanelSection.forcedShown`, `panelLayout.override(for:)` logic is split across SidebarView + model. Centralized `SidebarDataPresence` enum helps but logic still lives in multiple places.

7. **Fuzzy filter Mode B (global find) deferred**: TSK-666 global-find descendent index built but not wired. Visible-row mode A works; Mode B is 70% designed, 0% integrated. Anti-pattern: half-built features rot. Better: either finish Mode B or rip it out cleanly.

---

## Gotchas & Surprises

1. **NSCursor push/pop is a global stack**: Every push must balance with exactly one pop. AppKit can re-fire onHover(true) multiple times; `@State` guards prevent double-push. Disappear-while-hovered -> push strands on stack (deinit backstop needed). See RowHoverButtonStyle + ResizableSectionDivider.

2. **CodeMirror editor view hierarchy**: With MountedPanesLRU (TSK-108), a single key window can host SEVERAL mounted editor WebViews. Sidebar key monitor (`shouldYield`) must check ALL registered editors (liveWebViews), not just current() — otherwise Enter steals from the actually-focused editor (TSK-1280 miss).

3. **Warm WebView cache + fresh Tab.id churn**: Session switch creates new Tab.ids (snapshot persists file PATH, not id). Warm cache keyed by file path (stable). `lastHTML == html` gate in `updateNSView` prevents reload because the stashed state already matches. Works cross-session too (same file, same warm pane).

4. **@AppStorage Double → Binding<CGFloat> projection**: ResizableSectionDivider accepts Binding<CGFloat>, but @AppStorage holds Double. Adapter binding converts + clamps both ways. Epsilon-gated writes (0.5 pt delta) suppress jitter re-bodying the sidebar.

5. **Sidebar divider wiring complexity**: Three routes (pair drag, above-only, boundary). FILES has no height key (flex-fill); panels above have @AppStorage keys. Dividers sit between = complex presence logic. Wiring validation via SidebarDividerWiringTests.

6. **SourceScrollState bridges NSTextView to SwiftUI**: NSScrollView observations (.frame, scroll offset, line count) packed into published struct. Overlays (hover highlight, invisibles, gutter) read state to compute geometry. Works because NSView fires KVO + SwiftUI subscriSinkTriggers observable update.

7. **ToastCenter uses injectable clock**: Self-scheduled expiry via Task.sleep, but tests pass a fake clock (nanoseconds since boot). `sweep(now:)` prunes expired deterministically. No view-side timer — imperative edge case prevention.

8. **Secret detector scan task must live on concrete view**: If the scan @Task lives on a `Group { if shouldShow { ... } }` whose else is EmptyView, the task never fires on first clean render (EmptyView has no body lifecycle). Workaround: always-present Color.clear frame w/ .task on it.

9. **SettingsView NavigationStack + subpages**: Sub-pages (Plugins, LSP Diagnostics) are SettingsSubPage view wrappers. NavigationLink pushes them in-place w/ native back button. Never opens detached window. Fixes the owner-initiated detached-settings pain point.

10. **Sorted file-tree recency stripes + RWC-3 version bump**: FileRowView caches `FileTreeRecencyAttributes` per URL. FolderWatcher notifications trigger `sidebar.recencyVersion &+= 1` so the view re-loads the cache. Closing the gap where stripe was frozen "as of first render."

---

## Rebuild Notes

### Scope
Batch 4 covers ~7k LOC of **UI chrome, state wiring, and render-pane integrations**. Not user-facing content files (markdown/code editing) — those are Batch 5 (TextDisplayView core + Mermaid/HTML/CSV renderers).

### Approach

**Phased**:
1. **Phase 0 (infra)**: State channels (SourceViewChannel, git tracking, tab state). Warm caches (WebView + source LRU). Observation discipline.
2. **Phase 1 (sidebar)**: File tree + plugin sections. Resizable dividers + P1 bounding. Fuzzy filter (Mode A complete, Mode B skeleton).
3. **Phase 2 (chrome)**: StatusBar (path breadcrumb, git chip, vim-mode, memory). Toast + operation progress. Settings (flat layout, off-main LSP/plugins load).
4. **Phase 3 (panels)**: Script console, task runner, terminal command palette, structural search, SQL browser. All off-main + bounded output.
5. **Phase 4 (render surfaces)**: Markdown/HTML/CSV/SQLite panes. Warm caches. State-channel integration.

**Key decisions**:
- **State channels over model republish**: Every distinct data axis gets independent @Published + observation. Caret moves = StatusBar + source pane only. No sidebar cascade.
- **Canvas overlays for geometry**: SourceHoverHighlight, SourceInvisiblesView, SecretWarningBanner, ToastOverlayView all use Canvas siblings (not NSRulerView/NSViewRepresentable). Compositor-occlusion discipline by construction.
- **Warm caches for session survival**: Three separate LRU caches (markdown WebView, HTML WebView, editor WebView, source-view controller). Path-keyed. Take-once. Dual-cap (count + bytes for source, count only for WebViews).
- **Off-main for responsiveness**: All discovery (sidebar tree, git status, LSP queries, search, task discovery), all I/O (file ops, git subprocess, network) runs detached. Main-actor @Published result bump drives UI.
- **Resizable sections with sum-preserving drag**: Dividers between panels. Files (top, flex-fill) sits above accordion (bottom, bounded). FILES↔accordion boundary draggable. Epsilon-gated measurement suppresses jitter.
- **Plugin system design**: Registry-driven (read at render time, no observation). Sections + sidebar rows are two distinct capabilities. Install/remove lifecycle with validation-before-copy. Grant store + audit log.

**What NOT to do**:
- Don't merge all state into DocumentModel. Independent channels cut re-body load by ~90% (verified TSK-615 audit).
- Don't use NSRulerView or NSViewRepresentable for overlays. Compositor layer ordering is fragile (LESSONS.md TSK-488). Canvas + state-driven geometry is proven.
- Don't warm-cache without a text-consistency guard for editors (WarmEditorWebViewCache.parkedText). Risks stale text / masked edits.
- Don't leave Mode-B global-find half-built (TSK-666). Either finish it or remove it. Rot grows.
- Don't persist sidebar divider state without epsilon gating. UserDefaults flushes on every 0.1-pt jitter.

**Testing**:
- Host: Unit tests for state machines (LRU, balance, cursor push/pop, fuzzy matching, selection highlight, toast expiry). No view-layer tests (AppKit/SwiftUI not headless-testable).
- VM: LiveApp + pixel tests for render panes (Markdown/HTML/CSV/SQLite), sidebar accordion, status bar, toast/progress overlays, editor WebView warm-cache round-trips (build + run + screencap).
- Accessibility: VoiceOver announcements for toasts/operations, tab selection, sidebar navigation, editor caret position. AX element wrapping.

**Boundaries**:
- Batch 4 STOPS at render-pane data flow (panels know model, model doesn't know panels).
- Batch 5 will cover: editor buffer management, Markdown/HTML/CSV/Mermaid/image render logic, content-view switching.
- Batch 6: document model + tab lifecycle (currently split across DocumentModel + TabCoordinator).
