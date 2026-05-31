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
    @Published public private(set) var recents: [HistoryEntry] = []
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

    /// Source-view word-wrap toggle. When true, lines wrap at the
    /// viewport edge; when false (default), long lines scroll
    /// horizontally — the conventional code-viewer behavior. Persisted
    /// to UserDefaults via PreferencesStore.
    @Published public var sourceWordWrap: Bool {
        didSet { preferences.sourceWordWrap = sourceWordWrap }
    }
    public func toggleSourceWordWrap() { sourceWordWrap.toggle() }

    /// When on, NSLayoutManager renders dots for spaces, arrows for
    /// tabs, pilcrows for paragraph breaks. Persisted.
    @Published public var showInvisibleChars: Bool {
        didSet { preferences.showInvisibleChars = showInvisibleChars }
    }
    public func toggleShowInvisibleChars() { showInvisibleChars.toggle() }

    /// Helper for view code: scale a base font size by the unified
    /// zoom factor. Used by sidebar / tabs / status bar / mode bar so
    /// chrome grows with the same Cmd++/Cmd+− / Settings slider that
    /// drives document content. Historically backed by a separate
    /// `uiScale` preference; collapsed onto `zoom` so users no longer
    /// have to keep two sliders in sync. Migration of legacy
    /// `uiScale` defaults is handled in `PreferencesStore.zoom`.
    public func uiSize(_ base: CGFloat) -> CGFloat { base * CGFloat(zoom) }

    /// Latest scroll state from the source view, published by
    /// `TextDisplayView.onScrollChange`. Drives the SwiftUI gutter
    /// rendering (`SourceGutterView`). Seeded with empty values so
    /// the gutter has something to render at first paint before
    /// `viewDidLoad` fires.
    @Published public var sourceScrollState: SourceScrollState = SourceScrollState(
        offsetY: 0, viewportHeight: 0, lineHeight: 16, lineCount: 0, topInset: 10
    )
    /// Caret position published by TextDisplayView. Status bar reads
    /// this to render "Ln 12, Col 4". Reset to .zero on tab switch.
    @Published public var sourceSelection: SourceSelection = .zero
    @Published public var isPalettePresented: Bool = false
    /// "Go to file / folder" (Finder-style ⇧⌘G) prompt visibility.
    /// Owned here (not at ContentView level) so the menu item + script
    /// runner can toggle it without prop-drilling. See `GoToPathPrompt`.
    @Published public var isGoToPathPresented: Bool = false
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

    private let controller: DocumentController
    public let history: HistoryStore
    /// Persisted history for the Go-to-path prompt. Small (cap 10),
    /// separate from `history` so typing into the prompt doesn't churn
    /// the global recents list.
    public let goToPathHistory: GoToPathHistoryStore
    public let bookmarksStore: BookmarksStore
    private let preferences: PreferencesStore
    private var fileWatcher: FileWatcher?
    private var watchedURL: URL?

    /// Shared LSP pool — one server per `(language, workspaceRoot)`.
    /// Lazy: the actor is cheap to allocate; servers spawn on first
    /// request and reap when idle. Public so the sidebar's outline
    /// section + the diagnostics panel can talk to the same pool.
    public let lspPool: LSPPool = LSPPool()

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
        sidebar: SidebarModel = SidebarModel(),
        preferences: PreferencesStore = PreferencesStore()
    ) {
        self.controller = controller
        self.history = history
        self.goToPathHistory = goToPathHistory
        self.bookmarksStore = bookmarks
        self.sidebar = sidebar
        self.preferences = preferences
        // Shoulder-rail layout shares the SAME defaults instance the
        // injected PreferencesStore uses (tests inject a throwaway
        // suite; production uses .standard). Loaded from the two
        // comma-joined keys (panelEdges / panelOverrides) — empty on a
        // fresh install ⇒ all panels on .left, all overrides .auto ⇒
        // visibility === data-presence, today's behavior unchanged.
        self.panelLayout = PanelLayoutStore(defaults: preferences.defaults)
        self.recents = history.recent()
        self.bookmarks = bookmarks.all()
        self.sidebarWidth = preferences.sidebarWidth
        self.zoom = preferences.zoom
        self.sourceWordWrap = preferences.sourceWordWrap
        self.showInvisibleChars = preferences.showInvisibleChars
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

    public func showGoToPath() {
        isGoToPathPresented = true
        // Clear stale error state from a previous attempt so the dump
        // reflects only the current invocation.
        lastGoToError = ""
    }
    public func dismissGoToPath() {
        isGoToPathPresented = false
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
            if newSession,
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
    public func refreshDiffMarks() {
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
            let marks = DiffHunkParser.parse(diff)
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
            let marks = DiffHunkParser.parse(diff)
            let cmMarkers = DiffGutterFeeder.markers(from: marks)
            await MainActor.run { [weak self] in
                guard let self, self.tabCoordinator.splitURL == token else { return }
                self.editor.setEditorGutterMarkers(cmMarkers, forURL: token)
            }
        }
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
            crossSearchGeneration &+= 1  // cancel any in-flight search
            return
        }
        var opts = CrossFileSearch.Options()
        opts.caseSensitive = crossSearchCaseSensitive
        crossSearchIsRunning = true
        crossSearchGeneration &+= 1
        let gen = crossSearchGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self, opts, q] in
            let results = CrossFileSearch.search(root: root, query: q, options: opts)
            DispatchQueue.main.async {
                guard let self, self.crossSearchGeneration == gen else { return }
                self.crossSearchResults = results
                self.crossSearchIsRunning = false
            }
        }
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

    /// Scroll the active source view to this 1-based line number on
    /// the next render. The controller debounces by comparing to its
    /// last-applied target. Pair with a bumped `sourceScrollLineNonce`
    /// so re-requesting the same line still fires.
    @Published public var sourceScrollLineTarget: Int? = nil
    @Published public var sourceScrollLineNonce: Int = 0
    public func scrollSource(toLine line: Int) {
        sourceScrollLineTarget = line
        sourceScrollLineNonce &+= 1
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

    public func showEditorFindBar() { find.showEditorBar() }
    public func dismissEditorFindBar() { find.dismissEditorBar() }
    public func editorFindNext() { find.editorNext() }
    public func editorFindPrev() { find.editorPrev() }
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

    /// JS posted a Cmd-click. Resolve via LSP `definition`; on a
    /// single result, open the target tab + jump to the line. Multi-
    /// result is single-pick for now (first result) — matches the
    /// source-view's "go to first" default until the picker UI lands.
    public func handleEditorDefinition(
        tabID: UUID, fileURL: URL, request: CMPositionRequest
    ) {
        _ = effectiveLanguage(forTabID: tabID, url: fileURL)
        guard LSPLanguageRegistry.default.language(for: fileURL) != nil else { return }
        let lspLine = max(0, request.line - 1)
        let lspChar = max(0, request.character)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let locs = try await self.lspPool.definition(
                    fileURL: fileURL, line: lspLine, character: lspChar)
                guard let first = locs.first else { return }
                let targetLine = first.range.start.line + 1 // back to 1-based
                guard let targetURL = URL(string: first.uri) else { return }
                await MainActor.run {
                    self.openPath(targetURL, atLine: targetLine)
                }
            } catch {
                // Definition lookup failures are silent — there's no
                // UI surface for "LSP returned nothing"; users notice
                // by absence of navigation. Logged at trace level.
            }
        }
    }

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
            if let url = currentURL { repoFocus.refreshRepo(enclosing: url) }
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
            }
        }
        return ok
    }

    /// Forwarder. New code should call `editor.discardEditorBuffer(...)`.
    public func discardEditorBuffer(forTabID id: UUID) {
        editor.discardEditorBuffer(forTabID: id)
    }

    /// Forwarder. New code should call `editor.confirmCloseIfDirty(at:)`.
    public func confirmCloseIfDirty(at index: Int) -> DirtyClosePrompt? {
        editor.confirmCloseIfDirty(at: index)
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
    /// re-publishes when the user flips Light/Dark. Override field is
    /// for a future "Settings → Appearance" picker.
    @Published public var themeOverride: SyntaxTheme.Name? = nil
    public var activeTheme: SyntaxTheme {
        if let o = themeOverride { return SyntaxTheme.named(o) }
        return SyntaxTheme.resolved(forAppearance: NSApp?.effectiveAppearance)
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
    // Each entry is a 2-5× inflation of source size (code-fence
    // highlighting). Four covers the typical "couple of open MDs"
    // working set and caps the worst-case RAM footprint of this
    // cache around 15-20 MB. Cold-render on a miss is fast.
    private static let renderedHTMLCacheMax = 4

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
            extraStylesheet: MermaidBundle.shimCSS
        )
        if renderedHTMLCache[key] == nil {
            renderedHTMLCacheOrder.append(key)
        }
        renderedHTMLCache[key] = html
        if renderedHTMLCache.count > Self.renderedHTMLCacheMax {
            // S2-G: evict by insertion order, oldest first. Drop down
            // to ~2/3 of the cap so we don't churn on every insert.
            let dropCount = renderedHTMLCache.count - Self.renderedHTMLCacheMax * 2 / 3
            let toDrop = renderedHTMLCacheOrder.prefix(dropCount)
            for k in toDrop {
                renderedHTMLCache.removeValue(forKey: k)
            }
            renderedHTMLCacheOrder.removeFirst(toDrop.count)
        }
        return html
    }

    // MARK: Derived from current tab

    public var currentState: DocumentState { tabs.selected?.state ?? .empty }
    public var currentURL: URL? { tabs.selected?.url }
    public var currentViewMode: ViewMode { tabs.selected?.viewMode ?? .rendered }

    public var supportsViewModeToggle: Bool {
        guard let url = currentURL else { return false }
        let cat = FileTypeDetector.category(for: url)
        return cat == .markdown || cat == .mermaid
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

    // MARK: Opening files

    /// Opens a URL into the current tab if it's blank, switches to an existing
    /// tab that shows the URL, or appends a new tab.
    public func open(url: URL) {
        openResolved(url, forceNewTab: false)
    }

    /// Always opens a new tab — does NOT reuse an existing tab that shows
    /// the same URL or a blank tab. Used by "Open in New Tab" context menu.
    public func openInNewTab(_ url: URL) {
        openResolved(url, forceNewTab: true)
    }

    private func openResolved(_ url: URL, forceNewTab: Bool) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        // Pick the per-extension default mode: .table for CSV/TSV,
        // .rendered for markdown, .source for everything else. The
        // "carry current mode" branch below overrides for the common
        // "user is in HEX, opens another file" workflow.
        let initialMode = ViewModeOptions.defaultMode(for: resolved)
        let carryMode: ViewMode = {
            if forceNewTab { return initialMode }
            // If the active tab has a non-default mode the user
            // explicitly picked (e.g. HEX, Format), carry it. Otherwise
            // use the new file's natural default.
            if let cur = tabs.selected, cur.viewMode != .rendered, cur.viewMode != .source {
                return cur.viewMode
            }
            return initialMode
        }()

        // Off-main eager open for large text files. `controller.open`
        // reads + decodes the entire file synchronously; for a few-
        // hundred-MB log that is a multi-hundred-ms main-thread stall
        // (beachball on open). We stat first (cheap, no read) and, when
        // the file is above the loader's soft watermark AND would take
        // the text-load path (not a native preview / media URL handled
        // without a read), open the tab in `.loading(URL)` and read off-
        // main — reusing the exact `materializeIfNeeded` identity-guard
        // pattern (Task.isCancelled + re-find-by-id) so a slow read
        // never lands in the wrong or closed tab.
        if shouldDeferOpenOffMain(resolved) {
            openLargeFileOffMain(resolved, forceNewTab: forceNewTab, viewMode: carryMode)
            return
        }

        let state = controller.open(url: resolved)
        if forceNewTab {
            tabCoordinator.append(Tab(url: resolved, state: state, viewMode: initialMode))
        } else {
            tabCoordinator.openOrReveal(url: resolved, state: state, viewMode: carryMode)
        }
        // Carry HEX mode across file switch: if the active tab now
        // shows a different file in HEX, but the underlying state is
        // text or preview, kick the binary load so the picker doesn't
        // lie about what's on screen.
        if let t = tabs.selected, t.viewMode == .hex {
            switch t.state {
            case .binary, .empty, .loading: break
            case .loaded, .preview, .error:
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

    /// True when `openResolved` should route the file read off the main
    /// thread instead of slurping it synchronously. Gated on (a) the
    /// file being above the loader's soft watermark and (b) it NOT being
    /// a native-preview category (image/audio/video/pdf/sqlite) — those
    /// never read bytes into Swift memory, so the sync path is already
    /// cheap and routing them through `.loading` would just add a flash.
    private func shouldDeferOpenOffMain(_ resolved: URL) -> Bool {
        switch FileTypeDetector.category(for: resolved) {
        case .image, .audio, .video, .pdf, .sqlite:
            return false
        default:
            break
        }
        guard let bytes = (try? FileManager.default
            .attributesOfItem(atPath: resolved.path)[.size]) as? Int
        else { return false }
        return bytes > controller.loader.softWarnBytes
    }

    /// Open a large text file off the main thread. Mirrors
    /// `materializeIfNeeded`: place the tab in `.loading(url)`, read on a
    /// detached Task, then re-find the tab by id and swap to the final
    /// state only if it is still `.loading` for the same URL. Post-open
    /// bookkeeping (history / recents / sidebar root / watcher) runs on
    /// completion via `recordOpenedFile`, matching the sync path.
    private func openLargeFileOffMain(_ resolved: URL, forceNewTab: Bool, viewMode: ViewMode) {
        let loading: DocumentState = .loading(resolved)
        let tabID: UUID
        if forceNewTab {
            let tab = Tab(url: resolved, state: loading, viewMode: viewMode)
            tabCoordinator.append(tab)
            tabID = tab.id
        } else {
            let idx = tabCoordinator.openOrReveal(
                url: resolved, state: loading, viewMode: viewMode
            )
            tabID = tabs.tabs.indices.contains(idx) ? tabs.tabs[idx].id : UUID()
        }
        updateDerived()
        // Watch immediately — the tab + URL are known now; we don't need
        // the contents to bind the file watcher, and waiting for the read
        // would miss edits during a multi-hundred-ms load.
        startWatchingCurrentFile()

        tabCoordinator.materializeTask(forTabID: tabID)?.cancel()
        let task = Task.detached(priority: .userInitiated) { [controller] in
            let state = controller.open(url: resolved)
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
                // Carry HEX mode (mirrors the sync path).
                if t.viewMode == .hex {
                    switch state {
                    case .binary, .empty, .loading: break
                    case .loaded, .preview, .error:
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
        case .empty, .error, .loading:
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
        let state = controller.open(url: url)
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
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        // CRIT-4: capture the URL the watcher is bound to so the handler
        // can verify the user is still viewing it before reloading.
        let boundURL = url
        fileWatcher = try? FileWatcher(url: url, queue: .main) { [weak self] in
            Task { @MainActor in
                self?.reloadCurrentFile(matching: boundURL)
            }
        }
    }

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
        case .none, .discard:
            break
        case .save:
            if !saveEditor(forTabID: tabs.tabs[index].id) { return }
        case .cancel:
            return
        }
        guard tabs.tabs.indices.contains(index) else { return }
        let closedURL = tabs.tabs[index].url
        // Coordinator handles the tabs mutation + all six per-tab dict
        // cleanups in lock-step (folded into `cleanupAfterClose`).
        // Returns the closed tab's id so we can also purge non-
        // coordinator caches that key off it (renderedHTML, highlight
        // actor).
        if let id = tabCoordinator.closeTab(at: index) {
            purgeCaches(forURL: closedURL, tabID: id)
        }
        updateDerived()
        startWatchingCurrentFile()
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
            case .none, .discard: break
            case .save:
                if !saveEditor(forTabID: tabs.tabs[i].id) { return }
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
            case .none, .discard: break
            case .save:
                if !saveEditor(forTabID: tabs.tabs[i].id) { return }
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
    private func purgeCaches(forURL _: URL?, tabID: UUID? = nil) {
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
        tabCoordinator.select(at: index)
        materializeIfNeeded(at: index)
        updateDerived()
        startWatchingCurrentFile()
        // 0d: refresh the staleness signal for the now-active tab (background
        // tabs aren't watched, so a switch is when we re-stat). Signal only —
        // no reload.
        refreshDiskStateForActiveTab()
        // item9: if "pin"/follow is on, reveal the now-active file in the
        // sidebar (select + expand only, never re-root).
        followActiveTabIfNeeded()
    }

    /// Append a tab pointing at `url` without loading its contents.
    /// State stays `.empty` until the tab is selected; only then does
    /// `materializeIfNeeded(at:)` actually read the file. Workspace
    /// restore and multi-file drops use this so a 15-file session
    /// doesn't read 15 files at launch — only the focused one.
    public func appendLazyTab(url: URL, viewMode: ViewMode) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        // Clamp the requested viewMode to one the URL actually
        // supports. Workspaces persisted before mode-set validation
        // could end up with e.g. `.formatted` saved against a `.md`
        // tab; restoring that as-is would bind a Picker to a value
        // not in its tag list and the ModeBar would show no
        // selection at all. Fall back to the file's defaultMode in
        // that case.
        let allowed = ViewModeOptions.availableModes(for: resolved)
        let safeMode = allowed.contains(viewMode)
            ? viewMode
            : ViewModeOptions.defaultMode(for: resolved)
        tabCoordinator.append(Tab(url: resolved, state: .empty, viewMode: safeMode))
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
            let mode = ViewModeOptions.defaultMode(for: resolved)
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
        let task = Task.detached(priority: .userInitiated) { [controller] in
            let state = controller.open(url: url)
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
                // Mirror openResolved's HEX-mode carry: if a binary file
                // lands with the tab already set to .hex view, kick the
                // binary load.
                if viewMode == .hex {
                    switch state {
                    case .binary, .empty, .loading: break
                    case .loaded, .preview, .error:
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
        let new: ViewMode = currentViewMode == .rendered ? .source : .rendered
        setCurrentViewMode(new)
    }

    public func setCurrentViewMode(_ mode: ViewMode) {
        guard let i = tabs.selectedIndex, tabs.tabs.indices.contains(i) else { return }
        var t = tabs.tabs[i]
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
                case .binary, .empty, .loading: break
                case .loaded, .preview, .error:
                    loadBinaryAsync(url: url, intoTabID: t.id)
                }
            }
        case .formatted:
            if let url = t.url, Formatter.SupportedFormat.detect(url) != nil {
                tabCoordinator.setFormatted(true, forTabID: t.id)
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
                case .image, .audio, .video, .pdf, .sqlite:
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
        // Sibling to refreshDiffMarks: keep the multi-repo registry's
        // demand set in sync with the open-tab/selection state. The
        // tabCoordinator/sidebar Combine sinks in RepoFocusTracker cover
        // generic mutations, but this synchronous call makes the
        // open/save/reload paths deterministic (no debounce window).
        // Idempotent + equality-guarded — a no-op when demand is
        // unchanged.
        repoFocus.recompute()
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
