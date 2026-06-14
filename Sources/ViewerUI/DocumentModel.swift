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

    // MARK: - Per-tab dict forwarders (move-here-only — TabCoordinator
    //  owns the storage; these keep external call sites unchanged)

    /// Forwarder. New code should call `tabCoordinator.csvFilterStates`.
    public var csvFilterStates: [UUID: CSVFilterState] {
        tabCoordinator.csvFilterStates
    }

    public func csvFilterState(forTabID id: UUID) -> CSVFilterState {
        tabCoordinator.csvFilterState(forTabID: id)
    }

    public func setCsvFilterState(_ state: CSVFilterState, forTabID id: UUID) {
        tabCoordinator.setCsvFilterState(state, forTabID: id)
    }

    public func clearCsvFilterState(forTabID id: UUID) {
        tabCoordinator.clearCsvFilterState(forTabID: id)
    }

    /// Forwarder. New code should call `tabCoordinator.hexBytesPerRow`.
    public var hexBytesPerRow: [UUID: Int] { tabCoordinator.hexBytesPerRow }

    public func hexWidth(forTabID id: UUID) -> Int {
        tabCoordinator.hexWidth(forTabID: id, fallback: preferences.hexBytesPerRow)
    }

    public func setHexWidth(_ width: Int, forTabID id: UUID) {
        tabCoordinator.setHexWidth(width, forTabID: id)
        // Also bump the global default so the next opened binary
        // remembers what the user picked. Cheap; matches Sublime
        // "remember last setting" feel. Lives on DocumentModel
        // because PreferencesStore is a DocumentModel dependency.
        let clamped = HexLayout.clampWidth(width)
        if preferences.hexBytesPerRow != clamped {
            preferences.hexBytesPerRow = clamped
        }
    }

    /// Source-compat alias — the type was previously nested on
    /// DocumentModel; CSVTableView constructs `DocumentModel.CSVFilterState()`.
    /// Keeps that call site valid without churning view code.
    public typealias CSVFilterState = TabCoordinator.CSVFilterState
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

    /// The tabs whose panes are currently mounted, MRU-first (active first).
    /// Compact-maps `mountedPanes.ids` against the live tab list so an id for
    /// a tab closed out-of-band is simply not rendered (its pane unmounts).
    /// `ContentView.content` renders one `ZStack` pane per entry.
    public var mountedTabs: [ViewerCore.Tab] {
        mountedPanes.ids.compactMap { id in tabs.tabs.first { $0.id == id } }
    }

    @Published public private(set) var recents: [HistoryEntry] = []

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

    /// Preview mode's metadata side panel (file info, image dimensions,
    /// SQLite table/row counts). It used to render unconditionally with
    /// no dismiss affordance (TSK-608); the BottomAttributesBar "Info"
    /// toggle drives this. Persisted; default ON (prior behavior).
    @Published public var showPreviewMetadataPanel: Bool {
        didSet { preferences.previewMetadataVisible = showPreviewMetadataPanel }
    }

    /// When on, NSLayoutManager renders dots for spaces, arrows for
    /// tabs, pilcrows for paragraph breaks. Persisted.
    @Published public var showInvisibleChars: Bool {
        didSet { preferences.showInvisibleChars = showInvisibleChars }
    }
    public func toggleShowInvisibleChars() { showInvisibleChars.toggle() }

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
    /// LSP "Rename Symbol…" prompt presentation (TSK-640). Owned here so the
    /// command/menu + script runner toggle it without prop-drilling, mirroring
    /// `isGoToPathPresented`. The prompt's submit runs the host-tested
    /// `renameActiveEditorSymbolViaLSP`. The field seeds from `lspRenamePrefill`.
    @Published public var isLSPRenamePromptPresented: Bool = false
    /// Initial text for the rename field — empty for now (the user types the
    /// new name); a prepareRename placeholder is a follow-up.
    public private(set) var lspRenamePrefill: String = ""

    /// LSP "Code Actions…" picker (TSK-640). The command/menu opens it; it
    /// fetches actions at the cursor (async), presents the list, and applies the
    /// pick via the host-tested applyCodeAction. Mirrors the rename prompt with
    /// an async fetch state.
    public enum CodeActionPickerState: Equatable {
        case hidden
        case loading
        case presenting([LSPCodeAction])
    }
    @Published public private(set) var codeActionPicker: CodeActionPickerState = .hidden
    /// Bumped on every show/dismiss so a slow fetch landing AFTER the user
    /// dismissed (or re-opened) is dropped rather than popping a stale list.
    private var codeActionPickerGeneration = 0
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

    private let controller: DocumentController
    public let history: HistoryStore
    /// Persisted history for the Go-to-path prompt. Small (cap 10),
    /// separate from `history` so typing into the prompt doesn't churn
    /// the global recents list.
    public let goToPathHistory: GoToPathHistoryStore
    public let bookmarksStore: BookmarksStore
    /// User-defined snippets merged over the built-ins (TSK-705). Read by the
    /// Insert-Snippet menu + `insertSnippet`.
    public let snippetStore: SnippetStore
    private let preferences: PreferencesStore
    /// The app's preference store, exposed for the Settings export/import menu
    /// actions (TSK-681) which serialize/apply a `SettingsSnapshot`.
    public var preferencesStore: PreferencesStore { preferences }
    private var fileWatcher: FileWatcher?
    private var watchedURL: URL?

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
        bookmarks: BookmarksStore = BookmarksStore(storeURL: BookmarksStore.defaultStoreURL()),
        snippets: SnippetStore = SnippetStore(storeURL: SnippetStore.defaultStoreURL()),
        sidebar: SidebarModel = SidebarModel(),
        preferences: PreferencesStore = PreferencesStore(),
        // Injectable for tests (TSK-627: fake-server registry e2e). The
        // default is the production pool over LSPLanguageRegistry.default.
        lspPool: LSPPool = LSPPool()
    ) {
        self.lspPool = lspPool
        self.controller = controller
        self.history = history
        self.goToPathHistory = goToPathHistory
        self.bookmarksStore = bookmarks
        self.snippetStore = snippets
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
        self.showPreviewMetadataPanel = preferences.previewMetadataVisible
        self.showInvisibleChars = preferences.showInvisibleChars
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
        self.editor = EditorCoordinator(tabCoordinator: tabCoordinator)
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

    public func zoomIn() {
        zoom = min(zoom + PreferencesStore.zoomStep, PreferencesStore.maxZoom)
    }

    public func zoomOut() {
        zoom = max(zoom - PreferencesStore.zoomStep, PreferencesStore.minZoom)
    }

    public func zoomReset() {
        zoom = 1.0
    }

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
    /// Reveal `url` in the sidebar: switch the root if needed, expand
    /// every parent directory between the root and the URL, select the
    /// URL. Used by tab right-click → "Reveal in Sidebar" and by the
    /// implicit-reveal-on-click hook in the file tree.
    public func revealInSidebar(_ url: URL) {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        // If sidebar has no root, OR the URL isn't inside the current
        // root, set the root to the URL's containing folder (unless
        // the sidebar is locked — then bail with selection only).
        let needsRoot: Bool = {
            guard let root = sidebar.rootURL else { return true }
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            return !target.path.hasPrefix(rootPath + "/") && target.path != rootPath
        }()
        if needsRoot {
            if isSidebarLocked {
                // Locked — keep the existing root; we can only select
                // inside it, not navigate elsewhere. Silently no-op.
                return
            }
            let folder = target.hasDirectoryPath ? target : target.deletingLastPathComponent()
            sidebar.setRoot(folder)
        }
        // Expand every ancestor from the root down to (but not
        // including) the URL itself. This walks string components
        // rather than file-system traversal so it doesn't do IO.
        if let root = sidebar.rootURL {
            let rootStd = root.standardizedFileURL.resolvingSymlinksInPath()
            var cur = rootStd
            let rel = target.path
                .replacingOccurrences(of: rootStd.path + "/", with: "")
                .split(separator: "/")
                .map(String.init)
            // Always expand the root itself so the tree is visible.
            if !sidebar.isExpanded(cur) { sidebar.toggleExpansion(cur) }
            for segment in rel.dropLast() {
                cur = cur.appendingPathComponent(segment, isDirectory: true)
                if !sidebar.isExpanded(cur) { sidebar.toggleExpansion(cur) }
            }
        }
        sidebar.setSelected(target)
    }

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

    /// If follow-mode is on, reveal the active tab's file in the sidebar
    /// without re-rooting. Called on tab-selection change.
    private func followActiveTabIfNeeded() {
        guard sidebarFollowsActiveTab, let url = currentURL else { return }
        revealInSidebarWithinRoot(url)
    }

    /// Select + expand `url` in the sidebar IFF it's inside the current root.
    /// Never changes the root (unlike `revealInSidebar`, which can re-root).
    /// No-op when there's no root or the URL is outside it.
    private func revealInSidebarWithinRoot(_ url: URL) {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let root = sidebar.rootURL else { return }
        let rootStd = root.standardizedFileURL.resolvingSymlinksInPath()
        let inRoot = target.path == rootStd.path
            || target.path.hasPrefix(rootStd.path + "/")
        guard inRoot else { return }   // outside root → don't re-root
        var cur = rootStd
        let rel = target.path
            .replacingOccurrences(of: rootStd.path + "/", with: "")
            .split(separator: "/")
            .map(String.init)
        if !sidebar.isExpanded(cur) { sidebar.toggleExpansion(cur) }
        for segment in rel.dropLast() {
            cur = cur.appendingPathComponent(segment, isDirectory: true)
            if !sidebar.isExpanded(cur) { sidebar.toggleExpansion(cur) }
        }
        sidebar.setSelected(target)
    }

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
            // Show it immediately (don't wait for the FSEvents coalesce).
            sidebar.reloadChildren(of: directory)
            sidebar.setSelected(url)
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

    /// Rename the file/folder at `url` to `newName` (collision-safe via
    /// `FileRenamer`: never overwrites a different file), then refresh the
    /// tree, reselect the renamed item, and repoint any bookmarks that
    /// pointed at it (or, for a folder rename, anything beneath it).
    /// Returns the new URL, or nil on failure (logged; an invalid name /
    /// collision / sandbox denial must not crash the menu action). The
    /// single entry point for the sidebar right-click → Rename and the F2
    /// key (TSK-283).
    ///
    /// An editor tab open on the renamed file is intentionally left as-is:
    /// it surfaces the existing `diskState == .deleted` "moved on disk"
    /// signal, identical to renaming the file in Finder while it's open.
    /// Silently repointing the live editor buffer/state is a separate,
    /// view-coupled change deferred out of this slice.
    @discardableResult
    public func renameFile(at url: URL, to newName: String) -> URL? {
        do {
            let newURL = try FileRenamer.rename(at: url, to: newName)
            let parent = url.deletingLastPathComponent()
            sidebar.reloadChildren(of: parent)
            sidebar.setSelected(newURL)
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

    public func showPalette() { isPalettePresented = true }
    public func dismissPalette() { isPalettePresented = false }

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
    public private(set) lazy var commandRegistry: CommandRegistry = {
        let result = KeybindingConfig.load()
        logKeybindingResult(result)
        return CommandRegistry.builtIn.applying(overrides: result.config.bindings)
    }()

    /// Reload the keybinding config from disk (e.g. after the user edits
    /// the file or a settings UI rewrites it). Re-validates ids, re-folds
    /// overrides, re-logs partial failures. Triggers an objectWillChange
    /// so palette / menu observers refresh.
    public func loadKeybindings(directory: URL = KeybindingConfig.defaultDirectory) {
        let result = KeybindingConfig.load(directory: directory)
        logKeybindingResult(result)
        objectWillChange.send()
        commandRegistry = CommandRegistry.builtIn.applying(
            overrides: result.config.bindings)
    }

    /// Emit the partial-failure diagnostics from a keybinding parse to the
    /// observability sink (unknown ids, malformed values, bad file) so a
    /// user mis-edit is visible in the Logs view / stderr instead of
    /// silently dropped.
    private func logKeybindingResult(_ result: KeybindingConfig.ParseResult) {
        if result.malformedFile {
            Obs.shared.emit(.warn, "keybinding",
                "keybinding.json is not a JSON object of strings — ignored")
        }
        for (id, raw) in result.invalidValues {
            Obs.shared.emit(.warn, "keybinding",
                "unparseable shortcut '\(raw)' for '\(id)' — ignored",
                fields: ["id": id, "value": raw])
        }
        for id in result.unknownIDs {
            Obs.shared.emit(.warn, "keybinding",
                "unknown command id '\(id)' in keybinding.json — ignored",
                fields: ["id": id])
        }
        // Surface effective-shortcut collisions (built-in or user-caused)
        // so a rebind that shadows another command is noticed.
        _ = CommandRegistry.builtIn
            .applying(overrides: result.config.bindings)
            .shortcutMap { shortcut, losing, winning in
                Obs.shared.emit(.info, "keybinding",
                    "shortcut '\(shortcut.displayString)' bound to both '\(losing)' and '\(winning)' — last wins (\(winning))",
                    fields: ["shortcut": shortcut.displayString,
                             "losing": losing, "winning": winning])
            }
    }

    /// Weak handle to the sessions coordinator so palette-invoked
    /// commands can dispatch the session/sidebar verbs through
    /// `ScriptVerb.apply(verb:to:sessions:)` — the SAME pure dispatch
    /// surface the `--script` runner + headless harness use. Set by the
    /// app delegate at launch; `weak` to avoid a retain cycle (the
    /// coordinator owns the model). One-way dependency, same shape as
    /// `openFolderInNewSession`.
    public weak var sessionsCoordinator: SessionsAppCoordinator?

    /// Invoke a registered command by id from the palette.
    ///
    /// Routes through `ScriptVerb.apply` when the command has a
    /// `scriptVerb` (the pure, headless-tested dispatch path). Commands
    /// without a verb (window/`NSApp`-coupled — see the GAP list) are
    /// no-ops here and remain menu-only; the palette greys them out.
    /// Returns `true` if a verb was dispatched.
    @discardableResult
    public func invokeCommand(id: String) -> Bool {
        guard let cmd = commandRegistry.command(id: id),
              let verb = cmd.scriptVerb else { return false }
        guard let sessions = sessionsCoordinator else {
            // No coordinator wired (previews / some tests). The model-only
            // verbs would still apply, but ScriptVerb.apply needs the pair;
            // without it we can't dispatch safely.
            Obs.shared.emit(.warn, "command",
                "invokeCommand('\(id)') skipped: no sessions coordinator wired")
            return false
        }
        return ScriptVerb.apply(verb: verb, to: self, sessions: sessions)
    }

    /// True while the visible Go-to-path prompt was invoked as the
    /// empty-session entry point (the SessionTabBar `+` button via the
    /// first-paint gate). A folder confirmed under this intent must
    /// spawn a NEW session — including on the default Return/Open path,
    /// which otherwise mutates the active session (TSK-600: picking `~`
    /// after `+` re-rooted the current tab and created nothing).
    public private(set) var goToPathNewSessionIntent: Bool = false

    /// TSK-314: initial text for the prompt's path field. "~" for the
    /// new-session flow (the + button) so a bare Enter opens home and a
    /// typed path starts from a sensible anchor; nil (empty, "match
    /// Finder") for the regular in-session Go To.
    public private(set) var goToPathPrefill: String?

    public func showGoToPath(newSessionIntent: Bool = false) {
        goToPathNewSessionIntent = newSessionIntent
        goToPathPrefill = newSessionIntent ? "~" : nil
        isGoToPathPresented = true
        // Clear stale error state from a previous attempt so the dump
        // reflects only the current invocation.
        lastGoToError = ""
    }
    public func dismissGoToPath() {
        isGoToPathPresented = false
        goToPathNewSessionIntent = false
        goToPathPrefill = nil
        lastGoToError = ""
    }

    /// Record a successfully-opened path in the Go-to-path history.
    /// Called by `GoToPathPrompt` after `openPath`. Stored as the raw
    /// expanded path string (not URL) so the UI can re-display it
    /// verbatim — including tilde-form if we ever start preserving it.
    public func recordGoToPath(_ absolutePath: String) {
        goToPathHistory.record(absolutePath)
    }

    /// Headless equivalent of `GoToPathPrompt.submit(newSession:)`. The
    /// script runner can't drive the prompt's local TextField, so this
    /// method exposes the same expand → validate → open path so VM UI
    /// tests can exercise both happy-path and error-path behaviour.
    ///
    /// On success: records history, calls `openPath` (or
    /// `openFolderInNewSession` when `newSession` is true and the path
    /// is a directory), dismisses the prompt, clears `lastGoToError`.
    ///
    /// On failure: populates `lastGoToError` with the user-facing
    /// message and leaves the prompt visible so the next interaction
    /// can correct it.
    public func commitGoToPath(_ rawPath: String, newSession: Bool = false) {
        switch GoToPathExpansion.resolveExisting(rawPath) {
        case .failure(let err):
            lastGoToError = Self.userMessage(for: err)
        case .success(let url):
            recordGoToPath(url.path)
            if newSession || goToPathNewSessionIntent,
               GoToPathExpansion.isDirectory(url.path),
               let openInNew = openFolderInNewSession {
                openInNew(url)
            } else {
                openPath(url)
            }
            lastGoToError = ""
            dismissGoToPath()
        }
    }

    private static func userMessage(for err: GoToPathExpansion.Error) -> String {
        switch err {
        case .empty:    return "Enter an absolute path."
        case .relative: return "Path must be absolute (start with / or ~)."
        case .notFound: return "No file or folder at that path."
        }
    }

    // MARK: Footer git chip (UX-C, #225)

    /// Repo working-tree root for the footer git chip. Prefers the current
    /// file's repo (so the chip tracks the focused document even when it
    /// lives outside the sidebar tree), falling back to the sidebar root.
    ///
    /// Memoized so the footer body doesn't FS-walk (`discoverRoot` does up
    /// to 32 `fileExists` syscalls) on every re-eval — keyed by the input
    /// URL, recomputed only when the focused URL changes. Cheap and pure.
    public var gitChipRepoRoot: URL? {
        let anchor = currentURL ?? sidebar.rootURL
        guard let anchor else { return nil }
        if let hit = Self.gitChipRootCache, hit.anchor == anchor {
            return hit.root
        }
        let root = GitClient.discoverRoot(from: anchor)
        Self.gitChipRootCache = (anchor, root)
        return root
    }

    nonisolated(unsafe) private static var gitChipRootCache:
        (anchor: URL, root: URL?)? = nil

    /// Open a worktree directory in a NEW window/session — the
    /// non-destructive branch-switch path (each worktree is its own
    /// checkout, so nothing in the current tree is touched). Routes through
    /// the same `openFolderInNewSession` closure the sidebar's "Open in New
    /// Session" uses. No-op when no coordinator is wired (previews/tests).
    public func openWorktreeInNewWindow(_ path: URL) {
        guard let openInNew = openFolderInNewSession else {
            Obs.shared.emit(.warn, "git",
                "openWorktreeInNewWindow skipped: no new-session closure wired")
            return
        }
        openInNew(path)
    }

    /// Hard-gated branch switch from the footer chip (UX-C #225, step 2).
    ///
    /// Runs ENTIRELY off the main actor for the git I/O (`status`,
    /// `checkout`, optional `stash`), then hops back to the main actor for
    /// any NSAlert + the post-checkout reload. The dirty-gate decision is
    /// `GitBranchSwitch.decide` (pure, T1m-tested): a dirty tree REFUSES and
    /// offers a stash-then-switch escape hatch rather than risking the
    /// silent carry-over a plain `git checkout` can do.
    ///
    /// `forceStash == true` means the user already accepted the stash offer
    /// from a prior refusal — we stash, then proceed past the gate.
    public func switchBranch(to target: String, forceStash: Bool = false) {
        guard let root = gitChipRepoRoot else { return }
        let current = SessionGitInfo.badge(for: root).branch
        Task.detached { [weak self] in
            let client = GitClient(repoRoot: root, statusTimeout: 10)
            let status = client.status()
                .map { "\($0.indexStatus)\($0.workingStatus) \($0.path)" }
                .joined(separator: "\n")
            let decision = GitBranchSwitch.decide(
                current: current, target: target, porcelainStatus: status)

            switch decision {
            case .noop:
                return
            case .refuse(let reason, _):
                if forceStash {
                    let stash = client.stashPushAll(
                        message: "TextView: auto-stash before switch to \(target)")
                    guard stash.ok else {
                        await self?.presentGitSwitchAlert(
                            title: "Couldn’t stash changes",
                            message: stash.message, offerStash: false, target: target)
                        return
                    }
                    // Stash succeeded — don't return; let control leave the
                    // switch and run the checkout below.
                } else {
                    await self?.presentGitSwitchAlert(
                        title: "Switch blocked — working tree is dirty",
                        message: reason, offerStash: true, target: target)
                    return
                }
            case .allow:
                break
            }

            let result = client.checkout(branch: target)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if result.ok {
                    // Reload the focused file so the new branch's bytes
                    // show. The sidebar tree refreshes itself via its
                    // FSEvents watcher (a branch switch rewrites files on
                    // disk — see SidebarModel.onFolderChange); we just drop
                    // the children cache so a re-expand re-reads. The chip's
                    // branch label re-reads `.git/HEAD` on the next body
                    // pass, so invalidate the memoized root + republish.
                    Self.gitChipRootCache = nil
                    self.sidebar.clearCache()
                    self.reloadCurrentFile()
                    self.objectWillChange.send()
                } else {
                    Task { await self.presentGitSwitchAlert(
                        title: "git checkout failed",
                        message: result.message, offerStash: false, target: target) }
                }
            }
        }
    }

    /// Present the branch-switch NSAlert on the main actor. When
    /// `offerStash` is true the alert offers "Stash & Switch" (which
    /// re-invokes `switchBranch(forceStash: true)`) alongside Cancel.
    @MainActor
    private func presentGitSwitchAlert(
        title: String, message: String, offerStash: Bool, target: String
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = offerStash ? .warning : .critical
        if offerStash {
            alert.addButton(withTitle: "Stash & Switch")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }
        let response = alert.runModal()
        if offerStash, response == .alertFirstButtonReturn {
            switchBranch(to: target, forceStash: true)
        }
    }

    // MARK: Bookmarks

    /// True if the currently-focused URL (a tab's file URL OR the open
    /// folder root when no file is in focus) is bookmarked.
    public var isCurrentTabBookmarked: Bool {
        guard let url = bookmarkTargetURL else { return false }
        return bookmarksStore.contains(url)
    }

    /// What Cmd+D operates on: prefer the current tab's file; fall
    /// back to the sidebar's open folder root. Lets users bookmark
    /// folders (previously file-only).
    public var bookmarkTargetURL: URL? {
        currentURL ?? sidebar.rootURL
    }

    /// Toggle the current tab's (or current folder's) bookmark.
    public func toggleCurrentTabBookmark() {
        guard let url = bookmarkTargetURL else { return }
        let name = url.lastPathComponent.isEmpty
            ? url.path
            : url.lastPathComponent
        _ = bookmarksStore.toggle(url: url, displayName: name)
        publishBookmarksChange()
    }

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

    /// Remove a bookmark by URL.
    public func removeBookmark(_ url: URL) {
        bookmarksStore.remove(url: url)
        bookmarks = bookmarksStore.all(); invalidateBookmarkedLinesCache()
    }

    /// Remove a specific bookmark — file-level or line-level.
    public func removeBookmark(url: URL, line: Int?) {
        bookmarksStore.remove(url: url, line: line)
        bookmarks = bookmarksStore.all(); invalidateBookmarkedLinesCache()
    }

    /// Clear all bookmarks.
    public func clearBookmarks() {
        bookmarksStore.clear()
        bookmarks = []
        invalidateBookmarkedLinesCache()
    }

    /// TSK-330 — the app-level ⌘Z target outside the editor: whether the
    /// store has a removal that undo can restore.
    public var canUndoBookmarkRemoval: Bool { bookmarksStore.canUndoRemoval }

    /// Restore the most recently removed bookmark (the store has carried
    /// this stack since the Delete-to-remove ask; the Edit→Undo fallback
    /// is its first consumer). Republishes the bookmarks array so the
    /// panel + star indicators reflect the restoration immediately.
    @discardableResult
    public func undoLastBookmarkRemoval() -> Bool {
        guard bookmarksStore.undoLastRemoval() != nil else { return false }
        bookmarks = bookmarksStore.all()
        invalidateBookmarkedLinesCache()
        return true
    }

    /// Reload the `bookmarks` array from the store. Call this after a
    /// mutation that went directly through `bookmarksStore` (e.g. the
    /// sidebar context-menu's `toggle(url:)`) — those bypass the
    /// public DocumentModel API and won't otherwise propagate.
    public func refreshBookmarks() {
        bookmarks = bookmarksStore.all()
        invalidateBookmarkedLinesCache()
    }

    // MARK: - Line bookmarks

    /// Bookmark (or unbookmark) the line the caret is currently on
    /// in the source view. No-op when there's no current file or
    /// caret line is zero.
    public func toggleCurrentLineBookmark() {
        guard let url = currentURL else { return }
        let line = sourceSelection.line
        guard line > 0 else { return }
        let display = "\(url.lastPathComponent):\(line)"
        _ = bookmarksStore.toggle(url: url, displayName: display, line: line)
        bookmarks = bookmarksStore.all(); invalidateBookmarkedLinesCache()
    }

    /// Open `entry` and — if it's a line bookmark — scroll to the
    /// stored line and select it.
    public func openBookmark(_ entry: BookmarkEntry) {
        openPath(entry.url)
        if let line = entry.line {
            scrollSource(toLine: line)
        }
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

    // MARK: - Git diff marks for source-view gutter

    /// Per-line diff status for the *current* file. Recomputed on
    /// file open / file save / reload via `refreshDiffMarks()`.
    @Published public private(set) var sourceDiffMarks: [Int: DiffMark] = [:]

    /// In-flight `git diff` task. Held so we can cancel before
    /// launching a new one when the focused file changes — otherwise
    /// rapid tab switches stack git processes.
    private var diffMarksTask: Task<Void, Never>?
    /// Separate in-flight task for the SPLIT pane's gutter diff. The
    /// split pane gets its own diff feed (it can be a file in a DIFFERENT
    /// repo than the primary pane — "two repos colored simultaneously").
    private var splitDiffMarksTask: Task<Void, Never>?
    /// In-flight syntax-fold compute for the selected editor tab (TSK-466).
    /// Cancelled + relaunched on selection change / edit so a keystroke
    /// burst doesn't stack TreeSitter parses. Single handle is enough —
    /// only the *selected* editor tab's folds are ever computed.
    private var editorFoldsTask: Task<Void, Never>?

    /// Wall-clock cap for the gutter's `git diff` (CHANGE 3). On timeout
    /// we leave the prior markers rather than clearing. `nonisolated` so
    /// the `Task.detached` diff bodies can read it off-main.
    private nonisolated static let gutterDiffTimeout: TimeInterval = 3

    /// Debounce window for the off-main `git diff` that feeds the
    /// source-view diff stripe. A flurry of `updateDerived()` calls
    /// (opening many files, keystroke-rate watcher/save events) all
    /// funnel through `refreshDiffMarks`; sleeping this long before the
    /// git invocation collapses the burst into one process per
    /// quiescent window. MAGIC-005: named so the timing isn't an
    /// unexplained literal at the call site.
    private static let diffMarksDebounceNanos: UInt64 = 150_000_000  // 150 ms

    /// Recompute `sourceDiffMarks` by shelling out to `git diff` for
    /// the current file. Off-main; main-actor publish at the end.
    /// Cancels any prior in-flight task before launching the new one
    /// so a flurry of `updateDerived()` calls (e.g. opening 50 files
    /// via "Open Recent") doesn't pile up 50 git processes.
    ///
    /// CHANGE 1 (root sharing): resolve the repo root via the multi-repo
    /// registry (`trackedRepos.repoRoot(enclosing:)`) so we reuse its
    /// cached resolution + the per-root watcher that's already running.
    /// Falls back to `GitClient.discoverRoot` if the file's repo isn't
    /// tracked yet (it will be — opening the tab triggers
    /// `repoFocus.recompute()` which retains it).
    /// TSK-672/814: when blame mode is on, the editor gutter shows per-line
    /// authorship instead of diff bars. Toggled via `toggleEditorBlame()` /
    /// the "Toggle Git Blame" command. `refreshDiffMarks` is the central
    /// gutter-refresh (fired on file open/switch/save/watch), so routing it to
    /// blame here makes blame survive tab switches without a separate hook.
    @Published public var editorBlameActive = false

    public func refreshDiffMarks() {
        if editorBlameActive { refreshBlameMarks(); return }
        diffMarksTask?.cancel()
        guard let url = currentURL,
              let repoRoot = resolveGutterRoot(for: url)
        else {
            if !sourceDiffMarks.isEmpty { sourceDiffMarks = [:] }
            diffMarksTask = nil
            return
        }
        let relPath = Self.relativePath(of: url, under: repoRoot)
        let token = url
        diffMarksTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Debounce: if the user is rapidly switching tabs, we'll be
            // cancelled before the git invocation even starts. Same
            // window protects against keystroke-rate calls — the file-
            // watcher / save / external-edit feed all funnel through
            // here, so we get one git process per quiescent window
            // rather than one per event.
            try? await Task.sleep(nanoseconds: Self.diffMarksDebounceNanos)
            if Task.isCancelled { return }
            // CHANGE 3: per-call 3s wall-clock timeout on the diff.
            let client = GitClient(repoRoot: repoRoot, statusTimeout: Self.gutterDiffTimeout)
            let diff = client.diff(forPath: relPath)
            if Task.isCancelled { return }
            // Routed: Rust engine per the `.diff` gate, Swift fallback
            // inside the adapter (TSK-561 closed the gutter routing gap).
            let marks = RustDiffAdapter.hunkMarks(diff)
            // Build the CM6 marker payload off-main so the main-actor
            // hop below is just an assignment. `markers(from:)` is a
            // sort + map; cheap, but no point doing it on the main thread.
            let cmMarkers = DiffGutterFeeder.markers(from: marks)
            await MainActor.run { [weak self] in
                guard let self, self.currentURL == token else { return }
                self.sourceDiffMarks = marks
                // Mirror into the CM6 editor's pending-marker channel.
                // `setEditorGutterMarkers` resolves URL → tab itself so a
                // tab-switch racing the task completion can't mis-route.
                self.editor.setEditorGutterMarkers(cmMarkers, forURL: token)
            }
        }
    }

    /// TSK-814: feed the editor gutter with per-line git blame for the active
    /// file. Mirrors `refreshDiffMarks` (off-main git + a marker feeder routed
    /// through the same `setEditorGutterMarkers` channel), but produces
    /// `"blame"`-kind markers with author/time/summary tooltips. Reaped/replaced
    /// when blame mode turns off (the diff refresh resumes via the route-guard).
    public func refreshBlameMarks() {
        diffMarksTask?.cancel()
        guard editorBlameActive, let url = currentURL,
              let repoRoot = resolveGutterRoot(for: url)
        else { diffMarksTask = nil; return }
        let relPath = Self.relativePath(of: url, under: repoRoot)
        let token = url
        diffMarksTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: Self.diffMarksDebounceNanos)
            if Task.isCancelled { return }
            let client = GitClient(repoRoot: repoRoot, statusTimeout: Self.gutterDiffTimeout)
            let blame = client.blame(path: relPath)
            if Task.isCancelled { return }
            let cmMarkers = BlameGutterFeeder.markers(from: blame)
            await MainActor.run { [weak self] in
                guard let self, self.currentURL == token, self.editorBlameActive else { return }
                self.editor.setEditorGutterMarkers(cmMarkers, forURL: token)
            }
        }
    }

    /// Toggle the editor blame gutter (the "Toggle Git Blame" command / verb).
    /// Routes through `refreshDiffMarks`, which dispatches to blame-or-diff per
    /// `editorBlameActive` — so turning blame OFF restores the diff bars.
    public func toggleEditorBlame() {
        editorBlameActive.toggle()
        refreshDiffMarks()
    }

    /// CHANGE 2 (split coverage): refresh the SPLIT pane's gutter diff.
    /// The split pane's file gets NO gutter marks today — `refreshDiffMarks`
    /// only runs for `currentURL`. This parallel path keys on `splitURL`,
    /// pushing markers via `editor.setEditorGutterMarkers(_, forURL:)`,
    /// which makes "two repos colored simultaneously" true for gutters in
    /// split view. Shares the same debounce / cancel / per-tab routing
    /// shape; the split pane may resolve to a DIFFERENT repo than the
    /// primary pane. Does NOT publish `sourceDiffMarks` (that's the
    /// primary pane's source-view stripe only).
    public func refreshSplitDiffMarks() {
        splitDiffMarksTask?.cancel()
        guard let url = tabCoordinator.splitURL,
              let repoRoot = resolveGutterRoot(for: url)
        else {
            splitDiffMarksTask = nil
            return
        }
        let relPath = Self.relativePath(of: url, under: repoRoot)
        let token = url
        splitDiffMarksTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let client = GitClient(repoRoot: repoRoot, statusTimeout: Self.gutterDiffTimeout)
            let diff = client.diff(forPath: relPath)
            if Task.isCancelled { return }
            let marks = RustDiffAdapter.hunkMarks(diff)
            let cmMarkers = DiffGutterFeeder.markers(from: marks)
            await MainActor.run { [weak self] in
                guard let self, self.tabCoordinator.splitURL == token else { return }
                self.editor.setEditorGutterMarkers(cmMarkers, forURL: token)
            }
        }
    }

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
                let regions = await TreeSitterEngine.shared.computeFolds(text: text, language: lang)
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
    private static func loadedText(of tab: ViewerCore.Tab) -> String? {
        if case .loaded(let f) = tab.state { return f.contents }
        return nil
    }

    /// Resolve the gutter's repo root via the registry first (shared
    /// cached resolution + already-running watcher), falling back to a
    /// fresh `.git` walk for files in not-yet-tracked repos.
    private func resolveGutterRoot(for url: URL) -> URL? {
        if let root = trackedRepos.repoRoot(enclosing: url) { return root }
        return GitClient.discoverRoot(from: url)
    }

    /// Path of `url` relative to `root` (forward-slashed, normalized),
    /// or the absolute path if `url` isn't under `root`.
    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return filePath
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

    /// Monotonically increasing counter that scopes each runCrossSearch()
    /// call. Bumped on every invocation AND on dismiss. Background
    /// completions check the captured value against this and drop their
    /// result when stale — so a slow "foo" search can't overwrite a
    /// faster "foobar" search that started later, and a dismissed
    /// panel doesn't get repopulated by a late finish.
    private var crossSearchGeneration: Int = 0

    public func showCrossSearch() {
        isCrossSearchPresented = true
    }

    /// Open the unified search panel with `scope` pre-applied. Used by
    /// the sidebar folder-row "Search in Folder" item — the panel's
    /// onAppear hook syncs the picker state to this preset and clears
    /// it. See `FileRowContextMenu` for the call site.
    public func showCrossSearch(scope: SearchScope) {
        crossSearchPresetScope = scope
        isCrossSearchPresented = true
    }

    public func dismissCrossSearch() {
        isCrossSearchPresented = false
        crossSearchQuery = ""
        crossSearchResults = []
        crossSearchIsRunning = false
        crossSearchPresetScope = nil
        crossSearchRegexError = nil
        crossSearchGeneration &+= 1  // invalidate any in-flight search
    }

    /// Runs a cross-file search. `scope` overrides the search root —
    /// pass a folder URL to limit the grep to that folder. When `nil`,
    /// falls back to the sidebar's current root; if neither is set,
    /// this is a no-op (sets results to empty).
    ///
    /// The two-argument variant lets the unified search panel's scope
    /// picker target a different folder than the sidebar root (e.g.
    /// "Search in Folder" from a tree right-click). Callers that
    /// want sidebar-root behavior can keep using `runCrossSearch()`.
    public func runCrossSearch(scope: URL? = nil) {
        guard let root = scope ?? sidebar.rootURL else {
            crossSearchResults = []
            return
        }
        let q = crossSearchQuery
        guard !q.isEmpty else {
            crossSearchResults = []
            crossSearchIsRunning = false
            crossSearchRegexError = nil
            crossSearchGeneration &+= 1  // cancel any in-flight search
            return
        }
        // TSK-758 — regex mode: reject ReDoS/invalid patterns up front so the
        // panel can show why instead of silently returning "No matches".
        if crossSearchUseRegex,
           let reason = CrossFileSearch.validateRegex(q, caseSensitive: crossSearchCaseSensitive) {
            crossSearchRegexError = reason
            crossSearchResults = []
            crossSearchIsRunning = false
            crossSearchGeneration &+= 1
            return
        }
        crossSearchRegexError = nil
        let filenameMode = crossSearchFilenameMode
        var opts = CrossFileSearch.Options()
        opts.caseSensitive = crossSearchCaseSensitive
        opts.useRegex = crossSearchUseRegex
        crossSearchIsRunning = true
        crossSearchGeneration &+= 1
        let gen = crossSearchGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self, opts, q] in
            let results = filenameMode
                ? CrossFileSearch.searchFilenames(root: root, query: q, options: opts)
                : CrossFileSearch.search(root: root, query: q, options: opts)
            DispatchQueue.main.async {
                guard let self, self.crossSearchGeneration == gen else { return }
                self.crossSearchResults = results
                self.crossSearchIsRunning = false
            }
        }
    }

    /// TSK-726 — apply `crossSearchReplacement` across every file in the current
    /// cross-search results (the user reviewed the matches, now rewrites them).
    /// Runs `CrossFileReplace.apply` off-main (it re-reads + atomically
    /// rewrites files preserving encoding / permissions / symlinks), then posts
    /// a one-line status and clears the stale results so the panel doesn't show
    /// matches that no longer exist. The open-tab side (an editor showing a
    /// rewritten file) is handled by the existing disk-watcher staleness path;
    /// a DIRTY buffer is never clobbered (the engine writes disk, not buffers).
    /// No-op in filename-search mode (nothing to replace inside file contents).
    public func runCrossFileReplace() {
        guard !crossSearchFilenameMode else { return }
        let files = crossSearchResults.map(\.url)
        let q = crossSearchQuery
        guard !files.isEmpty, !q.isEmpty else { return }
        let replacement = crossSearchReplacement
        let caseSensitive = crossSearchCaseSensitive
        let useRegex = crossSearchUseRegex
        crossSearchIsRunning = true
        crossSearchReplaceStatus = nil
        crossSearchGeneration &+= 1  // invalidate any in-flight search
        DispatchQueue.global(qos: .userInitiated).async { [weak self, files, q] in
            let outcomes = CrossFileReplace.apply(
                toFiles: files, query: q, replacement: replacement,
                caseSensitive: caseSensitive, useRegex: useRegex)
            let summary = CrossFileReplace.Summary(outcomes: outcomes)
            DispatchQueue.main.async {
                guard let self else { return }
                self.crossSearchReplaceStatus = DocumentModel.replaceStatusText(summary)
                self.crossSearchResults = []   // matches are stale post-rewrite
                self.crossSearchIsRunning = false
            }
        }
    }

    /// Pure one-line summary of a project-wide replace, for the panel status.
    /// Pluralized; appends a failure tail when some files couldn't be written.
    static func replaceStatusText(_ summary: CrossFileReplace.Summary) -> String {
        let occ = summary.totalReplacements
        let files = summary.filesChanged
        let base: String
        if occ == 0 {
            base = "No occurrences replaced"
        } else {
            let o = occ == 1 ? "1 occurrence" : "\(occ) occurrences"
            let f = files == 1 ? "1 file" : "\(files) files"
            base = "Replaced \(o) in \(f)"
        }
        guard !summary.failures.isEmpty else { return base }
        let n = summary.failures.count
        return "\(base) · \(n) file\(n == 1 ? "" : "s") failed"
    }

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

    // MARK: Find bar (rendered mode) — forwarders

    public var isRenderedFindBarPresented: Bool {
        get { find.isRenderedBarPresented }
        set { find.isRenderedBarPresented = newValue }
    }
    public var renderedFindQuery: String {
        get { find.renderedQuery }
        set { find.renderedQuery = newValue }
    }
    public var renderedFindNextRequest: Int {
        get { find.renderedNextRequest }
        set { find.renderedNextRequest = newValue }
    }
    public var renderedFindPrevRequest: Int {
        get { find.renderedPrevRequest }
        set { find.renderedPrevRequest = newValue }
    }
    public var renderedFindCaseSensitive: Bool {
        get { find.renderedCaseSensitive }
        set { find.renderedCaseSensitive = newValue }
    }
    public var renderedFindMatched: Bool? {
        get { find.renderedMatched }
        set { find.renderedMatched = newValue }
    }
    public var renderedFindMatchSummary: String {
        get { find.renderedMatchSummary }
        set { find.renderedMatchSummary = newValue }
    }
    public var renderedFindFocusRequest: Int {
        get { find.renderedFocusRequest }
        set { find.renderedFocusRequest = newValue }
    }

    public func setRenderedFindMatchSummary(_ s: String) {
        find.setRenderedMatchSummary(s)
    }
    public func showRenderedFindBar() { find.showRenderedBar() }
    public func dismissRenderedFindBar() { find.dismissRenderedBar() }
    public func toggleRenderedFindBar() { find.toggleRenderedBar() }

    // MARK: Find bar (source mode) — forwarders

    public var isSourceFindBarPresented: Bool {
        get { find.isSourceBarPresented }
        set { find.isSourceBarPresented = newValue }
    }
    public var sourceFindQuery: String {
        get { find.sourceQuery }
        set { find.sourceQuery = newValue }
    }
    public var sourceFindCaseSensitive: Bool {
        get { find.sourceCaseSensitive }
        set { find.sourceCaseSensitive = newValue }
    }
    public var sourceFindIsRegex: Bool {
        get { find.sourceIsRegex }
        set { find.sourceIsRegex = newValue }
    }
    public var sourceFindNextRequest: Int {
        get { find.sourceNextRequest }
        set { find.sourceNextRequest = newValue }
    }
    public var sourceFindPrevRequest: Int {
        get { find.sourcePrevRequest }
        set { find.sourcePrevRequest = newValue }
    }
    public var sourceFindFocusRequest: Int {
        get { find.sourceFocusRequest }
        set { find.sourceFocusRequest = newValue }
    }

    /// Forwarders. Scroll the active source view to this 1-based line number
    /// on the next render. The controller debounces by comparing to its
    /// last-applied target; pair with a bumped `sourceScrollLineNonce` so
    /// re-requesting the same line still fires. Lives on the `sourceView`
    /// narrow channel — see `SourceViewChannel`.
    public var sourceScrollLineTarget: Int? {
        get { sourceView.sourceScrollLineTarget }
        set { sourceView.sourceScrollLineTarget = newValue }
    }
    public var sourceScrollLineNonce: Int {
        get { sourceView.sourceScrollLineNonce }
        set { sourceView.sourceScrollLineNonce = newValue }
    }
    public func scrollSource(toLine line: Int) {
        sourceView.scrollSource(toLine: line)
    }

    // MARK: - Per-file scroll persistence (UX-K, #231)
    //
    // Scroll offset is HIGH-FREQUENCY view-local state on the narrow
    // `SourceViewChannel.sourceScrollState` — it ticks on every wheel event
    // and deliberately does NOT republish `DocumentModel`. We must persist a
    // per-file scroll position without putting that on the hot path, so we
    // SAMPLE it lazily at the boundaries that actually matter:
    //
    //   - a tab loses focus (`selectTab` switches away),
    //   - the VISIBLE tab closes (`closeTab`); bulk closes
    //     (`closeOtherTabs` / `closeTabsToRight`) either keep the active tab
    //     or are mass-discard gestures where a stale scroll doesn't matter,
    //     so they aren't separately captured,
    //   - the active tab at a snapshot boundary (autosave fire / detach /
    //     quit) via `captureScrollForActiveTab`, read by
    //     `SessionState.makeSnapshot` off the live `Tab.scrollTopLine`.
    //
    // On capture we read the current top-of-viewport line off the channel and
    // stamp it into the tab via `tabCoordinator.replace`. `Tab.scrollTopLine`
    // is excluded from `Tab`'s Equatable, so this write can't churn the
    // SwiftUI tab-strip diff.

    /// Sample the live source-view scroll offset and stamp the resulting
    /// 1-based top line into the tab at `index`. No-op when the geometry isn't
    /// usable (zero-line doc / pre-first-paint) or the value is unchanged.
    /// Call at focus-loss / close boundaries — NEVER per scroll tick.
    func captureScroll(forTabAt index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        guard let line = sourceView.sourceScrollState.topVisibleLine else { return }
        var t = tabs.tabs[index]
        guard t.scrollTopLine != line else { return }
        t.scrollTopLine = line
        tabCoordinator.replace(at: index, with: t)
    }

    /// Convenience: capture the currently-selected tab's scroll position.
    /// Used by the autosave / termination snapshot path so the live tab
    /// carries an up-to-date `scrollTopLine` before serialization.
    public func captureScrollForActiveTab() {
        guard let i = tabs.selectedIndex else { return }
        captureScroll(forTabAt: i)
    }

    /// Restore a tab's persisted scroll position by routing through the
    /// existing `scrollSource(toLine:)` request (honored by `.source` /
    /// `.editor`). `nil` / non-positive ⇒ no-op (top of file). Called after a
    /// tab materializes / becomes active so the content is laid out first.
    func restoreScroll(forTabAt index: Int) {
        guard tabs.tabs.indices.contains(index),
              let line = tabs.tabs[index].scrollTopLine, line > 0 else { return }
        scrollSource(toLine: line)
    }

    /// TSK-718 hot exit: cap on persisted unsaved text per tab. Beyond this the
    /// unsaved content is NOT captured (the file reloads from disk on relaunch)
    /// — a guard so a huge in-flight edit can't bloat the per-session JSON.
    /// 1 MiB covers any realistic hand-edit.
    public static let hotExitMaxBytes = 1 << 20  // 1 MiB

    /// TSK-718 hot exit: stamp each tab's unsaved editor-buffer text onto its
    /// `Tab.unsavedText` so the next `makeSnapshot` persists it (and a relaunch
    /// restores the in-flight edits, VS Code-style). A clean buffer — or one
    /// whose text exceeds `hotExitMaxBytes` — clears the field. Runs at the
    /// autosave / detach / quit snapshot boundary alongside
    /// `captureScrollForActiveTab`, NEVER per keystroke.
    ///
    /// Iterates ALL tabs, not just the active one: a BACKGROUND tab can be
    /// dirty (edit tab A, switch to B — A's buffer stays dirty in memory).
    /// Reads only buffers that ALREADY exist (`editorBuffers[id]`, no seeding):
    /// a never-edited tab has no buffer, so there's nothing to capture and we
    /// don't materialize its full text just to snapshot.
    public func captureUnsavedTextForAllTabs() {
        for index in tabs.tabs.indices {
            let tab = tabs.tabs[index]
            var captured: String? = nil
            if let buf = editor.editorBuffers[tab.id], buf.isDirty,
               buf.text.utf8.count <= Self.hotExitMaxBytes {
                captured = buf.text
            }
            guard tab.unsavedText != captured else { continue }
            var t = tab
            t.unsavedText = captured
            tabCoordinator.replace(at: index, with: t)
        }
    }

    /// TSK-718 hot exit: re-inject persisted unsaved buffer text into a tab that
    /// just materialized from a session restore. Seeds the editor buffer from
    /// the freshly-read file (the on-disk baseline for the dirty diff), then
    /// overlays the restored unsaved text so the buffer comes back DIRTY with
    /// the user's in-flight edits and the TabBar dot reappears. No-op unless the
    /// tab loaded as `.loaded` text and carries a non-empty `unsavedText`.
    /// Returns whether it restored anything (test hook).
    @discardableResult
    func restoreUnsavedTextIfNeeded(forTabAt index: Int) -> Bool {
        guard tabs.tabs.indices.contains(index) else { return false }
        let tab = tabs.tabs[index]
        guard let unsaved = tab.unsavedText, !unsaved.isEmpty,
              case .loaded(let file) = tab.state else { return false }
        // Seed the baseline from disk, then overlay — `updateEditorText`
        // recomputes `isDirty` (unsaved vs disk) and mirrors it onto the Tab.
        editor.ensureEditorBuffer(for: file, tabID: tab.id)
        editor.updateEditorText(unsaved, forTabID: tab.id)
        return true
    }

    /// TSK-743 (source channel): per-URL memory of the source-view (NSTextView)
    /// top line for the ONE ephemeral preview slot. The slot reuses a single tab
    /// id across files and rebuilds the `Tab` on each swap — dropping
    /// `Tab.scrollTopLine` — so without this a sidebar preview-switch always
    /// returned a file to the top. Mirrors the editor channel's URL-keyed
    /// `previewScrollByURL`. Bounded so a long browse session can't grow it.
    private var previewSourceLineByURL: [URL: Int] = [:]
    private static let previewSourceLineCap = 64

    /// Remember `line` as `url`'s source-view top line for a later preview-return.
    private func rememberPreviewSourceLine(_ line: Int, for url: URL) {
        if previewSourceLineByURL[url] == nil,
           previewSourceLineByURL.count >= Self.previewSourceLineCap,
           let victim = previewSourceLineByURL.keys.first {
            previewSourceLineByURL.removeValue(forKey: victim)
        }
        previewSourceLineByURL[url] = line
    }

    /// TSK-821 (rendered channel): per-URL memory of the rendered-markdown
    /// WKWebView's vertical scroll offset (`window.scrollY`), the third scroll
    /// channel after the editor (CM6) and source (NSTextView) ones. The rendered
    /// pane is the DEFAULT mode for markdown, and a `loadHTMLString` reload (file
    /// switch / preview swap) always resets it to the top — so without this,
    /// returning to a markdown file you'd scrolled lands at the top. The value is
    /// reported asynchronously from the WebView (`evaluateJavaScript`), so this
    /// is captured at the reload boundary and restored on `didFinish`. Bounded.
    private var renderedScrollByURL: [URL: Double] = [:]
    private static let renderedScrollCap = 64

    /// Record the rendered WebView scroll offset for `url` (from the view's
    /// async `window.scrollY` read at a reload boundary).
    func rememberRenderedScroll(_ y: Double, for url: URL) {
        guard y > 0 else { return }   // top is the default; don't store it
        if renderedScrollByURL[url] == nil,
           renderedScrollByURL.count >= Self.renderedScrollCap,
           let victim = renderedScrollByURL.keys.first {
            renderedScrollByURL.removeValue(forKey: victim)
        }
        renderedScrollByURL[url] = y
    }

    /// The remembered rendered scroll offset for `url`, if any (nil ⇒ top).
    func renderedScrollOffset(for url: URL?) -> Double? {
        guard let url else { return nil }
        return renderedScrollByURL[url]
    }

    // MARK: - Split view (forwarders to TabCoordinator)
    //
    // The split pane lives on `tabCoordinator` because it shares the
    // "what's currently on screen" lifecycle with the tab list.
    // Forwarders here preserve the existing `model.splitURL` /
    // `model.openInSplit` / `model.closeSplit` / `model.toggleSplit`
    // call sites.

    public var splitURL: URL? {
        get { tabCoordinator.splitURL }
        set { tabCoordinator.splitURL = newValue }
    }
    public var isSplitOpen: Bool { tabCoordinator.isSplitOpen }

    public func openInSplit(_ url: URL) {
        tabCoordinator.openInSplit(url)
        // CHANGE 2: feed the split pane's gutter diff. The `$splitURL`
        // Combine sink in RepoFocusTracker keeps the registry demand set
        // in sync; this drives the per-file gutter (which needs diff
        // TEXT, not status, so it stays a separate path).
        refreshSplitDiffMarks()
    }
    public func closeSplit() {
        tabCoordinator.closeSplit()
        // Clears the split task + leaves no markers (splitURL is now nil).
        refreshSplitDiffMarks()
    }
    public func toggleSplit() {
        if tabCoordinator.splitURL != nil { closeSplit() }
        else if let url = currentURL { openInSplit(url) }
    }

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

    /// Focus the Git panel and select `tab`. If the panel section is
    /// collapsed, the consumer expands it. Used by the View menu
    /// items "Show Repository History" / "Show File History" / "Show
    /// Git Panel" so those entries are discoverable without forcing
    /// the user to click into the sidebar.
    public func showGitPanel(tab: GitPanelTab = .status) {
        gitPanelDesiredTab = tab
        gitPanelFocusRequest &+= 1
    }

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

    // MARK: - Git File History (WAVE 2b item 2)

    /// True iff `url` lives in a git repo AND is tracked — i.e. the
    /// in-app File-History view has something to show. Drives the
    /// enable/disable state of the "File History" menu items in the
    /// TabBar and sidebar context menus. Synchronous: `discoverRoot` is
    /// a filesystem walk and `isTracked` is a cheap index probe.
    public func canShowFileHistory(for url: URL) -> Bool {
        guard let root = GitClient.discoverRoot(from: url) else { return false }
        let rel = Self.repoRelativePath(of: url, root: root)
        guard let rel, !rel.isEmpty else { return false }
        return GitClient(repoRoot: root).isTracked(path: rel)
    }

    /// Open the in-app `FileHistoryView` for `url` as a view-hosting tab
    /// (WAVE 2b item 2). Replaces the old `showGitLog(.file)` path that
    /// rendered a synthetic markdown table. Computes the repo root via
    /// `GitClient.discoverRoot`, the path relative to that root (what
    /// `git log -- <path>` wants), and the leaf as the display name.
    /// No-op when the file isn't in a repo / isn't tracked, so callers
    /// can wire it unconditionally and rely on `canShowFileHistory` only
    /// for the menu-item enable state.
    public func openFileHistory(for url: URL) {
        guard let root = GitClient.discoverRoot(from: url),
              let rel = Self.repoRelativePath(of: url, root: root),
              !rel.isEmpty,
              GitClient(repoRoot: root).isTracked(path: rel) else { return }
        let view = FileHistoryView(
            doc: self,
            repoRoot: root,
            relativePath: rel,
            displayName: url.lastPathComponent
        )
        openHostedView(title: "History: \(url.lastPathComponent)", rootView: view)
    }

    /// Path of `url` relative to `root` (slash-joined, no leading slash),
    /// or `nil` when `url` isn't under `root`. Standardizes + resolves
    /// symlinks on both sides so a repo under `/var` (symlink to
    /// `/private/var`, the macOS scratch space) still matches.
    /// `nonisolated` so it's a pure helper testable off the main actor.
    nonisolated static func repoRelativePath(of url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        if filePath == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    // MARK: - Git log (legacy)

    public enum GitLogScope: Sendable { case file, folder, repo }

    /// Fetch `git log` for the given path (file or folder) and open it
    /// as a synthetic markdown tab. The rendered view picks up the
    /// markdown and shows commit metadata as a clickable list. Cached
    /// under `~/Library/Caches/MarkdownViewer/git-log/` so the
    /// rendered tab is a real file Launch Services can revisit.
    public func showGitLog(forPath url: URL, scope: GitLogScope) {
        guard let repoRoot = GitClient.discoverRoot(from: url) else { return }
        let relPath: String? = {
            let rootPath = repoRoot.standardizedFileURL.resolvingSymlinksInPath().path
            let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
            if scope == .repo { return nil }
            if filePath.hasPrefix(rootPath + "/") {
                return String(filePath.dropFirst(rootPath.count + 1))
            }
            return nil
        }()
        let client = GitClient(repoRoot: repoRoot)
        let entries = client.log(forPath: relPath, maxEntries: 200)
        // Build markdown body. Keep it dense — one entry per row,
        // commit SHA monospaced, subject as plain text, author + date
        // in a smaller subhead.
        var md = ""
        let title: String
        switch scope {
        case .file:   title = "History: \(url.lastPathComponent)"
        case .folder: title = "History: \(url.lastPathComponent)/"
        case .repo:   title = "History: \(repoRoot.lastPathComponent)"
        }
        md += "# \(title)\n\n"
        if entries.isEmpty {
            md += "_No commits._\n"
        } else {
            md += "| SHA | Subject | Author | Date |\n"
            md += "|---|---|---|---|\n"
            for e in entries {
                let safeSubject = e.subject
                    .replacingOccurrences(of: "|", with: "\\|")
                md += "| `\(e.sha)` | \(safeSubject) | \(e.author) | \(e.date) |\n"
            }
        }
        // Write under caches so Launch Services treats it as a real
        // file. Hashed filename to defeat collisions and keep dir
        // browsable.
        var hasher = Hasher()
        hasher.combine(repoRoot.path)
        hasher.combine(relPath ?? "")
        let hash = String(UInt(bitPattern: hasher.finalize()), radix: 16)
            .padding(toLength: 8, withPad: "0", startingAt: 0)
            .prefix(8)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = cache.appendingPathComponent("MarkdownViewer/git-log", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let baseName = (relPath ?? repoRoot.lastPathComponent)
            .split(separator: "/").last.map(String.init) ?? "history"
        let out = dir.appendingPathComponent("\(baseName)-\(hash).md")
        try? md.write(to: out, atomically: true, encoding: .utf8)
        openInNewTab(out)
    }
    /// Swap which file is in each pane. Convenience for the user
    /// who wants to flip primary/secondary.
    public func swapSplit() {
        guard let secondary = splitURL, let primary = currentURL else { return }
        splitURL = primary
        openPath(secondary)
    }
    // MARK: Find bar (source mode) — match state forwarders

    public var sourceFindMatchSummary: String {
        get { find.sourceMatchSummary }
        set { find.sourceMatchSummary = newValue }
    }
    public var sourceFindMatchLines: [Int] {
        get { find.sourceMatchLines }
        set { find.sourceMatchLines = newValue }
    }
    public var sourceFindCurrentMatchIndex: Int? {
        get { find.sourceCurrentMatchIndex }
        set { find.sourceCurrentMatchIndex = newValue }
    }

    public func setSourceFindMatchSummary(_ s: String) {
        find.setSourceMatchSummary(s)
    }
    public func setSourceFindMatches(lines: [Int], currentIndex: Int?) {
        find.setSourceMatches(lines: lines, currentIndex: currentIndex)
    }

    public func showSourceFindBar() { find.showSourceBar() }
    public func dismissSourceFindBar() { find.dismissSourceBar() }
    public func toggleSourceFindBar() { find.toggleSourceBar() }
    public func sourceFindNext() { find.sourceNext() }
    public func sourceFindPrev() { find.sourcePrev() }
    public func renderedFindNext() { find.renderedNext() }
    public func renderedFindPrev() { find.renderedPrev() }

    // MARK: Find bar (CM6 editor mode) — forwarders

    public var isEditorFindBarPresented: Bool {
        get { find.isEditorBarPresented }
        set { find.isEditorBarPresented = newValue }
    }
    public var editorFindQuery: String {
        get { find.editorQuery }
        set { find.editorQuery = newValue }
    }
    public var editorFindCaseSensitive: Bool {
        get { find.editorCaseSensitive }
        set { find.editorCaseSensitive = newValue }
    }
    public var editorFindIsRegex: Bool {
        get { find.editorIsRegex }
        set { find.editorIsRegex = newValue }
    }
    public var editorFindNextRequest: Int {
        get { find.editorNextRequest }
        set { find.editorNextRequest = newValue }
    }
    public var editorFindPrevRequest: Int {
        get { find.editorPrevRequest }
        set { find.editorPrevRequest = newValue }
    }
    public var editorFindFocusRequest: Int {
        get { find.editorFocusRequest }
        set { find.editorFocusRequest = newValue }
    }
    public var editorFindMatchSummary: String {
        get { find.editorMatchSummary }
        set { find.editorMatchSummary = newValue }
    }
    public var editorFindReplacement: String {
        get { find.editorReplacement }
        set { find.editorReplacement = newValue }
    }
    public var editorReplaceNextRequest: Int {
        get { find.editorReplaceNextRequest }
        set { find.editorReplaceNextRequest = newValue }
    }
    public var editorReplaceAllRequest: Int {
        get { find.editorReplaceAllRequest }
        set { find.editorReplaceAllRequest = newValue }
    }

    public func showEditorFindBar() { find.showEditorBar() }
    public func showEditorReplaceBar() { find.showEditorReplaceBar() }
    public func dismissEditorFindBar() { find.dismissEditorBar() }
    public func toggleEditorFindBar() { find.toggleEditorBar() }
    public func editorFindNext() { find.editorNext() }
    public func editorFindPrev() { find.editorPrev() }
    public func editorReplaceNext() { find.editorReplaceNext() }
    public func editorReplaceAll() { find.editorReplaceAll() }
    public func setEditorFindMatchSummary(_ s: String) {
        find.setEditorMatchSummary(s)
    }

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
    //
    // All editor mode state (cursor / scroll persistence, pending
    // diagnostics, goto-line nonce, indentation pref, save-on-blur)
    // now lives on `editor`. Forwarders here keep call sites in
    // ContentView / SettingsView / main.swift / ScriptRunner compiling
    // unchanged. New code should observe `model.editor` directly so
    // editor keystrokes / cursor ticks don't republish DocumentModel.

    /// Forwarder. New code should write `editor.editorGotoLine`.
    public var editorGotoLine: CMGotoLineRequest? {
        get { editor.editorGotoLine }
        set { editor.editorGotoLine = newValue }
    }

    /// Forwarder. Read at the `CodeMirrorEditorView` call site
    /// (`insertRequest:`).
    public var editorInsertRequest: CMInsertRequest? {
        editor.editorInsertRequest
    }

    /// Edit → Insert Date & Time (TSK-299). Formats the current time in
    /// the user's locale and inserts it at the active editor's caret.
    /// No-op unless the selected tab is in editor mode.
    public func insertDateAndTime() {
        guard currentViewMode == .editor else { return }
        editor.insertIntoEditor(DateTimeStamp.string(for: Date()))
    }

    /// True when a snippet can be inserted — the active tab is in editor mode.
    public var canInsertSnippet: Bool { currentViewMode == .editor }

    /// TSK-705 (slice 3) — insert `snippet`'s expanded text at the active
    /// editor caret. For now this inserts the plain text (placeholder defaults
    /// filled); tab-stop cursor navigation (using `ParsedSnippet.stops()`) is a
    /// later editor/VM slice. No-op (returns false) unless in editor mode.
    @discardableResult
    public func insertSnippet(_ snippet: Snippet) -> Bool {
        guard currentViewMode == .editor else { return false }
        editor.insertIntoEditor(snippet.parsed.plainText)
        return true
    }

    /// Forwarder. New code should bind `$editor.editorIndentation`.
    public var editorIndentation: CMIndentation {
        get { editor.editorIndentation }
        set { editor.editorIndentation = newValue }
    }

    /// Forwarder. New code should read `editor.editorCursorByTab`.
    public var editorCursorByTab: [UUID: CMCursorPosition] {
        editor.editorCursorByTab
    }

    /// Forwarder. New code should read `editor.editorScrollByTab`.
    public var editorScrollByTab: [UUID: CMScrollPosition] {
        editor.editorScrollByTab
    }

    public func recordEditorCursor(_ pos: CMCursorPosition, forTabID id: UUID) {
        editor.recordEditorCursor(pos, forTabID: id)
    }

    public func recordEditorScroll(_ pos: CMScrollPosition, forTabID id: UUID) {
        editor.recordEditorScroll(pos, forTabID: id)
        // TSK-719: the pinned sticky-scroll headers depend on the top-visible
        // line — refresh them when the selected tab scrolls.
        if tabs.selected?.id == id { recomputeStickyScrollHeaders() }
    }

    /// Forwarder. See `EditorCoordinator.setEditorDiagnostics`.
    public func setEditorDiagnostics(_ diags: [LSPDiagnostic], forURL url: URL) {
        editor.setEditorDiagnostics(diags, forURL: url)
    }

    /// Forwarder. New code should read `editor.pendingEditorDiagnostics`.
    public var pendingEditorDiagnostics: [UUID: [CMDiagnostic]] {
        editor.pendingEditorDiagnostics
    }

    public func consumePendingEditorDiagnostics(forTabID id: UUID) {
        editor.consumePendingEditorDiagnostics(forTabID: id)
    }

    /// Forwarder. New code should read `editor.pendingEditorGutterMarkers`.
    public var pendingEditorGutterMarkers: [UUID: [CMGutterMarker]] {
        editor.pendingEditorGutterMarkers
    }

    /// Forwarder. New code should read `editor.editorFoldRangesByTab`.
    /// Read at the `CodeMirrorEditorView` call site (`foldingRanges:`).
    public var editorFoldRangesByTab: [UUID: [CMFoldRange]] {
        editor.editorFoldRangesByTab
    }

    public func consumePendingEditorGutterMarkers(forTabID id: UUID) {
        editor.consumePendingEditorGutterMarkers(forTabID: id)
    }

    // MARK: - CM6 LSP bridge (hover / Cmd-click definition / context menu)

    /// Forwarder. New code should bind `$editor.saveEditorOnBlur`.
    public var saveEditorOnBlur: Bool {
        get { editor.saveEditorOnBlur }
        set { editor.saveEditorOnBlur = newValue }
    }

    /// JS posted a hover request. Fire the LSP `hover` round-trip
    /// asynchronously, then reply through the bridge so CM6's
    /// `hoverTooltip` callback resolves. Empty contents → no popover.
    public func respondToEditorHover(
        tabID: UUID, fileURL: URL, request: CMHoverRequest
    ) {
        // Reply with empty if no LSP language is configured — avoids
        // a pointless server roundtrip that would just time out.
        let lang = effectiveLanguage(forTabID: tabID, url: fileURL)
        _ = lang
        guard LSPLanguageRegistry.default.language(for: fileURL) != nil else {
            sendEditorHoverResponse(replyId: request.replyId, contents: "")
            return
        }
        // CM6 line is 1-based; LSP wants 0-based. character is
        // UTF-16 code units; the pool converts internally if the
        // server negotiated a different encoding.
        let lspLine = max(0, request.line - 1)
        let lspChar = max(0, request.character)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let hover = try await self.lspPool.hover(
                    fileURL: fileURL, line: lspLine, character: lspChar)
                let text: String = hover.map { h -> String in
                    return h.contents
                } ?? ""
                await MainActor.run {
                    self.sendEditorHoverResponse(
                        replyId: request.replyId, contents: text)
                }
            } catch {
                await MainActor.run {
                    self.sendEditorHoverResponse(
                        replyId: request.replyId, contents: "")
                }
            }
        }
    }

    /// The four LSP go-to verbs surfaceable as deliberate commands
    /// (TSK-464 — previously only `definition` was reachable, and only
    /// via Cmd-click/right-click in the editor).
    public enum LSPNavigationKind: String, Sendable, CaseIterable {
        case definition
        case declaration
        case typeDefinition
        case implementation
    }

    #if DEBUG
    /// Test-only: the last LSP navigation dispatched (kind + the exact
    /// 0-based position handed to the pool). Lets headless tests pin the
    /// kind→verb routing and the 1-based→0-based conversion without a
    /// live language server.
    var _lastLSPNavigation: (kind: LSPNavigationKind, url: URL, line: Int, character: Int)?
    #endif

    /// JS posted a Cmd-click. Resolve via LSP `definition`; on a
    /// single result, open the target tab + jump to the line. Multi-
    /// result is single-pick for now (first result) — matches the
    /// source-view's "go to first" default until the picker UI lands.
    public func handleEditorDefinition(
        tabID: UUID, fileURL: URL, request: CMPositionRequest
    ) {
        navigateViaLSP(kind: .definition, tabID: tabID, fileURL: fileURL, request: request)
    }

    /// Generalized LSP go-to: resolve `kind` at the given position and
    /// jump to the first result. Same single-pick + silent-failure
    /// contract as `handleEditorDefinition` (which delegates here).
    public func navigateViaLSP(
        kind: LSPNavigationKind, tabID: UUID, fileURL: URL, request: CMPositionRequest
    ) {
        _ = effectiveLanguage(forTabID: tabID, url: fileURL)
        guard lspPool.registry.language(for: fileURL) != nil else { return }
        let lspLine = max(0, request.line - 1)
        let lspChar = max(0, request.character)
        #if DEBUG
        _lastLSPNavigation = (kind, fileURL, lspLine, lspChar)
        #endif
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let pool = self.lspPool
                let locs: [LSPLocation]
                switch kind {
                case .definition:
                    locs = try await pool.definition(
                        fileURL: fileURL, line: lspLine, character: lspChar)
                case .declaration:
                    locs = try await pool.declaration(
                        fileURL: fileURL, line: lspLine, character: lspChar)
                case .typeDefinition:
                    locs = try await pool.typeDefinition(
                        fileURL: fileURL, line: lspLine, character: lspChar)
                case .implementation:
                    locs = try await pool.implementation(
                        fileURL: fileURL, line: lspLine, character: lspChar)
                }
                guard let first = locs.first else { return }
                let targetLine = first.range.start.line + 1 // back to 1-based
                guard let targetURL = URL(string: first.uri) else { return }
                await MainActor.run {
                    self.openPath(targetURL, atLine: targetLine)
                }
            } catch {
                // Navigation lookup failures are silent — there's no
                // UI surface for "LSP returned nothing"; users notice
                // by absence of navigation. Logged at trace level.
            }
        }
    }

    /// Command/verb entry: run an LSP go-to at the ACTIVE editor cursor.
    /// Returns false (and does nothing) when there's no selected tab
    /// with a URL or no recorded editor cursor — the command is a no-op
    /// rather than a guess at line 1.
    @discardableResult
    public func navigateViaLSPAtCursor(kind: LSPNavigationKind) -> Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard let cursor = editor.editorCursorByTab[tab.id] else { return false }
        navigateViaLSP(
            kind: kind, tabID: tab.id, fileURL: url,
            request: CMPositionRequest(line: cursor.line, character: cursor.column))
        return true
    }

    #if DEBUG
    /// Test-only: the last formatting dispatch (URL + the buffer snapshot
    /// the edits will be applied against). Pins the guard set + snapshot
    /// semantics without a live language server.
    var _lastFormatDispatch: (url: URL, snapshot: String)?
    #endif

    /// `editor.format` (TSK-627): whole-document format of the ACTIVE
    /// editor buffer via `textDocument/formatting`. Snapshot-guarded:
    /// the edits are resolved against the buffer text captured at
    /// dispatch, and applied only if the buffer is still unchanged when
    /// the response lands — a keystroke that raced the formatter wins,
    /// the stale response is dropped. Returns false when there is no
    /// selected tab with a URL, no editor buffer, or no LSP language.
    @discardableResult
    public func formatActiveEditorViaLSP() -> Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard lspPool.registry.language(for: url) != nil else { return false }
        guard let buf = editor.editorBuffers[tab.id] else { return false }
        let tabID = tab.id
        let snapshot = buf.text
        #if DEBUG
        _lastFormatDispatch = (url, snapshot)
        #endif
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let edits = try await self.lspPool.formatting(fileURL: url)
                guard !edits.isEmpty else { return }
                // CM6 documents are UTF-16; the negotiated LSP encoding is
                // utf-16 everywhere this app touches (same as the
                // diagnostics path in EditorCoordinator).
                let formatted = LSPTextEditApplier.apply(
                    edits, to: snapshot, encoding: .utf16)
                guard formatted != snapshot else { return }
                await MainActor.run {
                    // Snapshot guard: drop the result if the user typed
                    // while the formatter ran.
                    guard self.editor.editorBuffers[tabID]?.text == snapshot else { return }
                    self.updateEditorText(formatted, forTabID: tabID)
                }
            } catch {
                // Same silent-failure contract as the go-to verbs: no
                // formatter / server error degrades to "nothing happened".
            }
        }
        return true
    }

    /// TSK-350 — align GFM pipe tables in the active editor buffer, in place.
    /// Markdown deliberately has no format VIEW lens (its lenses are
    /// Rendered/Source — FormatToggleTests), so table alignment is a direct
    /// editor command rather than the `.formatted` toggle. No-op unless the
    /// selected tab is a markdown file with an editor buffer AND the alignment
    /// changes something. Returns whether it rewrote the buffer.
    @discardableResult
    public func formatMarkdownTablesInActiveEditor() -> Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        let ext = url.pathExtension.lowercased()
        guard ["md", "markdown", "mdown", "mkd"].contains(ext) else { return false }
        guard let buf = editor.editorBuffers[tab.id] else { return false }
        let formatted = Formatter.prettyPrint(buf.text, as: .markdown)
        guard formatted != buf.text else { return false }
        updateEditorText(formatted, forTabID: tab.id)
        return true
    }

    /// Whether `formatMarkdownTablesInActiveEditor` would act — drives the
    /// Edit-menu item's enablement. True only for a markdown tab with a live
    /// editor buffer.
    public var canAlignMarkdownTables: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
        else { return false }
        return editor.editorBuffers[tab.id] != nil
    }

    #if DEBUG
    /// Test-only: the last rename dispatch + the uris whose edits were
    /// SKIPPED because the file isn't open in any tab (viewer posture: a
    /// rename never silently writes files to disk).
    var _lastRenameDispatch: (url: URL, newName: String)?
    var _lastRenameSkippedURIs: [String] = []
    #endif

    /// `editor.rename` (TSK-640 stage 2): rename the symbol at the active
    /// editor cursor via `textDocument/rename`. Apply policy, deliberate:
    ///   • the DISPATCHING buffer is snapshot-guarded exactly like
    ///     `formatActiveEditorViaLSP` — a keystroke racing the server wins;
    ///   • edits to OTHER OPEN tabs apply against their current buffer
    ///     text (cross-file rename inside the session);
    ///   • edits to files NOT open anywhere are SKIPPED, never written to
    ///     disk behind the user's back (recorded for diagnostics).
    /// Returns false when there is no selected tab/URL, no LSP language,
    /// no editor buffer, no cursor, or an empty new name.
    @discardableResult
    public func renameActiveEditorSymbolViaLSP(newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard lspPool.registry.language(for: url) != nil else { return false }
        guard let buf = editor.editorBuffers[tab.id] else { return false }
        guard let cursor = editor.editorCursorByTab[tab.id] else { return false }
        let tabID = tab.id
        let snapshot = buf.text
        #if DEBUG
        _lastRenameDispatch = (url, trimmed)
        #endif
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let workspaceEdit = try await self.lspPool.rename(
                    fileURL: url, line: cursor.line, character: cursor.column,
                    newName: trimmed)
                guard !workspaceEdit.isEmpty else { return }
                await MainActor.run {
                    self.applyWorkspaceEditToOpenTabs(
                        workspaceEdit, dispatchTabID: tabID, dispatchSnapshot: snapshot)
                }
            } catch {
                // Same silent-failure contract as format/go-to: a server
                // error degrades to "nothing happened".
            }
        }
        return true
    }

    /// Whether the active editor offers an LSP rename right now: a selected
    /// tab with an LSP-registered language, a live editor buffer, and a
    /// recorded cursor. Mirrors `renameActiveEditorSymbolViaLSP`'s guards
    /// (minus the new-name check, which is submit-time) so the command/menu can
    /// gate enablement and `showLSPRenamePrompt` can refuse on a non-rename-able
    /// context. (TSK-640.)
    public var canRenameActiveEditorSymbol: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard lspPool.registry.language(for: url) != nil else { return false }
        guard editor.editorBuffers[tab.id] != nil else { return false }
        guard editor.editorCursorByTab[tab.id] != nil else { return false }
        return true
    }

    /// Present the rename prompt IF the active editor is rename-able (else a
    /// silent no-op — the command's enablement already greys it, this guards
    /// the script/programmatic path). The prompt's submit calls
    /// `submitLSPRename`. (TSK-640.)
    public func showLSPRenamePrompt() {
        guard canRenameActiveEditorSymbol else { return }
        lspRenamePrefill = ""
        isLSPRenamePromptPresented = true
    }

    public func dismissLSPRenamePrompt() {
        isLSPRenamePromptPresented = false
        lspRenamePrefill = ""
    }

    /// Submit the rename prompt: dispatch the (host-tested) rename and dismiss.
    /// Returns the dispatch result (false = guards refused / blank name) so the
    /// view can beep on a no-op. (TSK-640.)
    @discardableResult
    public func submitLSPRename(_ newName: String) -> Bool {
        let dispatched = renameActiveEditorSymbolViaLSP(newName: newName)
        dismissLSPRenamePrompt()
        return dispatched
    }

    /// Apply a decoded WorkspaceEdit to the open tabs (see the policy on
    /// `renameActiveEditorSymbolViaLSP`; `applyCodeAction` shares it).
    private func applyWorkspaceEditToOpenTabs(
        _ workspaceEdit: [String: [LSPTextEdit]],
        dispatchTabID: UUID,
        dispatchSnapshot: String
    ) {
        #if DEBUG
        _lastRenameSkippedURIs = []
        #endif
        for (uri, edits) in workspaceEdit {
            guard !edits.isEmpty,
                  let editURL = URL(string: uri), editURL.isFileURL else { continue }
            let editPath = editURL.standardizedFileURL.resolvingSymlinksInPath().path
            let target = tabs.tabs.first { t in
                guard let u = t.url else { return false }
                return u.standardizedFileURL.resolvingSymlinksInPath().path == editPath
            }
            guard let target, let buffer = editor.editorBuffers[target.id] else {
                #if DEBUG
                _lastRenameSkippedURIs.append(uri)
                #endif
                continue
            }
            if target.id == dispatchTabID {
                // Snapshot guard: the user typed while the server worked —
                // their text wins, the stale edits drop.
                guard buffer.text == dispatchSnapshot else { continue }
            }
            let updated = LSPTextEditApplier.apply(edits, to: buffer.text, encoding: .utf16)
            if updated != buffer.text {
                updateEditorText(updated, forTabID: target.id)
            }
        }
    }

    #if DEBUG
    /// Test-only door to the private apply step (the skip policy can't be
    /// reached through the fake server, whose fixture only ever edits the
    /// requested file).
    func _applyRenameWorkspaceEditForTesting(
        _ workspaceEdit: [String: [LSPTextEdit]],
        dispatchTabID: UUID,
        dispatchSnapshot: String
    ) {
        applyWorkspaceEditToOpenTabs(
            workspaceEdit, dispatchTabID: dispatchTabID, dispatchSnapshot: dispatchSnapshot)
    }
    #endif

    /// `editor.codeActions` (TSK-640): actions available at the active
    /// editor cursor (an empty range at the cursor position). Returns []
    /// on any failure — the same silent contract as the go-to verbs.
    public func codeActionsAtCursor() async -> [LSPCodeAction] {
        guard let tab = tabs.selected, let url = tab.url,
              lspPool.registry.language(for: url) != nil,
              let cursor = editor.editorCursorByTab[tab.id] else { return [] }
        let pos = LSPPosition(line: cursor.line, character: cursor.column)
        return (try? await lspPool.codeActions(
            fileURL: url, range: LSPRange(start: pos, end: pos))) ?? []
    }

    /// Apply a picked code action's WorkspaceEdit — same policy as rename
    /// (open tabs only; unopened files are never written). Command-only
    /// actions (empty `edit`) are refused: this viewer applies edits, it
    /// never executes server commands.
    @discardableResult
    public func applyCodeAction(_ action: LSPCodeAction) -> Bool {
        guard !action.edit.isEmpty else { return false }
        guard let tab = tabs.selected else { return false }
        let snapshot = editor.editorBuffers[tab.id]?.text ?? ""
        applyWorkspaceEditToOpenTabs(
            action.edit, dispatchTabID: tab.id, dispatchSnapshot: snapshot)
        return true
    }

    /// Whether the active editor can offer code actions now (an LSP language +
    /// a recorded cursor). Gates the command/menu + showCodeActionPicker. (TSK-640.)
    public var canRequestCodeActions: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard lspPool.registry.language(for: url) != nil else { return false }
        return editor.editorCursorByTab[tab.id] != nil
    }

    /// Open the code-action picker: present a spinner, fetch actions at the
    /// cursor off-main, then list them (or auto-dismiss if none). No-op on a
    /// non-LSP context (the command's enablement greys it; this guards the
    /// script/programmatic path). (TSK-640.)
    public func showCodeActionPicker() {
        guard canRequestCodeActions else { return }
        codeActionPickerGeneration += 1
        let generation = codeActionPickerGeneration
        codeActionPicker = .loading
        Task { [weak self] in
            guard let self else { return }
            let actions = await self.codeActionsAtCursor()
            // Drop a late fetch the user already dismissed / superseded.
            guard self.codeActionPickerGeneration == generation,
                  self.codeActionPicker == .loading else { return }
            self.codeActionPicker = actions.isEmpty ? .hidden : .presenting(actions)
        }
    }

    public func dismissCodeActionPicker() {
        codeActionPickerGeneration += 1
        codeActionPicker = .hidden
    }

    /// Apply a picked action and dismiss. Returns applyCodeAction's result
    /// (false = command-only / refused) so the view can beep on a no-op. (TSK-640.)
    @discardableResult
    public func pickCodeAction(_ action: LSPCodeAction) -> Bool {
        let applied = applyCodeAction(action)
        dismissCodeActionPicker()
        return applied
    }

    #if DEBUG
    /// Harness-only (TSK-492/640 VM render lane): present the code-action picker
    /// DIRECTLY with canned actions, bypassing the async LSP fetch, so a
    /// `MDV_UI_SCENE` can put the picker on screen deterministically for a
    /// real-pixel capture (the spawned app has no live LSP server). NOT a
    /// product path — the real flow is `showCodeActionPicker()`. Mirrors the
    /// `_applyRenameWorkspaceEditForTesting` DEBUG seam.
    func _presentCodeActionsForHarness(_ actions: [LSPCodeAction]) {
        codeActionPicker = .presenting(actions)
    }
    #endif

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

        // LSP nav submenu — only when a language is configured.
        if LSPLanguageRegistry.default.language(for: fileURL) != nil {
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

    private func sendEditorHoverResponse(replyId: String, contents: String) {
        // The current editor webview owns the response channel; we
        // route through the registry to avoid wiring an extra
        // per-tab Coordinator handle through to the model.
        guard let webView = CodeMirrorEditorRegistry.shared.current() else {
            return
        }
        let msg = CMOutboundMessage.hoverResponse(
            replyId: replyId, contents: contents, from: 0, to: 0)
        let json = CMBridgeCodec.encodeOutboundJSON(msg)
        webView.evaluateJavaScript("window.cmDispatch(\(json));")
    }

    // MARK: Pretty-print / Format

    /// Effective language for a given tab — override wins over
    /// auto-detection. Public so the ModeBar dropdown + the source
    /// view both read the same source of truth. Forwards to
    /// `tabCoordinator` for the override; auto-detect lives here
    /// (URL-based, no coordinator coupling required).
    public func effectiveLanguage(forTabID id: UUID, url: URL) -> HighlightLanguage {
        tabCoordinator.effectiveLanguage(
            forTabID: id,
            autodetected: HighlightLanguage.detect(from: url)
        )
    }

    /// The effective highlight language of the current tab — the manual
    /// override if one is set, else auto-detected from the URL. `nil` when no
    /// file tab is open. Drives the Language Mode menu's checkmark (TSK-753).
    public var currentEffectiveLanguage: HighlightLanguage? {
        guard let url = tabs.selected?.url, let id = tabs.selected?.id else { return nil }
        return effectiveLanguage(forTabID: id, url: url)
    }

    /// Set or clear the override for the current tab. Passing the
    /// auto-detected language clears the override (so a follow-up
    /// rename still does the right thing).
    public func setCurrentLanguage(_ lang: HighlightLanguage) {
        guard let url = tabs.selected?.url else { return }
        let auto = HighlightLanguage.detect(from: url)
        tabCoordinator.setSelectedTabLanguage(lang, autodetected: auto)
    }

    /// True if a manual override is set for the current tab.
    public var hasLanguageOverride: Bool {
        tabCoordinator.hasLanguageOverrideForSelected
    }

    /// True if the current tab's file is a format that can be pretty-
    /// printed (JSON / XML / HTML / SVG / .plist / .xib / .storyboard).
    public var supportsFormatToggle: Bool {
        guard let url = currentURL else { return false }
        return Formatter.SupportedFormat.detect(url) != nil
    }

    /// True if the current tab is currently showing pretty-printed
    /// content (as opposed to the raw file).
    public var isCurrentTabFormatted: Bool {
        tabCoordinator.isSelectedTabFormatted
    }

    public func toggleFormat() {
        guard supportsFormatToggle else { return }
        tabCoordinator.toggleFormatForSelected()
    }

    // MARK: Editor mode (Phase 6.x — editable plain-text buffer)
    //
    // One EditorBuffer per tab id, keyed off the same `tabs.tabs`
    // identity used by every other per-tab cache. The buffer is lazy
    // — created on first read for the tab in `.editor` view mode and
    // dropped on tab close. Storage lives on `tabCoordinator`; the
    // dirty-prompt / save-write logic stays here because it has to
    // run AppKit `NSAlert` and touch `PreferencesStore` /
    // file-watcher state.

    /// Forwarder. New code should observe
    /// `tabCoordinator.editorBuffers` directly so editor-text changes
    /// don't republish DocumentModel.
    public var editorBuffers: [UUID: EditorBuffer] {
        tabCoordinator.editorBuffers
    }

    /// Source-compat re-alias for the prompt enum. Old call sites that
    /// switched on `DocumentModel.DirtyClosePrompt` keep compiling
    /// against the new EditorCoordinator type.
    public typealias DirtyClosePrompt = EditorCoordinator.DirtyClosePrompt

    /// Forwarder. New code should call `editor.hasAnyUnsavedEdits`.
    public var hasAnyUnsavedEdits: Bool {
        editor.hasAnyUnsavedEdits
    }

    /// Forwarder. New code should call `editor.editorBuffer(forTabID:)`.
    public func editorBuffer(forTabID id: UUID) -> EditorBuffer? {
        editor.editorBuffer(forTabID: id)
    }

    /// Forwarder. New code should call `editor.ensureEditorBuffer(...)`.
    public func ensureEditorBuffer(for file: TextFile, tabID: UUID) {
        editor.ensureEditorBuffer(for: file, tabID: tabID)
    }

    /// Forwarder. New code should call `editor.updateEditorText(...)`.
    public func updateEditorText(_ newText: String, forTabID id: UUID) {
        editor.updateEditorText(newText, forTabID: id)
        // Editing a preview tab commits it: a dirty buffer must not be
        // silently discarded by the next single-click reusing the slot, so
        // promote it to a permanent tab (VSCode parity — TSK-306 §2.2). No-op
        // for a non-preview tab. Cheap: `previewTabID` is one scan of the tab
        // list, only equal when there IS a preview and it's the edited tab.
        if tabs.previewTabID == id { tabCoordinator.promoteTab(id: id) }
        // Recompute folds against the edited text (TSK-466). Only for the
        // selected tab — a background tab's editor isn't on screen.
        if tabs.selected?.id == id { refreshEditorFolds() }
    }

    /// Forwarder. New code should call `editor.saveActiveEditor()`.
    /// Also re-runs the git diff feed on success so the CM6 gutter
    /// bars + source-view diff stripe update against the new HEAD
    /// delta — without this, the bars stay frozen at "as of file open"
    /// until the next tab switch (which is what hits `updateDerived`).
    @discardableResult
    public func saveActiveEditor() -> Bool {
        let ok = editor.saveActiveEditor()
        if ok {
            refreshDiffMarks()
            // Sibling: refresh the tracked repo's badge status against
            // the new on-disk state (deterministic; doesn't wait on the
            // FSEvents debounce).
            if let url = currentURL {
                repoFocus.refreshRepo(enclosing: url)
                notifyLSPDidSave(url)
            }
        }
        return ok
    }

    /// Forwarder. New code should call `editor.saveEditor(forTabID:)`.
    /// Same refresh-on-success rationale as `saveActiveEditor` above.
    @discardableResult
    public func saveEditor(forTabID id: UUID) -> Bool {
        let ok = editor.saveEditor(forTabID: id)
        if ok {
            refreshDiffMarks()
            if let url = tabs.tabs.first(where: { $0.id == id })?.url {
                repoFocus.refreshRepo(enclosing: url)
                notifyLSPDidSave(url)
            }
        }
        return ok
    }

    /// Fire a `textDocument/didSave` to the LSP server after a successful
    /// editor write so on-save server behaviour (format/lint/index-on-save)
    /// triggers — `didChange` alone never does. Fire-and-forget like
    /// `ensureOpened`/`closeFile`; the pool no-ops when the file isn't open or
    /// the language has no LSP. (TSK-521.)
    private func notifyLSPDidSave(_ url: URL) {
        let pool = self.lspPool
        Task { try? await pool.didSave(fileURL: url) }
    }

    /// Forwarder. New code should call `editor.discardEditorBuffer(...)`.
    public func discardEditorBuffer(forTabID id: UUID) {
        editor.discardEditorBuffer(forTabID: id)
    }

    // MARK: - Save a Copy (TSK-300)

    public enum SaveCopyError: Error, Equatable {
        case noTab          // index out of range
        case emptyTab       // nothing to copy (no URL and no editable buffer)
        case encodingFailed // editor text couldn't be encoded
    }

    /// Write a COPY of the tab at `index` to `target`, leaving the open tab
    /// fully untouched (URL, dirty state, editor/HEX buffers, the file
    /// watcher — a copy is a side write, NOT a save of the active document).
    ///
    /// Captures the tab's CURRENT effective content so unsaved edits are
    /// included, most-specific first:
    ///   1. editable-HEX dirty bytes (#234), else
    ///   2. the editor buffer's live text (when dirty), else
    ///   3. a verbatim copy of the file on disk.
    ///
    /// (3) streams via `FileManager.copyItem` (no slurp into memory, preserves
    /// attributes); the dirty cases write atomically. Overwrite is supported
    /// (the SavePanel confirms it) without a data-loss window: case (3) copies
    /// to a temp sibling then `replaceItemAt`, and the dirty cases use atomic
    /// writes. This is the headless/automation core (`save-copy` verb); the
    /// menu + `NSSavePanel` that pick `target` are a thin live follow-up.
    @discardableResult
    public func saveCopy(ofTabAt index: Int, to target: URL) throws -> Bool {
        guard tabs.tabs.indices.contains(index) else { throw SaveCopyError.noTab }
        let tab = tabs.tabs[index]

        // 1. HEX-dirty bytes win (most specific live edit).
        if let bytes = hexDirtyBytes[tab.id] {
            try bytes.write(to: target, options: .atomic)
            return true
        }
        // 2. Editor-dirty text, encoded with the buffer's own encoding.
        if let buf = editor.editorBuffer(forTabID: tab.id), buf.isDirty {
            guard let data = buf.text.data(using: buf.encoding)
                    ?? buf.text.data(using: .utf8) else {
                throw SaveCopyError.encodingFailed
            }
            try data.write(to: target, options: .atomic)
            return true
        }
        // 3. Verbatim copy of the on-disk file (streamed, attribute-preserving).
        guard let src = tab.url else { throw SaveCopyError.emptyTab }
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".mdv-savecopy-\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: src, to: tmp)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        return true
    }

    /// Convenience: save a copy of the currently-selected tab. Returns false
    /// if there is no selection; rethrows write failures.
    @discardableResult
    public func saveCopyOfCurrentTab(to target: URL) throws -> Bool {
        guard let i = tabs.selectedIndex else { return false }
        return try saveCopy(ofTabAt: i, to: target)
    }

    /// Whether "Save a Copy…" has anything to write for the current tab —
    /// drives the File-menu item's `validateMenuItem`. True when a tab is
    /// selected AND it has on-disk content, a non-empty editor buffer, or
    /// pending HEX-dirty bytes (the three sources `saveCopy` draws from). A
    /// blank Untitled tab with no edits has nothing to copy → disabled.
    public var canSaveCopyOfCurrentTab: Bool {
        guard let tab = tabs.selected else { return false }
        if tab.url != nil { return true }
        if let buf = editor.editorBuffer(forTabID: tab.id), !buf.text.isEmpty { return true }
        return hexDirtyBytes[tab.id] != nil
    }

    /// A suggested filename for the Save-a-Copy panel: the current tab's own
    /// name, else a generic default. Pure so the menu layer doesn't reach
    /// into tab internals.
    public var saveCopySuggestedName: String {
        tabs.selected?.url?.lastPathComponent ?? "Untitled.txt"
    }

    /// Forwarder. New code should call `editor.confirmCloseIfDirty(at:)`.
    public func confirmCloseIfDirty(at index: Int) -> DirtyClosePrompt? {
        editor.confirmCloseIfDirty(at: index)
    }

    // MARK: - Editable HEX (#234)

    /// Latest dirty byte buffer per HEX tab. Stashed here (not just in the
    /// HexView controller) so the close-confirm "Save" branch can write it
    /// back even after the view is torn down, and so a tab switch doesn't
    /// lose the pending edits. Keyed by tab id; cleared on save / discard /
    /// tab close. Bounded by the 4 MB read cap.
    private var hexDirtyBytes: [UUID: Data] = [:]

    /// Test-only read seam for the per-tab HEX dirty stash. Lets the
    /// headless HEX suite assert leak-freedom (every close path empties
    /// the entry) and Discard/Cancel byte behavior without exposing the
    /// mutable dict. `internal` — reachable only via `@testable import`.
    func peekHexDirtyBytesForTest(_ id: UUID) -> Data? { hexDirtyBytes[id] }

    /// Mirror the HEX edit buffer's dirty state onto `Tab.isDirty` (the
    /// TabBar dot + the close-confirm gate, both reused unchanged from the
    /// editor path). Called by `HexView` on every dirty transition.
    public func setHexDirty(_ dirty: Bool, forTabID id: UUID) {
        guard let idx = tabs.tabs.firstIndex(where: { $0.id == id }) else { return }
        if !dirty { hexDirtyBytes.removeValue(forKey: id) }
        if tabs.tabs[idx].isDirty != dirty {
            var t = tabs.tabs[idx]
            t.isDirty = dirty
            tabCoordinator.replace(at: idx, with: t)
        }
    }

    /// Stash the latest dirty bytes for a HEX tab so the model-side close
    /// save can reach them. Called by `HexView` alongside `setHexDirty`.
    public func stashHexBytes(_ data: Data, forTabID id: UUID) {
        hexDirtyBytes[id] = data
    }

    /// Per-tab HEX "edit armed" intent — the ViewOnly toggle flipped OFF
    /// while the tab is in `.hex` (#234 / TSK-467). There is a single `.hex`
    /// `ViewMode`, so the armed flag has nowhere to live in the mode enum;
    /// it rides here (mirrors `hexDirtyBytes`). Default empty ⇒ View Only ON
    /// ⇒ read-only, so behaviour is byte-identical until the user opts in.
    private var hexEditArmedTabs: Set<UUID> = []

    /// True when the given HEX tab has been armed for byte editing.
    public func isHexEditArmed(forTabID id: UUID) -> Bool {
        hexEditArmedTabs.contains(id)
    }

    /// Arm / disarm byte editing for a HEX tab. Republishes so the toolbar's
    /// ViewOnly checkbox + `HexView.isEditable` re-evaluate (the `.hex`
    /// `ViewMode` is unchanged, so `setCurrentViewMode`'s republish doesn't
    /// fire — we send our own, equality-guarded).
    public func setHexEditArmed(_ armed: Bool, forTabID id: UUID) {
        let changed = armed
            ? hexEditArmedTabs.insert(id).inserted
            : (hexEditArmedTabs.remove(id) != nil)
        guard changed else { return }
        objectWillChange.send()
    }

    /// Write the edited HEX bytes back to disk (⌘S). Mirrors the editor
    /// save: pause the watcher around the write, refresh the loaded
    /// `BinaryFile` so a later re-render shows the saved bytes, clear the
    /// dirty dot. Surfaces I/O / symlink failures via NSAlert and stays
    /// dirty so the next ⌘S retries.
    @discardableResult
    public func saveHexEdits(_ data: Data, forTabID id: UUID) -> Bool {
        guard let idx = tabs.tabs.firstIndex(where: { $0.id == id }),
              let url = tabs.tabs[idx].url else { return false }
        let wasWatchingURL = watchedURL
        pauseFileWatcher()
        defer { if wasWatchingURL == currentURL { startWatchingCurrentFile() } }
        do {
            try HexBinaryWriter.write(data, to: url)
        } catch let HexWriteError.targetIsSymlink(resolved) {
            let proceed = presentHexSymlinkPrompt(url: url, resolvedTarget: resolved)
            guard proceed else { return false }
            do {
                try HexBinaryWriter.write(data, to: url, allowSymlink: true)
            } catch {
                presentHexSaveFailure(url: url, error: error)
                return false
            }
        } catch {
            presentHexSaveFailure(url: url, error: error)
            return false
        }
        // Refresh the tab's loaded BinaryFile to the saved bytes so the
        // dump re-renders against the new baseline if re-entered, and the
        // edit buffer's "original" matches disk.
        var t = tabs.tabs[idx]
        let newFile = BinaryFile(url: url, data: data,
                                 totalByteCount: data.count, isTruncated: false)
        t.state = .binary(newFile)
        t.isDirty = false
        tabCoordinator.replace(at: idx, with: t)
        hexDirtyBytes.removeValue(forKey: id)
        // Tell the live controller (if mounted) to mark its buffer saved.
        hexSavedNotifier?(id)
        if let url = tabs.tabs.first(where: { $0.id == id })?.url {
            repoFocus.refreshRepo(enclosing: url)
        }
        // textDocument/didSave (TSK-464): no text payload for a binary
        // write; the pool no-ops unless this file has a live LSP session
        // (i.e. a source file the user hex-patched while it was open).
        let pool = lspPool
        Task { try? await pool.didSave(fileURL: url, text: nil) }
        return true
    }

    /// Save a HEX tab's stashed dirty bytes (close-confirm "Save" branch).
    /// Returns false when there's nothing stashed (clean / not a hex edit).
    @discardableResult
    public func saveHexEdits(forTabID id: UUID) -> Bool {
        guard let data = hexDirtyBytes[id] else { return false }
        return saveHexEdits(data, forTabID: id)
    }

    /// True when the tab at `index` is a HEX tab with pending dirty bytes
    /// (vs. a text-editor dirty tab). Lets the close paths route "Save" to
    /// the binary writer instead of the text editor writer.
    public func isHexDirtyTab(at index: Int) -> Bool {
        guard tabs.tabs.indices.contains(index) else { return false }
        return hexDirtyBytes[tabs.tabs[index].id] != nil
    }

    /// Set by `HexView` so a model-side save (close-confirm path) can tell
    /// the live controller to mark its buffer clean. Weak-by-closure; nil
    /// when no hex view is mounted.
    public var hexSavedNotifier: ((UUID) -> Void)?

    private func presentHexSaveFailure(url: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't save \(url.lastPathComponent)"
        alert.informativeText = "\(error)"
        alert.runModal()
    }

    /// Symlink refusal prompt — same posture as the editor writer. Returns
    /// true if the user opts to write through the link (de-symlinking).
    private func presentHexSymlinkPrompt(url: URL, resolvedTarget: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(url.lastPathComponent) is a symbolic link"
        alert.informativeText = "Saving will replace the link with a regular file "
            + "(target: \(resolvedTarget)). Continue?"
        alert.addButton(withTitle: "Replace Link")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

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

    /// Returns the text that should be shown in the source view for
    /// the currently selected tab and `file`: either pretty-printed
    /// (when toggled and supported) or the raw contents — along with
    /// its byte length and the source file's mtime so the highlight
    /// cache key can be formed O(1).
    ///
    /// Memoizes the formatter output per tab id. Without this, every
    /// SwiftUI body re-eval (and there are many — find keystrokes,
    /// selection changes, scroll) reruns `Formatter.prettyPrint` on
    /// the full file, which is O(N) text-walk per call.
    ///
    /// RWC-2 / TD-09 (2026-05-30): the memo keys on `(sourceLength,
    /// modifiedTime)` rather than length alone, so a same-byte reload
    /// (`{"a":1}` → `{"b":2}`) re-runs the formatter instead of
    /// returning stale output. The not-formatted fast path reports
    /// `file.byteCount` (already O(1) on `TextFile`) instead of walking
    /// `file.contents.utf8` (PERF-04).
    ///
    /// Large read-only files skip pretty-print entirely: it's an O(N)
    /// text-walk that allocates a second full copy of the file, which
    /// for a few-hundred-MB log defeats the raised read ceiling — they
    /// render raw contents via the no-allocation plain fast path.
    public func displayedText(for file: TextFile) -> DisplayedText {
        if file.isLargeReadOnly {
            return DisplayedText(
                text: file.contents,
                byteLength: file.byteCount,
                modifiedTime: file.modifiedTime
            )
        }
        // TSK-729: the View Only (.source) lens must show UNSAVED edits, not the
        // stale on-disk text. If the selected tab has a DIRTY editor buffer, render
        // its live text (matching the Editor path's `buf?.text ?? file.contents`
        // and the outline path at :1342). A clean/absent buffer falls through to
        // the disk path below (identical text, and the format memo still applies).
        if let selID = tabs.selected?.id,
           let buf = editor.editorBuffer(forTabID: selID), buf.isDirty {
            let live = buf.text
            // Dirty edits bypass the format memo — its cache key is the on-disk
            // (length, mtime), which no longer matches the buffer. Pretty-print
            // live when the tab is in a formatted view; otherwise raw edited text.
            if tabCoordinator.formattedTabIDs.contains(selID),
               let format = Formatter.SupportedFormat.detect(file.url) {
                let pretty = Formatter.prettyPrint(live, as: format)
                return DisplayedText(
                    text: pretty,
                    byteLength: pretty.utf8.count,
                    modifiedTime: file.modifiedTime
                )
            }
            return DisplayedText(
                text: live,
                byteLength: live.utf8.count,
                modifiedTime: file.modifiedTime
            )
        }
        guard let id = tabs.selected?.id,
              tabCoordinator.formattedTabIDs.contains(id),
              let format = Formatter.SupportedFormat.detect(file.url) else {
            // Raw path: `file.byteCount` is the utf8 length captured at
            // load — no re-walk.
            return DisplayedText(
                text: file.contents,
                byteLength: file.byteCount,
                modifiedTime: file.modifiedTime
            )
        }
        let len = file.byteCount
        if let hit = tabCoordinator.formattedHit(
            forTabID: id, sourceLength: len, modifiedTime: file.modifiedTime
        ) {
            return DisplayedText(
                text: hit.formatted,
                byteLength: hit.formattedLength,
                modifiedTime: file.modifiedTime
            )
        }
        let result = Formatter.prettyPrint(file.contents, as: format)
        let formattedLen = result.utf8.count
        tabCoordinator.cacheFormatted(
            result, forTabID: id,
            sourceLength: len, modifiedTime: file.modifiedTime,
            formattedLength: formattedLen
        )
        return DisplayedText(
            text: result,
            byteLength: formattedLen,
            modifiedTime: file.modifiedTime
        )
    }

    /// Backwards-compat string-only accessor. New callers should use
    /// `displayedText(for:)` to get the byte length + mtime for free.
    public func displayText(for file: TextFile) -> String {
        displayedText(for: file).text
    }

    /// TSK-806: the text the SPLIT pane should render for `url` — the live
    /// UNSAVED edits when that file is open in a tab with a DIRTY editor buffer,
    /// else the on-disk `fallback`. Unlike `displayedText(for:)` this keys on the
    /// file's OWN tab (matched by URL), NOT `tabs.selected`: the split pane can
    /// show a DIFFERENT file than the active tab (`splitURL` is independent and
    /// swappable), so consulting the selected tab's buffer would render the wrong
    /// file's edits. A clean/absent buffer ⇒ on-disk text (same bytes anyway).
    public func splitPaneText(for url: URL, fallback: String) -> String {
        if let tab = tabs.tabs.first(where: { $0.url == url }),
           let buf = editor.editorBuffer(forTabID: tab.id), buf.isDirty {
            return buf.text
        }
        return fallback
    }

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
    private var highlightCaches: [UUID: HighlightCacheActor] = [:]

    // MARK: - View-hosting tabs (WAVE 2b item 1)
    //
    // A view-hosting tab renders an arbitrary embedded SwiftUI `rootView`
    // (the one genuine integration point for the built-but-unwired WAVE 2a
    // views). The `DocumentState.hostedView(id:title:)` case lives in
    // ViewerCore (Sendable, no SwiftUI); the actual `AnyView` payload is
    // owned HERE, keyed by the hosted-view id, because SwiftUI types must
    // not leak into ViewerCore. The registry is purged on tab close via
    // `purgeCaches`, so a closed File-History tab releases its model.
    private var hostedViews: [UUID: AnyView] = [:]

    /// The embedded view for `id`, or `nil` if no such hosted tab exists.
    /// `ContentView` calls this for the `.hostedView` document state.
    public func hostedView(forID id: UUID) -> AnyView? { hostedViews[id] }

    /// Open a new tab that hosts an arbitrary SwiftUI `rootView`. Always a
    /// fresh tab (these aren't file-backed, so there's nothing to reveal /
    /// dedup against). Returns the tab id so callers can identify it. The
    /// view is rendered by `ContentView` via `hostedView(forID:)`; closing
    /// the tab drops the registered view.
    @discardableResult
    public func openHostedView<V: View>(title: String, rootView: V) -> UUID {
        let hostID = UUID()
        hostedViews[hostID] = AnyView(rootView)
        let tab = Tab(state: .hostedView(id: hostID, title: title), viewMode: .source)
        tabCoordinator.append(tab)
        updateDerived()
        return hostID
    }

    /// Returns the per-tab cache actor for `tabID`, creating one
    /// lazily on first request. Views that need to observe
    /// highlight-ready events take `@ObservedObject` on the returned
    /// instance.
    public func highlightCacheActor(forTabID tabID: UUID) -> HighlightCacheActor {
        if let existing = highlightCaches[tabID] { return existing }
        let fresh = HighlightCacheActor()
        highlightCaches[tabID] = fresh
        return fresh
    }

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

    /// The active definition when a catalog theme is selected.
    public var activeThemeDefinition: ThemeDefinition? {
        guard let id = selectedThemeID else { return nil }
        return ThemeStore.shared.all().first { $0.id == id }
    }

    public var activeTheme: SyntaxTheme {
        if let def = activeThemeDefinition { return SyntaxTheme(from: def) }
        if let o = themeOverride { return SyntaxTheme.named(o) }
        return SyntaxTheme.resolved(forAppearance: NSApp?.effectiveAppearance)
    }

    /// TSK-641 (editor surface): the CM6 palette of the SELECTED catalog
    /// theme, or nil when no theme is selected (the editor then keeps the
    /// TSK-602 appearance-keyed legacy pair). Derived, not stored — a
    /// selectedThemeID change republishes and the editor coordinator's
    /// palette dedupe decides whether a setTheme actually ships.
    public var activeThemeCMPalette: [String: String]? {
        activeThemeDefinition.map { SyntaxTheme(from: $0).cmPalette }
    }

    /// The rendered view's extra stylesheet: the mermaid shim always, plus
    /// the active theme's token override when a catalog theme is selected.
    /// Pure composition — unit-tested; both renderPage sites use it.
    public var themedExtraStylesheet: String {
        guard let def = activeThemeDefinition else { return MermaidBundle.shimCSS }
        // pageCSS re-themes the reading page (bg/prose); tokCSS re-themes the
        // syntax tokens + code surface. nil theme → shim only (system-following).
        return MermaidBundle.shimCSS + "\n" + def.pageCSS() + "\n" + def.tokCSS()
    }

    /// View-facing accessor. Returns runs immediately if cached on the
    /// active tab's actor; otherwise returns `[]` and kicks off an
    /// async tokenize whose completion bumps the per-tab cache actor's
    /// `version`. Calls with the same key while a task is in flight
    /// are coalesced. Safe to call from `body`.
    ///
    /// PERF #5: writes go to the per-tab `HighlightCacheActor`, not a
    /// `@Published` property on this model — so a tokenize completion
    /// never republishes DocumentModel.
    public func highlightRuns(
        forTabID tabID: UUID,
        url: URL, text: String, language: HighlightLanguage,
        modifiedTime: Date? = nil
    ) -> [HighlightRun] {
        // .diff / .patch files use a hand-rolled per-line highlighter
        // — there's no TreeSitter grammar for unified diff and the
        // logic is line-prefix scanning. Run synchronously: the
        // walk is O(n) and produces deterministic output.
        let ext = url.pathExtension.lowercased()
        if ext == "diff" || ext == "patch" {
            return DiffHighlighter.highlight(text)
        }
        guard language != .plainText else { return [] }
        // utf8.count is O(1) for native UTF-8 string storage (Swift 5+);
        // (text as NSString).length materializes a UTF-16 bridge which
        // is O(N) per call and was a measurable hot-path cost from
        // SwiftUI body re-evals on multi-hundred-KB files.
        let length = text.utf8.count
        // RWC-1: mtime joins the key so a same-byte reload invalidates.
        let key = HighlightCacheKey(
            url: url, length: length, language: language,
            modifiedTime: modifiedTime
        )
        let actor = highlightCacheActor(forTabID: tabID)
        return actor.runsOrEnqueue(key: key, text: text)
    }


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
    private var renderedHTMLCache: [RenderedHTMLKey: String] = [:]
    /// Insertion-order list mirroring `renderedHTMLCache`. Used to evict
    /// the OLDEST entries on overflow (S2-G). Previously eviction used
    /// `Dictionary.keys.prefix(N)`, whose iteration order is
    /// implementation-defined — sometimes evicting the entry we'd just
    /// inserted, defeating the cache.
    private var renderedHTMLCacheOrder: [RenderedHTMLKey] = []
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
    private static let renderedHTMLCacheMax = 4

    // MARK: - Raw-HTML JavaScript opt-in (PER-TAB, default-OFF)
    //
    // SECURITY: rendering a raw `.html` file runs JavaScript DEFAULT-DENY
    // (see `HTMLDocumentPolicy` / `HTMLRenderedView`). The ONLY way JS is
    // enabled is an explicit per-tab opt-in the user flips in the mode bar.
    // Storage is a SET of opted-in tab ids: the SECURE DEFAULT is the
    // ABSENCE of the tab from the set (no entry ⇒ JS off). We never store
    // "off" — we only ever record an explicit opt-IN — so a fresh tab, a
    // restored session, or a forgotten dict entry can only ever fail
    // closed. The set is pruned on tab close via `purgeCaches`.
    @Published private var htmlJavaScriptOptIn: Set<UUID> = []

    /// PER-TAB JavaScript opt-in state for the raw-HTML renderer.
    /// `false` unless the user explicitly opted this tab in. This is the
    /// single read path the view consumes; the default is OFF.
    public func htmlJavaScriptEnabled(forTabID tabID: UUID) -> Bool {
        htmlJavaScriptOptIn.contains(tabID)
    }

    /// Convenience for the currently-selected tab. `false` when there is
    /// no selected tab (fail-closed).
    public var currentHTMLJavaScriptEnabled: Bool {
        guard let id = tabs.selected?.id else { return false }
        return htmlJavaScriptEnabled(forTabID: id)
    }

    /// Set the per-tab raw-HTML JS opt-in. The toggle is a deliberate
    /// user action — flipping it on records the tab id; flipping it off
    /// removes it (returning to the secure default). Only meaningful when
    /// the current tab is an `.html` file in rendered mode; harmless
    /// otherwise (the renderer for non-HTML files never reads it).
    public func setHTMLJavaScriptEnabled(_ enabled: Bool, forTabID tabID: UUID) {
        if enabled {
            htmlJavaScriptOptIn.insert(tabID)
        } else {
            htmlJavaScriptOptIn.remove(tabID)
        }
    }

    /// Toggle the current tab's raw-HTML JS opt-in.
    public func toggleCurrentHTMLJavaScript() {
        guard let id = tabs.selected?.id else { return }
        setHTMLJavaScriptEnabled(!htmlJavaScriptEnabled(forTabID: id), forTabID: id)
    }

    /// True when the current tab is an `.html` file being shown in
    /// rendered mode — i.e. when the "Enable JavaScript" toggle is
    /// meaningful. Honors the per-tab "Open As…" override.
    public var showsHTMLJavaScriptToggle: Bool {
        guard let url = currentURL else { return false }
        let cat = currentCategory ?? FileTypeDetector.category(for: url)
        return cat == .html && currentViewMode == .rendered
    }

    /// Returns the rendered HTML for `contents`, building+caching on
    /// miss. Call from a SwiftUI body — it's main-thread, sync, and the
    /// cached path is just a dict lookup so re-renders are fast.
    /// Cache key is (URL + content length) so a file-watcher reload
    /// with new content (different length) invalidates automatically.
    /// Returns the rendered HTML for `file` in `tabID`, building+caching
    /// on miss. Call from a SwiftUI body — it's main-thread, sync, and
    /// the cached path is just a dict lookup so re-renders are fast.
    ///
    /// Cache key is `(tabID, file.byteCount, file.modifiedTime)`. The
    /// caller passes `contents` separately because the mermaid host
    /// wraps the raw file in a fence (`"```mermaid\n…```\n"`) — the
    /// cache key intentionally ignores the wrapper since each tab only
    /// ever renders one shape (mermaid vs raw md), so a tabID match
    /// guarantees the same wrapping.
    public func renderedHTML(
        forTabID tabID: UUID,
        file: TextFile,
        contents: String,
        renderer: HTMLRenderer,
        stylesheet: String
    ) -> String {
        let key = RenderedHTMLKey(
            tabID: tabID,
            byteCount: file.byteCount,
            modifiedTime: file.modifiedTime
        )
        if let hit = renderedHTMLCache[key] { return hit }
        // Mermaid CSS rides along on every rendered markdown page. It's
        // tiny (~1 KB) and inlining it unconditionally avoids the flash
        // of unstyled mermaid hosts during initial render. The JS runtime
        // is injected separately by `MarkdownRenderedView.makeNSView` via
        // `WKUserScript`.
        let html = renderer.renderPage(
            contents,
            stylesheet: stylesheet,
            extraStylesheet: themedExtraStylesheet
        )
        storeRenderedHTML(key: key, html: html)
        return html
    }

    /// Cache-only read for SwiftUI bodies: a dict lookup, never a render.
    /// `nil` means "not rendered yet" — the body shows a placeholder and
    /// kicks `requestRenderedHTML` instead of rendering inline (TSK-611:
    /// the inline cold render — markdown→HTML plus the per-language
    /// TreeSitter `ts_query_new` compile for code fences — blocked the
    /// main thread for ~927ms inside a layout pass at file open).
    public func renderedHTMLIfCached(forTabID tabID: UUID, file: TextFile) -> String? {
        renderedHTMLCache[RenderedHTMLKey(
            tabID: tabID,
            byteCount: file.byteCount,
            modifiedTime: file.modifiedTime
        )]
    }

    /// Keys with a background render in flight; dedupes the request storm
    /// from repeated body evaluations while the first render runs.
    private var renderedHTMLInFlight: Set<RenderedHTMLKey> = []

    /// Kick a background render for `key` unless cached or already in
    /// flight. The render (and any cold TreeSitter grammar query compile
    /// it triggers) runs off-main; the result lands on the MainActor,
    /// fills the cache, and republishes so bodies re-evaluate onto the
    /// cached HTML. Returns the task for tests; `nil` when nothing was
    /// kicked (cache hit or duplicate).
    ///
    /// A result whose tab has been closed by the time it lands is
    /// dropped — `purgeCaches(forTabID:)` already evicted that tab and a
    /// late store would resurrect a dead entry.
    @discardableResult
    public func requestRenderedHTML(
        forTabID tabID: UUID,
        file: TextFile,
        contents: String,
        renderer: HTMLRenderer,
        stylesheet: String
    ) -> Task<Void, Never>? {
        let key = RenderedHTMLKey(
            tabID: tabID,
            byteCount: file.byteCount,
            modifiedTime: file.modifiedTime
        )
        guard renderedHTMLCache[key] == nil,
              !renderedHTMLInFlight.contains(key) else { return nil }
        renderedHTMLInFlight.insert(key)
        // Capture the themed stylesheet on the main actor BEFORE the
        // detached hop (it reads the live theme selection).
        let extraStylesheet = themedExtraStylesheet
        return Task.detached(priority: .userInitiated) { [weak self] in
            let html = renderer.renderPage(
                contents,
                stylesheet: stylesheet,
                extraStylesheet: extraStylesheet
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.renderedHTMLInFlight.remove(key)
                guard self.tabs.tabs.contains(where: { $0.id == tabID }) else { return }
                self.storeRenderedHTML(key: key, html: html)
                self.objectWillChange.send()
            }
        }
    }

    /// Shared insert + S2-G insertion-order eviction for the rendered-HTML
    /// cache (sync body path and async request path).
    ///
    /// MOUNTED-AWARE eviction (TSK-621): since TSK-611 the rendered body
    /// READS this cache only — evicting an entry whose tab is still in
    /// `MountedPanesLRU` flips that pane's branch webview→spinner, which
    /// DISMANTLES a retained WKWebView and re-renders it (the exact
    /// reload churn TSK-108's pane retention removed; the 5th markdown
    /// open used to tear down 2 retained panes). So: never evict a
    /// mounted tab's entry; evict the oldest NON-mounted first, and only
    /// down to capacity (the old drop-to-2/3 hysteresis amplified the
    /// over-eviction and is pointless now that eviction is rare). The
    /// cache may transiently exceed the cap by the mounted count — that
    /// is bounded by the pane LRU's own capacity (4).
    private func storeRenderedHTML(key: RenderedHTMLKey, html: String) {
        if renderedHTMLCache[key] == nil {
            renderedHTMLCacheOrder.append(key)
        }
        renderedHTMLCache[key] = html
        guard renderedHTMLCache.count > Self.renderedHTMLCacheMax else { return }
        let mounted = Set(mountedPanes.ids)
        var overflow = renderedHTMLCache.count - Self.renderedHTMLCacheMax
        var keep: [RenderedHTMLKey] = []
        keep.reserveCapacity(renderedHTMLCacheOrder.count)
        for k in renderedHTMLCacheOrder {
            if overflow > 0, !mounted.contains(k.tabID) {
                renderedHTMLCache.removeValue(forKey: k)
                overflow -= 1
            } else {
                keep.append(k)
            }
        }
        renderedHTMLCacheOrder = keep
    }

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

    /// Printable = the selected tab currently SHOWS a rendered web page:
    /// markdown/mermaid in rendered mode, or an HTML preview tab. Source/
    /// editor/hex/CSV printing is phase 2 (NSPrintOperation on the text
    /// view), deliberately out of this gate.
    public var canPrintRenderedPage: Bool {
        guard currentURL != nil else { return false }
        let cat = currentCategory
        if cat == .html { return currentViewMode == .rendered }
        return supportsViewModeToggle && currentViewMode == .rendered
    }

    /// `⌘P` — returns false (no-op) when the selected tab isn't a
    /// printable rendered page.
    @discardableResult
    public func printRenderedPage() -> Bool {
        guard canPrintRenderedPage else { return false }
        renderedPrintRequest &+= 1
        return true
    }

    /// `File → Export as PDF…` — returns false when not printable.
    @discardableResult
    public func exportRenderedPDF(to url: URL) -> Bool {
        guard canPrintRenderedPage else { return false }
        let nonce = (renderedPDFExportRequest?.nonce ?? 0) &+ 1
        renderedPDFExportRequest = PDFExportRequest(nonce: nonce, url: url)
        return true
    }

    /// Called by the rendered view after `createPDF` resolves.
    public func recordPDFExportResult(nonce: Int, ok: Bool, message: String) {
        renderedPDFExportResult = PDFExportResult(nonce: nonce, ok: ok, message: message)
        Obs.shared.emit(
            ok ? .info : .warn, "export",
            ok ? "PDF exported" : "PDF export failed",
            fields: ["detail": message])
    }

    // MARK: Derived from current tab

    public var currentState: DocumentState { tabs.selected?.state ?? .empty }
    public var currentURL: URL? { tabs.selected?.url }
    public var currentViewMode: ViewMode { tabs.selected?.viewMode ?? .rendered }

    /// Open a terminal tab `cd`'d to the focused file's folder (TSK-769
    /// "Open Terminal Here"). Adds the located tab BEFORE opening the pane so
    /// `setOpen`'s `ensureTerminal` doesn't also spawn a default home tab.
    /// With no focused file the new terminal falls back to the shell's home.
    public func openTerminalHere() {
        let cwd = TerminalCwd.workingDirectory(forFocusedFile: currentURL)
        terminalPane.addTab(workingDirectory: cwd)
        terminalPane.setOpen(true)
    }

    /// True when there's a file OR a project folder open — i.e. the status
    /// footer has something useful to show (path/metrics for a file; the
    /// folder-scoped git chip + "—" path for a folder-only project). TSK-738:
    /// the footer used to gate on `currentURL != nil` only, so it vanished after
    /// relaunch / opening a folder with no file tab selected (openFolder sets the
    /// sidebar root but selects no tab → currentURL nil).
    public var hasOpenContext: Bool { currentURL != nil || sidebar.rootURL != nil }

    /// True when the active file has a registered LSP language yet the
    /// diagnostics store holds no entry for it — i.e. no language server
    /// has analyzed it in this view. Source view never sends the
    /// `didOpen`/`didChange` that triggers `publishDiagnostics` (only the
    /// Editor / Outline paths do), so an empty store for a `.swift` file
    /// open in Source view is "not analyzed here", not a clean bill of
    /// health. The PROBLEMS panel reads this to avoid a falsely-
    /// reassuring "No problems detected." for an un-analyzed file
    /// (UAT LSP-01). Returns false for files with no LSP language (e.g.
    /// `.md`, `.txt`), where the all-clear copy is genuinely correct.
    public var activeFileUnanalyzedByLSP: Bool {
        guard let url = currentURL else { return false }
        guard LSPLanguageRegistry.default.language(for: url) != nil else { return false }
        return lspDiagnostics.byURL[url] == nil
    }

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

    // MARK: - Open As… (WAVE 2b item 6)

    /// The viewers offered by the universal "Open As…" menu for `url`.
    /// Every applicable category for ANY file, including binaries — the
    /// user can force a `.db` open as CSV, a `.png` as HEX, etc. Optional
    /// magic-byte sniff promotes a likely-real category to the top (an
    /// auto-hint, not a restriction).
    public func openAsCategories(for url: URL) -> [FileCategory] {
        // The full UNIVERSAL menu of viewers. Order = the menu order. Now
        // the complete viewer set (every FileCategory that maps to a real
        // viewer), so "Open As" is genuinely "open any file as any viewer":
        // text-shaped lenses (Source / Plain / Markdown / Mermaid / HTML),
        // native previews (Image / Audio / Video / PDF / SQLite), and HEX
        // (.binary) for raw bytes. `.unknown` is omitted — it's the
        // not-a-viewer sentinel, not a lens. (2026-06-01: folded the former
        // context-menu Open-As capability into this one chip; added the
        // media + mermaid lenses that were previously unreachable here.)
        var cats: [FileCategory] = [
            .code, .plainText, .markdown, .mermaid, .html,
            .image, .audio, .video, .pdf, .sqlite, .binary
        ]
        // Magic-byte hint: if the bytes look like a known type the
        // extension didn't reveal (e.g. `mydb.db.bak` → SQLite), float
        // that category to the front so it's the obvious first pick.
        if let hint = Self.sniffCategory(url: url),
           let idx = cats.firstIndex(of: hint) {
            cats.remove(at: idx)
            cats.insert(hint, at: 0)
        }
        return cats
    }

    /// Open `url` in a NEW tab forced to `category` (WAVE 2b item 6).
    /// Used by the sidebar file context menu's "Open As…" submenu, where
    /// the target file may not be the current tab. Loads through the
    /// chosen lens and selects the new tab.
    public func openAs(url: URL, category: FileCategory) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let state = controller.open(url: resolved, forcedCategory: category)
        let mode = ViewModeOptions.defaultMode(for: resolved, forcedCategory: category)
        tabCoordinator.append(Tab(
            url: resolved, state: state, viewMode: mode, categoryOverride: category))
        updateDerived()
        recordOpenedFile(state: state, resolved: resolved)
        startWatchingCurrentFile()
    }

    /// Set (or clear, with `nil`) the current tab's "Open As…" category
    /// override and re-open the tab through that lens. Re-runs the loader
    /// with the forced category (so a binary can be decoded as text /
    /// rendered as a SQLite preview / shown in HEX) and resets the view
    /// mode to that viewer's natural default.
    public func setCurrentCategoryOverride(_ category: FileCategory?) {
        guard let i = tabs.selectedIndex, tabs.tabs.indices.contains(i),
              let url = tabs.tabs[i].url else { return }
        let tabID = tabs.tabs[i].id
        // Recompute the load + the default mode under the override.
        let state = controller.open(url: url, forcedCategory: category)
        let mode = ViewModeOptions.defaultMode(for: url, forcedCategory: category)
        var t = tabs.tabs[i]
        t.categoryOverride = category
        t.state = state
        t.viewMode = mode
        tabCoordinator.replace(at: i, with: t)
        // Drop derived caches keyed on the old rendering so the new
        // viewer doesn't show stale rendered HTML / highlight runs.
        purgeCaches(forURL: url, tabID: tabID)
        updateDerived()
    }

    /// The user's pinned default view mode for `category` (TSK-671), or `nil`
    /// when that category uses its built-in default. Read by the bottom
    /// type-control menu's "Default view" section.
    public func defaultViewMode(for category: FileCategory) -> ViewMode? {
        preferences.viewModeDefault(for: category)
    }

    /// Pin (`mode`) or clear (`nil`) the default view mode for `category`.
    /// Affects FUTURE opens of that category — open tabs keep their mode.
    /// Publishes so the menu's checkmark moves immediately on selection.
    public func setDefaultViewMode(_ mode: ViewMode?, for category: FileCategory) {
        preferences.setViewModeDefault(mode, for: category)
        objectWillChange.send()
    }

    /// Best-effort magic-byte category sniff for the "Open As…" auto-hint.
    /// Reads only the file's header — cheap, never the whole file. Returns
    /// `nil` when nothing recognizable matches (then the menu just uses
    /// its default order). This is a HINT, never a gate.
    nonisolated static func sniffCategory(url: URL) -> FileCategory? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 16), !head.isEmpty else { return nil }
        let b = [UInt8](head)
        // SQLite: "SQLite format 3\0".
        let sqliteMagic: [UInt8] = Array("SQLite format 3".utf8)
        if b.count >= sqliteMagic.count, Array(b.prefix(sqliteMagic.count)) == sqliteMagic {
            return .sqlite
        }
        // PNG.
        if b.count >= 8, Array(b.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return .image
        }
        // JPEG.
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .image }
        // GIF.
        if b.count >= 6, Array(b.prefix(3)) == Array("GIF".utf8) { return .image }
        // PDF — "%PDF".
        if b.count >= 4, Array(b.prefix(4)) == Array("%PDF".utf8) { return .pdf }
        return nil
    }

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

    // MARK: - UX-A (#224) view-mode CONTROL (presentation layer)
    //
    // The content-toolbar's Render | Editor | HEX × ViewOnly + Format
    // control is a PRESENTATION layer over the existing `ViewMode` set.
    // It does NOT introduce new modes or new routing — every state below
    // maps onto a `ViewMode` the model already loads/routes, via the pure
    // `ViewModeControl` mapping. This keeps the brittle load/routing path
    // (LOADBUG) untouched while giving the toolbar the owner-resolved
    // mental model (`Source = Editor + ViewOnly`).

    /// The view modes the current file can show — the gate `ViewModeControl`
    /// resolves against. Honors the per-tab "Open As…" override so a
    /// forced-type tab offers the override's lenses.
    public var availableViewModes: [ViewMode] {
        ViewModeOptions.availableModes(
            for: currentURL, forcedCategory: tabs.selected?.categoryOverride,
            isRenderableText: Self.renderableTextHint(tabs.selected?.state))
    }

    /// Derive the `isRenderableText` content hint (TSK-332) from a loaded
    /// document state. `.loaded` is the loader's verdict that the bytes
    /// decoded as text (it rejects on NUL/undecodable), so an unknown- or
    /// binary-EXTENSION file that actually IS text upgrades from HEX-only to
    /// Source. Returns `nil` (NOT `false`) for every other state so the
    /// extension-driven default is left untouched: only `.loaded` is a
    /// positive text signal — `.binary`/`.preview`/`.loading`/`.empty` must
    /// not assert "renderable text" (a `.loading` tab hasn't decided yet, and
    /// `availableViewModes` re-derives once it lands `.loaded`).
    nonisolated static func renderableTextHint(_ state: DocumentState?) -> Bool? {
        if case .loaded = state { return true }
        return nil
    }

    /// How the toolbar should render itself for the current mode (which
    /// primary button is selected, whether ViewOnly reads on, whether the
    /// Format button is the active lens).
    public var viewModePresentation: ViewModeControl.Presentation {
        let base = ViewModeControl.present(currentViewMode)
        // HEX edit-armed state rides DocumentModel, not the (single) `.hex`
        // ViewMode, so `present` always reports HEX read-only. Reflect the
        // per-tab armed flag here so the ViewOnly checkbox + HexView.isEditable
        // read a live value (#234 / TSK-467).
        guard base.primary == .hex, let id = tabs.selected?.id else { return base }
        return ViewModeControl.Presentation(
            primary: .hex,
            viewOnly: !isHexEditArmed(forTabID: id),
            isFormatted: false)
    }

    /// Select a primary lens (Render / Editor / HEX) from the toolbar.
    /// Resolves through the pure mapping against the file's available
    /// modes, then routes via the UNCHANGED `setCurrentViewMode`. A tap the
    /// file can't satisfy falls back to its nearest available lens rather
    /// than forcing an unavailable mode.
    public func selectViewPrimary(
        _ primary: ViewModeControl.Primary, viewOnly: Bool
    ) {
        guard let mode = ViewModeControl.resolve(
            primary: primary, viewOnly: viewOnly, available: availableViewModes
        ) else { return }
        setCurrentViewMode(mode)
    }

    /// Flip the ViewOnly toggle while keeping the current primary lens.
    /// For the Editor primary this is the Source(read-only) ↔ Editor(edit)
    /// swap. For HEX it arms/disarms byte editing via the per-tab flag (the
    /// `.hex` ViewMode is the same either way — #234 / TSK-467). For Render
    /// it's a no-op (always read-only).
    public func setViewOnly(_ viewOnly: Bool) {
        let primary = viewModePresentation.primary
        if primary == .hex {
            if let id = tabs.selected?.id { setHexEditArmed(!viewOnly, forTabID: id) }
            return
        }
        selectViewPrimary(primary, viewOnly: viewOnly)
    }

    /// True when the Format button should be shown for the current file
    /// (pretty-printable types only — JSON / XML / plist / SVG / HTML / …).
    public var showsFormatButton: Bool {
        ViewModeControl.showsFormat(available: availableViewModes)
    }

    /// Toolbar Format button: flip into the `.formatted` lens, or back to
    /// the underlying text source when already formatted. Routes through
    /// the UNCHANGED `setCurrentViewMode` (not the standalone
    /// `toggleFormat()` flag-only path) so `currentViewMode` stays
    /// authoritative — the presentation reads `isFormatted` off the enum
    /// case, so the button's active state and the picker can't desync.
    public func toggleFormatLens() {
        guard showsFormatButton else { return }
        if currentViewMode == .formatted {
            setCurrentViewMode(.source)
        } else {
            setCurrentViewMode(.formatted)
        }
    }

    /// Toolbar-button visibility for the three primaries (media / PDF /
    /// binary tabs hide Editor; plain `.txt` hides Render).
    public var showsRenderPrimary: Bool {
        ViewModeControl.showsRender(available: availableViewModes)
    }
    public var showsEditorPrimary: Bool {
        ViewModeControl.showsEditor(available: availableViewModes)
    }

    // MARK: - UX-A (#224) breadcrumb (file-path navigation)

    /// One clickable segment of the current file's path breadcrumb.
    public struct BreadcrumbSegment: Identifiable, Equatable {
        /// Stable id = the absolute path up to and including this segment.
        public var id: String { url.path }
        /// Display name (the path component, or "~" / "/" for the roots).
        public let name: String
        /// The absolute URL this segment points at (a folder, except the
        /// last segment which is the file itself).
        public let url: URL
        /// True for the final segment (the file). The file segment reveals
        /// the file; folder segments reveal/navigate to that folder.
        public let isFile: Bool
    }

    /// Abbreviatable breadcrumb of the current file's path, home-relative
    /// (the `~` root collapses everything under `$HOME`). Each segment
    /// carries the absolute URL up to it so a click can reveal that folder
    /// in the sidebar. Empty when no file is open.
    ///
    /// The toolbar abbreviates the MIDDLE visually (leading "…") when the
    /// row is narrow; the full segment list is always available here so the
    /// overflow menu / tests see every component.
    public var pathBreadcrumb: [BreadcrumbSegment] {
        guard let fileURL = currentURL else { return [] }
        let std = fileURL.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
        let homePath = home.path
        let fullPath = std.path

        // Decide the display root: "~" when the file is under $HOME, else
        // the filesystem root "/". Build segments from there down.
        var segments: [BreadcrumbSegment] = []
        let underHome = fullPath == homePath
            || fullPath.hasPrefix(homePath + "/")
        let rootURL: URL = underHome ? home : URL(fileURLWithPath: "/")
        let rootName = underHome ? "~" : "/"
        segments.append(BreadcrumbSegment(
            name: rootName, url: rootURL, isFile: false))

        // Relative components from the root to the file.
        let rootPath = rootURL.path
        let rel: [String]
        if fullPath == rootPath {
            rel = []
        } else {
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            rel = String(fullPath.dropFirst(prefix.count))
                .split(separator: "/").map(String.init)
        }
        var cur = rootURL
        for (idx, comp) in rel.enumerated() {
            let isLast = idx == rel.count - 1
            cur = cur.appendingPathComponent(
                comp, isDirectory: !isLast || std.hasDirectoryPath)
            segments.append(BreadcrumbSegment(
                name: comp, url: cur, isFile: isLast))
        }
        return segments
    }

    /// Navigate to a breadcrumb segment: reveal the file (final segment)
    /// or the folder (any other segment) in the sidebar. Reuses the
    /// existing `revealInSidebar` (re-roots if needed, expands ancestors,
    /// selects). A folder segment that the sidebar can't reach (locked
    /// root, outside root) no-ops inside `revealInSidebar`.
    public func navigateToBreadcrumb(_ segment: BreadcrumbSegment) {
        revealInSidebar(segment.url)
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
        let initialMode = ViewModeOptions.defaultMode(
            for: resolved, isRenderableText: isRenderableText,
            preferred: preferences.viewModeDefaults)
        if forceNewTab { return initialMode }
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
    private func recordOpenedFile(state: DocumentState, resolved: URL) {
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
                sidebar.setRoot(resolved.deletingLastPathComponent())
                sidebar.setSelected(resolved)
                preferences.lastFolderURL = sidebar.rootURL
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

    /// The active tab's current text (live editor buffer if present, else the
    /// loaded-from-disk contents), or nil for a non-text tab. Used by
    /// encoding-convert (TSK-352).
    private var activeTextForEncodingConvert: (text: String, tabID: UUID, url: URL)? {
        guard let tab = tabs.selected, let url = tab.url else { return nil }
        if let buf = editor.editorBuffers[tab.id] { return (buf.text, tab.id, url) }
        if case .loaded(let f) = tab.state { return (f.contents, tab.id, url) }
        return nil
    }

    /// True when "Convert Encoding" can act — there's an active text file.
    public var canConvertActiveFileEncoding: Bool { activeTextForEncodingConvert != nil }

    /// Active text + its CURRENT encoding (for line-ending conversion, which must
    /// preserve the file's encoding — TSK-675).
    private var activeTextWithEncoding: (text: String, tabID: UUID, url: URL, encoding: String.Encoding)? {
        guard let tab = tabs.selected, let url = tab.url else { return nil }
        if let buf = editor.editorBuffers[tab.id] { return (buf.text, tab.id, url, buf.encoding) }
        if case .loaded(let f) = tab.state { return (f.contents, tab.id, url, f.encoding) }
        return nil
    }

    /// True when "Convert Line Endings" can act — there's an active text file.
    public var canConvertActiveFileLineEnding: Bool { activeTextWithEncoding != nil }

    /// Apply a pure text transform to the active file (preserving encoding +
    /// folding in unsaved edits): transform → write-through → drop+reload. A
    /// no-op (returns false) when there's no active text file or the transform
    /// changes nothing. Shared by the whitespace-cleanup commands (TSK-675).
    @discardableResult
    private func applyTextTransformToActiveFile(_ transform: (String) -> String) -> Bool {
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

    /// True when the whitespace-cleanup / line-op commands can act — active text file.
    public var canCleanUpActiveFile: Bool { activeTextWithEncoding != nil }

    /// Edit ▸ Lines: sort / reverse / dedupe the whole active file in place
    /// (terminator + trailing-newline preserved). Encoding preserved.
    @discardableResult
    public func sortActiveFileLines(ascending: Bool) -> Bool {
        applyTextTransformToActiveFile { LineOps.sort($0, ascending: ascending) }
    }
    @discardableResult
    public func reverseActiveFileLines() -> Bool {
        applyTextTransformToActiveFile(LineOps.reverse)
    }
    @discardableResult
    public func removeDuplicateActiveFileLines() -> Bool {
        applyTextTransformToActiveFile(LineOps.removeDuplicates)
    }

    /// TSK-675 — strip trailing spaces/tabs from every line (line endings + all
    /// other content preserved).
    @discardableResult
    public func trimTrailingWhitespaceInActiveFile() -> Bool {
        applyTextTransformToActiveFile(TextCleanup.trimTrailingWhitespace)
    }

    /// TSK-675 — ensure the file ends with exactly one newline, matching its own
    /// dominant line-ending convention (LF for mixed/none).
    @discardableResult
    public func ensureFinalNewlineInActiveFile() -> Bool {
        applyTextTransformToActiveFile { text in
            let detected = LineEndingDetector.detect(in: text)
            let ending: LineEnding = (detected == .crlf || detected == .cr) ? detected : .lf
            return TextCleanup.ensureFinalNewline(text, using: ending)
        }
    }

    /// TSK-675 — word/character/line counts for the active text file, or nil when
    /// no text file is active (drives the Document Statistics command).
    public var activeDocumentStats: DocumentStats? {
        guard let text = activeFileText else { return nil }
        return DocumentStats.compute(text)
    }

    /// True when the CSV conversions can act — an active `.csv`/`.tsv` text file.
    public var canConvertActiveCSV: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        return ["csv", "tsv"].contains(url.pathExtension.lowercased()) && activeFileText != nil
    }

    /// The active CSV rendered as a Markdown pipe table, or nil when no CSV is active.
    public func activeCSVAsMarkdownTable() -> String? {
        guard canConvertActiveCSV, let text = activeFileText else { return nil }
        let r = CSVParser.parse(text)
        return CsvConvert.toMarkdownTable(header: r.header, rows: r.rows)
    }

    /// The active CSV rendered as a JSON array of objects, or nil when no CSV is active.
    public func activeCSVAsJSON() -> String? {
        guard canConvertActiveCSV, let text = activeFileText else { return nil }
        let r = CSVParser.parse(text)
        return CsvConvert.toJSON(header: r.header, rows: r.rows)
    }

    /// True when "Minify JSON" can act — an active `.json` text file.
    public var canMinifyActiveJSON: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        return url.pathExtension.lowercased() == "json" && activeTextWithEncoding != nil
    }

    /// TSK — compact the active JSON file (whitespace-strip, order + values
    /// preserved). No-op on invalid JSON. Encoding/line-endings preserved.
    @discardableResult
    public func minifyActiveJSON() -> Bool {
        applyTextTransformToActiveFile(Formatter.minifyJSON)
    }

    /// Result of "Check Links": how many links were examined + the broken ones.
    public struct LinkCheckReport: Sendable { public let total: Int; public let broken: [MarkdownLink] }

    /// True when "Check Links" / "Lint Markdown" can act — an active Markdown file.
    public var canCheckLinks: Bool { canExportActiveAsHTML }

    /// Lint the active Markdown for common doc-quality issues (missing image alt,
    /// heading-level skips, duplicate anchors). nil when no Markdown is active.
    public func lintActiveMarkdown() -> [MarkdownLintIssue]? {
        guard canExportActiveAsHTML, let text = activeFileText else { return nil }
        return MarkdownLint.lint(text)
    }

    /// TSK-675 — find broken LOCAL links/images in the active Markdown file
    /// (relative paths resolved against the file's directory; external links and
    /// in-page anchors are not checked). nil when no Markdown file is active.
    public func checkLinksInActiveMarkdown() -> LinkCheckReport? {
        guard let tab = tabs.selected, let url = tab.url,
              ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()),
              let text = activeFileText else { return nil }
        let baseDir = url.deletingLastPathComponent()
        let broken = MarkdownLinks.brokenLocalLinks(in: text) { path in
            let decoded = path.removingPercentEncoding ?? path
            let resolved = baseDir.appendingPathComponent(decoded).standardizedFileURL
            return FileManager.default.fileExists(atPath: resolved.path)
        }
        return LinkCheckReport(total: MarkdownLinks.extract(text).count, broken: broken)
    }

    /// True when "Copy/Export as HTML" can act — an active Markdown text file.
    public var canExportActiveAsHTML: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
        else { return false }
        return activeFileText != nil
    }

    /// Render the active Markdown file to a STANDALONE HTML document (TSK-675) for
    /// Copy/Export as HTML — CSP-free (renders in a browser), embedding the
    /// markdown stylesheet + theme overrides. nil when no Markdown file is active.
    public func htmlExportForActiveMarkdown(inlineImages: Bool = false) -> String? {
        guard let tab = tabs.selected, let url = tab.url,
              ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()),
              let text = activeFileText else { return nil }
        let body = HTMLRenderer().render(text)
        let css = MarkdownStylesheet.load() + "\n" + themedExtraStylesheet
        var html = HtmlExport.standaloneDocument(
            body: body, stylesheet: css, title: url.deletingPathExtension().lastPathComponent)
        if inlineImages {
            // Make a saved file portable: inline local images as data: URIs.
            let baseDir = url.deletingLastPathComponent()
            html = HtmlExport.inlineLocalImages(html) { src in
                let decoded = src.removingPercentEncoding ?? src
                let imgURL = baseDir.appendingPathComponent(decoded).standardizedFileURL
                return try? Data(contentsOf: imgURL)
            }
        }
        return html
    }

    /// Default filename for "Export as HTML" (active file's stem + `.html`).
    public var htmlExportFilename: String {
        guard let url = tabs.selected?.url else { return "export.html" }
        return HtmlExport.htmlFilename(for: url)
    }

    /// Render the active Markdown to a portable (self-contained) temp `.html` and
    /// return its URL, for "Open in Browser". nil when no Markdown is active or
    /// the write fails.
    public func writeActiveMarkdownPreviewHTML() -> URL? {
        guard let url = tabs.selected?.url,
              let html = htmlExportForActiveMarkdown(inlineImages: true) else { return nil }
        let name = BrowserPreview.tempFileName(stem: url.deletingPathExtension().lastPathComponent)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try Data(html.utf8).write(to: dest, options: .atomic) } catch { return nil }
        return dest
    }

    /// True when the Markdown heading-shift commands can act — active Markdown file.
    public var canShiftMarkdownHeadings: Bool { canInsertTableOfContents }

    /// Promote (`delta < 0`, fewer `#`) / demote (`delta > 0`, more `#`) every
    /// ATX heading in the active Markdown file. Encoding + line endings preserved.
    @discardableResult
    public func shiftActiveMarkdownHeadings(by delta: Int) -> Bool {
        applyTextTransformToActiveFile { MarkdownHeadingShift.shift($0, by: delta) }
    }

    /// True when "Insert Table of Contents" can act — an active Markdown text file.
    public var canInsertTableOfContents: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
        else { return false }
        return activeTextWithEncoding != nil
    }

    /// TSK-675 — insert/refresh a Markdown table of contents (from the file's own
    /// headings) wrapped in `<!-- toc -->` markers, so a re-run regenerates in
    /// place. Encoding + line endings preserved via the shared write-through.
    @discardableResult
    public func insertTableOfContents() -> Bool {
        applyTextTransformToActiveFile { text in
            MarkdownTOC.insert(into: text, headings: MarkdownOutline.headings(in: text))
        }
    }

    /// TSK-675 — convert the active file's LEADING indentation between tabs and
    /// spaces, using the editor's configured indent width. Leading whitespace
    /// only (alignment after the first non-space is untouched); line endings +
    /// encoding preserved.
    @discardableResult
    public func convertActiveFileIndentation(toSpaces: Bool) -> Bool {
        let width = editorIndentation.size
        return applyTextTransformToActiveFile { text in
            toSpaces
                ? IndentConverter.tabsToSpaces(text, width: width)
                : IndentConverter.spacesToTabs(text, width: width)
        }
    }

    /// TSK-675 (robust plain-text editing) — normalize the active file's line
    /// endings to `target` (LF/CRLF/CR), preserving its encoding and any unsaved
    /// edits. Write-through then drop+reload (same mechanism as
    /// `convertActiveFileEncoding`). Returns false (no change) when there's no
    /// active text file or the file already uses `target` — the on-disk file is
    /// left untouched in that case.
    @discardableResult
    public func convertActiveFileLineEnding(to target: LineEnding) -> Bool {
        guard let ctx = activeTextWithEncoding else { return false }
        let converted = LineEndingConverter.convert(ctx.text, to: target)
        guard converted != ctx.text else { return false }
        do {
            _ = try EditorWriter.save(converted, to: ctx.url, encoding: ctx.encoding)
        } catch {
            Obs.shared.emit(.warn, "files",
                            "Convert line endings failed: \(String(describing: error))")
            return false
        }
        editor.discardEditorBuffer(forTabID: ctx.tabID)
        reloadCurrentFile()
        return true
    }

    /// The active tab's current text — the editor buffer's live text if editing,
    /// else the loaded-from-disk contents; nil when no text file is active.
    /// Backs the palette's `#` in-file search (TSK-727).
    public var activeFileText: String? {
        guard let tab = tabs.selected else { return nil }
        if let buf = editor.editorBuffers[tab.id] { return buf.text }
        if case .loaded(let f) = tab.state { return f.contents }
        return nil
    }

    /// TSK-352 — re-save the active file's current text (including any unsaved
    /// edits) in `target` encoding, then reload so the app re-detects it.
    /// `EditorBuffer.encoding` is immutable, so we write-through then drop +
    /// reload the buffer (the reload re-seeds it from disk with the new
    /// encoding). Returns false (no change) when there's no active text file or
    /// the text isn't representable in `target` (e.g. emoji → Latin-1) — the
    /// on-disk file is left untouched in that case.
    @discardableResult
    public func convertActiveFileEncoding(to target: String.Encoding) -> Bool {
        guard let ctx = activeTextForEncodingConvert else { return false }
        do {
            _ = try EditorWriter.save(ctx.text, to: ctx.url, encoding: target)
        } catch {
            Obs.shared.emit(.warn, "files",
                            "Convert encoding failed: \(String(describing: error))")
            return false
        }
        editor.discardEditorBuffer(forTabID: ctx.tabID)
        reloadCurrentFile()
        return true
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
                // Coordinator runs the NSAlert + drives the chosen
                // outcome (discard + reload via the `onReloadFromDisk`
                // closure we wired at init, or refresh-fingerprint).
                editor.presentExternalEditConflict(
                    forTabID: tab.id, at: i, url: watchedURL
                )
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

    private func startWatchingCurrentFile() {
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
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
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
        // Coordinator handles the tabs mutation + all six per-tab dict
        // cleanups in lock-step (folded into `cleanupAfterClose`).
        // Returns the closed tab's id so we can also purge non-
        // coordinator caches that key off it (renderedHTML, highlight
        // actor).
        if let id = tabCoordinator.closeTab(at: index) {
            purgeCaches(forURL: closedURL, tabID: id)
        }
        settleSelectionAfterClose()
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
    private func settleSelectionAfterClose() {
        guard let i = tabs.selectedIndex else { return }
        materializeIfNeeded(at: i)
        refreshDiskStateForActiveTab()
    }

    public func closeCurrentTab() {
        if let i = tabs.selectedIndex {
            closeTab(at: i)
        }
    }

    public func closeOtherTabs(keeping index: Int) {
        let keepID = tabs.tabs.indices.contains(index) ? tabs.tabs[index].id : nil
        // Prompt-then-act for every dirty tab that's about to vanish.
        // We process indices in descending order so the user can cancel
        // mid-batch and what's left of the close still makes sense.
        let doomed = tabs.tabs.enumerated()
            .filter { $0.element.id != keepID && $0.element.isDirty }
            .map { $0.offset }
            .sorted(by: >)
        for i in doomed {
            switch confirmCloseIfDirty(at: i) {
            case .none: break
            case .discard: hexDirtyBytes.removeValue(forKey: tabs.tabs[i].id)
            case .save:
                if isHexDirtyTab(at: i) {
                    if !saveHexEdits(forTabID: tabs.tabs[i].id) { return }
                } else if !saveEditor(forTabID: tabs.tabs[i].id) { return }
            case .cancel:
                return
            }
        }
        // Snapshot doomed tabs' URLs *before* the coordinator mutates
        // `tabs`, so the non-coordinator cache purge has the right
        // URLs to pass.
        let doomedURLsByID: [UUID: URL?] = Dictionary(
            uniqueKeysWithValues: tabs.tabs
                .filter { $0.id != keepID }
                .map { ($0.id, $0.url) }
        )
        let closedIDs = tabCoordinator.closeOtherTabs(keeping: index)
        for id in closedIDs {
            purgeCaches(forURL: doomedURLsByID[id] ?? nil, tabID: id)
        }
        settleSelectionAfterClose()
        updateDerived()
        startWatchingCurrentFile()
    }

    public func closeTabsToRight(of index: Int) {
        // Same dirty-prompt loop as closeOtherTabs. Process the
        // doomed tabs from right-to-left so a Cancel partway through
        // leaves a contiguous tail intact (rather than holes).
        // Bounds-check up front: a stale gesture (menu/script verb
        // firing after the tab vanished from another path) can hand
        // us an out-of-range index, and the `(index+1)..<count`
        // range construction below would trap before the coordinator
        // ever runs.
        guard index >= 0, index < tabs.tabs.count else { return }
        let toClose = (index + 1)..<tabs.tabs.count
        let doomedDirty = toClose.reversed().filter { tabs.tabs[$0].isDirty }
        for i in doomedDirty {
            switch confirmCloseIfDirty(at: i) {
            case .none: break
            case .discard: hexDirtyBytes.removeValue(forKey: tabs.tabs[i].id)
            case .save:
                if isHexDirtyTab(at: i) {
                    if !saveHexEdits(forTabID: tabs.tabs[i].id) { return }
                } else if !saveEditor(forTabID: tabs.tabs[i].id) { return }
            case .cancel:
                return
            }
        }
        let doomedURLsByID: [UUID: URL?] = Dictionary(
            uniqueKeysWithValues: tabs.tabs
                .suffix(from: index + 1)
                .map { ($0.id, $0.url) }
        )
        let closedIDs = tabCoordinator.closeTabsToRight(of: index)
        for id in closedIDs {
            purgeCaches(forURL: doomedURLsByID[id] ?? nil, tabID: id)
        }
        settleSelectionAfterClose()
        updateDerived()
        startWatchingCurrentFile()
    }

    /// Drop all cache entries belonging to a closed tab. Highlight
    /// runs live in per-tab `HighlightCacheActor`s (PERF #5);
    /// closing a tab drops the actor entirely — no fan-out to other
    /// tabs because each tab has its own. Rendered-HTML entries are
    /// tabID-keyed (PERF #2 finding); purge unconditionally on tab
    /// close since no other tab can hit the same key. These two
    /// caches stay on DocumentModel (not TabCoordinator) because
    /// they're conceptually subsystems (highlighting, markdown
    /// rendering), and only their *eviction* is tab-id-keyed.
    private func purgeCaches(forURL closedURL: URL?, tabID: UUID? = nil) {
        if let tabID {
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

    public func moveTab(from src: Int, to dst: Int) {
        tabCoordinator.move(from: src, to: dst)
        updateDerived()
    }

    public func moveCurrentTabLeft() {
        guard let i = tabs.selectedIndex else { return }
        tabCoordinator.swapWithPrevious(at: i)
        updateDerived()
    }

    public func moveCurrentTabRight() {
        guard let i = tabs.selectedIndex else { return }
        tabCoordinator.swapWithNext(at: i)
        updateDerived()
    }


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

    /// Append a tab pointing at `url` without loading its contents.
    /// State stays `.empty` until the tab is selected; only then does
    /// `materializeIfNeeded(at:)` actually read the file. Workspace
    /// restore and multi-file drops use this so a 15-file session
    /// doesn't read 15 files at launch — only the focused one.
    public func appendLazyTab(url: URL, viewMode: ViewMode,
                              categoryOverride: FileCategory? = nil,
                              scrollTopLine: Int? = nil,
                              unsavedText: String? = nil) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        // Dedup invariant (matches `TabsState.openOrReveal`): never create a
        // SECOND tab for a file that's already open. `appendLazyTab` was the
        // one open-path that skipped this guard, so workspace restore (and
        // multi-file drop) appended a fresh tab per persisted entry even when
        // an identical path was already present. Combined with `makeSnapshot`
        // re-persisting the live list, that ratcheted an active session up to
        // ~2000 tabs of ~35 unique files and pushed launch footprint to ~1 GB.
        // A no-op here keeps "one tab per file" true regardless of caller.
        let key = TabsState.dedupKey(resolved)
        if tabCoordinator.tabs.tabs.contains(where: {
            $0.url.map(TabsState.dedupKey) == key
        }) {
            return
        }
        // Clamp the requested viewMode to one the URL actually
        // supports. Workspaces persisted before mode-set validation
        // could end up with e.g. `.formatted` saved against a `.md`
        // tab; restoring that as-is would bind a Picker to a value
        // not in its tag list and the ModeBar would show no
        // selection at all. Fall back to the file's defaultMode in
        // that case.
        // With a category override, mode validity is judged against the
        // OVERRIDE category's modes (e.g. a `.db` opened as Source must
        // keep .source), not the URL's extension-derived ones.
        let allowed = ViewModeOptions.availableModes(
            for: resolved, forcedCategory: categoryOverride)
        let safeMode = allowed.contains(viewMode)
            ? viewMode
            : ViewModeOptions.defaultMode(for: resolved, forcedCategory: categoryOverride)
        tabCoordinator.append(Tab(
            url: resolved, state: .empty, viewMode: safeMode,
            categoryOverride: categoryOverride,
            // UX-K (#231): carry the persisted per-file scroll position onto
            // the lazy tab so `restoreScroll` can re-apply it once the tab
            // materializes into focus.
            scrollTopLine: scrollTopLine,
            // TSK-718 hot exit: carry the persisted unsaved buffer text so
            // `materializeIfNeeded` can overlay it into the editor buffer once
            // the file has been read from disk (giving the dirty baseline).
            unsavedText: unsavedText))
    }

    /// Open many URLs at once. Files are appended as lazy tabs (state
    /// = .empty, url set); only the LAST file is read into memory and
    /// gets selection, matching Finder's "drop several files, the last
    /// one wins focus" convention. Folders are routed to `openFolder`
    /// (they set the sidebar root, they are not tabs).
    ///
    /// UDC-5 (2026-05-30): the prior code lazy-appended every non-last
    /// URL unconditionally, then `openPath`'d the last. A dropped FOLDER
    /// anywhere but last became a lazy file tab; selecting it ran
    /// `controller.open` on a directory and produced a broken `.error`
    /// tab. We now partition folders from files up front so folders
    /// never enter the tab list.
    public func openMultiple(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            // A non-existent path is treated as a "file" so the user
            // still sees the standard "File not found" error tab rather
            // than silently vanishing.
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                folders.append(url)
            } else {
                files.append(url)
            }
        }
        // Folders first: each sets/updates the sidebar root. The last
        // folder wins (matches `openPath`/`openFolder` "last root wins").
        for folder in folders {
            openFolder(folder)
        }
        // Files: all but the last lazy, last eager (history-recorded,
        // watcher-bound, focused).
        for url in files.dropLast() {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            let mode = ViewModeOptions.defaultMode(
                for: resolved, preferred: preferences.viewModeDefaults)
            appendLazyTab(url: resolved, viewMode: mode)
        }
        if let lastFile = files.last {
            // `open(url:)` — not `openPath` — since we've already
            // classified this as a non-directory.
            open(url: lastFile)
        }
    }

    /// If the tab at `index` is a lazy placeholder (state == .empty
    /// while url is set), kick a background read and flip state to
    /// `.loading(url)`. The file read happens on a detached Task; on
    /// completion we re-locate the tab by id and swap to the final
    /// state. Idempotent: tabs in any non-.empty state are left alone.
    ///
    /// Why off-main: `controller.open(_:)` reads the entire file
    /// synchronously. For a 32 MB log the read alone is ~50-100 ms on
    /// SSD, plus encoding detection — long enough to drop a frame
    /// when the user clicks a tab. State going to `.loading` makes
    /// the UI show a placeholder (after a small grace period) rather
    /// than appear frozen.
    private func materializeIfNeeded(at index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        let t = tabs.tabs[index]
        guard let url = t.url, case .empty = t.state else { return }
        let tabID = t.id
        // Cancel any in-flight read for this tab id (rapid re-select
        // would otherwise pile up). Cooperative cancellation: we can't
        // interrupt the sync `controller.open(url:)` mid-read, but the
        // completion checks `Task.isCancelled` before hopping to main.
        tabCoordinator.materializeTask(forTabID: tabID)?.cancel()
        var loading = t
        loading.state = .loading(url)
        tabCoordinator.replace(at: index, with: loading)
        let viewMode = t.viewMode
        // WAVE 2b item 6: honor a restored "Open As…" override when the
        // lazy tab finally materializes.
        let override = t.categoryOverride
        let matToken = PerfSignpost.begin(.materialize, "materializeIfNeeded")
        let task = Task.detached(priority: .userInitiated) { [controller] in
            let state = controller.open(url: url, forcedCategory: override)
            PerfSignpost.end(matToken)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Clear our slot regardless of outcome — the Task is
                // done from here on out, even if we drop the result.
                self.tabCoordinator.clearMaterializeTask(forTabID: tabID)
                if Task.isCancelled { return }
                // The tab may have been closed, replaced, or had its
                // state mutated meanwhile. Only swap if the slot we
                // started on is still the same tab + still .loading
                // for the same URL. Otherwise drop the result.
                guard let idx = self.tabs.tabs.firstIndex(where: { $0.id == tabID }) else {
                    return
                }
                let current = self.tabs.tabs[idx]
                guard case .loading(let pendingURL) = current.state, pendingURL == url else {
                    return
                }
                var t2 = current
                t2.state = state
                self.tabCoordinator.replace(at: idx, with: t2)
                // UX-K (#231): the lazy tab's content is now laid out — restore
                // its persisted scroll position. The `selectTab` immediate
                // `restoreScroll` fired before this content existed (the source
                // view had no glyphs to scroll to), so re-fire here for the
                // tab that just materialized into focus. Only when it's still
                // the selected tab (a background materialize must not yank the
                // viewport of whatever the user is now looking at).
                if self.tabs.selectedIndex == idx {
                    self.restoreScroll(forTabAt: idx)
                }
                // TSK-718 hot exit: the file is now read (buffer baseline
                // available) — overlay any persisted unsaved edits so the tab
                // comes back dirty with the user's in-flight content. Runs for
                // background materializes too (each restored tab gets its edits
                // back when it first loads, not only the focused one).
                self.restoreUnsavedTextIfNeeded(forTabAt: idx)
                // LOADBUG (2026-06-01): PERF #1 severed the
                // `tabCoordinator.objectWillChange` → `DocumentModel.
                // objectWillChange` forwarding, so `replace` alone fires the
                // coordinator's publisher but NOT the model's. ContentView /
                // ModeBar observe `DocumentModel`, so without this the
                // just-landed `.loaded`/`.binary`/`.error` state is correct on
                // the model but the realized view never re-bodies — it stays
                // frozen on the `.loading` placeholder ("main.swift cannot be
                // loaded" / blank). Mirror `openLargeFileOffMain`'s completion
                // (which already calls `updateDerived()`); the synchronous open
                // / select / close paths all republish this way too.
                self.updateDerived()
                // Mirror openResolved's HEX-mode carry: if a text file
                // lands with the tab already set to .hex view, kick the
                // binary load. Exclude `.preview` (native-preview
                // categories whose default mode is now `.preview`, Bug B)
                // — hex-loading them would replace the native viewer (e.g.
                // SQLite browser) with a hex dump on a plain lazy
                // materialize. See the matching block in `openResolved`.
                if viewMode == .hex {
                    switch state {
                    case .binary, .empty, .loading, .hostedView, .preview: break
                    case .loaded, .error:
                        self.loadBinaryAsync(url: url, intoTabID: tabID)
                    }
                }
            }
        }
        tabCoordinator.setMaterializeTask(task, forTabID: tabID)
    }

    public func selectNextTab() {
        guard !tabs.isEmpty, let cur = tabs.selectedIndex else { return }
        let next = (cur + 1) % tabs.tabs.count
        selectTab(at: next)
    }

    public func selectPreviousTab() {
        guard !tabs.isEmpty, let cur = tabs.selectedIndex else { return }
        let prev = (cur - 1 + tabs.tabs.count) % tabs.tabs.count
        selectTab(at: prev)
    }

    public func toggleViewMode() {
        // ⇧⌘R / toggle-view is scoped to markdown & mermaid (the only
        // types with a Rendered↔Source pairing). On every other type the
        // live menu greys the item out via validateMenuItem, but the model
        // action is reachable programmatically (--script toggle-view, MCP
        // set_view_mode, walkthrough); make it a true no-op there so a
        // single invoke can't leave the picker showing "Rendered" over a
        // Source pane (SC-MENU-01). `setCurrentViewMode` also rejects an
        // unavailable `.rendered`; this guard additionally avoids a no-op
        // republish.
        guard supportsViewModeToggle else { return }
        let new: ViewMode = currentViewMode == .rendered ? .source : .rendered
        setCurrentViewMode(new)
    }

    public func setCurrentViewMode(_ mode: ViewMode) {
        guard let i = tabs.selectedIndex, tabs.tabs.indices.contains(i) else { return }
        var t = tabs.tabs[i]
        // Reject `.rendered` on a TEXT tab that doesn't offer it.
        // `.rendered` is markdown/mermaid/html-only (see ViewModeOptions);
        // flipping it onto a plainText / source / JSON tab leaves the
        // picker selecting "Rendered" while the state-driven content pane
        // keeps drawing the Source NSTextView — a picker↔pane desync
        // (SC-MENU-01: toggle-view / ⇧⌘R, MCP set_view_mode, and any
        // programmatic caller route through here unguarded; the live menu
        // greys ⇧⌘R via validateMenuItem, but the model action itself was
        // not guarded). Scoped to `.rendered` on text categories rather
        // than a blanket availableModes gate on purpose: the
        // `.source`/`.rendered` arm below intentionally maps `.rendered`
        // onto MEDIA tabs (image/audio/video/pdf/sqlite — picker shows
        // only [.preview, .hex]) to RESTORE `.preview` when leaving HEX,
        // a documented round-trip a blanket gate would break.
        if mode == .rendered, let url = t.url {
            let cat = t.categoryOverride ?? FileTypeDetector.category(for: url)
            switch cat {
            case .markdown, .mermaid, .plainText, .code, .html:
                // Text-representation category: trust availableModes.
                if !ViewModeOptions.availableModes(
                    for: url, forcedCategory: t.categoryOverride
                ).contains(.rendered) { return }
            case .image, .audio, .video, .pdf, .sqlite, .archive, .binary, .unknown:
                // Media / binary: `.rendered` is the leave-HEX escape
                // hatch handled below — leave it to the preview-restore arm.
                break
            }
        }
        // Side effects per mode:
        //   - .hex: state-swap is async (binary load can be slow on big
        //     files; main-thread blocking → beachball). View mode is
        //     set immediately so the picker reflects the user's pick.
        //   - .formatted: pretty-print is computed lazily by
        //     displayText(for:); just flip the flag.
        //   - .source / .rendered: clear formatted flag. Reverse from
        //     HEX (also async).
        switch mode {
        case .hex:
            // HEX is available for any file with bytes — text, image,
            // PDF, midi, anything. Trigger the binary load whenever
            // current state isn't already binary; loadBinaryAsync is
            // a no-op for an already-binary tab and re-reads cheaply
            // otherwise.
            if let url = t.url {
                switch t.state {
                case .binary, .empty, .loading, .hostedView: break
                case .loaded, .preview, .error:
                    loadBinaryAsync(url: url, intoTabID: t.id)
                }
            }
        case .formatted:
            if let url = t.url, Formatter.SupportedFormat.detect(url) != nil {
                tabCoordinator.setFormatted(true, forTabID: t.id)
            }
        case .preview:
            // Native-preview lens (image/audio/video/pdf/sqlite). The
            // content pane is state-driven: `.preview` state renders
            // MediaPreviewView. Coming back from HEX (state `.binary`) we
            // must restore the `.preview` state, mirroring the media-restore
            // arm in `.source/.rendered/...` below. For a fresh open the tab
            // is already in `.preview` state, so this is a no-op there.
            tabCoordinator.setFormatted(false, forTabID: t.id)
            if let url = t.url, case .binary = t.state {
                let state = controller.open(url: url)
                t.state = state
            }
        case .source, .rendered, .table, .diff:
            tabCoordinator.setFormatted(false, forTabID: t.id)
            if let url = t.url, case .binary = t.state {
                // Coming back from HEX. If the file is a media type
                // (image / audio / video / pdf / sqlite) it has no text
                // representation — `loadTextAsync` would silently fail
                // and the tab would stay in `.binary` state, so the
                // content area would keep showing HexView even though
                // the picker now says Source/Rendered. Restore the
                // native `.preview` state instead. For real text files
                // we still fall through to the async text reload.
                let cat = FileTypeDetector.category(for: url)
                switch cat {
                case .image, .audio, .video, .pdf, .sqlite, .archive:
                    let state = controller.open(url: url)
                    t.state = state
                case .markdown, .mermaid, .plainText, .code, .html:
                    loadTextAsync(url: url, intoTabID: t.id)
                case .binary, .unknown:
                    // bug3: binary / unknown files have no Source/Rendered/
                    // Table/Diff mode (see ViewModeOptions.availableModes), so
                    // this arm is no longer reachable via the picker. Keep the
                    // tab in `.binary` (HexView) rather than kicking a
                    // `loadTextAsync` the loader already rejected as binary —
                    // that re-read silently failed and left the picker and the
                    // content view disagreeing. No-op.
                    break
                }
            }
        case .editor:
            // Activation gate: refuse the editor upgrade for files past
            // the CM6 cap (50 MB). `ContentView` already renders the
            // LargeEditorPlaceholderView so no 60 MB JS string reaches a
            // WebContent process — but without refusing here the mode
            // itself flips to `.editor`, which is both wrong (the picker
            // lies) and the contract EditorPhase4ScenarioTests pins. Keep
            // the tab on its current mode instead.
            if case .loaded(let file) = t.state,
               file.byteCount > codeMirrorEditorMaxBytes {
                return
            }
            // Editor needs the text contents in memory. If the tab
            // currently holds a binary view, kick a text re-load so
            // the buffer has something to bind to; the buffer itself
            // is created lazily by `editorBuffer(forTabID:)` once
            // the file lands as `.loaded`.
            tabCoordinator.setFormatted(false, forTabID: t.id)
            if let url = t.url, case .binary = t.state {
                loadTextAsync(url: url, intoTabID: t.id)
            }
            // Seed an EditorBuffer eagerly when the file is already
            // loaded so the view's first frame has real text rather
            // than an empty placeholder.
            if case .loaded(let file) = t.state {
                tabCoordinator.ensureEditorBuffer(for: file, tabID: t.id)
            }
        }
        t.viewMode = mode
        tabCoordinator.replace(at: i, with: t)
        // Republish DocumentModel so the picker + content re-evaluate.
        // View mode lives on `TabCoordinator`, but `ContentView` /
        // `ModeBar` observe `DocumentModel` — PERF #1 severed the
        // child→model `objectWillChange` forwarding and re-added direct
        // `@ObservedObject` only for `sidebar` + `find`, NOT `tabs`.
        // Every other display-changing tab mutation (open / close /
        // select) republishes through `updateDerived()`; this was the
        // lone gap, which left the Render|Source|Editor|HEX picker and
        // the content pane stuck on the previous mode. `updateDerived`'s
        // unconditional `windowTitle` assignment fires the publisher.
        updateDerived()
    }

    /// Off-main file read, on-main state swap. Keeps the UI
    /// responsive for multi-MB files. We re-locate the tab by id at
    /// completion time so a meanwhile-closed tab is a no-op rather
    /// than crashing.
    ///
    /// CORR-5 (2026-05-30): after the async hop we also re-validate
    /// that the relocated tab's URL still equals `url` before mutating
    /// — a meanwhile-completed re-open / reload could have repointed
    /// the same tab id at a different file, and writing this stale read
    /// into it would show the wrong contents. Mirrors the guard in
    /// `materializeIfNeeded`'s completion.
    ///
    /// CR-04 (2026-05-30): a read failure no longer silently no-ops
    /// (leaving the prior, now-stale view). It routes through
    /// `controller.open(url:)` to reuse the standard error mapping so
    /// the tab flips to an `.error` placeholder.
    private func loadBinaryAsync(url: URL, intoTabID id: UUID) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = try? BinaryFileLoader().load(url: url)
            await MainActor.run { [weak self] in
                guard let self,
                      let idx = self.tabs.tabs.firstIndex(where: { $0.id == id }),
                      self.tabs.tabs[idx].url == url
                else { return }
                // Bug C (latest-switch-wins): `setCurrentViewMode` flips
                // `viewMode` synchronously but kicks THIS load async +
                // unguarded. A rapid HEX→Source toggle supersedes the HEX
                // request before this lands; writing `.binary` now would
                // leave HexView showing under a non-HEX picker (the
                // "mode switcher acts weird" desync, and — with a real
                // read landing into a re-materialized `.loading` slot —
                // the dropped-completion endless spinner). Only commit the
                // binary view if the tab is STILL in `.hex`; otherwise the
                // user has moved on and the corresponding text-mode load
                // owns the state.
                guard self.tabs.tabs[idx].viewMode == .hex else { return }
                var tab = self.tabs.tabs[idx]
                if let bin = loaded {
                    tab.state = .binary(bin)
                } else {
                    // CR-04: surface the failure rather than leaving the
                    // prior (stale) state. `controller.open` maps the
                    // read error to a user-facing `.error` message.
                    tab.state = self.controller.open(url: url)
                }
                self.tabCoordinator.replace(at: idx, with: tab)
                // LOADBUG: republish the model so ContentView re-bodies onto
                // the freshly-landed `.binary` state. Without it the picker
                // (synchronously flipped by setCurrentViewMode) says HEX while
                // the content pane stays on the previous mode's view — and the
                // later "Editor" pick then re-bodies on the still-`.binary`
                // state and shows HexView. See the matching note at the
                // materializeIfNeeded completion.
                self.updateDerived()
            }
        }
    }

    private func loadTextAsync(url: URL, intoTabID id: UUID) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = try? TextFileLoader().load(url: url)
            await MainActor.run { [weak self] in
                guard let self,
                      let idx = self.tabs.tabs.firstIndex(where: { $0.id == id }),
                      self.tabs.tabs[idx].url == url
                else { return }
                // Bug C (latest-switch-wins): symmetric to loadBinaryAsync.
                // This load was kicked for a text-shaped mode (coming back
                // from HEX, or to seed `.editor`). If the user has since
                // switched the tab BACK to `.hex`, committing `.loaded`
                // now would drop them out of the byte grid they re-picked.
                // Drop the superseded load.
                guard self.tabs.tabs[idx].viewMode != .hex else { return }
                var tab = self.tabs.tabs[idx]
                if let text = loaded {
                    tab.state = .loaded(text)
                } else {
                    // CR-04: route the read failure through the standard
                    // error mapping so the tab shows an error placeholder
                    // instead of silently keeping stale content.
                    tab.state = self.controller.open(url: url)
                }
                self.tabCoordinator.replace(at: idx, with: tab)
                // LOADBUG: republish so ContentView re-bodies onto the
                // freshly-landed `.loaded` text state (e.g. coming back from
                // HEX to Source/Editor). Symmetric to loadBinaryAsync above.
                self.updateDerived()
            }
        }
    }

    // MARK: Recents

    public func clearRecents() {
        history.clear()
        recents = []
    }

    // MARK: Internal

    private func updateDerived() {
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
