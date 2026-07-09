import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

/// Top-level app state. Owns the file history, sidebar root, bookmarks,
/// LSP plumbing, and bridging to the pure-logic `DocumentController`.
/// Tabs + their per-tab caches now live on `tabCoordinator` (Quality
/// #1, 2026-05-25) — see `TabCoordinator` for that surface. Most of
/// the legacy public API (`tabs`, `csvFilterStates`, `editorBuffers`,
/// `splitURL`, etc.) is retained on `DocumentModel` as forwarders so
/// existing call sites compile unchanged. Lives on the main actor.
@MainActor
public final class DocumentModel: ObservableObject {

    /// Tabs + per-tab caches. Views that only need tab state (TabBar,
    /// per-tab content tree) should observe this directly so that
    /// unrelated DocumentModel ticks (history changes, sidebar root
    /// rebinds, etc.) don't force them to re-render. Same pattern as
    /// `find` for find state.
    public let tabCoordinator = TabCoordinator()

    /// Editor mode lifecycle: CM6 save path, dirty tracking, close-
    /// prompt routing, external-edit conflict prompt, `editorGotoLine`,
    /// per-tab cursor + scroll persistence, pending-diagnostics fan-out,
    /// and the two editor-only prefs (`editorIndentation`,
    /// `saveEditorOnBlur`). Views that only need editor state observe
    /// this directly so that DocumentModel-side ticks (sidebar, history,
    /// recents, etc.) don't force editor re-renders, and inversely so
    /// editor mutations (keystrokes, cursor ticks, diagnostics pushes)
    /// don't republish DocumentModel.
    ///
    /// `editorBuffers` deliberately stays on `tabCoordinator` — the
    /// existing `cleanupAfterClose` fan-out drops them in lock-step
    /// with the other five per-tab dicts. EditorCoordinator forwards
    /// to TabCoordinator for buffer access.
    public let editor: EditorCoordinator

    /// On-disk Local History store (TSK-301/1103). Snapshots saved editor
    /// content per the owner policy (`LocalHistoryPolicy`) so the unified
    /// version viewer can list/view/diff/restore earlier revisions. One store
    /// for the app; keyed by absolute file path. Default location:
    /// `~/Library/Application Support/MarkdownViewer/LocalHistory/`.
    public let localHistoryStore: LocalHistoryStore

    /// Multi-repo git registry: demand resolution + per-root watchers +
    /// focus tracking. A sibling coordinator (like `editor`) that drives
    /// `trackedRepos` (the channel) and the off-main store. Views NEVER
    /// observe `repoFocus`; they observe `trackedRepos` (the version
    /// tick). See `RepoFocusTracker` / `TrackedReposChannel`.
    public let repoFocus: RepoFocusTracker

    /// THE published observation surface for git status / repo-root
    /// classification across all tracked repos. SidebarView / GitPanelView
    /// observe THIS directly via `@ObservedObject` — its `version` ticks
    /// on real status change, scoped so it never republishes
    /// DocumentModel. Convenience forwarder to `repoFocus.channel`.
    public var trackedRepos: TrackedReposChannel { repoFocus.channel }

    // Lifecycle wiring — see init for the side-effect closures we
    // hand to `editor` so its save / cursor-mirror / reload paths
    // can drive DocumentModel state without holding a strong reference.

    /// Backwards-compat forwarder. New code should read
    /// `tabCoordinator.tabs` directly.
    public var tabs: TabsState { tabCoordinator.tabs }

    /// Backwards-compat forwarder. New code should read
    /// `tabCoordinator.openTabURLs` directly.
    public var openTabURLs: Set<URL> { tabCoordinator.openTabURLs }

    // Per-tab dict forwarders (csvFilterStates / csvFilterState / setCsvFilterState /
    // hexBytesPerRow / hexWidth / setHexWidth) + the CSVFilterState typealias →
    // DocumentModel+PerTabDicts.swift (TSK-1110 SRP slice). clearCsvFilterState is
    // in DocumentModel+Split.swift (TSK-308).
    @Published public private(set) var windowTitle: String = "TextView"

    /// Perf Fix#1 (TSK-108): the bounded set of tab ids whose content panes
    /// stay MOUNTED in the content `ZStack` even while inactive — so
    /// switching back to a tab does NOT tear down + reload its `WKWebView`
    /// (rendered-markdown / CM6 editor), the dominant tab-switch freeze.
    /// MRU-ordered, capacity-bounded; the active tab is always index 0.
    /// Driven SOLELY from `updateDerived()` (the universal post-selection /
    /// -close / -session hook) via `noteActiveTabForRetention()`, so every
    /// open / select / close / session-switch path keeps it correct without
    /// per-callsite wiring. `@Published` (not a narrow store) so `ContentView`
    /// observes it directly — avoids the dead-toggle observation-timing bug
    /// (design: `docs/research/perf-fix1-view-retention.md`, RISK #1).
    @Published public private(set) var mountedPanes = MountedPanesLRU(capacity: 4)

    /// TSK-1436/1479: where user-visible feedback (paste announcements,
    /// operation failures) surfaces. Defaults to the app-wide center; tests
    /// inject a private one to assert postings without global state.
    var toasts: ToastCenter = .shared

    /// The tabs whose panes are currently mounted, MRU-first (active first).
    /// Compact-maps `mountedPanes.ids` against the live tab list so an id for
    /// a tab closed out-of-band is simply not rendered (its pane unmounts).
    /// `ContentView.content` renders one `ZStack` pane per entry.
    public var mountedTabs: [ViewerCore.Tab] {
        mountedPanes.ids.compactMap { id in tabs.tabs.first { $0.id == id } }
    }

    // internal(set): DocumentModel+Bookmarks' pruneMissingRecents refreshes it.
    @Published public internal(set) var recents: [HistoryEntry] = []

    /// Newest-first recents for the empty-tab landing screen (TSK-745). The
    /// sidebar's Recent section scrolls the full list; the welcome screen shows
    /// only the top few so it stays a glanceable launcher, not a wall.
    nonisolated public static let landingRecentsCap = 8
    /// Pure cap (host-testable without populating the live history store).
    nonisolated public static func landingRecents(from all: [HistoryEntry]) -> [HistoryEntry] {
        Array(all.prefix(landingRecentsCap))
    }
    public var landingRecents: [HistoryEntry] { Self.landingRecents(from: recents) }

    @Published public private(set) var bookmarks: [BookmarkEntry] = []

    /// Set when the last `openBookmark(_:)` was REFUSED because the bookmark's
    /// target no longer matches the identity captured at add time — a TOCTOU
    /// symlink/dir swap or a deletion (TSK-309). A user-facing message the
    /// sidebar can surface as an inline warning; the corresponding file is NOT
    /// opened. Cleared on the next successful bookmark open.
    @Published public private(set) var lastBookmarkOpenWarning: String? = nil
    /// Width of the sidebar in points. Mutated frequently during a drag —
    /// see `setSidebarWidthLive` (no persistence) vs `setSidebarWidth`
    /// (persists immediately).
    @Published public var sidebarWidth: Double

    /// Zoom multiplier applied to both the rendered view (`WKWebView.pageZoom`)
    /// and the source view (font-size). 1.0 = system default.
    @Published public var zoom: Double {
        didSet { preferences.zoom = zoom }
    }

    /// Absolute base point size for editor/source CONTENT text (TSK-358). The
    /// on-screen content size is `effectiveContentFontSize` = this × `zoom`, so
    /// the zoom slider remains a multiplier and this sets the un-zoomed baseline.
    /// Persisted via PreferencesStore; default 13 = the historical content base.
    @Published public var contentFontSize: Double {
        didSet { preferences.contentFontSize = contentFontSize }
    }

    /// Source-view word-wrap toggle. When true, lines wrap at the
    /// viewport edge; when false (default), long lines scroll
    /// horizontally — the conventional code-viewer behavior. Persisted
    /// to UserDefaults via PreferencesStore.
    @Published public var sourceWordWrap: Bool {
        didSet { preferences.sourceWordWrap = sourceWordWrap }
    }
    public func toggleSourceWordWrap() { sourceWordWrap.toggle() }

    /// TSK-1105: surface the sessions-enabled pref (TSK-264 — drives
    /// RootContextFactory: multi-session vs single-root) as a published model
    /// knob so the Settings toggle binds like the others. Default ON.
    @Published public var sessionsEnabled: Bool {
        didSet { preferences.sessionsEnabled = sessionsEnabled }
    }

    /// Preview mode's metadata side panel (file info, image dimensions,
    /// SQLite table/row counts). It used to render unconditionally with
    /// no dismiss affordance (TSK-608); the BottomAttributesBar "Info"
    /// toggle drives this. Persisted; default ON (prior behavior).
    @Published public var showPreviewMetadataPanel: Bool {
        didSet { preferences.previewMetadataVisible = showPreviewMetadataPanel }
    }
    /// True while the in-place image editor is active (TSK-1302) — ContentView suppresses the side
    /// file-property pane so the full-width editor isn't crowded by it. Transient (not persisted).
    @Published public var isEditingImage = false

    /// TSK-698 — the Script Console panel (JQ-style query/transform over the active
    /// buffer). Transient (not persisted); driven by `openScriptConsole()`.
    @Published public var showScriptConsole = false
    /// The Script Console's controller, seeded from the active buffer when opened.
    @Published public var scriptConsoleVM: ScriptConsoleViewModel?

    /// TSK-1161 — the Structural Search panel (AST query over the active buffer). Transient;
    /// driven by `openStructuralSearch()`.
    @Published public var showStructuralSearch = false
    /// The Structural Search controller, seeded from the active buffer + language when opened.
    @Published public var structuralSearchVM: StructuralSearchViewModel?

    /// TSK-1160 — the Task Runner panel (discover + run-with-captured-output). Transient;
    /// driven by `openTaskRunner()`.
    @Published public var showTaskRunner = false
    /// The Task Runner controller, seeded by discovering tasks from the active project root.
    @Published public var taskRunnerVM: TaskRunnerViewModel?

    /// TSK-1176 — the Terminal Command Palette (search history + favorites). Transient;
    /// driven by `openTerminalCommandPalette()`.
    @Published public var showTerminalCommandPalette = false
    /// The palette controller, seeded over the live favorites + command history.
    @Published public var terminalCommandPaletteVM: TerminalCommandPaletteViewModel?

    /// TSK-1475 — the terminal-favorites management editor (rename / reorder /
    /// delete). Transient; driven by `openTerminalFavoritesEditor()`.
    @Published public var showTerminalFavoritesEditor = false
    /// The editor controller, created fresh over the live favorites store on open.
    @Published public var terminalFavoritesEditorVM: TerminalFavoritesEditorModel?

    /// TSK-1500 — the "Recover Deleted File" picker sheet (deleted-but-has-history
    /// files). Transient; driven by the "Recover Deleted File…" menu item.
    @Published public var showRecoverDeletedFile = false

    /// TSK-1166 — the active passive-watcher disk-conflict, surfaced as a non-modal
    /// `DiskConflictBanner` above the editor (vs the blocking NSAlert the deliberate
    /// `refreshTab` path still uses). `nil` = no conflict. Set by the file-watcher
    /// tick when a dirty buffer's file changed on disk; cleared by `resolveDiskConflict`.
    @Published public var activeDiskConflict: DiskConflictBannerInfo?

    /// TSK-1325 — the Image Convert panel (pick target format + quality → new tab). Transient;
    /// driven by `openConvertImage()`.
    @Published public var showConvertImage = false
    /// The convert controller, seeded with the active image tab's URL when opened.
    @Published public var convertImageVM: ConvertImageViewModel?

    /// TSK-1323/1324 — the Audio Extract/Convert panel. Transient; driven by
    /// `openExtractAudio()` (from a video tab) or `openConvertAudio()` (from an audio tab).
    @Published public var showAudioConvert = false
    /// The audio extract/convert controller, seeded with the active media tab's URL when opened.
    @Published public var audioConvertVM: AudioConvertViewModel?

    /// Terminal ANSI colour theme name (TSK-1312) — drives `TerminalPalette`'s
    /// 16-colour palette. Persisted; default "Default" (the muted shipped palette).
    /// "Classic (xterm)" gives standard vivid colours (closer to what CLI tools like
    /// claude code expect). Setting it rebuilds the palette; open terminals pick the new
    /// colours up on their next redraw. Bound by the Settings "Colour scheme" picker.
    @Published public var terminalColorThemeName: String {
        didSet {
            preferences.terminalColorThemeName = terminalColorThemeName
            TerminalPalette.activeThemeName = terminalColorThemeName
        }
    }

    /// When on, NSLayoutManager renders dots for spaces, arrows for
    /// tabs, pilcrows for paragraph breaks. Persisted.
    @Published public var showInvisibleChars: Bool {
        didSet { preferences.showInvisibleChars = showInvisibleChars }
    }
    public func toggleShowInvisibleChars() { showInvisibleChars.toggle() }

    /// Vim mode in the CM6 editor (opt-in; owner-approved 2026-06-15). Drives
    /// `CodeMirrorEditorView(vimMode:)` → JS `setVimMode` (vimCompartment).
    /// Off by default; toggled via View → Vim Mode. Persisted.
    @Published public var vimModeEnabled: Bool {
        didSet { preferences.vimModeEnabled = vimModeEnabled }
    }
    public func toggleVimMode() { vimModeEnabled.toggle() }

    /// TSK-936 — read-only editing toggle (View → Toggle Read-Only). When on, the
    /// CM6 editor rejects edits via its `readOnly` facet. Session-level (NOT
    /// persisted — a deliberate "lock this session" guard, not a sticky default).
    /// Drives `CodeMirrorEditorView(readOnly:)`.
    @Published public var isEditorReadOnly: Bool = false
    public func toggleEditorReadOnly() { isEditorReadOnly.toggle() }

    /// Show the scaled document overview / minimap (top-right) for markdown
    /// source views (TSK-305). On by default; toggled via View → Markdown
    /// Overview. Persisted.
    @Published public var showMarkdownOverview: Bool {
        didSet { preferences.showMarkdownOverview = showMarkdownOverview }
    }
    public func toggleMarkdownOverview() { showMarkdownOverview.toggle() }

    /// The live vim mode reported by the editor ("NORMAL"/"INSERT"/"VISUAL…"),
    /// shown in the footer status bar. Empty when vim mode is off. Transient
    /// (not persisted) — driven by `CodeMirrorEditorView.onVimModeChange`.
    @Published public var editorVimMode: String = ""
    public func setEditorVimMode(_ raw: String) {
        let next = raw.isEmpty ? "" : raw.uppercased()
        if next != editorVimMode { editorVimMode = next }
    }

    /// TSK-259 — the user-selected monospace family for the text
    /// surfaces (nil = system). Write-through to PreferencesStore;
    /// resolution is fail-safe in FontPreference.resolvedFont.
    @Published public var sourceFontName: String? {
        didSet { preferences.sourceFontName = sourceFontName }
    }

    /// When on, the CM6 editor draws vertical indentation guide lines
    /// (`CodeMirrorEditorView(indentGuides:)` → JS `setIndentGuides`).
    /// Persisted; off by default (opt-in, TSK-487) so the editor's
    /// default look is unchanged until the user enables it in Settings.
    @Published public var editorIndentGuides: Bool {
        didSet { preferences.editorIndentGuides = editorIndentGuides }
    }
    public func toggleEditorIndentGuides() { editorIndentGuides.toggle() }

    /// User-provided path to an `ffmpeg` executable for MP3 audio export
    /// (Settings → Audio). `nil`/empty ⇒ auto-discover on PATH + common
    /// locations via `FFmpegLocator`; if neither resolves, MP3 export is
    /// disabled. Proxies `PreferencesStore.audioFFmpegPath`; consumed by
    /// `AudioExporter.encode(…, ffmpegOverride:)` (TSK-528 / TSK-535).
    @Published public var audioFFmpegPath: String? {
        didSet { preferences.audioFFmpegPath = audioFFmpegPath }
    }

    /// Helper for view code: scale a base font size by the unified
    /// zoom factor. Used by sidebar / tabs / status bar / mode bar so
    /// chrome grows with the same Cmd++/Cmd+− / Settings slider that
    /// drives document content. Historically backed by a separate
    /// `uiScale` preference; collapsed onto `zoom` so users no longer
    /// have to keep two sliders in sync. Migration of legacy
    /// `uiScale` defaults is handled in `PreferencesStore.zoom`.
    public func uiSize(_ base: CGFloat) -> CGFloat { base * CGFloat(zoom) }

    /// On-screen point size for editor/source CONTENT text (TSK-358):
    /// `contentFontSize` (absolute base) × `zoom`. The editor (CM6), source text,
    /// and source gutter all bind to this so they stay in lock-step.
    public var effectiveContentFontSize: CGFloat {
        ContentFontSizing.effective(baseSize: contentFontSize, zoom: zoom)
    }

    /// High-frequency source-view view-local state (live scroll offset,
    /// caret/selection, scroll-to-line request). A sibling channel like
    /// `editor` / `find` — its `objectWillChange` is deliberately NOT
    /// forwarded into `DocumentModel.objectWillChange`, so a scroll tick or
    /// caret move re-bodies ONLY the views that observe it directly
    /// (`SourceModeView`, `StatusBar`) and never the sidebar / content tree.
    /// See `SourceViewChannel` for the full rationale (the republish cascade).
    public let sourceView = SourceViewChannel()

    /// Forwarder. Latest scroll state from the source view, published by
    /// `TextDisplayView.onScrollChange`. Drives the SwiftUI gutter
    /// (`SourceGutterView`). Lives on `sourceView` (the narrow channel) so it
    /// doesn't republish DocumentModel; views read `model.sourceView` directly.
    public var sourceScrollState: SourceScrollState {
        get { sourceView.sourceScrollState }
        set { sourceView.sourceScrollState = newValue }
    }
    /// Forwarder. Caret position published by TextDisplayView. Status bar
    /// reads this to render "Ln 12, Col 4". Reset to .zero on tab switch.
    public var sourceSelection: SourceSelection {
        get { sourceView.sourceSelection }
        set { sourceView.sourceSelection = newValue }
    }
    @Published public var isPalettePresented: Bool = false
    /// "Go to file / folder" (Finder-style ⇧⌘G) prompt visibility.
    /// Owned here (not at ContentView level) so the menu item + script
    /// runner can toggle it without prop-drilling. See `GoToPathPrompt`.
    @Published public var isGoToPathPresented: Bool = false
    /// The shared tool-results panel's current result set (TSK-1434) — non-nil
    /// presents the panel (Check Links / Lint / Doc Stats / CSV Summary route
    /// here instead of modal alerts). See `DocumentModel+ToolResults`.
    @Published public var toolResults: ToolResults?
    /// LSP "Rename Symbol…" prompt presentation (TSK-640). Owned here so the
    /// command/menu + script runner toggle it without prop-drilling, mirroring
    /// `isGoToPathPresented`. The prompt's submit runs the host-tested
    /// `renameActiveEditorSymbolViaLSP`. The field seeds from `lspRenamePrefill`.
    @Published public var isLSPRenamePromptPresented: Bool = false
    /// Initial text for the rename field — empty for now (the user types the
    /// new name); a prepareRename placeholder is a follow-up.
    /// `internal(set)`: the rename-prompt methods in DocumentModel+LSPEditorCommands.swift
    /// (TSK-1110 SRP slice) seed/clear this cross-file.
    public internal(set) var lspRenamePrefill: String = ""

    /// LSP "Code Actions…" picker (TSK-640). The command/menu opens it; it
    /// fetches actions at the cursor (async), presents the list, and applies the
    /// pick via the host-tested applyCodeAction. Mirrors the rename prompt with
    /// an async fetch state.
    public enum CodeActionPickerState: Equatable {
        case hidden
        case loading
        case presenting([LSPCodeAction])
    }
    // internal(set) / internal: the code-action commands in
    // DocumentModel+LSPEditorCommands.swift (TSK-1110 SRP slice) drive this picker
    // state + the generation counter cross-file.
    @Published public internal(set) var codeActionPicker: CodeActionPickerState = .hidden
    /// Bumped on every show/dismiss so a slow fetch landing AFTER the user
    /// dismissed (or re-opened) is dropped rather than popping a stale list.
    var codeActionPickerGeneration = 0
    /// Last error produced by the most recent `commitGoToPath` call.
    /// Empty string when the last commit succeeded or no commit has
    /// happened yet. Surfaced to the diagnostic dump so VM UI tests can
    /// assert on validation outcomes without typing into the prompt's
    /// local `@State` editor (which the script runner can't reach). The
    /// SwiftUI prompt continues to drive its own inline error label off
    /// its own @State; this property is the model-side mirror that the
    /// script-verb path populates.
    @Published public var lastGoToError: String = ""
    public let sidebar: SidebarModel

    /// Shoulder-rail layout (per-panel edge + explicit-visibility
    /// override). Constructor-injected like `sidebar` — a `let`, owned
    /// here but observed DIRECTLY by the rails / sidebar / ContentView
    /// (see the PERF #1 audit note in `init`). NOT forwarded into
    /// `DocumentModel.objectWillChange`.
    public let panelLayout: PanelLayoutStore

    /// Bottom terminal pane (UX-D / #226). Owns open/closed + height +
    /// the lazily-spawned shell. Observed DIRECTLY by `ContentView` + the
    /// left-rail terminal toggle (same narrow pattern as `panelLayout`);
    /// NOT forwarded into `DocumentModel.objectWillChange`, so toggling
    /// the terminal or its per-frame output never republishes the content
    /// tree (PERF #1).
    public let terminalPane: TerminalPaneStore

    let controller: DocumentController  // internal: used by SRP-slice extensions (TSK-1110)
    public let history: HistoryStore
    /// Persisted history for the Go-to-path prompt. Small (cap 10),
    /// separate from `history` so typing into the prompt doesn't churn
    /// the global recents list.
    public let goToPathHistory: GoToPathHistoryStore
    /// TSK-1017: durable per-file scroll + zoom memory. Backs the in-session
    /// `Tab.scrollTopLine` (UX-K #231) with a disk store keyed by FILE
    /// IDENTITY, so a file reopened in a later session/relaunch returns to the
    /// position it was left at. Written only when the user actually scrolled
    /// or zoomed since restore (see `ScrollMemoryStore.shouldPersist`).
    public let scrollMemory: ScrollMemoryStore
    public let bookmarksStore: BookmarksStore
    /// User-defined snippets merged over the built-ins (TSK-705). Read by the
    /// Insert-Snippet menu + `insertSnippet`.
    public let snippetStore: SnippetStore
    /// Per-file view-mode LOCKS (TSK-811). When the user locks the chosen lens
    /// for a file, reopening it re-applies that mode. Distinct from the
    /// per-CATEGORY `viewModeDefaults` (TSK-671): this pins one file (or one
    /// extension). Read on open (`resolveOpenMode`) and by the ModeBar lock icon.
    public let viewModeLocks: ViewModeLockStore
    let preferences: PreferencesStore  // internal: used by SRP-slice extensions (TSK-1110)
    /// The app's preference store, exposed for the Settings export/import menu
    /// actions (TSK-681) which serialize/apply a `SettingsSnapshot`.
    public var preferencesStore: PreferencesStore { preferences }
    private var fileWatcher: FileWatcher?
    var watchedURL: URL?  // internal: used by SRP-slice extensions (TSK-1110)
    /// TSK-929: the watched file's inode, captured at watch-start so that if it
    /// vanishes from its path we can find where it was renamed to (same inode,
    /// new name in the same folder) and follow it instead of "file not found".
    private var watchedInode: Int?

    /// Shared LSP pool — one server per `(language, workspaceRoot)`.
    /// Lazy: the actor is cheap to allocate; servers spawn on first
    /// request and reap when idle. Public so the sidebar's outline
    /// section + the diagnostics panel can talk to the same pool.
    public let lspPool: LSPPool

    /// Per-(file URL) LSP diagnostics, populated by server-pushed
    /// `textDocument/publishDiagnostics` notifications. Wired up to
    /// the pool's onDiagnostics callback in `bootstrapLSP()`.
    public let lspDiagnostics: LSPDiagnosticsStore = LSPDiagnosticsStore()

    /// Single shared store for the unified References / workspace-symbol
    /// panel. Read by the sidebar's `LSPNavigationPanel`, written by
    /// the right-click context menu (refs) and the panel's search field
    /// (workspace symbols).
    public let lspNavigation: LSPNavigationStore = LSPNavigationStore()

    /// Hook the pool's diagnostics + (future) other server-push
    /// callbacks. Called once at startup. Idempotent — setOnDiagnostics
    /// just replaces the handler.
    public func bootstrapLSP() {
        let store = self.lspDiagnostics
        // Capture self weakly through a sendable box: the outer Task
        // hands a weak ref to the inner setOnDiagnostics callback,
        // which re-enters MainActor to safely call back into self.
        let weakSelfBox = WeakModelBox(self)
        Task {
            await self.lspPool.setOnDiagnostics { url, diags in
                Task { @MainActor in
                    store.replace(url: url, with: diags)
                    // Also push translated diagnostics into the CM6
                    // editor view (squiggles + lint gutter). No-op for
                    // URLs that don't currently have an editor tab.
                    weakSelfBox.value?.setEditorDiagnostics(diags, forURL: url)
                }
            }
        }
    }

    /// Set by the app delegate at startup to route folder context-menu
    /// "Open in New Session" requests through the sessions coordinator.
    /// `DocumentModel` doesn't import `SessionsAppCoordinator` directly
    /// — the closure keeps the dependency one-way. nil during tests
    /// (and the UI hides the menu item when nil).
    public var openFolderInNewSession: ((URL) -> Void)?

    public init(
        controller: DocumentController = DocumentController(),
        history: HistoryStore = HistoryStore(storeURL: HistoryStore.defaultStoreURL()),
        goToPathHistory: GoToPathHistoryStore = GoToPathHistoryStore(
            storeURL: GoToPathHistoryStore.defaultStoreURL()
        ),
        scrollMemory: ScrollMemoryStore = ScrollMemoryStore(
            storeURL: ScrollMemoryStore.defaultStoreURL()
        ),
        bookmarks: BookmarksStore = BookmarksStore(storeURL: BookmarksStore.defaultStoreURL()),
        snippets: SnippetStore = SnippetStore(storeURL: SnippetStore.defaultStoreURL()),
        viewModeLocks: ViewModeLockStore = ViewModeLockStore(
            storeURL: ViewModeLockStore.defaultStoreURL()
        ),
        sidebar: SidebarModel = SidebarModel(),
        preferences: PreferencesStore = PreferencesStore(),
        // On-disk Local History store (TSK-301/1103). Injectable so tests can
        // point it at a temp dir; production uses the default App Support path.
        // Production wires the toggle (TSK-1103 merge): the store reads
        // LocalHistoryPolicy.isEnabled live so a "Local History off" pref takes
        // effect. Tests inject their own (toggle-wired) store.
        localHistory: LocalHistoryStore = LocalHistoryStore(
            isEnabled: { LocalHistoryPolicy.isEnabled(defaults: .standard) }),
        // Injectable for tests (TSK-627: fake-server registry e2e). The
        // default is the production pool over LSPLanguageRegistry.default.
        lspPool: LSPPool = LSPPool()
    ) {
        self.lspPool = lspPool
        self.localHistoryStore = localHistory
        self.controller = controller
        self.history = history
        self.goToPathHistory = goToPathHistory
        self.scrollMemory = scrollMemory
        self.bookmarksStore = bookmarks
        self.snippetStore = snippets
        self.viewModeLocks = viewModeLocks
        self.sidebar = sidebar
        self.preferences = preferences
        // Shoulder-rail layout shares the SAME defaults instance the
        // injected PreferencesStore uses (tests inject a throwaway
        // suite; production uses .standard). Loaded from the two
        // comma-joined keys (panelEdges / panelOverrides) — empty on a
        // fresh install ⇒ all panels on .left, all overrides .auto ⇒
        // visibility === data-presence, today's behavior unchanged.
        self.panelLayout = PanelLayoutStore(defaults: preferences.defaults)
        // Bottom terminal pane (#226). Same value-type-backed persistence
        // (its own UserDefaults keys via TerminalPaneLayout). Lazily
        // spawns the shell only when first opened.
        self.terminalPane = TerminalPaneStore(defaults: preferences.defaults)
        self.recents = history.recent()
        self.bookmarks = bookmarks.all()
        self.sidebarWidth = preferences.sidebarWidth
        self.zoom = preferences.zoom
        self.contentFontSize = preferences.contentFontSize
        self.sourceWordWrap = preferences.sourceWordWrap
        self.sessionsEnabled = preferences.sessionsEnabled
        self.showPreviewMetadataPanel = preferences.previewMetadataVisible
        self.terminalColorThemeName = preferences.terminalColorThemeName
        TerminalPalette.activeThemeName = preferences.terminalColorThemeName   // apply at launch (didSet doesn't fire in init)
        self.showInvisibleChars = preferences.showInvisibleChars
        self.vimModeEnabled = preferences.vimModeEnabled
        self.showMarkdownOverview = preferences.showMarkdownOverview
        self.sourceFontName = preferences.sourceFontName
        self.editorIndentGuides = preferences.editorIndentGuides
        self.audioFFmpegPath = preferences.audioFFmpegPath
        // Restore the persisted theme override (TSK-101). An unknown/stale raw
        // (e.g. a renamed theme) maps to nil = Follow System, never a crash.
        self.themeOverride = preferences.themeOverrideRaw.flatMap(SyntaxTheme.Name.init(rawValue:))
        // TSK-641 stage 4: seed the chrome surfaces from the PERSISTED theme
        // selection (the property's didSet doesn't fire for the initial
        // value; resolved straight from the store — self isn't fully
        // initialized yet). nil selection = system-native chrome.
        ChromeTheme.current = ThemeStore.shared.selectedID
            .flatMap { id in ThemeStore.shared.all().first { $0.id == id } }
            .map { ChromeColors(from: $0) }
        // Construct the editor coordinator BEFORE wiring its side-
        // effect closures so the closures can capture `self` weakly.
        // EditorCoordinator registers a close-hook on TabCoordinator
        // in its init — must happen before any tab can close.
        // TSK-1567: route the assist-toggle persistence through the model's own
        // preferences store (a hermetic suite under test) so parallel suites don't
        // race on `UserDefaults.standard`.
        self.editor = EditorCoordinator(
            tabCoordinator: tabCoordinator, assistDefaults: preferences.defaults)
        // Single Local-History store (TSK-1103 merge): the editor save-path
        // snapshot hook (EditorCoordinator.saveEditor) and the unified version
        // viewer must read/write the SAME instance, so the viewer sees exactly
        // what a save records.
        self.editor.localHistoryStore = localHistory
        // Multi-repo git registry. A sibling coordinator that subscribes
        // to tabCoordinator/sidebar @Published streams (the views already
        // observe those) and drives the off-main store + channel. Its
        // republish path is `trackedRepos.version`, entirely separate
        // from DocumentModel.objectWillChange. Constructed here (before
        // the self-capturing editor closures) so all stored properties
        // are initialized first.
        self.repoFocus = RepoFocusTracker(
            tabCoordinator: tabCoordinator,
            sidebar: sidebar
        )
        let tc = tabCoordinator
        let weakSelfBox2 = WeakModelBox(self)
        editor.tabsSnapshot = { [tc] in tc.tabs.tabs }
        editor.activeTabIDSnapshot = { [tc] in tc.tabs.selected?.id }
        editor.onReplaceTab = { [tc] idx, tab in tc.replace(at: idx, with: tab) }
        editor.onCursorMirrorToStatusBar = { [weakSelfBox2] pos in
            // Status bar reads `sourceSelection` for both source and
            // editor modes; mirror so the L:C readout works uniformly.
            weakSelfBox2.value?.sourceSelection = SourceSelection(
                line: pos.line, column: pos.column, length: 0
            )
        }
        editor.onPauseFileWatcher = { [weakSelfBox2] in
            weakSelfBox2.value?.pauseFileWatcher()
        }
        editor.watchedURLSnapshot = { [weakSelfBox2] in
            weakSelfBox2.value?.watchedURL
        }
        editor.onResumeFileWatcherIfApplicable = { [weakSelfBox2] wasURL in
            guard let self2 = weakSelfBox2.value else { return }
            if wasURL == self2.currentURL { self2.startWatchingCurrentFile() }
        }
        editor.onReloadFromDisk = { [weakSelfBox2] url, index in
            weakSelfBox2.value?.reload(url: url, at: index)
        }
        editor.onDidSaveToDisk = { [weakSelfBox2] url, text in
            // textDocument/didSave (TSK-464): a notification, not a request —
            // fire-and-forget is the correct shape. The pool no-ops unless the
            // file has a live LSP session, so this never spawns a server.
            guard let pool = weakSelfBox2.value?.lspPool else { return }
            Task { try? await pool.didSave(fileURL: url, text: text) }
        }
        // Seed sidebar visibility from prefs. We DON'T force visible if
        // no folder is open — sidebar without a root is empty by design.
        self.sidebar.isVisible = preferences.sidebarVisible
        // Persist any subsequent toggle.
        self.sidebar.$isVisible
            .dropFirst()  // ignore the seed assignment above
            .sink { [weak self] visible in
                self?.preferences.sidebarVisible = visible
            }
            .store(in: &cancellables)

        // PERF #1 (2026-05-25): the previous build forwarded every
        // `sidebar.objectWillChange` tick into `DocumentModel.
        // objectWillChange`. That works for visibility but cascades
        // every sidebar mutation (hover-driven `selectedURL`, the
        // 60s git poll, the FolderWatcher debounce, expand/collapse,
        // sort-mode toggles) into a re-body of every view observing
        // DocumentModel — including the content tree that runs
        // `renderedHTML`, `highlightRuns`, gutter math, etc. The
        // fan-out was the single largest contributor to perceived
        // sidebar-driven lag.
        //
        // Fix is the textbook narrow-observation pattern: views
        // that depend on sidebar state observe `sidebar` directly
        // via `@ObservedObject var sidebar: SidebarModel`. Views
        // that only need DocumentModel state stop paying sidebar
        // ticks entirely.
        //
        // Audit (every view that reads `model.sidebar.<published>`
        // from a body or a Combine-publishing `.onChange`):
        //   - ContentView (sidebar.isVisible)
        //   - ClaudeTimelineSection (sidebar.rootURL)
        //   - RecentChangesSection (sidebar.rootURL)
        //   - Git/GitPanelSection (sidebar.rootURL)
        //   - CrossSearchPanel (sidebar.rootURL, multi-site body)
        //   - SearchAnywhereSection (sidebar.rootURL, multi-site)
        //   - SettingsView (sidebar.isVisible Toggle binding)
        //   - SidebarView / FileRowContextMenu — already observes
        //     `sidebar` directly; unchanged.
        // Write-only call sites (no observation needed):
        //   - WalkthroughPlayerImpl (sets `isVisible`)
        //   - Sessions/SessionState (setRoot)
        //
        // Shoulder rails (2026-05-30): `panelLayout` (PanelLayoutStore)
        // follows the SAME narrow-observation rule. It is a `let` owned
        // here but its `objectWillChange` is NOT forwarded into
        // DocumentModel — the rails / SidebarView / ContentView observe
        // `model.panelLayout` directly via `@ObservedObject`. Forwarding
        // it would reintroduce the PERF #1 republish storm (a rail
        // toggle would re-body the whole content tree); leaving it
        // observed-by-nobody would reintroduce the `setCurrentViewMode`
        // dead-toggle (the rail/sidebar would never re-body on a
        // toggle). Pinned by `PanelLayoutRepublishInvariantTests`.
    }

    private var cancellables: Set<AnyCancellable> = []

    // zoomIn / zoomOut / zoomReset extracted to DocumentModel+Zoom.swift (TSK-1110).

    public func openFolder(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        sidebar.setRoot(resolved)
        history.record(url: resolved, kind: .folder)
        recents = history.recent()
        preferences.lastFolderURL = resolved
    }

    /// A6: single dispatch point for "open this URL" — checks whether it's a
    /// folder or a file and routes appropriately. Used by drag-drop,
    /// application(_:open:) and the argv handler. If the path doesn't exist
    /// we still call `open(url:)` so the user sees the "File not found"
    /// error tab rather than a silent no-op.
    // revealInSidebar(_:) → DocumentModel+SidebarReveal.swift (TSK-1110 SRP slice).
    // The isSidebarLocked / sidebarFollowsActiveTab state + toggles below stay.

    /// Whether the sidebar root is locked. When true, `revealInSidebar`
    /// and other auto-navigation hooks won't change the root.
    @Published public var isSidebarLocked: Bool = false

    public func toggleSidebarLock() { isSidebarLocked.toggle() }

    /// "Pin" / follow-active-tab (item9). When on, switching the active tab
    /// auto-reveals its file in the sidebar — but SELECT + EXPAND ONLY, never
    /// re-rooting. So following a tab whose file lives outside the current
    /// root is a no-op (no jarring root jump); a tab inside the root selects
    /// and expands its ancestors. Global flag (per-session variant rides
    /// session independence later).
    @Published public var sidebarFollowsActiveTab: Bool = false

    public func toggleSidebarFollowsActiveTab() { sidebarFollowsActiveTab.toggle() }

    // followActiveTabIfNeeded() / revealInSidebarWithinRoot(_:) →
    // DocumentModel+SidebarReveal.swift (TSK-1110 SRP slice). selectTab (stays)
    // calls followActiveTabIfNeeded cross-file.

    public func openPath(_ url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
           isDir.boolValue {
            openFolder(url)
        } else {
            open(url: url)
        }
    }

    /// TSK-329 — create a new empty file in `directory` (atomic + TOCTOU-
    /// safe via `NewFileCreator`: O_EXCL|O_NOFOLLOW, non-colliding name),
    /// reveal it in the tree, select it, and open it for editing in one
    /// step. Returns the created URL, or nil on failure (logged; a sandbox
    /// denial or an exhausted name cap must not crash the menu action).
    /// The single entry point for File→New and the folder right-click →
    /// New File.
    @discardableResult
    public func createNewFile(in directory: URL, baseName: String = "Untitled.txt") -> URL? {
        do {
            let url = try NewFileCreator.create(in: directory, baseName: baseName)
            // Show it immediately (don't wait for the FSEvents coalesce) — but
            // ONLY when the dir is in the sidebar tree. The landing fallback
            // creates in the temp-scratch dir (no folder open); enumerating that
            // (huge /var/folders) would hang + pollute the sidebar (TSK-1294).
            if sidebar.contains(directory) {
                sidebar.reloadChildren(of: directory)
                sidebar.setSelected(url)
            }
            open(url: url)
            return url
        } catch {
            Obs.shared.emit(.warn, "files",
                            "New File failed: \(String(describing: error))")
            return nil
        }
    }

    /// TSK-747 — create a new file of a chosen `type` (txt/md/csv/json) in
    /// `directory`. Thin convenience over `createNewFile(in:baseName:)` so the
    /// "New File ▸ …" menus have one typed entry point; the extension drives
    /// the editor's language detection on open.
    @discardableResult
    public func createNewFile(in directory: URL, type: NewFileType) -> URL? {
        createNewFile(in: directory, baseName: type.baseName)
    }

    /// TSK-760: "New text file" from the empty-tab landing. Creates an editable
    /// Untitled.txt and opens it. Unlike File→New (⌘N, which `validateMenuItem`
    /// disables when no folder is open), the landing button must ALWAYS work —
    /// the landing is shown precisely when nothing is open — so it falls back to
    /// the per-user temp scratch dir (`temporaryDirectory`, the sanctioned
    /// automated-write location) when there is no workspace folder; the user
    /// Saves-As to a real home from there. With a folder open it targets the
    /// same directory File→New would (`newFileTargetDirectory`).
    @discardableResult
    public func newTextFileForLanding() -> URL? {
        return newFileForLanding(type: .text)
    }

    /// TSK-747 — "New file of `type`" from the empty-tab landing. Same
    /// always-works fallback semantics as `newTextFileForLanding` (temp scratch
    /// when no folder is open), but for any offered `NewFileType`.
    @discardableResult
    public func newFileForLanding(type: NewFileType) -> URL? {
        let dir = newFileTargetDirectory ?? FileManager.default.temporaryDirectory
        return createNewFile(in: dir, type: type)
    }

    /// TSK-1054 — create a new blank PNG image (default 800×600 white), uniquely
    /// named, in `directory`, and return its URL. Binary write (not the text
    /// `NewFileCreator` path). Host-testable; a follow-on dialog supplies a
    /// custom size/color.
    @discardableResult
    public func createNewBlankImage(
        in directory: URL,
        width: Int = BlankImageCreator.defaultWidth,
        height: Int = BlankImageCreator.defaultHeight,
        color: RGBAColor = BlankImageCreator.defaultColor
    ) -> URL? {
        guard let data = BlankImageCreator.pngData(
            width: width, height: height, color: color) else { return nil }
        var url = directory.appendingPathComponent("Untitled.png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("Untitled \(n).png")
            n += 1
        }
        do {
            try data.write(to: url)
            // Only refresh the sidebar when the dir is in-tree — the landing
            // "New Image" falls back to the temp-scratch dir when no folder is
            // open; enumerating it would hang + pollute the sidebar (TSK-1294).
            if sidebar.contains(directory) {
                sidebar.reloadChildren(of: directory)
            }
            return url
        } catch {
            return nil
        }
    }

    /// TSK-1054 — File ▸ New Image: create a blank image (in the open folder, or
    /// the per-user temp scratch dir when none is open — same always-works
    /// fallback as the other New actions) and open it in the editor.
    @discardableResult
    public func newBlankImageForLanding(
        width: Int = BlankImageCreator.defaultWidth,
        height: Int = BlankImageCreator.defaultHeight,
        color: RGBAColor = BlankImageCreator.defaultColor
    ) -> URL? {
        let dir = newFileTargetDirectory ?? FileManager.default.temporaryDirectory
        guard let url = createNewBlankImage(
            in: dir, width: width, height: height, color: color) else { return nil }
        openPath(url)
        return url
    }

    /// True when there's clipboard text to paste into a new scratch tab (TSK-935).
    public var canNewTabFromClipboard: Bool {
        !(NSPasteboard.general.string(forType: .string) ?? "").isEmpty
    }

    /// TSK-935: "New Tab from Clipboard" — create a scratch file seeded with the
    /// clipboard text and open it. The extension is content-detected (JSON →
    /// `.json` so it opens with JSON tools; else `.txt`). Lands in the open
    /// folder, or the per-user temp scratch dir when none is open.
    @discardableResult
    public func newScratchTabFromClipboard() -> URL? {
        guard let content = NSPasteboard.general.string(forType: .string),
              !content.isEmpty else { return nil }
        let type = NewFileType.detect(content)
        let dir = newFileTargetDirectory ?? FileManager.default.temporaryDirectory
        do {
            let url = try NewFileCreator.create(
                in: dir, baseName: type.pastedBaseName, contents: content)
            sidebar.reloadChildren(of: dir)
            sidebar.setSelected(url)
            open(url: url)
            return url
        } catch {
            Obs.shared.emit(.warn, "files",
                            "New Tab from Clipboard failed: \(String(describing: error))")
            return nil
        }
    }

    /// Rename the file/folder at `url` to `newName` (collision-safe via
    /// `FileRenamer`: never overwrites a different file), then refresh the
    /// tree, reselect the renamed item, and repoint any bookmarks that
    /// pointed at it (or, for a folder rename, anything beneath it).
    /// Returns the new URL, or nil on failure (logged; an invalid name /
    /// collision / sandbox denial must not crash the menu action). The
    /// single entry point for the sidebar right-click → Rename and the F2
    /// key (TSK-283).
    ///
    /// TSK-1463: open tabs FOLLOW the rename — `retargetOpenTabs` repoints
    /// the tab URL, loaded state, and editor buffer (preserving unsaved
    /// edits), for the exact item and anything beneath a renamed folder.
    /// (This used to be deferred; a rename stranded open tabs on the dead
    /// path with a spurious "deleted on disk" dot.)
    @discardableResult
    public func renameFile(at url: URL, to newName: String) -> URL? {
        do {
            let newURL = try FileRenamer.rename(at: url, to: newName)
            let parent = url.deletingLastPathComponent()
            sidebar.reloadChildren(of: parent)
            sidebar.setSelected(newURL)
            retargetOpenTabs(from: url, to: newURL)
            if bookmarksStore.relocate(from: url, to: newURL) > 0 {
                refreshBookmarks()
            }
            return newURL
        } catch {
            Obs.shared.emit(.warn, "files",
                            "Rename failed: \(String(describing: error))")
            return nil
        }
    }

    /// File→New target: the selected sidebar folder if one is selected and
    /// is a directory, else the sidebar root. nil when no folder is open
    /// (the menu item disables).
    public var newFileTargetDirectory: URL? {
        if let sel = sidebar.selectedURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: sel.path, isDirectory: &isDir),
               isDir.boolValue {
                return sel
            }
            // A file is selected → its containing folder.
            if sidebar.rootURL != nil { return sel.deletingLastPathComponent() }
        }
        return sidebar.rootURL
    }

    /// Open a file at a specific 1-based source line and place the
    /// caret / selection there. Used by search-result rows
    /// (`SearchAnywhereSection`, `CrossSearchPanel`) so the user lands
    /// on the matched line instead of just at the top of the file.
    ///
    /// Mode handling:
    ///   - If the file would otherwise open in `.rendered` mode
    ///     (markdown default), we coerce it to `.source` — there's no
    ///     concept of "line N" in the rendered HTML view.
    ///   - `.editor` (CM6) honors the jump via `editorGotoLine`.
    ///   - `.source` and any other line-numbered text mode honors it
    ///     via `scrollSource(toLine:)`. We set BOTH so that a later
    ///     mode switch surfaces the right caret without re-firing the
    ///     search-result click.
    ///
    /// Directories have no "line"; delegates to `openPath`.
    public func openPath(_ url: URL, atLine line: Int) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
           isDir.boolValue {
            openFolder(url)
            return
        }
        open(url: url)
        guard line > 0 else { return }
        // If the opener landed us in rendered markdown, switch to
        // source so the line is actually visible. Other modes
        // (.table / .diff / .hex / .formatted) keep their default —
        // the source-text channel still gets the request, so a later
        // "switch to source" picks the caret up.
        if currentViewMode == .rendered {
            setCurrentViewMode(.source)
        }
        if currentViewMode == .editor {
            editorGotoLine = CMGotoLineRequest(line: line, select: true)
        }
        scrollSource(toLine: line)
    }

    /// Restores the most recently opened folder (if any). Call from app launch.
    ///
    /// Skips restoration if the folder is under a TCC-protected location
    /// (`~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures`, iCloud
    /// Drive). Even just enumerating those folders triggers a per-launch
    /// TCC prompt on macOS 14+, which makes auto-restore *worse* than
    /// helpful for those paths. The user can always re-open via File →
    /// Open Folder or by dragging the folder onto the app.
    public func restorePreviousFolderIfAvailable() {
        guard let url = preferences.lastFolderURL else { return }
        if Self.isUnderTCCProtectedRoot(url) {
            return  // explicit no-op; user can re-open manually
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        openFolder(url)
    }

    /// True if `url` sits inside one of the macOS TCC-protected roots
    /// (Documents / Desktop / Downloads / Pictures / iCloud Drive
    /// container). These paths trigger a permission prompt on first
    /// access from any app; for an ad-hoc-signed dev build the prompt
    /// repeats on every rebuild (new CDHash → new app to TCC). We avoid
    /// touching them implicitly on launch.
    static func isUnderTCCProtectedRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = NSHomeDirectory()
        let protectedPrefixes: [String] = [
            home + "/Documents",
            home + "/Desktop",
            home + "/Downloads",
            home + "/Pictures",
            home + "/Library/Mobile Documents",  // iCloud Drive
        ]
        return protectedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public func setSidebarWidth(_ width: Double) {
        let clamped = min(max(width, PreferencesStore.minSidebarWidth),
                          PreferencesStore.maxSidebarWidth)
        sidebarWidth = clamped
        preferences.setSidebarWidth(clamped)
    }

    /// P15: assigns the published width without persisting. Use this from a
    /// continuous gesture; call `persistSidebarWidth()` on gesture end.
    public func setSidebarWidthLive(_ width: Double) {
        let clamped = min(max(width, PreferencesStore.minSidebarWidth),
                          PreferencesStore.maxSidebarWidth)
        sidebarWidth = clamped
    }

    public func persistSidebarWidth() {
        preferences.setSidebarWidth(sidebarWidth)
    }

    /// TSK-906: bumped on palette dismiss so the active CM6 editor re-takes
    /// first responder (the overlay tear-down left focus nowhere). Consumed by
    /// `CodeMirrorEditorView(editorFocusRequest:)`.
    @Published public var editorFocusRequest: Int = 0
    public func showPalette() { isPalettePresented = true }
    public func dismissPalette() {
        isPalettePresented = false
        editorFocusRequest &+= 1
    }

    /// TSK-905: bumped when the active RENDERED preview changes (tab switch /
    /// view-mode→rendered / open) so its `WKWebView` re-takes first responder
    /// and ↑/↓/PageUp scroll it. WKWebViews are first-responder-by-tab-position
    /// by default — only the last-added one gets key events — so a preview that
    /// isn't the last tab is dead to arrows until we explicitly focus it.
    /// Consumed by `MarkdownRenderedView(focusRequest:)`.
    @Published public private(set) var previewFocusRequest: Int = 0
    private var lastFocusedPreviewTabID: UUID?

    /// Re-evaluate which rendered preview is active and bump `previewFocusRequest`
    /// only when it CHANGED. Called from `updateDerived` (the common post-change
    /// refresh) so it covers tab switches, view-mode flips, and opens — but the
    /// change-key (active rendered tab id) makes a same-preview derived refresh a
    /// no-op, so focus is never stolen mid-interaction.
    private func refreshPreviewFocus() {
        let active: UUID? = (currentViewMode == .rendered) ? tabs.selected?.id : nil
        defer { lastFocusedPreviewTabID = active }
        if let active, active != lastFocusedPreviewTabID {
            previewFocusRequest &+= 1
        }
    }

    /// TSK-938: which existing focus-request nonce returns first-responder to the
    /// ACTIVE document for the current view mode. `nil` for modes that own their
    /// first-responder by other means (NSTextView source/formatted/table/hex/diff
    /// — the content view is the responder, not a nonce-driven WKWebView/CM6
    /// surface), so an Esc-to-document there is a UI-layer `makeFirstResponder`,
    /// not a model nonce bump.
    private enum DocumentFocusTarget: Equatable { case editor, preview }
    private var documentFocusTarget: DocumentFocusTarget? {
        switch currentViewMode {
        case .editor:   return .editor    // CM6 webview (editorFocusRequest)
        case .rendered: return .preview   // rendered WKWebView (previewFocusRequest)
        case .source, .formatted, .table, .diff, .preview, .hex:
            return nil
        }
    }

    /// TSK-938: Esc "return focus to the active document tab." When the keyboard
    /// is parked in a tool surface (file-nav / search / git / terminal / any
    /// non-document field) and the user hits Esc, hand first-responder back to the
    /// active document by bumping the SAME focus-request nonce TSK-905/906 already
    /// drive — no new focus path. `currentFocusIsDocument` is resolved by the thin
    /// UI key handler from the live first-responder; passing `true` makes this a
    /// no-op so a stray Esc never re-grabs focus the document already holds (the
    /// over-grab guard, mirroring `refreshPreviewFocus`'s change-key).
    ///
    /// Returns `true` iff a focus-request nonce was bumped — i.e. the model
    /// handled the Esc. `false` means nothing to do (focus already on the
    /// document, no open document, or a mode with no nonce-driven focus target —
    /// the caller may then fall back to its own `makeFirstResponder`).
    @discardableResult
    public func returnFocusToActiveDocument(currentFocusIsDocument: Bool) -> Bool {
        // Over-grab guard: already on the document ⇒ leave it alone.
        guard !currentFocusIsDocument else { return false }
        // No active document ⇒ nothing to focus.
        guard tabs.selected != nil else { return false }
        switch documentFocusTarget {
        case .editor:
            editorFocusRequest &+= 1
            return true
        case .preview:
            previewFocusRequest &+= 1
            return true
        case nil:
            return false
        }
    }

    // MARK: - Command registry (UX-M / #232)

    /// The effective command catalog: the built-in `CommandRegistry`
    /// with the user's `~/.textview/keybinding.json` overrides folded in.
    /// Loaded lazily on first access and cached. The palette's command
    /// list and the menu's shortcut resolution both read this so there's
    /// ONE source of truth for the action surface + its key bindings.
    ///
    /// Lazy (not loaded in `init`) so hermetic unit tests that build a
    /// bare `DocumentModel` don't touch `~/.textview`; the live app warms
    /// it once at launch via `loadKeybindings()`.
    // internal(set) (not private(set)) so the DocumentModel+CommandRegistry.swift
    // SRP slice (TSK-1110) can reload it on a keybinding change.
    public internal(set) lazy var commandRegistry: CommandRegistry = {
        let result = KeybindingConfig.load()
        logKeybindingResult(result)
        return CommandRegistry.builtIn.applying(overrides: result.config.bindings)
    }()

    /// Macro record/replay coordinator (TSK-1162), keyed off the same command
    /// registry the verb dispatch uses. Lazy so a bare DocumentModel pays
    /// nothing until a recording starts.
    public private(set) lazy var macros = MacroController(registry: commandRegistry)

    // loadKeybindings(directory:) / logKeybindingResult(_:) →
    // DocumentModel+CommandRegistry.swift (TSK-1110 SRP slice).

    /// Weak handle to the sessions coordinator so palette-invoked
    /// commands can dispatch the session/sidebar verbs through
    /// `ScriptVerb.apply(verb:to:sessions:)` — the SAME pure dispatch
    /// surface the `--script` runner + headless harness use. Set by the
    /// app delegate at launch; `weak` to avoid a retain cycle (the
    /// coordinator owns the model). One-way dependency, same shape as
    /// `openFolderInNewSession`.
    public weak var sessionsCoordinator: SessionsAppCoordinator?

    // invokeCommand(id:) → DocumentModel+CommandRegistry.swift (TSK-1110 SRP slice).

    // MARK: - Go-to-path — prompt-intent state (logic in DocumentModel+GoToPath.swift)
    //
    // The prompt-intent stored state stays on the class (an extension can't
    // declare stored props); the show/dismiss/record/commit logic lives in
    // DocumentModel+GoToPath.swift. Both vars widened private(set)→internal(set)
    // so the moved methods write them. (isGoToPathPresented + lastGoToError are
    // @Published public elsewhere; goToPathHistory drives the recents.)

    /// True while the visible Go-to-path prompt was invoked as the
    /// empty-session entry point (the SessionTabBar `+` button via the
    /// first-paint gate). A folder confirmed under this intent must
    /// spawn a NEW session — including on the default Return/Open path,
    /// which otherwise mutates the active session (TSK-600: picking `~`
    /// after `+` re-rooted the current tab and created nothing).
    public internal(set) var goToPathNewSessionIntent: Bool = false

    /// TSK-314: initial text for the prompt's path field. "~" for the
    /// new-session flow (the + button) so a bare Enter opens home and a
    /// typed path starts from a sensible anchor; nil (empty, "match
    /// Finder") for the regular in-session Go To.
    public internal(set) var goToPathPrefill: String?

    // MARK: Bookmarks — publish + gutter line-cache (commands → DocumentModel+Bookmarks.swift)

    /// Re-publish the `bookmarks` list from the store and invalidate
    /// the per-URL cached set used by the source-view gutter. Call
    /// this after any external mutation of `bookmarksStore` so the
    /// SwiftUI bindings + gutter rebuild reflect the change. Public
    /// so other dispatchers (walkthrough engine, MCP automation,
    /// future plugin handlers) can mutate the store directly and
    /// publish their writes without duplicating the boilerplate.
    public func publishBookmarksChange() {
        bookmarks = bookmarksStore.all()
        invalidateBookmarkedLinesCache()
    }

    /// Set (or clear, with nil) the bookmark-open warning banner. Vended so the
    /// bookmark commands in DocumentModel+Bookmarks.swift can drive the
    /// `private(set)` @Published `lastBookmarkOpenWarning` without owning it.
    func setBookmarkOpenWarning(_ message: String?) {
        lastBookmarkOpenWarning = message
    }

    /// Memoization for `bookmarkedLines(for:)` — the gutter calls it
    /// on every Canvas redraw, so a fresh O(N) scan over the bookmark
    /// array per scroll publish piles up. We cache one URL → Set and
    /// invalidate whenever the bookmarks array mutates.
    private var bookmarkedLinesCache: (url: URL, lines: Set<Int>)?

    /// 1-based line numbers currently bookmarked for `url`. Used by
    /// the source-view gutter to draw markers.
    public func bookmarkedLines(for url: URL) -> Set<Int> {
        let n = url.standardizedFileURL.resolvingSymlinksInPath()
        if let cache = bookmarkedLinesCache, cache.url == n {
            return cache.lines
        }
        let lines = Set(bookmarks.compactMap { entry in
            entry.url == n ? entry.line : nil
        })
        bookmarkedLinesCache = (n, lines)
        return lines
    }

    /// Invalidate `bookmarkedLinesCache`. Called from anywhere that
    /// mutates `bookmarks`.
    private func invalidateBookmarkedLinesCache() {
        bookmarkedLinesCache = nil
    }

    // MARK: - Git diff marks for source-view gutter — state (logic in DocumentModel+GitDiffGutter.swift)

    /// Per-line diff status for the *current* file. Recomputed on file open /
    /// save / reload via `refreshDiffMarks()` (now in DocumentModel+GitDiffGutter.swift).
    /// Written through the vended `setSourceDiffMarks(_:)` so the moved refresh
    /// methods can publish while the external contract stays `private(set)`.
    @Published public private(set) var sourceDiffMarks: [Int: DiffMark] = [:]

    /// Publish `sourceDiffMarks` from the gutter-refresh methods (extension).
    /// Vended because the stored property keeps its `private(set)` contract.
    func setSourceDiffMarks(_ marks: [Int: DiffMark]) { sourceDiffMarks = marks }

    /// In-flight `git diff` task. Held so we can cancel before launching a new
    /// one when the focused file changes — otherwise rapid tab switches stack
    /// git processes. Internal so the extension's refresh methods reassign it.
    var diffMarksTask: Task<Void, Never>?
    /// Separate in-flight task for the SPLIT pane's gutter diff. The split pane
    /// gets its own diff feed (it can be a file in a DIFFERENT repo than the
    /// primary pane — "two repos colored simultaneously"). Internal (extension).
    var splitDiffMarksTask: Task<Void, Never>?
    /// In-flight syntax-fold compute for the selected editor tab (TSK-466).
    /// Cancelled + relaunched on selection change / edit so a keystroke
    /// burst doesn't stack TreeSitter parses. Single handle is enough —
    /// only the *selected* editor tab's folds are ever computed.
    private var editorFoldsTask: Task<Void, Never>?

    /// TSK-672/814: when blame mode is on, the editor gutter shows per-line
    /// authorship instead of diff bars, toggled via `toggleEditorBlame()` / the
    /// "Toggle Git Blame" command (both in DocumentModel+GitDiffGutter.swift).
    /// The central `refreshDiffMarks` routes to blame per this flag so blame
    /// survives tab switches without a separate hook.
    @Published public var editorBlameActive = false

    /// Recompute syntax fold regions for the selected editor tab off-main
    /// and push them into the CM6 editor's per-tab fold channel (TSK-466).
    /// Mirrors `refreshDiffMarks`' cancel-then-relaunch shape. Called on
    /// selection change (`updateDerived`) and on edits (`updateEditorText`).
    ///
    /// Source = TreeSitter `FoldRegion` (the same syntax folds the
    /// read-only Source view uses, #139), mapped through
    /// `SyntaxFoldRangeMapping`. A future LSP-fold union would add a
    /// second source here; the v1 default is TreeSitter-only because it
    /// needs no language server and is always available.
    ///
    /// No-op unless the selected tab is a loaded file in editor mode.
    /// The engine caps by byte size and caches by content hash, so a
    /// recompute over unchanged text is cheap; the `setEditorFoldRanges`
    /// equality guard suppresses the redundant republish.
    public func refreshEditorFolds() {
        editorFoldsTask?.cancel()
        guard let tab = tabs.selected,
              tab.viewMode == .editor,
              let url = tab.url
        else {
            editorFoldsTask = nil
            recomputeStickyScrollHeaders()  // TSK-719: clear when not in editor
            return
        }
        let tid = tab.id
        let lang = effectiveLanguage(forTabID: tid, url: url)
        // Prefer the live edited buffer; fall back to the loaded-on-disk
        // text for a freshly-selected tab whose editor buffer hasn't been
        // seeded yet (updateDerived can fire before the editor view's
        // ensureEditorBuffer pass).
        let text = editor.editorBuffer(forTabID: tid)?.text ?? Self.loadedText(of: tab)
        guard let text, !text.isEmpty else {
            editor.setEditorFoldRanges([], forTabID: tid)
            editor.setEditorFoldRegions([], forTabID: tid)
            recomputeStickyScrollHeaders()
            editorFoldsTask = nil
            return
        }
        editorFoldsTask = Task { [weak self] in
            // `computeFolds` runs the parse on a detached task internally;
            // do the (O(n) converter) mapping off-main too so the main
            // actor only sees the final assignment. Keep the line-based
            // `regions` too — sticky scroll (TSK-719) reasons in lines.
            let result = await Task.detached(priority: .userInitiated)
                { () -> (regions: [FoldRegion], cm: [CMFoldRange]) in
                // Stage-B (TSK-649/TSK-1202): the Swift fold twin is deleted —
                // rust is the only fold engine (language coverage is a strict
                // superset of the deleted queries). A bridge fault degrades to
                // no folds for this pass (gutter empty, observable), never a
                // crash; the next text change retries.
                let regions = RustFoldAdapter.foldRegions(text, language: lang)
                let cm = SyntaxFoldRangeMapping.cmFoldRanges(from: regions, documentText: text)
                return (regions, cm)
            }.value
            if Task.isCancelled { return }
            guard let self, self.tabs.selected?.id == tid else { return }
            self.editor.setEditorFoldRanges(result.cm, forTabID: tid)
            self.editor.setEditorFoldRegions(result.regions, forTabID: tid)
            self.recomputeStickyScrollHeaders()
        }
    }

    /// TSK-719 — the enclosing scope headers pinned at the top of the editor
    /// viewport ("sticky scroll"), outermost → innermost. Recomputed (cheaply)
    /// whenever the selected tab's scroll position or fold regions change.
    /// Empty unless the selected tab is in `.editor` mode. The pinned bar that
    /// renders this is the VM render tail; this published model is host-tested.
    @Published public private(set) var stickyScrollHeaders: [StickyScrollHeaders.Header] = []

    /// Recompute `stickyScrollHeaders` from the selected tab's fold regions, its
    /// editor scroll top line, and its current buffer text. Cheap (a bounded
    /// line scan for only the pinned lines); safe to call on every scroll tick.
    public func recomputeStickyScrollHeaders() {
        guard let tab = tabs.selected, tab.viewMode == .editor, let url = tab.url else {
            if !stickyScrollHeaders.isEmpty { stickyScrollHeaders = [] }
            return
        }
        let tid = tab.id
        let regions = editor.editorFoldRegionsByTab[tid] ?? []
        let top = editor.editorScrollByTab[tid]?.viewportFromLine ?? 1
        let text = editor.editorBuffer(forTabID: tid)?.text ?? Self.loadedText(of: tab)
        guard let text, !regions.isEmpty else {
            _ = url  // (url kept for symmetry with refreshEditorFolds guards)
            if !stickyScrollHeaders.isEmpty { stickyScrollHeaders = [] }
            return
        }
        let headers = StickyScrollHeaders.headers(
            foldRegions: regions, viewportTopLine: top, documentText: text)
        if headers != stickyScrollHeaders { stickyScrollHeaders = headers }
    }

    /// The loaded-from-disk text of a tab, or nil if it isn't in the
    /// `.loaded` state (binary / error / preview / still loading).
    static func loadedText(of tab: ViewerCore.Tab) -> String? {
        if case .loaded(let f) = tab.state { return f.contents }
        return nil
    }

    /// Bounded prefix of the SELECTED tab's loaded source text — the content the
    /// source view renders. Lets a diagnostic dump / UAT assert WHAT loaded (e.g.
    /// that a routed .rtf/.docx shows its EXTRACTED text, not raw container
    /// bytes), since the editor buffer (`editorText`) is nil for an un-edited
    /// read-only tab. Capped so the per-step dump stays small. "" when no tab is
    /// loaded. (TSK-1241 — render-content VM-UAT enabler.)
    public var selectedLoadedTextPrefix: String {
        guard let tab = tabs.selected, let text = Self.loadedText(of: tab) else { return "" }
        return String(text.prefix(400))
    }

    // MARK: Cross-file search

    @Published public var isCrossSearchPresented: Bool = false
    @Published public var crossSearchQuery: String = ""
    @Published public var crossSearchResults: [CrossFileSearch.FileMatches] = []
    @Published public var crossSearchIsRunning: Bool = false
    @Published public var crossSearchCaseSensitive: Bool = false
    /// TSK-758 — search file NAMES across the folder instead of file CONTENTS.
    /// false = text grep (default), true = filename match. Sticky across opens.
    @Published public var crossSearchFilenameMode: Bool = false
    /// TSK-758 — treat the query as a regular expression (ReDoS-guarded via
    /// `CrossFileSearch.validateRegex`). Sticky across opens.
    @Published public var crossSearchUseRegex: Bool = false
    /// Non-nil when regex mode is on and the query is a rejected/invalid
    /// pattern — surfaced as a hint in the panel; the search is skipped.
    @Published public var crossSearchRegexError: String? = nil

    // TSK-726 — project-wide REPLACE (cross-file search was read-only). The
    // replacement string, the panel's replace-row disclosure, and the one-line
    // result of the last replace ("Replaced 12 in 3 files" / an error summary).
    @Published public var crossSearchReplacement: String = ""
    @Published public var crossSearchReplaceVisible: Bool = false
    @Published public var crossSearchReplaceStatus: String? = nil

    /// One-shot hand-off used by callers that want the unified search
    /// panel to open with a pre-set scope (e.g. the sidebar folder-row
    /// "Search in Folder" context-menu item). Consumed by the panel's
    /// `onAppear` and cleared back to `nil` immediately so subsequent
    /// opens don't re-apply a stale scope.
    @Published public var crossSearchPresetScope: SearchScope? = nil

    // TSK-1465 — cross-search operation feedback + safe replace.
    /// Live walk feedback ("Searched N entries · M matches") published by the
    /// engine's onProgress hook, throttled to the walk's cancel stride. nil
    /// when no search is in flight. (No "total" — knowing it would cost a
    /// full pre-walk of the tree, doubling IO for a number the stride counter
    /// already approximates.)
    @Published public var crossSearchProgress: CrossSearchProgress? = nil
    /// The pending replace PREVIEW (per-file would-be counts, computed
    /// WITHOUT writing). Non-nil ⇒ the panel shows the confirm step;
    /// `confirmCrossFileReplace()` applies it, `cancelCrossFileReplacePreview()`
    /// discards. Cleared by any new search (the files it summarizes changed).
    @Published public var crossSearchReplacePreview: [CrossFileReplace.FileOutcome]? = nil
    /// Cooperative cancel handle for the CURRENT walk (TSK-1465). The engine
    /// polls it every cancel stride; `cancelCrossSearch()` trips it. Unlike a
    /// generation bump, a trip lets the in-flight walk return PARTIAL results,
    /// which still land (same generation) — "stop and show what you found".
    var crossSearchCancelToken: CrossSearchCancelToken? = nil

    /// Monotonically increasing counter that scopes each runCrossSearch()
    /// call. Bumped on every invocation AND on dismiss. Background
    /// completions check the captured value against this and drop their
    /// result when stale — so a slow "foo" search can't overwrite a
    /// faster "foobar" search that started later, and a dismissed
    /// panel doesn't get repopulated by a late finish. Internal (not private) so
    /// the cross-search commands in DocumentModel+CrossSearch.swift can drive
    /// this cancellation counter — a stored property can't move to the extension.
    var crossSearchGeneration: Int = 0

    // MARK: Find — three modes, one coordinator (Quality #E + J, 2026-05-25)
    //
    // The three find bags (rendered / source / editor) used to live as
    // ~15 `@Published` fields directly on DocumentModel. Each keystroke
    // into a find field fired `DocumentModel.objectWillChange` and
    // forced every observer (TabBar, Sidebar, StatusBar, all per-tab
    // content views) to re-evaluate. Now find state lives on a child
    // `FindCoordinator`; views that care observe `model.find` directly,
    // views that don't no longer pay for find keystrokes.
    //
    // Backwards-compat: the old `renderedFindQuery` / `sourceFindQuery`
    // / `editorFindQuery` / etc. surface is preserved as computed-
    // property forwarders below. These do NOT trigger
    // `DocumentModel.objectWillChange` — they bottom out in `find.*`
    // assignments which fire `find.objectWillChange`. Tests that
    // poke `model.renderedFindQuery = "x"` keep working unchanged.
    public let find = FindCoordinator()

    // MARK: Find bar (rendered + source mode) — forwarders
    // → extracted to DocumentModel+FindBarForwarders.swift (TSK-1110 SRP split, slice 3).

    // MARK: Source-view scroll-to-line — forwarders to SourceViewChannel

    // sourceScrollLineTarget / sourceScrollLineNonce / scrollSource(toLine:) →
    // DocumentModel+SourceScroll.swift (TSK-1110 SRP slice).

    // MARK: - Per-file scroll persistence — state (logic in DocumentModel+ScrollPersistence.swift)
    //
    // The persistence STORED state stays on the class (an extension can't declare
    // instance stored properties); the sampling/restore logic lives in
    // DocumentModel+ScrollPersistence.swift (UX-K #231 / TSK-1110). The backing
    // dicts are widened private→internal so the extension can drive them.

    /// TSK-1017: the per-file scroll/zoom entry we last RESTORED from (or
    /// stored to) the durable `scrollMemory`, keyed by resolved path. Lets
    /// `ScrollMemoryStore.shouldPersist` tell an actually-scrolled file from
    /// an untouched open/glance/close — so we don't write-amplify the store.
    var scrollMemoryBaseline: [String: ScrollMemoryStore.Entry] = [:]

    #if DEBUG
    /// Test seam (TSK-1047): count of live-CM6 scroll-push ATTEMPTS made by the
    /// tab-select restore path, and the last line pushed. A host test reads these
    /// to prove (a) a TAB switch attempts the live push (the mounted-pane gap fix)
    /// and (b) a SESSION switch (flag set) does NOT (no double-apply over the
    /// reattach/seed belt). The true on-screen scroll is VM-only. Setter widened
    /// to internal so DocumentModel+ScrollPersistence (another file) can write it.
    public internal(set) var _test_liveEditorScrollPushes = 0
    public internal(set) var _test_lastLiveEditorScrollLine = 0
    #endif

    /// TSK-1047: set true by `SessionState` around the `selectTab` it drives
    /// during a session activation — the path where the editor pane is REBUILT
    /// (dismantle→make), so the warm-editor reattach / once-per-mount seed already
    /// restore scroll. Gates `applyRestoredScroll`'s live CM6 push so a session
    /// switch doesn't double-apply (a TAB switch leaves it false → the live push
    /// runs, since a mounted pane has no rebuild to carry the scroll). Plain Bool,
    /// main-actor — set/cleared synchronously around the one `selectTab` call.
    public var isSessionSwitchInFlight: Bool = false

    /// TSK-718 hot exit: cap on persisted unsaved text per tab. Beyond this the
    /// unsaved content is NOT captured (the file reloads from disk on relaunch)
    /// — a guard so a huge in-flight edit can't bloat the per-session JSON.
    /// 1 MiB covers any realistic hand-edit.
    public static let hotExitMaxBytes = 1 << 20  // 1 MiB

    /// Directory for >1 MiB hot-exit spill files (TSK-1026). Defaults to the
    /// real per-user spill dir; host tests point it at scratch so a capture
    /// never writes into the user's real store (the BUG-027 class).
    public var hotExitSpillDirectory: URL = HotExitSpill.directory()

    /// TSK-743 (source channel): per-URL memory of the source-view (NSTextView)
    /// top line for the ONE ephemeral preview slot. The slot reuses a single tab
    /// id across files and rebuilds the `Tab` on each swap — dropping
    /// `Tab.scrollTopLine` — so without this a sidebar preview-switch always
    /// returned a file to the top. Mirrors the editor channel's URL-keyed
    /// `previewScrollByURL`. Bounded so a long browse session can't grow it.
    var previewSourceLineByURL: [URL: Int] = [:]

    /// TSK-821 (rendered channel): per-URL memory of the rendered-markdown
    /// WKWebView's vertical scroll offset (`window.scrollY`), the third scroll
    /// channel after the editor (CM6) and source (NSTextView) ones. The rendered
    /// pane is the DEFAULT mode for markdown, and a `loadHTMLString` reload (file
    /// switch / preview swap) always resets it to the top — so without this,
    /// returning to a markdown file you'd scrolled lands at the top. The value is
    /// reported asynchronously from the WebView (`evaluateJavaScript`), so this
    /// is captured at the reload boundary and restored on `didFinish`. Bounded.
    var renderedScrollByURL: [URL: Double] = [:]

    /// TSK-1303: per-image-URL LIVE edit state, written by the image editor view
    /// as the user edits + folded onto `Tab.imageEditState` at the session-switch
    /// snapshot boundary (mirrors `renderedScrollByURL`). In-memory only (dropped
    /// on the session-switch drain), so the durable copy rides the tab snapshot.
    var imageEditStateByURL: [URL: ImageEditState] = [:]

    // MARK: - Split view
    //
    // The split-pane forwarders (`splitURL`, `isSplitOpen`, `openInSplit`,
    // `closeSplit`, `toggleSplit`, `swapSplit`) and `splitPaneText` moved to
    // `DocumentModel+Split.swift` (TSK-308). `refreshSplitDiffMarks()` stays
    // here — it reaches the file-private `splitDiffMarksTask` /
    // `resolveGutterRoot` state.

    // MARK: - Git panel focus

    /// Which Git-panel tab the user just asked the menu / a command
    /// palette entry to focus. Paired with `gitPanelFocusRequest` so
    /// SwiftUI's value-blind publish doesn't swallow repeat asks for
    /// the same tab.
    public enum GitPanelTab: String, Sendable, CaseIterable {
        case status, log, stash, trees, remotes
    }
    @Published public var gitPanelFocusRequest: Int = 0
    @Published public var gitPanelDesiredTab: GitPanelTab = .status

    // showGitPanel(tab:) / canFocusGitPanel → DocumentModel+GitPanelFocus.swift
    // (TSK-1110 SRP slice). The GitPanelTab enum + the nonces above stay here.

    // MARK: - Focus shortcuts (TSK-937) — nonce STATE (gates + actions in DocumentModel+FocusShortcuts.swift)
    //
    // Monotonically-bumped focus-request nonces the target views observe via
    // `.onChange` to take first responder (SwiftUI's value-blind publish dedupes,
    // so a nonce guarantees a repeat "focus X" isn't swallowed). `internal(set)`
    // so the FocusShortcuts extension can bump them (an extension can't write a
    // `private(set)` from another file).

    /// Bumped to ask the in-app terminal surface to take first responder.
    @Published public internal(set) var terminalFocusRequest: Int = 0

    /// Bumped to ask the Files (file-nav) panel to take first responder.
    @Published public internal(set) var fileNavFocusRequest: Int = 0

    /// Bumped to ask the active document surface to take first responder.
    @Published public internal(set) var documentFocusRequest: Int = 0

    /// Folder-stats slide-down visibility (WAVE 2b item 3). Lives on the
    /// model (not as `SidebarView` `@State`) so it survives sidebar
    /// re-bodies AND is drivable by the `--script` verification harness.
    /// Defaults closed; it's an on-demand inspector, not persisted.
    @Published public var folderStatsExpanded = false

    /// Long-lived HEAD-invalidated repo-statistics cache (WAVE 2b item 3).
    /// Owned here (not on the transient `SidebarView`) so it survives
    /// sidebar re-bodies / tab switches / reopens — a fresh
    /// `FolderStatsView` instance reuses the cached aggregates instead of
    /// re-walking the whole history each time the panel is opened. The
    /// cache is HEAD-keyed, so a new commit transparently recomputes.
    public let repoStatsCache = RepoStatsCache()

    // MARK: - Git File History — availability cache (launchers → DocumentModel+FileHistory.swift)

    /// Backs the synchronous `canShowFileHistory` menu/context-menu gate
    /// without forking git on the main thread (TSK-972). The real
    /// `discoverRoot` + `isTracked` probe runs off-main; results are cached
    /// and the answer is republished when it lands so SwiftUI re-evaluates
    /// `.disabled`. See `FileHistoryAvailabilityCache`.
    let fileHistoryAvailability = FileHistoryAvailabilityCache()

    // extensionsInventory / canShowLocalHistory(for:) / repoRelativePath(of:root:)
    // → DocumentModel+FileHistoryAvailability.swift (TSK-1110 SRP slice). The
    // fileHistoryAvailability cache above stays.

    // MARK: - Git log (legacy)
    // → extracted to DocumentModel+GitLog.swift (TSK-1110 SRP split, slice 7).
    // `swapSplit()` moved to `DocumentModel+Split.swift` (TSK-308).
    // MARK: Find bar (source mode) — match state forwarders
    // → extracted to DocumentModel+FindBarForwarders.swift (TSK-1110 SRP split, slice 5).

    // MARK: Find — menu gating (canFind*, findIsAvailable)
    // → extracted to DocumentModel+FindGating.swift (TSK-1110 SRP split, slice 6).

    // MARK: Find bar (CM6 editor mode) — forwarders
    // → extracted to DocumentModel+FindBarForwarders.swift (TSK-1110 SRP split, slice 4).

    // MARK: Editor mode — show-invisibles + cursor + diagnostics push
    //
    // `showInvisibleChars` already exists for the source view (above);
    // we reuse the same flag for the editor — single user-facing
    // setting, no daylight between the two modes. CM6 picks it up via
    // the `setShowInvisibles` bridge call wired in
    // `CodeMirrorEditorView.applyPendingState`.
    //
    // Editor-mode cursor + scroll position flow through the existing
    // `sourceSelection` / `sourceScrollState` channels so the status
    // bar's L:C readout works uniformly across source + editor modes
    // (it reads `sourceSelection`).

    // MARK: Editor lifecycle — forwarders to EditorCoordinator (Quality #2)
    // → extracted to DocumentModel+EditorForwarders.swift (TSK-1110 SRP split, slice 2).

    // MARK: - Code folding — dispatch state (actions in DocumentModel+Folding.swift)
    //
    // The @Published one-shot dispatch record + nonce STAY here (an extension
    // can't declare stored properties); the Fold* types and the menu-action
    // methods (foldAll/unfoldAll/dispatchFold) live in DocumentModel+Folding.swift,
    // which records here via the vended `recordFoldDispatch`. TSK-948 / TSK-1110.

    /// The most recently dispatched fold command, or nil if none yet. The
    /// Source-mode view observes this (filtered to `.target == .source`) to
    /// drive its `FoldState`; tests assert it to prove the menu wired through.
    @Published public private(set) var lastFoldDispatch: FoldDispatch?
    private var foldDispatchNonce: Int = 0

    /// Vended for `DocumentModel+Folding.dispatchFold` (another file — it cannot
    /// write the file-private `lastFoldDispatch` setter or the private nonce).
    /// Records a fold dispatch as a nonce-distinct one-shot.
    func recordFoldDispatch(_ command: FoldCommand, target: FoldDispatchTarget) {
        foldDispatchNonce &+= 1
        lastFoldDispatch = FoldDispatch(
            command: command, target: target, nonce: foldDispatchNonce)
    }

    // editorIndentation / editorCursorByTab / editorScrollByTab / recordEditorCursor /
    // recordEditorScroll / seedEditorScroll / editorMountSelectionSeed / setEditorDiagnostics /
    // pendingEditorDiagnostics / consumePendingEditorDiagnostics / pendingEditorGutterMarkers /
    // editorFoldRangesByTab / consumePendingEditorGutterMarkers → DocumentModel+EditorState.swift
    // (TSK-1110 SRP slice).

    // MARK: - CM6 LSP bridge (hover / Cmd-click definition / context menu)

    /// Forwarder. New code should bind `$editor.saveEditorOnBlur`.
    public var saveEditorOnBlur: Bool {
        get { editor.saveEditorOnBlur }
        set { editor.saveEditorOnBlur = newValue }
    }

    // MARK: - CM6 LSP request bridges (hover / completion)
    //
    // lspLanguageConfigured(for:) + lspPosition(line:character:) (the shared LSP
    // gate + CM6→LSP position conversion, TSK-963) → DocumentModel+LSPShared.swift
    // (TSK-1110 SRP slice).

    // respondToEditorHover(...) + sendEditorHoverResponse(...) →
    // DocumentModel+CM6Hover.swift (TSK-1110 SRP slice).

    // respondToEditorCompletion(...) + sendEditorCompletionResponse(...) →
    // DocumentModel+CM6Completion.swift (TSK-1110 SRP slice).

    // MARK: - CM6 completion bridge (TSK-963 / TSK-463)
    //
    // The DocumentModel-side entry point for editor completion, mirroring the
    // hover bridge above. It routes through the SAME consolidated gate +
    // position conversion, so the language predicate and 1-based→0-based
    // semantics can never drift from the rest of the LSP surface.
    //
    // Scope note (honest): the LSP design (`LSP_DESIGN.md` §0) deliberately
    // scoped completion OUT — there is no `completion` method on `LSPPool`/
    // `LSPClient` and no `textDocument/completion` round-trip yet, and adding
    // those crosses `Sources/ViewerCore/LSP/` + the CM6 JS bundle (a separate,
    // multi-file slice that collides with this consolidation slice's
    // DocumentModel-only scope). What lands here is the model-layer entry +
    // its gate contract: a completion request with NO LSP language replies
    // empty WITHOUT spawning a server. The pool/JS round-trip is the follow-up
    // (TSK-463 reopened) — it plugs into `_lastCompletionRequest` and the
    // `requestCompletions(...)` seam below with no further DocumentModel churn.

    /// A single completion candidate surfaced to the editor. Minimal by
    /// design — label + optional detail/insert text — so the pool round-trip
    /// can map an `LSPCompletionItem` onto it without leaking the wire type
    /// into the UI layer.
    public struct EditorCompletionItem: Equatable, Sendable {
        public let label: String
        public let detail: String?
        public let insertText: String?
        public init(label: String, detail: String? = nil, insertText: String? = nil) {
            self.label = label; self.detail = detail; self.insertText = insertText
        }
    }

    // editorCompletions / handleCompletionRequest / requestCompletions →
    // DocumentModel+CM6Completion.swift (TSK-1110 SRP slice). The
    // _lastCompletionRequest DEBUG probe below stays here (stored prop).

    #if DEBUG
    /// Test-only: the last completion request that PASSED the language gate
    /// (URL + the 0-based position handed downstream). nil when the gate
    /// refused (no LSP language) — lets the host gate pin "no language ⇒ no
    /// dispatch / no spawn" without a live server.
    var _lastCompletionRequest: (url: URL, line: Int, character: Int)?
    #endif


    // LSPNavigationKind enum + handleEditorDefinition / navigateViaLSP /
    // navigateViaLSPAtCursor → DocumentModel+LSPNavigation.swift (TSK-1110 SRP
    // slice). The _lastLSPNavigation DEBUG probe below stays here (stored prop).

    #if DEBUG
    /// Test-only: the last LSP navigation dispatched (kind + the exact
    /// 0-based position handed to the pool). Lets headless tests pin the
    /// kind→verb routing and the 1-based→0-based conversion without a
    /// live language server.
    var _lastLSPNavigation: (kind: LSPNavigationKind, url: URL, line: Int, character: Int)?
    #endif


    #if DEBUG
    /// Test-only: the last "Find References" dispatch (URL + 0-based position
    /// handed to the pool). Lets the host gate pin the menu/palette → request
    /// routing + the 1-based→0-based conversion without a live language server.
    var _lastReferencesRequest: (url: URL, line: Int, character: Int)?
    #endif

    // findReferencesAtCursor() / canFindReferences + formatActiveEditorViaLSP() →
    // DocumentModel+LSPEditorCommands.swift (TSK-1110 SRP slice). The
    // _lastReferencesRequest / _lastFormatDispatch DEBUG probes stay here (stored props).

    #if DEBUG
    /// Test-only: the last formatting dispatch (URL + the buffer snapshot
    /// the edits will be applied against). Pins the guard set + snapshot
    /// semantics without a live language server.
    var _lastFormatDispatch: (url: URL, snapshot: String)?
    #endif


    // formatMarkdownTablesInActiveEditor() / canAlignMarkdownTables →
    // DocumentModel+EditorFormatCommands.swift (TSK-1110 SRP slice).

    #if DEBUG
    /// Test-only: the last rename dispatch + the uris whose edits were
    /// SKIPPED because the file isn't open in any tab (viewer posture: a
    /// rename never silently writes files to disk).
    var _lastRenameDispatch: (url: URL, newName: String)?
    var _lastRenameSkippedURIs: [String] = []
    #endif

    // LSP rename (renameActiveEditorSymbolViaLSP / canRenameActiveEditorSymbol /
    // showLSPRenamePrompt / dismissLSPRenamePrompt / submitLSPRename) + the shared
    // applyWorkspaceEditToOpenTabs (now internal; the code-action commands below
    // call it cross-file until they move too) → DocumentModel+LSPEditorCommands.swift
    // (TSK-1110 SRP slice). The _lastRenameDispatch / _lastRenameSkippedURIs DEBUG
    // probes above + the lspRenamePrefill / isLSPRenamePromptPresented @Published
    // prompt state stay here.

    // LSP code-actions (codeActionsAtCursor / applyCodeAction / canRequestCodeActions
    // / showCodeActionPicker / dismissCodeActionPicker / pickCodeAction + the harness
    // seam) → DocumentModel+LSPEditorCommands.swift (TSK-1110 SRP slice). The
    // codeActionPicker / codeActionPickerGeneration @Published state stays here.

    /// JS posted a right-click. Build a native NSMenu and pop it at
    /// the screen point CM6 forwarded. Keeps Cmd-click + right-click
    /// → "Go to Definition" symmetric with the source-view's menu.
    public func showEditorContextMenu(
        tabID: UUID, fileURL: URL, request: CMContextMenuRequest
    ) {
        let menu = NSMenu(title: "Editor")

        // Key for the side-storage entry, captured so the `defer` at the
        // end of this method can drop it once `popUp` returns. nil when
        // no LSP item was added (no target to park).
        var menuTargetKey: ObjectIdentifier?

        // LSP nav submenu — only when a language is configured. Gates on the
        // POOL's registry (TSK-963) so the menu item appears exactly when the
        // navigation it triggers will actually dispatch, not when the global
        // default registry happens to map the language.
        if lspLanguageConfigured(for: fileURL) {
            let target = EditorMenuTarget { [weak self] in
                guard let self = self else { return }
                self.handleEditorDefinition(
                    tabID: tabID, fileURL: fileURL,
                    request: CMPositionRequest(
                        line: request.line, character: request.character))
            }
            let goDef = NSMenuItem(
                title: "Go to Definition",
                action: #selector(EditorMenuTarget.invoke(_:)),
                keyEquivalent: "")
            goDef.target = target
            menu.addItem(goDef)
            // NSMenuItem holds only a weak `target`, so a closure-backed
            // shim would deallocate before the action fires. Park it in
            // a side dict for the duration of the (synchronous) popUp.
            let key = ObjectIdentifier(goDef)
            editorMenuTargets[key] = target
            menuTargetKey = key
            menu.addItem(NSMenuItem.separator())
        }

        // Standard editing items. These send the AppKit-standard
        // first-responder selectors; the WKWebView synthesizes them
        // into the embedded contenteditable.
        let cut = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)),
                             keyEquivalent: "")
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)),
                              keyEquivalent: "")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)),
                               keyEquivalent: "")
        cut.isEnabled = request.hasSelection
        copy.isEnabled = request.hasSelection
        menu.addItem(cut); menu.addItem(copy); menu.addItem(paste)

        // WebKit posts CM6's contextmenu coordinates as `screenX/Y`,
        // which originate top-left. NSMenu.popUp expects AppKit
        // screen coords (bottom-left). The flip pivot in the global
        // AppKit coordinate space is the PRIMARY screen's `frame.maxY`
        // (NSScreen.screens[0] — the screen with the menu bar), NOT
        // the height of whichever monitor the cursor is on. Using a
        // secondary screen's frame.height produced wrong y on multi-
        // monitor setups (especially when secondaries had non-zero
        // frame.origin.y, e.g. a portrait monitor below the primary).
        let webkitPoint = request.screenPoint
        let pivotY = (NSScreen.screens.first?.frame.maxY)
            ?? (NSScreen.main?.frame.maxY)
            ?? 0
        let appkitY = pivotY - webkitPoint.y
        let popPoint = NSPoint(x: webkitPoint.x, y: appkitY)
        // CORR-2: `popUp` runs its own synchronous modal tracking loop —
        // the menu-item action (if any) fires DURING this call, before
        // it returns. So the parked target only needs to outlive the
        // popUp; drop it on return so the dict can't grow without bound.
        // (The prior code only overwrote the entry on the NEXT
        // invocation, and since each popUp creates a fresh NSMenuItem
        // with a fresh ObjectIdentifier, no overwrite ever happened and
        // the dict leaked one EditorMenuTarget per right-click.)
        defer {
            if let key = menuTargetKey {
                editorMenuTargets.removeValue(forKey: key)
            }
        }
        menu.popUp(positioning: nil, at: popPoint, in: nil)
    }

    /// Side-storage for NSMenuItem targets created in
    /// `showEditorContextMenu`. NSMenuItem holds only a weak `target`,
    /// so a closure-backed shim would deallocate before the menu action
    /// fires. The entry is parked for the duration of the synchronous
    /// `popUp` and dropped via `defer` on return, so the dict holds at
    /// most one entry and never grows (CORR-2).
    private var editorMenuTargets: [ObjectIdentifier: EditorMenuTarget] = [:]

    // MARK: Editor mode (Phase 6.x — editable plain-text buffer)
    //
    // editorBuffers / hasAnyUnsavedEdits / editorBuffer / ensureEditorBuffer /
    // updateEditorText / saveActiveEditor / saveEditor / discardEditorBuffer +
    // the DirtyClosePrompt typealias → DocumentModel+EditorBuffer.swift
    // (TSK-1110 SRP slice). Buffer storage lives on tabCoordinator/editor.

    // MARK: - Editable HEX (#234)

    /// Latest dirty byte buffer per HEX tab. Stashed here (not just in the
    /// HexView controller) so the close-confirm "Save" branch can write it
    /// back even after the view is torn down, and so a tab switch doesn't
    /// lose the pending edits. Keyed by tab id; cleared on save / discard /
    /// tab close. Bounded by the 4 MB read cap.
    // internal: the HEX edit logic lives in DocumentModel+EditableHex.swift (TSK-1110).
    var hexDirtyBytes: [UUID: Data] = [:]

    // peekHexDirtyBytesForTest / dirtyHexBytes / setHexDirty / stashHexBytes →
    // DocumentModel+EditableHex.swift (TSK-1110 SRP slice).

    /// Per-tab HEX "edit armed" intent — the ViewOnly toggle flipped OFF
    /// while the tab is in `.hex` (#234 / TSK-467). There is a single `.hex`
    /// `ViewMode`, so the armed flag has nowhere to live in the mode enum;
    /// it rides here (mirrors `hexDirtyBytes`). Default empty ⇒ View Only ON
    /// ⇒ read-only, so behaviour is byte-identical until the user opts in.
    var hexEditArmedTabs: Set<UUID> = []

    // isHexEditArmed / setHexEditArmed / saveHexEdits(_:forTabID:) /
    // saveHexEdits(forTabID:) / isHexDirtyTab → DocumentModel+EditableHex.swift
    // (TSK-1110 SRP slice).

    /// Set by `HexView` so a model-side save (close-confirm path) can tell
    /// the live controller to mark its buffer clean. Weak-by-closure; nil
    /// when no hex view is mounted.
    public var hexSavedNotifier: ((UUID) -> Void)?

    // presentHexSaveFailure / presentHexSymlinkPrompt → DocumentModel+EditableHex.swift
    // (TSK-1110 SRP slice).

    /// The displayed source text plus its utf8 byte length, computed
    /// once per body re-eval. The length is carried so callers (the
    /// syntax-highlight path) can form a cache key without re-walking
    /// the string with `utf8.count` on every re-eval (PERF-04).
    public struct DisplayedText: Sendable {
        public let text: String
        public let byteLength: Int
        public let modifiedTime: Date?
        public init(text: String, byteLength: Int, modifiedTime: Date?) {
            self.text = text
            self.byteLength = byteLength
            self.modifiedTime = modifiedTime
        }
    }

    // displayedText(for:) / displayText(for:) → DocumentModel+DisplayText.swift
    // (TSK-1110 SRP slice). [The DisplayedText struct above stays — it's the
    // shared return type.]

    // `splitPaneText(for:fallback:)` (TSK-806) moved to
    // `DocumentModel+Split.swift` (TSK-308) — split-pane API cluster.

    // MARK: Syntax highlighting

    /// PERF #5 (2026-05-25): per-tab cache, owned by
    /// `HighlightCacheActor` and stored in `highlightCaches`. The
    /// previous design kept a single `@Published highlightCache` on
    /// `DocumentModel` — every tokenize completion republished the
    /// model, which cascaded re-bodies through every observing view
    /// even though only the source view depended on the runs.
    ///
    /// Now: each tab has its own actor. Tokenize completions bump
    /// the actor's `@Published version`, which only the source view
    /// for that tab observes. DocumentModel never republishes.
    ///
    /// `HighlightCacheKey` lives in `Highlight/HighlightCacheActor.swift`
    /// — re-aliased here for source compatibility with callers that
    /// reference `DocumentModel.HighlightCacheKey`.
    public typealias HighlightCacheKey = ViewerUI.HighlightCacheKey
    // internal (not private) so the DocumentModel+Highlighting.swift SRP slice
    // (TSK-1110) can read/populate the per-tab actor registry.
    var highlightCaches: [UUID: HighlightCacheActor] = [:]
    // highlightCacheActor(forTabID:) / highlightRuns(...) →
    // DocumentModel+Highlighting.swift.

    // MARK: - View-hosting tabs (WAVE 2b item 1)
    //
    // A view-hosting tab renders an arbitrary embedded SwiftUI `rootView`
    // (the one genuine integration point for the built-but-unwired WAVE 2a
    // views). The `DocumentState.hostedView(id:title:)` case lives in
    // ViewerCore (Sendable, no SwiftUI); the actual `AnyView` payload is
    // owned HERE, keyed by the hosted-view id, because SwiftUI types must
    // not leak into ViewerCore. The registry is purged on tab close via
    // `purgeCaches`, so a closed File-History tab releases its model.
    // Internal (not private) so the open/resolve logic can live in the
    // DocumentModel+ViewHosting.swift SRP slice (TSK-1110).
    var hostedViews: [UUID: AnyView] = [:]
    /// Canvas rendered-lens controllers by tab id (M3.S1; see
    /// DocumentModel+ViewHosting for the accessors).
    var canvasControllers: [UUID: CanvasTabController] = [:]
    // hostedView(forID:) / openHTTPClient() / openHostedView(_:) →
    // DocumentModel+ViewHosting.swift.

    /// Currently-active syntax theme. Computed from system appearance;
    /// re-publishes when the user flips Light/Dark. The override is driven by
    /// Settings → Appearance → Theme (Follow System / Xcode Light / Xcode Dark)
    /// and persists across relaunch via `PreferencesStore` (app-wide global,
    /// owner-locked #184). Without the `didSet`, a chosen Light/Dark reverted to
    /// Follow System on every reload (TSK-101); restored in `init` alongside
    /// `zoom`/`sourceWordWrap`.
    @Published public var themeOverride: SyntaxTheme.Name? = nil {
        didSet { preferences.themeOverrideRaw = themeOverride?.rawValue }
    }
    /// TSK-641 stage 2: the definition-based selection (built-ins + user +
    /// VS Code imports via ThemeStore). Wins over the legacy two-theme
    /// override; nil = legacy behavior. Changing it invalidates the
    /// rendered-HTML cache so the tokCSS override re-splices.
    @Published public var selectedThemeID: String? = ThemeStore.shared.selectedID {
        didSet {
            ThemeStore.shared.selectedID = selectedThemeID
            renderedHTMLCache.removeAll()
            // TSK-641 stage 4: the chrome surfaces follow the selection.
            // The @Published change re-bodies the chrome views; they read
            // the new ChromeTheme on that pass. nil = system-native.
            ChromeTheme.current = activeThemeDefinition.map { ChromeColors(from: $0) }
        }
    }

    // activeThemeDefinition / activeTheme / activeThemeCMPalette /
    // themedExtraStylesheet → DocumentModel+Theming.swift (TSK-1110 SRP slice).

    // highlightRuns(forTabID:url:text:language:modifiedTime:) →
    // DocumentModel+Highlighting.swift (TSK-1110 SRP slice).


    // MARK: Rendered markdown cache

    /// Memoizes `HTMLRenderer.renderPage` output keyed by tab identity
    /// + the file's filesystem identity (mtime + byteCount). Without
    /// this, ContentView.body re-runs renderPage on every model
    /// mutation — and renderPage now drives TreeSitter highlighting
    /// for every fenced code block, which is expensive enough to be
    /// visible as latency.
    ///
    /// Why mtime + byteCount instead of a content hash:
    ///   - The prior key was `(URL, fnv64(contents))`. fnv64 walks
    ///     the entire UTF-8 of the file on every body re-eval —
    ///     ~1ms per MB on the main actor. With finding #1's republish
    ///     storm, that was the dominant cost for multi-MB markdown.
    ///   - mtime + byteCount is O(1) per lookup and `TextFile`
    ///     captures both at load time, so the key formation never
    ///     touches the file contents.
    ///   - Same-byte-length reloads (`# Hello\n` → `# World\n`)
    ///     still invalidate because the watcher reload path runs
    ///     `TextFileLoader.load(url:)` again, which re-stats the
    ///     file and gets a new mtime. APFS mtime is nanosecond-
    ///     resolution; back-to-back rewrites produce distinct
    ///     timestamps in practice.
    ///   - `EditorBuffer.save(...)` re-stats after write to capture
    ///     the new mtime (see `saveEditorBuffer(forTabID:)`).
    ///
    /// Stylesheet doesn't enter the key because it only changes
    /// between app launches.
    public struct RenderedHTMLKey: Hashable, Sendable {
        public let tabID: UUID
        public let byteCount: Int
        /// `nil` only for synthetic `TextFile`s constructed without
        /// an mtime (in-memory tests). Two same-tab, same-bytecount
        /// renders with nil mtime collapse to the same cache entry —
        /// acceptable for tests; in production every `TextFile` from
        /// the loader carries one.
        public let modifiedTime: Date?
    }
    // internal (not private) so the DocumentModel+RenderedCache.swift SRP slice
    // (TSK-1110) owns the cache get/put/evict logic over this storage.
    var renderedHTMLCache: [RenderedHTMLKey: String] = [:]
    /// Insertion-order list mirroring `renderedHTMLCache`. Used to evict
    /// the OLDEST entries on overflow (S2-G). Previously eviction used
    /// `Dictionary.keys.prefix(N)`, whose iteration order is
    /// implementation-defined — sometimes evicting the entry we'd just
    /// inserted, defeating the cache.
    var renderedHTMLCacheOrder: [RenderedHTMLKey] = []
    // CACHE SIZING (corrected 2026-06-01 — P3d): the value is a plain Swift
    // String (the rendered HTML page), a 2-5× inflation of source size from
    // code-fence highlighting. For the COMMON case (KB-sized markdown) four
    // entries are TENS OF KB, not megabytes. The "15-20 MB" prior wording was
    // a pathological worst-case ceiling (four simultaneously-cached ~1 MB,
    // almost-entirely-fenced docs) AND it sent profiling chasing the wrong
    // object: the MB-scale rendered-markdown memory is the WebKit WebContent
    // process (parsed DOM + render tree + IOSurface backing), a SEPARATE
    // process this in-heap String cache has nothing to do with (see
    // LESSONS.md WebKit XPC attribution + the P3a/P3e analysis). Four covers
    // the typical "couple of open MDs" working set; cold-render on a miss is
    // fast.
    static let renderedHTMLCacheMax = 4

    // MARK: - Raw-HTML JavaScript opt-in — state (logic in DocumentModel+HTMLJavaScript.swift)
    //
    // SECURITY: rendering a raw `.html` file runs JavaScript DEFAULT-DENY (see
    // `HTMLDocumentPolicy` / `HTMLRenderedView`). The opt-in storage is a SET of
    // opted-in tab ids — the secure default is ABSENCE (no entry ⇒ JS off); we
    // never store "off", only an explicit opt-IN, so a fresh/restored/forgotten
    // tab can only fail closed. The set is pruned on tab close via `purgeCaches`.
    // The opt-in/trust methods live in DocumentModel+HTMLJavaScript.swift; this
    // stored state stays on the class (an extension can't declare stored props).
    // `htmlJavaScriptOptIn` is widened private→internal so those methods mutate it.
    @Published var htmlJavaScriptOptIn: Set<UUID> = []

    /// PER-DOCUMENT "trust this local HTML" store (TSK-1189). Path-keyed +
    /// persisted; `var` so tests can inject a throwaway suite. The trust
    /// decision is fail-closed (`HTMLTrustPolicy.isTrusted`).
    public var htmlTrustStore = HTMLTrustStore()

    /// PER-DOCUMENT network consent for a TRUSTED HTML doc (TSK-1203). Separate,
    /// second escalation: a trusted page's `connect-src` stays `'none'` until the
    /// user allows specific hosts for THAT page. `var` so tests inject a suite.
    public var htmlNetworkConsent = HTMLNetworkConsentStore()

    // Rendered-markdown cache LOGIC → DocumentModel+RenderedCache.swift
    // (TSK-1110 SRP slice): renderedHTML / renderedHTMLIfCached /
    // requestRenderedHTML / storeRenderedHTML. The storage above stays here.

    /// Keys with a background render in flight; dedupes the request storm
    /// from repeated body evaluations while the first render runs.
    var renderedHTMLInFlight: Set<RenderedHTMLKey> = []

    // MARK: Print / Export as PDF (TSK-638, phase 1: rendered pages)

    /// Bumped to ask the SELECTED rendered view to run the AppKit print
    /// operation (the representable owns the live WKWebView; the model
    /// only signals — the find-nonce pattern).
    @Published public var renderedPrintRequest: Int = 0
    /// Export request: nonce + destination. The rendered view answers by
    /// calling `recordPDFExportResult`.
    @Published public var renderedPDFExportRequest: PDFExportRequest?
    /// Last export outcome (status line + tests).
    @Published public var renderedPDFExportResult: PDFExportResult?

    public struct PDFExportRequest: Equatable, Sendable {
        public let nonce: Int
        public let url: URL
    }
    public struct PDFExportResult: Equatable, Sendable {
        public let nonce: Int
        public let ok: Bool
        public let message: String
    }

    // canPrintRenderedPage / printRenderedPage() / exportRenderedPDF(to:) /
    // recordPDFExportResult(...) → DocumentModel+PrintExport.swift (TSK-1110 SRP slice).

    // MARK: Derived from current tab

    public var currentState: DocumentState { tabs.selected?.state ?? .empty }
    public var currentURL: URL? { tabs.selected?.url }
    public var currentViewMode: ViewMode { tabs.selected?.viewMode ?? .rendered }

    /// TSK-1256: a line-precise `mdv://` reference to the current editor line in the
    /// active tab — the single-line shape behind the `copy-reference` verb /
    /// "Copy Reference" command (the range-aware entry point is
    /// `currentSelectionReference`). The pure shape (url + line) is `Self.lineReference`,
    /// so the reference form is host-testable without standing up a model.
    public func currentLineReference() -> String? {
        Self.lineReference(url: currentURL, line: sourceView.sourceSelection.line)
    }

    /// TSK-942: an `mdv://` reference to the current editor SELECTION — a line RANGE
    /// when a multi-line span is selected, otherwise the single current line. The
    /// `copy-reference` verb uses this so "copy a reference to these lines" carries
    /// the whole selection. (The source view populates the selection length from the
    /// NSTextView selectedRange; the CM6 caret mirror reports length 0, so CM6
    /// gracefully degrades to the single-line reference.)
    public func currentSelectionReference() -> String? {
        let sel = sourceView.sourceSelection
        guard sel.length > 0, let text = activeFileText else { return currentLineReference() }
        let endLine = TextLineGeometry.endLine(
            in: text, startLine: sel.line, startColumn: sel.column, utf16Length: sel.length)
        return Self.lineRangeReference(url: currentURL, startLine: sel.line, endLine: endLine)
    }

    /// Pure builder: a file reference carrying the 1-based `line`, or nil if no url.
    public static func lineReference(url: URL?, line: Int) -> String? {
        url.map { ElementRef.file(path: $0.path, line: line, endLine: nil).serialized }
    }

    /// TSK-942: an `mdv://` reference to a LINE RANGE (a selected span), for
    /// "copy a reference to these lines for the agent". Collapses to a single-line
    /// reference when the range is one line.
    public static func lineRangeReference(url: URL?, startLine: Int, endLine: Int) -> String? {
        url.map {
            ElementRef.file(path: $0.path, line: startLine,
                            endLine: endLine > startLine ? endLine : nil).serialized
        }
    }

    // openTerminalHere() / openTerminalInApp(at:isDirectory:) /
    // insertTerminalFavorite(_:) → DocumentModel+TerminalLaunch.swift (TSK-1110 SRP slice).

    /// TSK-769: user-curated favorite terminal commands (a cross-session
    /// shortlist; the PTY shell still owns up-arrow history). Hand-editable JSON;
    /// the Terminal menu lists these for one-click insertion.
    public let terminalFavorites = TerminalFavoritesStore()

    /// True when there's a file OR a project folder open — i.e. the status
    /// footer has something useful to show (path/metrics for a file; the
    /// folder-scoped git chip + "—" path for a folder-only project). TSK-738:
    /// the footer used to gate on `currentURL != nil` only, so it vanished after
    /// relaunch / opening a folder with no file tab selected (openFolder sets the
    /// sidebar root but selects no tab → currentURL nil).
    public var hasOpenContext: Bool { currentURL != nil || sidebar.rootURL != nil }

    // activeFileUnanalyzedByLSP / activeFileHasLSPSymbols / fetchActiveCodeSymbols()
    // → DocumentModel+ActiveFileLSP.swift (TSK-1110 SRP slice).

    public var supportsViewModeToggle: Bool {
        guard let url = currentURL else { return false }
        let cat = currentCategory ?? FileTypeDetector.category(for: url)
        return cat == .markdown || cat == .mermaid
    }

    /// The effective category for the current tab — its "Open As…"
    /// override if set, else extension/UTI auto-detection (WAVE 2b item 6).
    public var currentCategory: FileCategory? {
        if let override = tabs.selected?.categoryOverride { return override }
        guard let url = currentURL else { return nil }
        return FileTypeDetector.category(for: url)
    }

    /// Whether the current tab has an explicit "Open As…" override.
    public var hasCategoryOverride: Bool {
        tabs.selected?.categoryOverride != nil
    }

    // openAsCategories / openAs / setCurrentCategoryOverride / defaultViewMode /
    // setDefaultViewMode / sniffCategory → DocumentModel+OpenAs.swift (TSK-1110 SRP slice).

    // MARK: - Per-file view-mode lock (TSK-811)

    // currentViewModeIsLocked / toggleCurrentViewModeLock() →
    // DocumentModel+ViewModeLock.swift (TSK-1110 SRP slice).

    /// Full file path of the current tab, with `$HOME` shortened to `~`.
    /// Returns nil when no file is loaded.
    /// Uses `abbreviatingWithTildeInPath` — the AppKit standard that
    /// matches Finder's path-bar abbreviation behavior.
    public var currentFilePath: String? {
        guard let url = currentURL else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    public var viewModeBinding: Binding<ViewMode> {
        Binding(
            get: { [weak self] in self?.currentViewMode ?? .rendered },
            set: { [weak self] in self?.setCurrentViewMode($0) }
        )
    }

    // MARK: Opening files

    /// Opens a URL into the current tab if it's blank, switches to an existing
    /// tab that shows the URL, or appends a new tab.
    public func open(url: URL) {
        openResolved(url, forceNewTab: false)
    }

    /// Opens `url` into the ONE ephemeral *preview* slot (VSCode-style): a
    /// single-click / arrow-nav in the sidebar reuses this slot instead of
    /// spawning a tab per file (TSK-306 / TSK-272). An explicit commit —
    /// `open(url:)` (Enter / double-click), opening the same file again, or
    /// editing the buffer — promotes it to a permanent tab. If `url` is already
    /// open in any tab it is simply revealed (never previewed, never
    /// duplicated). See `docs/PREVIEW_TAB_DESIGN.md`.
    public func openPreview(url: URL) {
        openResolved(url, forceNewTab: false, preview: true)
    }

    /// Always opens a new tab — does NOT reuse an existing tab that shows
    /// the same URL or a blank tab. Used by "Open in New Tab" context menu.
    public func openInNewTab(_ url: URL) {
        openResolved(url, forceNewTab: true)
    }

    /// Universal Paste (TSK-1163 / TSK-958): read the clipboard, resolve its best
    /// viewer kind (`PasteDispatch`), materialize the payload to a per-user temp
    /// file (`UniversalPastePlan`), and open it in a new tab. The clipboard is
    /// treated as DATA — never executed. No-op + beep when nothing pasteable is
    /// present. The pasteboard read + temp write are AppKit (review/VM); the
    /// type-precedence + materialization DECISION is host-tested
    /// (PasteDispatchTests / UniversalPastePlanTests).
    @discardableResult
    public func universalPaste(from pasteboard: NSPasteboard = .general) -> Bool {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let htmlBody = pasteboard.data(forType: .html)
            .flatMap { String(data: $0, encoding: .utf8) }
        guard let target = PasteDispatch.resolve(types: types, htmlBody: htmlBody) else {
            NSSound.beep()  // nothing recognized on the clipboard
            return false
        }
        let plan = UniversalPastePlan.plan(for: target)
        // TSK-1327: a rich-text paste that carries an HTML representation becomes
        // STRUCTURED Markdown (bullets→"- ", headings→"#", bold/links preserved)
        // via the host-tested RichTextHTMLParser — the owner's "format pasted rich
        // text appropriately" ask — instead of a raw .rtf dump. Falls through to the
        // plan (raw RTF) when there's no usable HTML body or the conversion is empty.
        if target == .richText, let html = htmlBody, !html.isEmpty {
            let markdown = RichTextHTMLParser.markdown(fromHTML: html)
            if !markdown.isEmpty,
               let mdURL = Self.writePasteTemp(Data(markdown.utf8), ext: "md",
                                               name: plan.suggestedName) {
                openInNewTab(mdURL)
                postPasteFeedback(
                    UniversalPastePlan.humanDescription(for: target, convertedToMarkdown: true))
                return true
            }
        }
        let url: URL?
        switch plan.source {
        case .fileURL:
            url = Self.pasteboardFileURL(pasteboard)
        case .data(let preferred, let fallbacks, let ext):
            url = Self.materializePasteData(pasteboard, preferred: preferred,
                                            fallbacks: fallbacks, ext: ext,
                                            name: plan.suggestedName)
        case .string(let ext):
            url = Self.materializePasteString(pasteboard, ext: ext, name: plan.suggestedName)
        }
        guard let url else { NSSound.beep(); return false }
        openInNewTab(url)
        postPasteFeedback(UniversalPastePlan.humanDescription(for: target))
        return true
    }

    /// TSK-1479: announce what the paste became ("Pasted as table") + offer a
    /// one-click Undo that closes the tab the paste created. The tab id is
    /// captured NOW; the undo re-resolves it at click time so it's a safe
    /// no-op if the user already closed (or moved) the tab. (⌘Z is NOT routed
    /// here — Edit→Undo belongs to the text-editing chain; the toast button
    /// is the affordance.)
    private func postPasteFeedback(_ description: String) {
        guard let created = tabs.selected?.id else { return }
        toasts.post(.success, description, actionLabel: "Undo") { [weak self] in
            guard let self,
                  let idx = self.tabs.tabs.firstIndex(where: { $0.id == created })
            else { return }
            self.closeTab(at: idx)
        }
    }

    /// The file URL carried on the pasteboard (file-URLs only), or nil.
    private static func pasteboardFileURL(_ pb: NSPasteboard) -> URL? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]
        return urls?.first
    }

    /// Read the preferred (or a fallback) data representation and write it to a
    /// temp file. nil if no representation is present or the write fails.
    private static func materializePasteData(
        _ pb: NSPasteboard, preferred: String, fallbacks: [String], ext: String, name: String
    ) -> URL? {
        for raw in [preferred] + fallbacks {
            if let data = pb.data(forType: NSPasteboard.PasteboardType(raw)), !data.isEmpty {
                return writePasteTemp(data, ext: ext, name: name)
            }
        }
        return nil
    }

    private static func materializePasteString(_ pb: NSPasteboard, ext: String, name: String) -> URL? {
        guard let s = pb.string(forType: .string), !s.isEmpty,
              let data = s.data(using: .utf8) else { return nil }
        return writePasteTemp(data, ext: ext, name: name)
    }

    /// Write pasted bytes to a uniquely-named per-user temp file (never the
    /// owner's Documents/Desktop — sanctioned `temporaryDirectory`). nil on failure.
    private static func writePasteTemp(_ data: Data, ext: String, name: String) -> URL? {
        let base = name.isEmpty ? "Pasted" : name
        let unique = "\(base)-\(UUID().uuidString.prefix(8)).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(unique)
        do { try data.write(to: url); return url } catch { return nil }
    }

    private func openResolved(_ url: URL, forceNewTab: Bool, preview: Bool = false) {
        let openToken = PerfSignpost.begin(.open, "DocumentModel.openResolved")
        defer { PerfSignpost.end(openToken) }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        // Off-main eager open for large text files. `controller.open`
        // reads + decodes the entire file synchronously; for a few-
        // hundred-MB log that is a multi-hundred-ms main-thread stall
        // (beachball on open). We stat first (cheap, no read) and, when
        // the file is above the loader's soft watermark AND would take
        // the text-load path (not a native preview / media URL handled
        // without a read), open the tab in `.loading(URL)` and read off-
        // main — reusing the exact `materializeIfNeeded` identity-guard
        // pattern (Task.isCancelled + re-find-by-id) so a slow read
        // never lands in the wrong or closed tab. The TSK-332 content
        // hint needs the sync decode (skipped here), so resolve the mode
        // WITHOUT it; the async load lands a `.loaded` state and
        // `availableViewModes` re-derives the hint once it does.
        if shouldDeferOpenOffMain(resolved) {
            let mode = resolveOpenMode(resolved, forceNewTab: forceNewTab, isRenderableText: nil)
            openLargeFileOffMain(resolved, forceNewTab: forceNewTab, viewMode: mode, preview: preview)
            return
        }

        let state = controller.open(url: resolved)
        // TSK-332: feed the loader's text/binary verdict back into mode
        // resolution so an unknown-/binary-EXTENSION file that decoded as
        // text (`.loaded`) opens as Source instead of the extension-only
        // HEX default (and offers Source in the picker).
        let mode = resolveOpenMode(
            resolved, forceNewTab: forceNewTab,
            isRenderableText: Self.renderableTextHint(state))
        if forceNewTab {
            tabCoordinator.append(Tab(url: resolved, state: state, viewMode: mode))
        } else if preview {
            // Preview slot: reuse the one ephemeral tab (or reveal an existing
            // permanent one). See `openPreview(url:)` / `TabsState.openPreview`.
            //
            // TSK-742/743/744: the slot REUSES one tab id when swapping files, and
            // the editor buffer + scroll/cursor/etc. are keyed by tab id — so on a
            // sidebar file-switch the editor pane kept the PREVIOUS file's content
            // (742) and scroll (743/744). Capture the preview tab's identity, do
            // the swap, then if the SAME id now shows a DIFFERENT, non-dirty file,
            // drop its stale id-keyed editor state so the next ensureEditorBuffer
            // reseeds the new file. (Editing promotes a preview to a permanent tab,
            // so a dirty preview shouldn't occur; the !isDirty guard preserves
            // edits defensively rather than discarding unsaved work.)
            let priorPreview = tabCoordinator.tabs.tabs.first(where: { $0.isPreview })
                .map { (id: $0.id, url: $0.url) }
            // TSK-743 (source channel): the slot rebuild below drops
            // `Tab.scrollTopLine`, so refresh the OUTGOING file's source-view
            // scroll from the live geometry and remember it by URL BEFORE the
            // swap (mirrors the editor stash) — the view still shows the
            // outgoing file at this instant, so its scroll is current.
            if let prior = priorPreview, prior.url != resolved,
               let priorURL = prior.url,
               let idx = tabCoordinator.tabs.tabs.firstIndex(where: { $0.id == prior.id }) {
                captureScroll(forTabAt: idx)
                if let line = tabCoordinator.tabs.tabs[idx].scrollTopLine, line > 0 {
                    rememberPreviewSourceLine(line, for: priorURL)
                }
            }
            tabCoordinator.openPreview(url: resolved, state: state, viewMode: mode)
            if let prior = priorPreview,
               let now = tabCoordinator.tabs.tabs.first(where: { $0.id == prior.id && $0.isPreview }),
               now.url != prior.url,
               !(tabCoordinator.editorBuffers[prior.id]?.isDirty ?? false) {
                // TSK-743: remember the OUTGOING file's scroll/cursor before the
                // reset drops it, so returning to it via preview restores the
                // position; TSK-744: reset the reused id so the INCOMING file
                // doesn't inherit it; then restore the incoming file's own
                // remembered position (no-op/top when never previewed = isolation).
                if let priorURL = prior.url {
                    editor.stashPreviewState(forTabID: prior.id, url: priorURL)
                }
                tabCoordinator.discardEditorBuffer(forTabID: prior.id)
                editor.resetEditorState(forTabID: prior.id)
                editor.restorePreviewState(forTabID: prior.id, url: resolved)
                // TSK-743 (source channel): stamp the INCOMING file's remembered
                // source line onto the reused tab so `restoreScroll` re-applies
                // it (nil when never previewed → top of file, isolation kept).
                if let idx = tabCoordinator.tabs.tabs.firstIndex(where: { $0.id == prior.id }) {
                    var t = tabCoordinator.tabs.tabs[idx]
                    t.scrollTopLine = previewSourceLineByURL[resolved]
                    tabCoordinator.replace(at: idx, with: t)
                }
            }
        } else {
            tabCoordinator.openOrReveal(url: resolved, state: state, viewMode: mode)
        }
        // Carry HEX mode across file switch: if the active tab now
        // shows a different file in HEX, but the underlying state is
        // text, kick the binary load so the picker doesn't lie about
        // what's on screen.
        //
        // NOT for `.preview`: a `.preview` state is ALWAYS a native-
        // preview category (image/audio/video/pdf/sqlite). Their default
        // ViewMode is now the first-class `.preview` lens (Bug B fix), so
        // a fresh open won't even enter this `.hex` block — but the case
        // is kept defensive. Hex-loading a preview here flipped `.preview`
        // → `.binary`, tearing down the just-mounted native viewer (e.g.
        // the SQLite browser) and showing a hex dump instead. The user
        // reaches HEX for a preview only via an explicit
        // `setCurrentViewMode(.hex)`, which still loads the bytes.
        if let t = tabs.selected, t.viewMode == .hex {
            switch t.state {
            case .binary, .empty, .loading, .hostedView, .preview: break
            case .loaded, .error:
                loadBinaryAsync(url: resolved, intoTabID: t.id)
            }
        }
        updateDerived()
        recordOpenedFile(state: state, resolved: resolved)
        startWatchingCurrentFile()
        // item9: follow-mode reveal for opens (open doesn't route through
        // selectTab). Select + expand within the current root only.
        followActiveTabIfNeeded()
    }

    /// Resolve the view mode a freshly-opened tab should land in. New tabs
    /// (`forceNewTab`) take the file's natural default; otherwise the active
    /// tab's explicitly-picked non-default mode (e.g. HEX, Format) is CARRIED
    /// forward when the destination actually offers it. `isRenderableText` is
    /// the TSK-332 content hint threaded through both the default and the
    /// carry-membership check so an unknown-extension text file resolves to —
    /// and offers — Source rather than the extension-only HEX default.
    private func resolveOpenMode(
        _ resolved: URL, forceNewTab: Bool, isRenderableText: Bool?
    ) -> ViewMode {
        // The per-CATEGORY default (TSK-671), then the per-FILE lock (TSK-811)
        // layered on top: a filename/extension lock WINS over the category
        // default for the matching file, but only when the locked lens is in
        // this file's `availableModes` (stale/cross-type locks degrade to the
        // category default rather than desyncing the picker from the pane).
        let categoryDefault = ViewModeOptions.defaultMode(
            for: resolved, isRenderableText: isRenderableText,
            preferred: preferences.viewModeDefaults)
        let available = ViewModeOptions.availableModes(
            for: resolved, isRenderableText: isRenderableText)
        let initialMode = viewModeLocks.resolvedMode(
            for: resolved, available: available, inferredDefault: categoryDefault)
        if forceNewTab { return initialMode }
        // A per-file lock is the user's EXPLICIT pin for THIS file, so it wins
        // over carrying the active tab's mode forward — opening a locked file
        // always lands in its locked lens (TSK-811).
        if viewModeLocks.isLocked(for: resolved) { return initialMode }
        // If the active tab has a non-default mode the user explicitly picked
        // (e.g. HEX, Format), carry it. Otherwise use the new file's default.
        if let cur = tabs.selected, cur.viewMode != .rendered, cur.viewMode != .source {
            // Only carry a mode the DESTINATION file actually offers.
            // `.preview` is valid only for native-preview categories
            // (image/audio/video/pdf/sqlite); carrying it onto a text file —
            // or `.table`/`.diff` onto a file that doesn't support them —
            // would leave the picker selecting a mode that isn't in
            // `availableModes`, desyncing picker vs pane. Falling back to the
            // destination's natural default keeps the carry useful for shared
            // modes (e.g. HEX→HEX, image→image preview) without smuggling an
            // invalid one.
            //
            // SC-CHROME-02: `availableModes` membership alone is NOT enough
            // for native-preview destinations. Those expose `[.preview, .hex]`,
            // so a carried `.hex` passes the membership test — but the loader
            // returns a `.preview` document state and the HEX-load block in
            // `openResolved` correctly skips it, so the pane stays the native
            // lens while the picker reads HEX (picker↔pane desync). A native-
            // preview file renders ONLY through `.preview`; carrying anything
            // but `.preview` onto it is a guaranteed desync, so fall back to
            // its natural default (`.preview`) instead.
            if ViewModeOptions.availableModes(
                for: resolved, isRenderableText: isRenderableText).contains(cur.viewMode),
               !(isNativePreviewDestination(resolved) && cur.viewMode != .preview) {
                return cur.viewMode
            }
        }
        return initialMode
    }

    /// True when `openResolved` should route the file read off the main
    /// thread instead of slurping it synchronously. Gated on (a) the
    /// file being above the loader's soft watermark and (b) it NOT being
    /// a native-preview category (image/audio/video/pdf/sqlite) — those
    /// never read bytes into Swift memory, so the sync path is already
    /// cheap and routing them through `.loading` would just add a flash.
    /// Pure routing decision (host-testable seam for TSK-842): native-preview
    /// categories never take the text-load path, so they never defer; otherwise
    /// defer iff the file is larger than `threshold` (the loader's
    /// `deferReadOffMainBytes`). Lowered from the 64 MiB `softWarnBytes` cliff
    /// so a SYNC read on main of a cold / iCloud-stubbed file no longer freezes
    /// the UI.
    static func shouldDeferOpen(category: FileCategory, bytes: Int, threshold: Int) -> Bool {
        switch category {
        case .image, .audio, .video, .pdf, .sqlite:
            return false
        default:
            return bytes > threshold
        }
    }

    private func shouldDeferOpenOffMain(_ resolved: URL) -> Bool {
        guard let bytes = (try? FileManager.default
            .attributesOfItem(atPath: resolved.path)[.size]) as? Int
        else { return false }
        return Self.shouldDeferOpen(
            category: FileTypeDetector.category(for: resolved),
            bytes: bytes,
            threshold: controller.loader.deferReadOffMainBytes)
    }

    /// True when `resolved` is a native-preview category
    /// (image/audio/video/pdf/sqlite) — i.e. it renders through the
    /// `.preview` document state, and `.preview` is its only non-HEX
    /// lens. Carry-mode uses this to refuse carrying a non-`.preview`
    /// mode (e.g. `.hex`) onto such a destination: `.hex` is in its
    /// `availableModes` but the loaded state is `.preview`, so the
    /// picker would contradict the pane (SC-CHROME-02). Mirrors the
    /// category switch in `shouldDeferOpenOffMain`; kept a local switch
    /// because `ViewModeOptions.hasNativePreview` is internal to
    /// ViewerKit and not visible here.
    private func isNativePreviewDestination(_ resolved: URL) -> Bool {
        switch FileTypeDetector.category(for: resolved) {
        case .image, .audio, .video, .pdf, .sqlite:
            return true
        default:
            return false
        }
    }

    /// Open a large text file off the main thread. Mirrors
    /// `materializeIfNeeded`: place the tab in `.loading(url)`, read on a
    /// detached Task, then re-find the tab by id and swap to the final
    /// state only if it is still `.loading` for the same URL. Post-open
    /// bookkeeping (history / recents / sidebar root / watcher) runs on
    /// completion via `recordOpenedFile`, matching the sync path.
    private func openLargeFileOffMain(_ resolved: URL, forceNewTab: Bool, viewMode: ViewMode, preview: Bool = false) {
        let loading: DocumentState = .loading(resolved)
        let tabID: UUID
        if forceNewTab {
            let tab = Tab(url: resolved, state: loading, viewMode: viewMode)
            tabCoordinator.append(tab)
            tabID = tab.id
        } else {
            // Preview opens reuse the ephemeral slot just like the sync path;
            // the off-main read still lands by tab id (the materialize guard
            // below is identity-based, so promote-during-load is safe).
            let idx = preview
                ? tabCoordinator.openPreview(url: resolved, state: loading, viewMode: viewMode)
                : tabCoordinator.openOrReveal(url: resolved, state: loading, viewMode: viewMode)
            tabID = tabs.tabs.indices.contains(idx) ? tabs.tabs[idx].id : UUID()
        }
        updateDerived()
        // Watch immediately — the tab + URL are known now; we don't need
        // the contents to bind the file watcher, and waiting for the read
        // would miss edits during a multi-hundred-ms load.
        startWatchingCurrentFile()

        tabCoordinator.materializeTask(forTabID: tabID)?.cancel()
        let matToken = PerfSignpost.begin(.materialize, "openLargeFileOffMain")
        let task = Task.detached(priority: .userInitiated) { [controller] in
            let state = controller.open(url: resolved)
            PerfSignpost.end(matToken)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.tabCoordinator.clearMaterializeTask(forTabID: tabID)
                if Task.isCancelled { return }
                guard let idx = self.tabs.tabs.firstIndex(where: { $0.id == tabID }) else {
                    return
                }
                let current = self.tabs.tabs[idx]
                guard case .loading(let pendingURL) = current.state,
                      pendingURL == resolved else { return }
                var t = current
                t.state = state
                // TSK-900: this open resolved the mode without the content hint
                // (the bytes weren't read yet), so an unknown-/binary-extension
                // TEXT file was parked in `.hex`. Now the verdict is in — upgrade
                // a hex tab that decoded as text to its content-aware default,
                // rather than dumping a text file as hex below.
                t.viewMode = Self.deferredLoadViewModeUpgrade(
                    current: t.viewMode,
                    isLoadedText: Self.renderableTextHint(state) == true,
                    url: resolved, preferred: self.preferences.viewModeDefaults)
                self.tabCoordinator.replace(at: idx, with: t)
                // Carry HEX mode (mirrors the sync path + materializeIfNeeded).
                // Exclude `.preview`: a native-preview category whose default
                // (and only) ViewMode is .hex must NOT be auto-hex-loaded, or
                // the just-mounted native viewer (SQLite browser / image /
                // PDF) is torn down and replaced with a hex dump. Today
                // `shouldDeferOpenOffMain` already excludes the preview
                // categories so `.preview` can't reach here, but keep all
                // three carry blocks identical so a future change to the
                // defer-gate can't silently reintroduce the flip.
                if t.viewMode == .hex {
                    switch state {
                    case .binary, .empty, .loading, .hostedView, .preview: break
                    case .loaded, .error:
                        self.loadBinaryAsync(url: resolved, intoTabID: tabID)
                    }
                }
                self.updateDerived()
                self.recordOpenedFile(state: state, resolved: resolved)
            }
        }
        tabCoordinator.setMaterializeTask(task, forTabID: tabID)
    }

    /// Shared post-open bookkeeping: record a successful open as a recent
    /// and auto-root the sidebar to the file's parent if none is open.
    /// Errors / empty / still-loading states record nothing. Extracted so
    /// both the synchronous open path and the off-main large-file
    /// completion run identical bookkeeping.
    func recordOpenedFile(state: DocumentState, resolved: URL) {
        switch state {
        case .loaded, .binary, .preview:
            history.record(url: resolved, kind: .file)
            recents = history.recent()
            // Auto-root the sidebar to the file's containing folder if
            // no folder is currently open. The user explicitly opened
            // a file, so we already have read access to its parent.
            // (Auto-restore at launch is more cautious — it skips TCC-
            // protected roots — but this path runs in response to a
            // user action, so it's safe to set.)
            if sidebar.rootURL == nil {
                let parent = resolved.deletingLastPathComponent()
                // TSK-1294: do NOT auto-root the per-user temp dir. The landing
                // "New File"/"New Image" fallback creates a scratch file there
                // when no folder is open; rooting it would enumerate the (huge,
                // churny) temp dir — a multi-second hang — and dump it into the
                // sidebar. It's an internal scratch location, not a workspace.
                let tempDir = FileManager.default.temporaryDirectory
                    .standardizedFileURL.resolvingSymlinksInPath()
                if parent.path != tempDir.path {
                    sidebar.setRoot(parent)
                    sidebar.setSelected(resolved)
                    preferences.lastFolderURL = sidebar.rootURL
                }
            }
        case .empty, .error, .loading, .hostedView:
            break
        }
    }

    /// Re-reads the current tab's file and refreshes its state. Used by the
    /// menu's "Reload" item and (indirectly) by the file watcher.
    public func reloadCurrentFile() {
        guard let i = tabs.selectedIndex, tabs.tabs.indices.contains(i),
              let url = tabs.tabs[i].url else { return }
        reload(url: url, at: i)
    }

    /// TSK-916: "Reload from Disk" for an arbitrary file (the sidebar / breadcrumb
    /// context-menu action), not just the active one. Re-reads the file into its
    /// open tab if one exists; a no-op (returns false) when the file isn't open —
    /// the sidebar holds no content to reload, and the on-disk bytes are the
    /// source of truth the next open will read anyway.
    @discardableResult
    public func reloadFileFromDisk(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        guard let i = tabs.tabs.firstIndex(where: {
            $0.url?.standardizedFileURL == target
        }), let tabURL = tabs.tabs[i].url else { return false }
        reload(url: tabURL, at: i)
        return true
    }

    /// True when `url` is open in some tab — gates the "Reload from Disk" menu
    /// item so it only enables when there's actually a tab to reload (TSK-916).
    public func isFileOpenInTab(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        return tabs.tabs.contains { $0.url?.standardizedFileURL == target }
    }

    // Active-file FORMAT conversions (encoding / line-ending / indent convert) +
    // their `can*` flags + the activeTextForEncodingConvert helper →
    // DocumentModel+ActiveFileFormatConvert.swift (TSK-1110 SRP slice).

    /// Active text + its CURRENT encoding (for line-ending conversion, which must
    /// preserve the file's encoding — TSK-675).
    // internal: the active-file command SRP slices (e.g. DocumentModel+ActiveFileDataConvert.swift,
    // TSK-1110) read this shared accessor cross-file.
    var activeTextWithEncoding: (text: String, tabID: UUID, url: URL, encoding: String.Encoding)? {
        guard let tab = tabs.selected, let url = tab.url else { return nil }
        if let buf = editor.editorBuffers[tab.id] { return (buf.text, tab.id, url, buf.encoding) }
        if case .loaded(let f) = tab.state { return (f.contents, tab.id, url, f.encoding) }
        return nil
    }

    /// Apply a pure text transform to the active file (preserving encoding +
    /// folding in unsaved edits): transform → write-through → drop+reload. A
    /// no-op (returns false) when there's no active text file or the transform
    /// changes nothing. Shared by the whitespace-cleanup commands (TSK-675).
    @discardableResult
    // internal: the active-file command SRP slices (e.g. DocumentModel+ActiveFileDataConvert.swift,
    // TSK-1110) share this transform→write-through→reload seam cross-file.
    func applyTextTransformToActiveFile(_ transform: (String) -> String) -> Bool {
        guard let ctx = activeTextWithEncoding else { return false }
        let result = transform(ctx.text)
        guard result != ctx.text else { return false }
        do {
            _ = try EditorWriter.save(result, to: ctx.url, encoding: ctx.encoding)
        } catch {
            Obs.shared.emit(.warn, "files",
                            "Text cleanup failed: \(String(describing: error))")
            return false
        }
        editor.discardEditorBuffer(forTabID: ctx.tabID)
        reloadCurrentFile()
        return true
    }

    // canCleanUpActiveFile + the Edit ▸ Lines/Transformations text-transform commands
    // (sort/reverse/dedupe/remove-empty/collapse-blank lines, upper/lower/capitalize,
    // trim-trailing-whitespace, ensure-final-newline) →
    // DocumentModel+ActiveFileTextTransforms.swift (TSK-1110 SRP slice).

    /// TSK-675 — word/character/line counts for the active text file, or nil when
    /// no text file is active (drives the Document Statistics command).
    public var activeDocumentStats: DocumentStats? {
        guard let text = activeFileText else { return nil }
        return DocumentStats.compute(text)
    }

    // CSV/JSON data-format conversions (canConvertActiveCSV / activeCSVAsMarkdownTable /
    // activeCSVAsJSON / activeCSVSummary / canMinifyActiveJSON / minifyActiveJSON /
    // activeJSONAsCSV + the contentSniff helpers) → DocumentModel+ActiveFileDataConvert.swift
    // (TSK-1110 SRP slice).

    // LinkCheckReport / canCheckLinks / lintActiveMarkdown / checkLinksInActiveMarkdown
    // / canExportActiveAsHTML / htmlExportForActiveMarkdown / htmlExportFilename /
    // writeActiveMarkdownPreviewHTML → DocumentModel+ActiveFileMarkdownExport.swift
    // (TSK-1110 SRP slice).

    // canShiftMarkdownHeadings / shiftActiveMarkdownHeadings / canInsertTableOfContents
    // / insertTableOfContents → DocumentModel+ActiveFileMarkdownTransform.swift
    // (TSK-1110 SRP slice).

    /// The active tab's current text — the editor buffer's live text if editing,
    /// else the loaded-from-disk contents; nil when no text file is active.
    /// Backs the palette's `#` in-file search (TSK-727).
    public var activeFileText: String? {
        guard let tab = tabs.selected else { return nil }
        if let buf = editor.editorBuffers[tab.id] { return buf.text }
        if case .loaded(let f) = tab.state { return f.contents }
        return nil
    }

    /// CRIT-4: only reload when the currently-selected tab's URL still
    /// matches the URL the file watcher was bound to. Without this, an
    /// in-flight watcher event for a file the user just navigated away
    /// from would silently rewrite a different tab's state.
    ///
    /// Editor-mode external-edit guard: if the tab holds unsaved
    /// editor edits and the on-disk file has changed, surface an
    /// NSAlert (Keep mine / Reload disk) rather than blindly
    /// clobbering the user's typing. Clean tabs reload unconditionally
    /// — the existing behavior for the read-only Source view.
    private func reloadCurrentFile(matching watchedURL: URL) {
        guard let i = tabs.selectedIndex,
              tabs.tabs.indices.contains(i),
              tabs.tabs[i].url == watchedURL else { return }
        // TSK-929: if the file vanished from its path, it may have been renamed/
        // moved WITHIN its folder — follow it by inode instead of showing "file
        // not found". Editor buffer + scroll/cursor are tab.id-keyed, so they
        // follow the tab across the URL change; we just re-point url + watcher.
        if !FileManager.default.fileExists(atPath: watchedURL.path),
           let inode = watchedInode,
           let newURL = RenameFollower.findRenamed(
               inode: inode, inDirectory: watchedURL.deletingLastPathComponent()) {
            var t = tabs.tabs[i]
            t.url = newURL
            t.diskState = .fresh
            tabCoordinator.replace(at: i, with: t)
            startWatchingCurrentFile()   // re-point watcher + re-capture inode
            reload(url: newURL, at: i)
            Obs.shared.emit(.info, "filewatcher",
                "followed rename \(watchedURL.lastPathComponent) -> \(newURL.lastPathComponent)",
                fields: ["from": watchedURL.path, "to": newURL.path])
            return
        }
        // 0d: compute the disk-staleness SIGNAL on the watcher tick. This is
        // purely additive — the auto-reload below still runs (and resets the
        // signal to `.fresh`), so behavior is unchanged. The signal is what a
        // future flag-instead-of-reload pref + the status-bar red "Modified"
        // chip consume; for a clean tab it's transient (reload clears it),
        // but a deleted file persists as `.deleted`.
        refreshDiskState(at: i)
        let tab = tabs.tabs[i]
        if tab.isDirty, let buf = tabCoordinator.editorBuffers[tab.id] {
            let attrs = try? FileManager.default.attributesOfItem(atPath: watchedURL.path)
            let mtime = attrs?[.modificationDate] as? Date
            let size = attrs?[.size] as? Int
            if buf.hasExternalEdit(currentMTime: mtime, currentSize: size) {
                // TSK-1269/1165: try a CLEAN 3-way auto-merge first. When the
                // external change and the local edits don't overlap, the
                // reconciler merges them and we apply silently (both preserved) —
                // no banner, no data loss. Only a real overlapping conflict falls
                // through to the DiskConflictBanner below.
                if applyExternalAutoMerge(
                    forTabID: tab.id, url: watchedURL, diskMTime: mtime, diskSize: size) {
                    return
                }
                // TSK-1166: a PASSIVE watcher conflict (the user didn't ask to
                // reload) surfaces as a non-modal `DiskConflictBanner` above the
                // editor rather than a blocking NSAlert. Idempotent: a duplicate
                // watcher event for the same tab just re-sets the (Equatable-equal)
                // info. Backstop: even if the banner is missed, the write-time
                // `SaveConflictDecision` still catches the conflict on save.
                activeDiskConflict = DiskConflictBannerInfo(
                    tabID: tab.id, index: i, url: watchedURL)
                return
            }
        }
        reload(url: watchedURL, at: i)
    }

    /// Reload a file at `url` into the tab at `index`. Called from the
    /// watcher's debounce path and from EditorCoordinator's external-
    /// edit "Discard & Reload" branch (via the `onReloadFromDisk`
    /// closure wired at init). `fileprivate` so EditorCoordinator
    /// reaches it through the closure rather than direct access.
    ///
    /// CORR-3 (2026-05-30): the external-edit "Discard & Reload" path
    /// captures `index` BEFORE running a modal NSAlert. Between the
    /// capture and this call the user could close another tab, shifting
    /// indices — so `index` may now be out of bounds or point at a
    /// different tab. We re-locate by the tab's URL at `index` and bail
    /// if the slot no longer matches, instead of blindly subscripting
    /// (which trapped on a stale index) or rewriting the wrong tab.
    ///
    /// UDC-2 (2026-05-30): when the tab is in `.editor` mode and its
    /// buffer is CLEAN, refresh the buffer from the reloaded file so
    /// CM6 shows the new bytes. The prior code only swapped `tab.state`
    /// (which feeds source/rendered views); the editor kept rendering
    /// the stale buffer, and a subsequent save wrote those stale bytes
    /// back over the external edit — silent data loss. A DIRTY buffer
    /// is never clobbered here: the dirty case is gated upstream by
    /// `reloadCurrentFile(matching:)`, which routes to the external-
    /// edit conflict prompt; the prompt's "Discard & Reload" branch
    /// drops the buffer entirely before calling back in, so by the time
    /// we see it the buffer is gone (re-seeds lazily from new state).
    fileprivate func reload(url: URL, at index: Int) {
        // CORR-3: tolerate a stale index handed across a modal.
        guard tabs.tabs.indices.contains(index),
              tabs.tabs[index].url == url else {
            // Last resort: try to re-locate by URL in case the tab just
            // shifted position. Only act on an unambiguous single match.
            let matches = tabs.tabs.indices.filter { tabs.tabs[$0].url == url }
            guard matches.count == 1, let idx = matches.first else { return }
            applyReload(url: url, at: idx)
            return
        }
        applyReload(url: url, at: index)
    }

    /// Shared reload body once the target index is validated.
    private func applyReload(url: URL, at index: Int) {
        // Preserve a per-tab "Open As…" override across a watcher reload
        // so an overridden file doesn't snap back to auto-detection when
        // it changes on disk (WAVE 2b item 6).
        let state = controller.open(url: url, forcedCategory: tabs.tabs[index].categoryOverride)
        var t = tabs.tabs[index]
        let wasEditor = t.viewMode == .editor
        t.state = state
        // 0d: a successful reload re-baselines the loaded copy against disk,
        // so the staleness signal is cleared.
        t.diskState = .fresh
        tabCoordinator.replace(at: index, with: t)
        // UDC-2: rebase a clean editor buffer onto the reloaded text.
        if wasEditor, case .loaded(let newFile) = state {
            let id = t.id
            if let existing = tabCoordinator.editorBuffers[id] {
                if !existing.isDirty {
                    tabCoordinator.setEditorBuffer(
                        EditorBuffer(from: newFile), forTabID: id
                    )
                }
                // Dirty buffers are intentionally left alone — see the
                // doc comment on `reload`; the dirty path never reaches
                // here without the buffer first being discarded.
            }
            // If no buffer exists yet, `editorBuffer(forTabID:)` will
            // seed one from the fresh `.loaded` state on first access.
        }
        updateDerived()
    }

    /// Recompute the disk-staleness SIGNAL for the tab at `index` by statting
    /// its file and comparing against the loaded `(mtime, size)` baseline.
    /// Stores the result on `Tab.diskState`. Pure signal — does NOT reload
    /// or change any behavior (0d): consumers (status-bar red "Modified"
    /// chip, future tab red-dot) read it; auto-reload still runs unchanged.
    ///
    /// Baseline source: the loaded `TextFile.modifiedTime/byteCount`, falling
    /// back to an editor buffer's `lastSavedMTime/Size`. A tab with no
    /// baseline (e.g. binary/preview/loading) can't be classified → `.fresh`.
    func refreshDiskState(at index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        let tab = tabs.tabs[index]
        guard let url = tab.url else { return }

        // Loaded-copy baseline.
        var baselineMTime: Date? = nil
        var baselineSize: Int? = nil
        if case .loaded(let file) = tab.state {
            baselineMTime = file.modifiedTime
            baselineSize = file.byteCount
        } else if let buf = tabCoordinator.editorBuffers[tab.id] {
            baselineMTime = buf.lastSavedMTime
            baselineSize = buf.lastSavedSize
        } else {
            // No comparable baseline (binary / preview / loading). Leave as-is
            // unless the file vanished — a deleted signal is still meaningful.
            if !FileManager.default.fileExists(atPath: url.path) {
                setDiskState(.deleted, at: index)
            }
            return
        }

        let exists = FileManager.default.fileExists(atPath: url.path)
        let attrs = exists ? (try? FileManager.default.attributesOfItem(atPath: url.path)) : nil
        let newState = ViewerCore.Tab.classifyDiskState(
            baselineMTime: baselineMTime, baselineSize: baselineSize,
            currentMTime: attrs?[.modificationDate] as? Date,
            currentSize: attrs?[.size] as? Int,
            currentExists: exists
        )
        setDiskState(newState, at: index)
    }

    /// Recompute the active tab's disk-staleness signal.
    func refreshDiskStateForActiveTab() {
        if let i = tabs.selectedIndex { refreshDiskState(at: i) }
    }

    /// Set `Tab.diskState` at `index`, republishing only on an actual change
    /// (Equatable Tab → SwiftUI diff). No-op if unchanged.
    private func setDiskState(_ state: ViewerCore.Tab.DiskState, at index: Int) {
        guard tabs.tabs.indices.contains(index),
              tabs.tabs[index].diskState != state else { return }
        var t = tabs.tabs[index]
        t.diskState = state
        tabCoordinator.replace(at: index, with: t)
        objectWillChange.send()
    }

    /// Force-reload the tab at `index` from disk, regardless of whether the
    /// watcher detected an on-disk change. Backs the right-click tab →
    /// "Refresh" menu item (bug6). Reuses the existing reload path and the
    /// dirty-buffer conflict prompt: a tab with unsaved editor edits routes
    /// through `presentExternalEditConflict` (Keep My Edits / Discard &
    /// Reload) so a force-refresh never silently clobbers the user's typing;
    /// a clean tab reloads unconditionally.
    public func refreshTab(at index: Int) {
        guard tabs.tabs.indices.contains(index),
              let url = tabs.tabs[index].url else { return }
        let tab = tabs.tabs[index]
        if tab.isDirty, tabCoordinator.editorBuffers[tab.id] != nil {
            // Dirty editor buffer: prompt before discarding. The prompt's
            // "Discard & Reload" branch drops the buffer and calls back into
            // `reload(url:at:)` via `onReloadFromDisk`; "Keep My Edits"
            // leaves the buffer untouched.
            _ = editor.presentExternalEditConflict(forTabID: tab.id, at: index, url: url)
            return
        }
        reload(url: url, at: index)
    }

    /// TSK-1269 slice 1 — the host-testable DECISION half of wiring
    /// `ExternalEditReconciler` (3-way auto-merge) into the dirty-buffer
    /// external-change flow. Reconciles the tab's UNSAVED editor buffer against
    /// the current on-disk content (base = last-saved `originalText`, ours =
    /// live `text`, theirs = disk) and returns the `Outcome` for the caller to
    /// apply: `.autoMerged`/`.cleanReload` carry the text to set, `.conflict`
    /// carries git-style markers, `.noExternalChange` means keep local. Returns
    /// `nil` when there is no editor buffer for the tab (uses the non-seeding
    /// `editorBuffers` dict, NOT the seeding `editorBuffer(forTabID:)` getter)
    /// or the disk read fails — the caller then falls back to the existing
    /// Keep/Discard prompt. Pure read, no mutation — host-testable. Applying the
    /// outcome (buffer-replace + CM6 redisplay) and routing `refreshTab`/the
    /// watcher through it are slices 2/3 (render → review).
    public func reconcileExternalEdit(forTabID id: UUID, url: URL) -> ExternalEditReconciler.Outcome? {
        guard let buf = editor.editorBuffers[id] else { return nil }
        guard let disk = try? String(contentsOf: url, encoding: buf.encoding) else { return nil }
        return ExternalEditReconciler.reconcile(base: buf.originalText, local: buf.text, disk: disk)
    }

    /// TSK-1269/1165 (slices 2/3) — APPLY the reconciler outcome for a dirty tab
    /// whose file changed externally. Only `.autoMerged` (a clean, non-overlapping
    /// 3-way merge) is applied here: the buffer takes the merged text and stays
    /// DIRTY (`originalText` untouched, so the user still saves the merge and a
    /// Revert reaches the pre-conflict baseline), while the disk fingerprint is
    /// refreshed so this same external change doesn't re-fire the watcher.
    /// Returns `true` iff a merge was applied; `false` (no buffer / a real
    /// `.conflict` / no change) leaves the caller to surface the conflict banner.
    /// The buffer mutation is host-tested; CM6 re-display is the render tail.
    @discardableResult
    func applyExternalAutoMerge(
        forTabID id: UUID, url: URL, diskMTime: Date?, diskSize: Int?
    ) -> Bool {
        guard case let .autoMerged(merged)? = reconcileExternalEdit(forTabID: id, url: url),
              var buf = editor.editorBuffers[id] else { return false }
        buf.setText(merged)
        buf.refreshSavedFingerprint(diskMTime: diskMTime, diskSize: diskSize)
        tabCoordinator.setEditorBuffer(buf, forTabID: id)
        ToastCenter.shared.post(.info, "Merged external changes into your edits")
        return true
    }

    /// TSK-1171 — build the 3-pane conflict-resolution model for a dirty tab whose
    /// buffer conflicts with disk: base = the last-saved baseline, ours = the
    /// buffer's edits, theirs = the on-disk text. Returns nil when there's no
    /// buffer, disk is unreadable, or the 3-way merge has NO conflicts (nothing to
    /// resolve — the auto-merge path handles that). Host-testable; the sheet that
    /// presents the returned model is the render tail.
    public func beginConflictResolution(forTabID id: UUID, url: URL) -> ConflictResolutionModel? {
        guard let buf = editor.editorBuffers[id],
              let disk = try? String(contentsOf: url, encoding: buf.encoding) else { return nil }
        let result = ThreeWayMerge.merge(base: buf.originalText, ours: buf.text, theirs: disk)
        guard result.hasConflicts else { return nil }
        return ConflictResolutionModel(
            result: result, oursLabel: "My edits", theirsLabel: "On disk")
    }

    /// TSK-1171 — apply the user's fully-resolved conflict text to the tab's buffer.
    /// Kept DIRTY (so the user still saves the resolution) with the disk fingerprint
    /// refreshed (so the watcher doesn't immediately re-fire the same conflict).
    @discardableResult
    public func applyConflictResolution(
        _ text: String, forTabID id: UUID, diskMTime: Date?, diskSize: Int?
    ) -> Bool {
        guard var buf = editor.editorBuffers[id] else { return false }
        buf.setText(text)
        buf.refreshSavedFingerprint(diskMTime: diskMTime, diskSize: diskSize)
        tabCoordinator.setEditorBuffer(buf, forTabID: id)
        return true
    }

    func startWatchingCurrentFile() {
        let url = currentURL
        // B9: idempotent — no-op if already watching the same URL.
        if fileWatcher != nil && watchedURL == url { return }
        fileWatcher?.stop()
        fileWatcher = nil
        watchedURL = url
        // Switching watch targets clears any prior failure cue; the
        // (re)construction below re-establishes it if this target fails.
        // A nil URL or a not-yet-existent file is "nothing to watch", not
        // a watcher failure, so it leaves the cue cleared.
        liveReloadUnavailable = false
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            watchedInode = nil
            return
        }
        // TSK-929: capture the inode now so a later rename can be followed.
        watchedInode = RenameFollower.inode(of: url)
        // CRIT-4: capture the URL the watcher is bound to so the handler
        // can verify the user is still viewing it before reloading.
        let boundURL = url
        // S4: surface watcher construction/loss instead of swallowing it.
        // A dead watcher means external-edit detection (and the FW-7
        // save-time conflict reconcile it feeds) is silently off for this
        // file's whole session — the one watcher/load/save path that
        // would otherwise degrade with no signal. Emit to the
        // observability sink (Logs view / os_log) on both the
        // construction throw and the reattach-exhaustion `onLost`.
        do {
            fileWatcher = try FileWatcher(
                url: url,
                queue: .main,
                onLost: { [weak self] in
                    // Fires on the watcher's queue (.main) after reattach
                    // attempts are exhausted (e.g. the file was deleted and
                    // never recreated). Mark live reload as down so a later
                    // start re-probes, and emit a diagnostic.
                    Task { @MainActor in
                        guard let self, self.watchedURL == boundURL else { return }
                        self.liveReloadUnavailable = true
                        Obs.shared.emit(.warn, "filewatcher",
                            "live reload lost for \(boundURL.lastPathComponent): watcher gave up after repeated reattach failures",
                            fields: ["path": boundURL.path])
                    }
                },
                handler: { [weak self] in
                    Task { @MainActor in
                        self?.reloadCurrentFile(matching: boundURL)
                    }
                }
            )
            liveReloadUnavailable = false
        } catch {
            // O_EVTONLY open failed (descriptor exhaustion, kqueue/FSEvents
            // resource pressure, a race deleting the file). Leave
            // `fileWatcher` nil but record it so the dead watcher is
            // detectable rather than an invisible no-op.
            liveReloadUnavailable = true
            Obs.shared.emit(.error, "filewatcher",
                "could not start live reload for \(boundURL.lastPathComponent): \(error)",
                fields: ["path": boundURL.path, "error": "\(error)"])
        }
    }

    /// True when external-edit detection (live reload) is NOT active for
    /// the currently-watched file — the watcher either failed to construct
    /// or was lost after exhausting reattach attempts. Cleared on a
    /// successful (re)start. Surfaced so the UI can show a one-time,
    /// non-modal "live reload unavailable" cue and so the diagnostic dump
    /// can report a dead watcher; the authoritative signal is also emitted
    /// to `Obs.shared`.
    @Published public private(set) var liveReloadUnavailable: Bool = false

    // MARK: Session lifecycle hooks (Phase 1)

    /// Pause file watching for this DocumentModel. Called by the
    /// `SessionState` when its session is detached (another session
    /// becomes active). Idempotent — calling on an already-paused
    /// model is a no-op.
    ///
    /// Phase 1 only pauses the file watcher; everything else
    /// (caches, @Published state) stays warm so reactivation is
    /// instant. Future phases will cancel diff/highlight Tasks too.
    public func pauseFileWatcher() {
        fileWatcher?.stop()
        fileWatcher = nil
        watchedURL = nil
        // A deliberate pause is not a failure — don't leave a stale
        // "unavailable" cue showing while the session is backgrounded.
        liveReloadUnavailable = false
    }

    /// Resume file watching against the current tab's URL. Called by
    /// the `SessionState` when its session is re-mounted. Safe to
    /// call when not currently paused (it's a re-attach if the URL
    /// changed; no-op if it didn't, courtesy of the idempotency
    /// check in `startWatchingCurrentFile()`).
    public func resumeFileWatcher() {
        startWatchingCurrentFile()
    }

    // MARK: Tab management

    public func newTab() {
        tabCoordinator.append(Tab())
        updateDerived()
    }

    public func closeTab(at index: Int) {
        // Editor-dirty guard: prompt before we destroy the tab. The
        // user can Save (we proceed), Don't Save (we proceed), or
        // Cancel (we abort). Routed through every close-path entry —
        // `closeTab`, `closeOtherTabs`, `closeTabsToRight`, and the
        // app delegate's "close window" handler.
        //
        // TSK-733: the prompt is the CLOSE-path contract ONLY. A session
        // SWITCH must NOT prompt — it drains tabs via
        // `closeAllTabsPreservingDirty()` (the dirty buffer is snapshotted
        // into the session and restored on switch-back), so this prompt is
        // exercised only when the user is genuinely DESTROYING a tab.
        switch confirmCloseIfDirty(at: index) {
        case .none:
            break
        case .discard:
            // Drop any stashed HEX edits so a later same-tab-id reuse
            // doesn't resurrect them. Text-editor buffers are dropped by
            // the coordinator's close fan-out.
            hexDirtyBytes.removeValue(forKey: tabs.tabs[index].id)
        case .save:
            if isHexDirtyTab(at: index) {
                if !saveHexEdits(forTabID: tabs.tabs[index].id) { return }
            } else if !saveEditor(forTabID: tabs.tabs[index].id) { return }
        case .cancel:
            return
        }
        closeTabUnconditionally(at: index)
    }

    /// The prompt-free core of `closeTab(at:)`: capture scroll, hand the
    /// tab mutation + per-tab cleanups to the coordinator, purge non-
    /// coordinator caches, settle selection, and re-attach the watcher.
    /// Split out (TSK-733) so a session SWITCH can drain its tabs WITHOUT
    /// re-running the dirty-close prompt — the outgoing session's dirty
    /// buffers are already snapshotted (`captureUnsavedTextForAllTabs`)
    /// and restored on switch-back, so prompting on a switch is wrong.
    /// The user-initiated close path (`closeTab` / `closeOtherTabs` /
    /// `closeTabsToRight`) still gates on `confirmCloseIfDirty` first.
    /// Perf P2/P3 (TSK-1043/1044): set for the duration of a BULK tab drain
    /// (`closeAllTabsPreservingDirty`, the session-switch path). While set,
    /// `closeTabUnconditionally` skips its per-tab `settleSelectionAfterClose`
    /// (→ no transient mid-drain `materializeIfNeeded` of a survivor that's
    /// itself about to close — P3) and the per-tab `updateDerived()` /
    /// `startWatchingCurrentFile()` (→ run ONCE at the end of the drain instead
    /// of N+1 times — the `refreshDiffMarks`/`warmLSP`/`repoFocus` storm — P2).
    /// The incoming session's `selectTab` materializes the real focused tab.
    private var isBulkDraining = false

    #if DEBUG
    /// Perf P2/P3 (TSK-1043/1044) test probe — DEBUG-only invocation counters so
    /// a HOST test can prove the bulk-drain batching: a full session drain must
    /// fire `updateDerived()` ONCE (not N+1 per outgoing tab) and trigger NO
    /// transient mid-drain `materializeIfNeeded` of a survivor about to close.
    /// Mirrors the `MountProbe` pattern; reset by the test before the action.
    public internal(set) var updateDerivedCalls = 0
    public internal(set) var materializeCalls = 0
    public func resetDrainProbes() { updateDerivedCalls = 0; materializeCalls = 0 }
    #endif

    func closeTabUnconditionally(at index: Int) {   // internal: HotExitTests exercises the spill cleanup
        guard tabs.tabs.indices.contains(index) else { return }
        // UX-K (#231): if we're closing the currently-VISIBLE tab, sample its
        // scroll position first so a snapshot taken right after close (e.g.
        // detach-time `makeSnapshot`) still carries the last position. The
        // source channel only reflects the active tab, so capturing a
        // background tab here would be meaningless — gate on selection.
        if tabs.selectedIndex == index {
            captureScroll(forTabAt: index)
        }
        let closedURL = tabs.tabs[index].url
        // TSK-1026: a DESTRUCTIVE close orphans any >1 MiB hot-exit spill for
        // this file (no tab will re-capture it) — drop it so it can't leak on
        // disk. NOT done on the session-SWITCH close
        // (`closeAllTabsPreservingDirty`), which intentionally keeps the dirty
        // buffer for switch-back.
        if let p = closedURL?.path {
            HotExitSpill.remove(forPath: p, in: hotExitSpillDirectory)
        }
        // Coordinator handles the tabs mutation + all six per-tab dict
        // cleanups in lock-step (folded into `cleanupAfterClose`).
        // Returns the closed tab's id so we can also purge non-
        // coordinator caches that key off it (renderedHTML, highlight
        // actor).
        if let id = tabCoordinator.closeTab(at: index) {
            purgeCaches(forURL: closedURL, tabID: id)
        }
        // P2/P3: during a bulk drain the per-tab settle/derive/watch is pure
        // wasted work — every survivor is about to be closed too, and the
        // incoming hydrate re-selects the real focused tab. Run them ONCE at
        // the end of the drain (`closeAllTabsPreservingDirty`).
        guard !isBulkDraining else { return }
        settleSelectionAfterClose()
        updateDerived()
        startWatchingCurrentFile()
    }

    /// TSK-733: drain EVERY open tab WITHOUT the dirty-close prompt. Used
    /// by the session-switch path (`SessionsAppCoordinator
    /// .switchSessionFaçade`) to clear the shared `DocumentModel`'s tab
    /// list for the incoming session. A switch is NOT a destructive close:
    /// the outgoing session's dirty editor buffers have already been
    /// snapshotted into its `SessionSnapshot` via
    /// `captureUnsavedTextForAllTabs()` (TSK-718 hot-exit machinery), so
    /// switching back rehydrates the in-flight edits byte-identical and the
    /// tab comes back dirty. Prompting Save/Don't-Save/Cancel here would be
    /// a spurious dialog on a non-destructive operation (the TSK-733 bug).
    ///
    /// HEX-dirty bytes are dropped per-tab (mirroring `closeTab`'s
    /// `.discard` branch) so a later same-tab-id reuse can't resurrect
    /// them; HEX edits are not part of the session hot-exit snapshot.
    public func closeAllTabsPreservingDirty() {
        // Capture text-editor unsaved buffers onto each tab's `unsavedText`
        // before the buffers are dropped by the coordinator's close fan-out,
        // so a snapshot taken AFTER the drain (or already taken by the
        // caller's detach) carries the in-flight edits. Idempotent with the
        // detach-time capture — the equality guard inside makes a re-capture
        // a no-op.
        captureUnsavedTextForAllTabs()
        // TSK-1303: fold each image tab's live edit state onto `Tab.imageEditState`
        // before the drain drops the view-local image VMs, so the snapshot (taken
        // after the drain, or by the caller's detach) carries the in-flight edits.
        captureImageEditStateForAllTabs()
        // P2/P3 (TSK-1043/1044): suppress the per-tab settle/materialize/
        // updateDerived/watch storm for the duration of the drain — each
        // outgoing tab triggering `refreshDiffMarks`/`warmLSP`/`repoFocus` +
        // a transient survivor materialize is wasted work when the whole list
        // is being cleared. Reconcile ONCE after the loop. `defer` guarantees
        // the flag is cleared even if a close path throws.
        isBulkDraining = true
        defer { isBulkDraining = false }
        while !tabs.tabs.isEmpty {
            hexDirtyBytes.removeValue(forKey: tabs.tabs[0].id)
            closeTabUnconditionally(at: 0)
        }
        // Single post-drain reconcile: `updateDerived()` runs
        // `noteActiveTabForRetention` (now `retainOnly({})` drops every pane in
        // one pass) + window title; `startWatchingCurrentFile()` settles the
        // (now-empty) watch state. No `settleSelectionAfterClose` — there is no
        // survivor to materialize; the incoming session's `selectTab` does that.
        updateDerived()
        startWatchingCurrentFile()
    }

    /// Post-close selection settle (TSK-266): closing a tab makes the
    /// coordinator auto-select a NEIGHBOR, but unlike `selectTab` none
    /// of the close paths ran the incoming-tab duties — so a LAZY
    /// survivor (`.empty` with url: multi-open / workspace-restore tabs)
    /// stayed unmaterialized and the content pane sat blank until the
    /// user re-clicked the tab, which reads as "closing a tab takes a
    /// second". Mirror `selectTab`: kick the lazy read and refresh the
    /// staleness signal for the now-active file.
    // internal: used by the DocumentModel+TabCloseVariants.swift SRP slice (TSK-1110)
    func settleSelectionAfterClose() {
        guard let i = tabs.selectedIndex else { return }
        materializeIfNeeded(at: i)
        refreshDiskStateForActiveTab()
    }

    // closeCurrentTab / closeOtherTabs(keeping:) / closeTabsToRight(of:) →
    // DocumentModel+TabCloseVariants.swift (TSK-1110 SRP slice). The core closeTab /
    // closeTabUnconditionally + the shared confirmCloseIfDirty / settleSelectionAfterClose
    // helpers stay here.

    /// Drop all cache entries belonging to a closed tab. Highlight
    /// runs live in per-tab `HighlightCacheActor`s (PERF #5);
    /// closing a tab drops the actor entirely — no fan-out to other
    /// tabs because each tab has its own. Rendered-HTML entries are
    /// tabID-keyed (PERF #2 finding); purge unconditionally on tab
    /// close since no other tab can hit the same key. These two
    /// caches stay on DocumentModel (not TabCoordinator) because
    /// they're conceptually subsystems (highlighting, markdown
    /// rendering), and only their *eviction* is tab-id-keyed.
    func purgeCaches(forURL closedURL: URL?, tabID: UUID? = nil) {
        if let tabID {
            // Canvas rendered-lens controller (M3.S1): tear down the webview
            // host with the tab. The STORE doc stays open (agents may still
            // hold it); only the view binding dies.
            dropCanvasController(forTab: tabID)
            // PERF #5: drop the per-tab highlight cache actor.
            // GC happens automatically once the last observer (the
            // source view) drops its `@ObservedObject` reference.
            highlightCaches.removeValue(forKey: tabID)

            let priorOrder = renderedHTMLCacheOrder
            renderedHTMLCache = renderedHTMLCache.filter { $0.key.tabID != tabID }
            // Keep the order list in sync — drop the tab's entries while
            // preserving relative ordering of survivors (S2-G).
            let survivorKeys = Set(renderedHTMLCache.keys)
            renderedHTMLCacheOrder = priorOrder.filter { survivorKeys.contains($0) }

            // Drop the closed tab's raw-HTML JS opt-in so a recycled
            // UUID can't inherit a stale "JS on" decision (the set is
            // keyed by tab id; absence = secure default off).
            htmlJavaScriptOptIn.remove(tabID)

            // TSK-889: real close → tear down + drop any preserved (warm-reopen)
            // source-view controller for this tab. A no-op unless the
            // preservation flag is on and a controller was resident. Must fire
            // here (not on dismantle) so the glyph store frees on actual close,
            // and a recycled UUID can't inherit a stale laid-out view.
            SourceControllerCache.shared.purge(tabID: tabID)
        }
        // Drop any hosted-view payloads no longer referenced by a live
        // tab. `purgeCaches` runs AFTER the coordinator has mutated
        // `tabs`, so a sweep over the surviving tabs' hosted ids is the
        // safe, close-path-agnostic way to release closed File-History
        // views (and their FileHistoryModel) without threading the
        // hosted id through every close entry point.
        if !hostedViews.isEmpty {
            var live = Set<UUID>()
            for t in tabs.tabs {
                if case .hostedView(let hid, _) = t.state { live.insert(hid) }
            }
            hostedViews = hostedViews.filter { live.contains($0.key) }
        }
        // L1 (memory): drop the closed file's LSP diagnostics so the
        // `byURL` map doesn't accumulate one entry per file touched over a
        // session (each can carry KBs of squiggle ranges). Guard on "no
        // surviving tab still shows this URL" so closing one of two tabs on
        // the same file keeps the diagnostics the other tab still renders.
        // `purgeCaches` runs AFTER the coordinator mutated `tabs`, so the
        // survivor scan is accurate. LSPPool's per-file version/hash
        // bookkeeping is intentionally left (clearing it without sending a
        // real `textDocument/didClose` would desync the server — a separate
        // lifecycle feature, not a leak-plug; see BACKLOG).
        if let closedURL, !tabs.tabs.contains(where: { $0.url == closedURL }) {
            lspDiagnostics.clear(url: closedURL)
        }
    }

    // moveTab / moveCurrentTabLeft / moveCurrentTabRight / selectNextTab /
    // selectPreviousTab → DocumentModel+TabNavigation.swift (TSK-1110 SRP slice).


    public func selectTab(at index: Int) {
        // UX-K (#231): capture the OUTGOING tab's scroll position before we
        // switch away — this is the focus-loss boundary. No-op if we're
        // re-selecting the same tab (the channel still shows its own offset).
        if let cur = tabs.selectedIndex, cur != index {
            captureScroll(forTabAt: cur)
        }
        tabCoordinator.select(at: index)
        materializeIfNeeded(at: index)
        updateDerived()
        startWatchingCurrentFile()
        // 0d: refresh the staleness signal for the now-active tab (background
        // tabs aren't watched, so a switch is when we re-stat).
        refreshDiskStateForActiveTab()
        // TSK-452 (owner repro: "bottom file stats" stale after switching):
        // the original 0d call was signal-only, so a file changed WHILE
        // BACKGROUNDED kept its load-time stats/content until some later
        // watcher tick. Switching is the user saying "show me this file" —
        // when the re-stat above flags staleness, run the SAME guarded
        // reload the watcher path uses: clean tabs refresh silently, dirty
        // editor buffers still get the external-edit conflict prompt.
        if let sel = tabs.selected, sel.diskState == .staleVsDisk,
           let url = sel.url {
            reloadCurrentFile(matching: url)
        }
        // item9: if "pin"/follow is on, reveal the now-active file in the
        // sidebar (select + expand only, never re-root).
        followActiveTabIfNeeded()
        // UX-K (#231): restore the now-active tab's persisted scroll. If the
        // tab was already materialized this scrolls immediately; if it just
        // started a lazy materialize, `materializeIfNeeded`'s completion
        // re-fires the restore once the content is laid out.
        restoreScroll(forTabAt: index)
    }

    // appendLazyTab(url:viewMode:...) / openMultiple(_:) →
    // DocumentModel+LazyTabOpen.swift (TSK-1110 SRP slice).

    // materializeIfNeeded(at:) → DocumentModel+TabMaterialize.swift (TSK-1110 SRP
    // slice). Called by selectTab + settleSelectionAfterClose (both stay here).

    // toggleViewMode / selectViewMode(at:) / setCurrentViewMode(_:) →
    // DocumentModel+ViewModeSwitch.swift (TSK-1110 SRP slice).

    // loadBinaryAsync(url:intoTabID:) / loadTextAsync(url:intoTabID:) →
    // DocumentModel+TabLoading.swift (TSK-1110 SRP slice). Called by materializeIfNeeded.

    // MARK: Recents

    public func clearRecents() {
        history.clear()
        recents = []
    }

    // MARK: Internal

    // Internal (not private) so SRP-slice extensions (e.g.
    // DocumentModel+ViewHosting.swift, TSK-1110) can republish derived state.
    func updateDerived() {
        #if DEBUG
        updateDerivedCalls += 1   // P2 probe: a bulk drain must fire this ONCE
        #endif
        windowTitle = tabs.selected?.title ?? "TextView"
        // `openTabURLs` maintenance now lives on `TabCoordinator`
        // — every coordinator-side mutation refreshes it. We don't
        // need to fan that out from here.
        //
        // Recompute the source-view diff stripe when the focused
        // file changes. Cheap-ish: shells `git diff` once per switch
        // (off-main); skipped when not inside a repo.
        refreshDiffMarks()
        // Sibling: recompute the CM6 editor's syntax fold ranges for the
        // newly-focused tab (TSK-466). No-op outside editor mode.
        refreshEditorFolds()
        // Sibling (TSK-905): if the active rendered preview changed, ask it to
        // take first responder so arrows scroll it. Change-keyed, so this is a
        // no-op on same-preview refreshes (no focus stealing).
        refreshPreviewFocus()
        // Sibling to refreshDiffMarks: keep the multi-repo registry's
        // demand set in sync with the open-tab/selection state. The
        // tabCoordinator/sidebar Combine sinks in RepoFocusTracker cover
        // generic mutations, but this synchronous call makes the
        // open/save/reload paths deterministic (no debounce window).
        // Idempotent + equality-guarded — a no-op when demand is
        // unchanged.
        repoFocus.recompute()
        // LSP-01: warm the language server from the MODEL side on the
        // open/select path, mirroring the repoFocus.recompute() call
        // above (the F-GIT-1 fix for the same republish-ordering class).
        // The Outline sidebar section's LSPOutlineWrapper.refresh() is
        // the only other spawn trigger, but it fires on the section's
        // .onAppear/.onChange — which an occluded/scripted window does
        // not reliably realize, making sourcekit-lsp spawn non-
        // deterministic. Driving ensureOpened here makes the spawn
        // deterministic on every focus change regardless of view
        // realization. Self-gating + idempotent (see warmLSPForCurrentFile).
        warmLSPForCurrentFile()
        // LSP-S3 (TSK-148): symmetric to warmLSPForCurrentFile — drop LSP
        // per-file state for files no longer open in any tab, so the pool's
        // Swift-side maps don't grow unbounded across a long session.
        reapClosedLSPFiles()
        // Perf Fix#1 (TSK-108): keep the mounted-pane retention set current.
        // Runs LAST so it sees the post-mutation tab list / selection.
        noteActiveTabForRetention()
    }

    /// Reconcile `mountedPanes` with the current tab list + selection, in ONE
    /// place driven by `updateDerived()` — so every open / select / close /
    /// session-switch path keeps it correct without per-callsite wiring:
    ///   • `retainOnly` drops ids whose tab was closed via ANY path (close,
    ///     close-others, session switch — they're simply gone from `tabs`);
    ///   • `activate` moves the now-selected tab to the front (MRU) and evicts
    ///     the least-recently-active tail beyond capacity.
    /// Change-guarded so a republish-without-selection-change (content reload,
    /// diff-marks refresh) does NOT fire an extra `objectWillChange`.
    private func noteActiveTabForRetention() {
        let openIDs = Set(tabs.tabs.map(\.id))
        var next = mountedPanes
        next.retainOnly(openIDs)
        if let id = tabs.selected?.id { next.activate(id) }
        if next != mountedPanes { mountedPanes = next }
    }

    /// URL the LSP pool was last warmed for. Dedupes the
    /// `warmLSPForCurrentFile()` call so a republish that doesn't change
    /// the focused file (e.g. a diff-marks refresh, a tab-title change)
    /// doesn't kick a redundant `ensureOpened` Task. Reset to nil only
    /// matters for correctness on re-open of the same path after a close,
    /// which `ensureOpened`'s own per-(key,file) idempotency already makes
    /// a no-op — so we never need to clear it.
    private var lastWarmedLSPURL: URL?

    /// URLs we've driven `ensureOpened` for and not yet closed. The reap
    /// diff (`reapClosedLSPFiles`) subtracts the live open-tab set from this
    /// to find files to `closeFile`, and removes them here — so this set
    /// stays bounded by the open tabs, never the lifetime file count.
    private var lspWarmedURLs: Set<URL> = []

    /// Spawn / open the language server for the currently-focused file,
    /// independent of whether the Outline sidebar section is realized.
    ///
    /// Fully self-gating and side-effect-free for non-LSP files:
    ///   * only acts when the current tab is `.loaded` text,
    ///   * dedupes against `lastWarmedLSPURL` so it's a no-op on
    ///     republishes that don't move focus,
    ///   * `pool.ensureOpened` itself no-ops when the file's extension has
    ///     no registered LSP language or no discoverable workspace root,
    ///     so opening a `.md`/`.txt` never spawns anything.
    /// `ensureOpened` is idempotent per (key, fileURL): re-focusing an
    /// already-open file makes no new spawn. Errors (missing binary, dead
    /// cooldown) are swallowed — the Outline/hover UI surfaces them when
    /// the user actually engages those features.
    private func warmLSPForCurrentFile() {
        guard let url = currentURL,
              case .loaded(let file) = currentState else { return }
        guard lastWarmedLSPURL != url else { return }
        lastWarmedLSPURL = url
        lspWarmedURLs.insert(url)
        let pool = self.lspPool
        let text = file.contents
        Task { try? await pool.ensureOpened(fileURL: url, text: text) }
    }

    /// Symmetric counterpart to `warmLSPForCurrentFile` (LSP-S3 / TSK-148):
    /// drop the pool's per-file maps for files no longer open in any tab.
    /// Level-triggered — diffs the warmed set against the authoritative
    /// `tabCoordinator.openTabURLs`, so it covers every close path (single,
    /// close-others, close-to-right) uniformly and is robust to call timing.
    /// `closeFile` is safe and idempotent: a later re-open re-`didOpen`s the
    /// file (see `LSPPool.closeFile` docs), so over-eager reaping only costs a
    /// re-open, never correctness. Bounds `lspWarmedURLs` to the open tabs.
    private func reapClosedLSPFiles() {
        let stillOpen = tabCoordinator.openTabURLs
        let closed = lspWarmedURLs.subtracting(stillOpen)
        guard !closed.isEmpty else { return }
        lspWarmedURLs.subtract(closed)
        let pool = self.lspPool
        Task { for url in closed { await pool.closeFile(fileURL: url) } }
    }
}

/// Sendable weak box around a MainActor-isolated DocumentModel reference.
/// Strict-concurrency forbids capturing `self` (a mutable var in escaping
/// async closures) directly; this box gives a value-typed handoff that
/// the inner closure can capture cleanly. The wrapped reference is
/// MainActor-isolated; readers must hop to MainActor before deref.
private struct WeakModelBox: @unchecked Sendable {
    weak var value: DocumentModel?
    init(_ v: DocumentModel) { self.value = v }
}

/// NSMenuItem target shim. Wraps a closure into an `NSObject` selector
/// so closure-backed menu items in `showEditorContextMenu` survive the
/// NSMenu.popUp lifecycle. The owning `DocumentModel.editorMenuTargets`
/// dict holds the strong reference.
@MainActor
final class EditorMenuTarget: NSObject {
    private let block: () -> Void
    init(perform: @escaping () -> Void) { self.block = perform }
    @objc func invoke(_ sender: Any?) { block() }
}
