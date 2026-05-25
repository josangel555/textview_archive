import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

/// Top-level app state. Owns the open tabs, file history, and bridging to
/// the pure-logic `DocumentController`. Lives on the main actor.
@MainActor
public final class DocumentModel: ObservableObject {
    @Published public private(set) var tabs: TabsState = .init()
    /// O(1)-contains set of URLs currently open in any tab. Maintained
    /// by `updateDerived()` after every tabs mutation. Sidebar uses
    /// this to render "open elsewhere" indicators without scanning
    /// `tabs.tabs` per row.
    @Published public private(set) var openTabURLs: Set<URL> = []

    /// Per-tab CSV filter state. Persists across tab switches so the
    /// user doesn't lose their filter when navigating away and back.
    /// Keyed by tab id; pruned in the close paths next to the other
    /// tab-id-keyed caches.
    @Published public private(set) var csvFilterStates: [UUID: CSVFilterState] = [:]

    /// In-flight materialization Tasks keyed by tab id. Tracked so:
    /// (a) rapid re-select of the same lazy tab cancels the previous
    /// read before starting a new one, and (b) tab close / closeOthers
    /// /closeToRight cancels the read for the doomed tab so we don't
    /// waste I/O finishing a load whose result is going to be dropped.
    private var materializeTasks: [UUID: Task<Void, Never>] = [:]

    public func csvFilterState(forTabID id: UUID) -> CSVFilterState {
        csvFilterStates[id] ?? CSVFilterState()
    }

    public func setCsvFilterState(_ state: CSVFilterState, forTabID id: UUID) {
        if csvFilterStates[id] != state { csvFilterStates[id] = state }
    }

    public func clearCsvFilterState(forTabID id: UUID) {
        csvFilterStates.removeValue(forKey: id)
    }

    /// Per-tab HEX viewer bytes-per-row. Falls back to the global
    /// default in PreferencesStore (`hexBytesPerRow`). Pruned in the
    /// tab-close paths alongside other tab-id-keyed maps. Not
    /// persisted across app relaunches — intentional: globally
    /// changing the default is the durable knob; per-tab is a
    /// session-scoped override.
    @Published public private(set) var hexBytesPerRow: [UUID: Int] = [:]

    public func hexWidth(forTabID id: UUID) -> Int {
        if let w = hexBytesPerRow[id] { return HexLayout.clampWidth(w) }
        return HexLayout.clampWidth(preferences.hexBytesPerRow)
    }

    public func setHexWidth(_ width: Int, forTabID id: UUID) {
        let clamped = HexLayout.clampWidth(width)
        if hexBytesPerRow[id] != clamped { hexBytesPerRow[id] = clamped }
        // Also bump the global default so the next opened binary
        // remembers what the user picked. Cheap; matches Sublime
        // "remember last setting" feel.
        if preferences.hexBytesPerRow != clamped {
            preferences.hexBytesPerRow = clamped
        }
    }

    public struct CSVFilterState: Equatable, Sendable {
        public var globalQuery: String = ""
        public var globalScope: Int? = nil
        public var perColumn: [Int: String] = [:]
        public var advancedShown: Bool = false

        public init(globalQuery: String = "", globalScope: Int? = nil,
                    perColumn: [Int: String] = [:], advancedShown: Bool = false) {
            self.globalQuery = globalQuery
            self.globalScope = globalScope
            self.perColumn = perColumn
            self.advancedShown = advancedShown
        }
    }
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
        self.recents = history.recent()
        self.bookmarks = bookmarks.all()
        self.sidebarWidth = preferences.sidebarWidth
        self.zoom = preferences.zoom
        self.sourceWordWrap = preferences.sourceWordWrap
        self.showInvisibleChars = preferences.showInvisibleChars
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

        // Forward sidebar's @Published changes up so views observing
        // DocumentModel (e.g. ContentView) re-render when the user
        // toggles visibility, expands a folder, etc. Without this,
        // child-ObservableObject changes are invisible to the parent
        // observer — classic SwiftUI footgun.
        self.sidebar.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
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

    /// Recompute `sourceDiffMarks` by shelling out to `git diff` for
    /// the current file. Off-main; main-actor publish at the end.
    /// Cancels any prior in-flight task before launching the new one
    /// so a flurry of `updateDerived()` calls (e.g. opening 50 files
    /// via "Open Recent") doesn't pile up 50 git processes.
    public func refreshDiffMarks() {
        diffMarksTask?.cancel()
        guard let url = currentURL,
              let repoRoot = GitClient.discoverRoot(from: url)
        else {
            if !sourceDiffMarks.isEmpty { sourceDiffMarks = [:] }
            diffMarksTask = nil
            return
        }
        let relPath: String = {
            let rootPath = repoRoot.standardizedFileURL.resolvingSymlinksInPath().path
            let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
            if filePath.hasPrefix(rootPath + "/") {
                return String(filePath.dropFirst(rootPath.count + 1))
            }
            return filePath
        }()
        let token = url
        diffMarksTask = Task.detached(priority: .userInitiated) { [weak self] in
            // 150 ms debounce: if the user is rapidly switching tabs,
            // we'll get cancelled before the git invocation even starts.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let client = GitClient(repoRoot: repoRoot)
            let diff = client.diff(forPath: relPath)
            if Task.isCancelled { return }
            let marks = DiffHunkParser.parse(diff)
            await MainActor.run { [weak self] in
                guard let self, self.currentURL == token else { return }
                self.sourceDiffMarks = marks
            }
        }
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

    // MARK: Find bar (rendered mode)

    /// Whether the rendered-view find bar is showing. The source-view's
    /// find bar is owned by NSTextView (via `performFindPanelAction:`)
    /// and is not tracked here.
    @Published public var isRenderedFindBarPresented: Bool = false

    /// Current query string in the rendered-view find bar. The
    /// MarkdownRenderedView Coordinator observes this and calls
    /// `WKWebView.find(_:configuration:)` as it changes.
    @Published public var renderedFindQuery: String = ""

    /// Bumped when the user clicks "Next" or "Previous" in the find bar.
    /// The Coordinator observes the counter, runs find with the
    /// `backwards` flag set appropriately, then ignores the counter
    /// until it changes again.
    @Published public var renderedFindNextRequest: Int = 0
    @Published public var renderedFindPrevRequest: Int = 0
    @Published public var renderedFindCaseSensitive: Bool = false

    /// Whether the last WKWebView `find` call returned a match. Reset
    /// to `nil` when the query is empty (no search has run) so the
    /// find bar can distinguish "haven't searched" from "no matches."
    @Published public var renderedFindMatched: Bool? = nil
    /// Pre-formatted "n/N" surface for the find bar. Empty when no
    /// active search. Set by MarkdownRenderedView.Coordinator after
    /// each JS find call returns total + currentIndex.
    @Published public var renderedFindMatchSummary: String = ""
    public func setRenderedFindMatchSummary(_ s: String) {
        guard s != renderedFindMatchSummary else { return }
        renderedFindMatchSummary = s
    }

    /// Nonce that increments each time the user requests the find bar
    /// (Cmd+F). The bar's TextField observes this and refocuses on
    /// every bump, so pressing Cmd+F while the bar is already open
    /// brings focus back to the field instead of being a no-op.
    @Published public var renderedFindFocusRequest: Int = 0
    public func showRenderedFindBar() {
        isRenderedFindBarPresented = true
        renderedFindFocusRequest &+= 1
    }
    public func dismissRenderedFindBar() {
        isRenderedFindBarPresented = false
        renderedFindQuery = ""
        renderedFindMatched = nil
    }

    // MARK: Find bar (source mode)

    /// Same find-bar pattern as renderedFind* above, applied to the
    /// NSTextView source viewer. We keep separate state so view-mode
    /// transitions don't clobber the user's query.
    @Published public var isSourceFindBarPresented: Bool = false
    @Published public var sourceFindQuery: String = ""
    @Published public var sourceFindCaseSensitive: Bool = false
    @Published public var sourceFindIsRegex: Bool = false
    @Published public var sourceFindNextRequest: Int = 0
    @Published public var sourceFindPrevRequest: Int = 0
    @Published public var sourceFindFocusRequest: Int = 0

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

    // MARK: - Split view

    /// URL displayed in the right-hand secondary pane, or nil when
    /// split is closed. v1 is read-only and stateless: the secondary
    /// pane has no tab bar, no find bar, no per-tab view-mode — it
    /// just shows whatever file the user pinned there. Tab bar /
    /// find / etc stay on the primary (left) side.
    @Published public var splitURL: URL? = nil
    /// True when the split is open. Convenience for menu validation.
    public var isSplitOpen: Bool { splitURL != nil }

    public func openInSplit(_ url: URL) {
        splitURL = url.standardizedFileURL.resolvingSymlinksInPath()
    }
    public func closeSplit() { splitURL = nil }
    public func toggleSplit() {
        if splitURL != nil { closeSplit() }
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
    /// Human-readable "n/N" or "" — published by the TextDisplayView
    /// coordinator after it recomputes match ranges. The find bar
    /// renders this directly.
    @Published public var sourceFindMatchSummary: String = ""
    /// 1-based document line numbers for every active find-bar match,
    /// in document order. Published by `SourceTextController` whenever
    /// the find set changes. Consumed by `FindMatchMinimapView` to
    /// draw tick marks alongside the source-view scrollbar.
    @Published public var sourceFindMatchLines: [Int] = []
    /// Index into `sourceFindMatchLines` of the active match — the
    /// one find-bar "next" would land on. Nil when no current match.
    @Published public var sourceFindCurrentMatchIndex: Int? = nil
    /// Guarded setter — call this instead of direct assignment from
    /// SwiftUI callbacks. The `@Published` storage stays writable
    /// because `FindBar` takes the value as a Binding (display only;
    /// it doesn't mutate but SwiftUI's Binding needs setter access).
    public func setSourceFindMatchSummary(_ s: String) {
        guard s != sourceFindMatchSummary else { return }
        sourceFindMatchSummary = s
    }
    /// Apply a `FindMatchSet` update from the source view. Dedupes on
    /// equality so the publish chain doesn't churn SwiftUI on every
    /// apply() tick when the match set is unchanged.
    public func setSourceFindMatches(lines: [Int], currentIndex: Int?) {
        if sourceFindMatchLines != lines {
            sourceFindMatchLines = lines
        }
        if sourceFindCurrentMatchIndex != currentIndex {
            sourceFindCurrentMatchIndex = currentIndex
        }
    }

    public func showSourceFindBar() {
        isSourceFindBarPresented = true
        sourceFindFocusRequest &+= 1
    }
    public func dismissSourceFindBar() {
        isSourceFindBarPresented = false
        sourceFindQuery = ""
        setSourceFindMatchSummary("")
        setSourceFindMatches(lines: [], currentIndex: nil)
    }
    public func sourceFindNext() { sourceFindNextRequest &+= 1 }
    public func sourceFindPrev() { sourceFindPrevRequest &+= 1 }
    public func renderedFindNext() { renderedFindNextRequest &+= 1 }
    public func renderedFindPrev() { renderedFindPrevRequest &+= 1 }

    // MARK: Find bar (CM6 editor mode) — Phase 2 of CM6 integration
    //
    // Mirrors the source-mode find state so the SwiftUI `FindBar`
    // component can drive both back-ends with one shape. Editor-mode
    // find dispatches CM6 search commands via the v1 bridge
    // (`setSearchQuery` / `findNext` / `findPrev`); the readout comes
    // back as `findResultChanged`. The CM built-in panel is suppressed
    // — we own the visual surface.

    @Published public var isEditorFindBarPresented: Bool = false
    @Published public var editorFindQuery: String = ""
    @Published public var editorFindCaseSensitive: Bool = false
    @Published public var editorFindIsRegex: Bool = false
    /// Bumped on every `editorFindNext()` / `editorFindPrev()` so
    /// `CodeMirrorEditorView` (which compares `Equatable` props) can
    /// notice the request and ship the bridge call. Same pattern as
    /// the source bar.
    @Published public var editorFindNextRequest: Int = 0
    @Published public var editorFindPrevRequest: Int = 0
    @Published public var editorFindFocusRequest: Int = 0
    /// "3/12"-style readout — set from JS via `findResultChanged`.
    @Published public var editorFindMatchSummary: String = ""

    public func showEditorFindBar() {
        isEditorFindBarPresented = true
        editorFindFocusRequest &+= 1
    }
    public func dismissEditorFindBar() {
        isEditorFindBarPresented = false
        editorFindQuery = ""
        editorFindMatchSummary = ""
    }
    public func editorFindNext() { editorFindNextRequest &+= 1 }
    public func editorFindPrev() { editorFindPrevRequest &+= 1 }
    public func setEditorFindMatchSummary(_ s: String) {
        guard s != editorFindMatchSummary else { return }
        editorFindMatchSummary = s
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

    /// Bumped each time the host wants the CM6 editor to scroll +
    /// place the caret on a 1-based line. The active
    /// `CodeMirrorEditorView` builds the `CMGotoLineRequest` from this.
    @Published public var editorGotoLine: CMGotoLineRequest? = nil

    /// Indent setting for CM6 editor. Drives CM6's `indentUnit` + tab
    /// size facets via the v1 bridge. Defaults to 2 spaces (matches
    /// the bundle's `applySetIndentation` default).
    @Published public var editorIndentation: CMIndentation = .spaces(2)

    /// Last-known editor cursor position per tab. Used to restore the
    /// caret when the user switches tabs (CM6 view dismantles + remounts
    /// today; without persistence, every tab switch jumps to line 1).
    /// Phase 4 shared-WebView refactor (design doc §14.3) will obsolete
    /// this; for now it's the minimum-cost UX win.
    @Published public private(set) var editorCursorByTab: [UUID: CMCursorPosition] = [:]

    /// Last-known editor scroll position per tab. Persistence story:
    /// in-memory only for now (lives across tab switches inside a single
    /// session). Cross-session persistence is a Phase 3+ deliverable.
    @Published public private(set) var editorScrollByTab: [UUID: CMScrollPosition] = [:]

    public func recordEditorCursor(_ pos: CMCursorPosition, forTabID id: UUID) {
        editorCursorByTab[id] = pos
        // Mirror onto the shared status-bar selection so the bottom
        // "Ln X, Col Y" readout works in editor mode. Source-mode
        // writes the same field; only one is active at a time.
        sourceSelection = SourceSelection(line: pos.line, column: pos.column, length: 0)
    }

    public func recordEditorScroll(_ pos: CMScrollPosition, forTabID id: UUID) {
        editorScrollByTab[id] = pos
    }

    /// Push LSP diagnostics for `url` into the CM6 editor as squiggles.
    /// Looks up the active editor buffer to do the position translation;
    /// no-op if the URL doesn't have an open editor tab. The translated
    /// payload is parked on `pendingEditorDiagnostics[tabID]` so the
    /// active `CodeMirrorEditorView` can pick it up on its next
    /// `updateNSView`. Empty array clears.
    public func setEditorDiagnostics(_ diags: [LSPDiagnostic], forURL url: URL) {
        // Find the open editor tab for this URL, if any. Multiple tabs
        // for the same URL → push to all of them.
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        for tab in tabs.tabs {
            guard let tabURL = tab.url else { continue }
            let stdTab = tabURL.standardizedFileURL.resolvingSymlinksInPath()
            guard stdTab == standardized else { continue }
            guard let buf = editorBuffers[tab.id] else { continue }
            let cmDiags = CMDiagnosticMapping.cmDiagnostics(
                from: diags,
                documentText: buf.text,
                encoding: .utf16
            )
            pendingEditorDiagnostics[tab.id] = cmDiags
        }
    }

    /// Per-tab pending diagnostics payload. `CodeMirrorEditorView`
    /// reads + clears this on each `updateNSView` cycle so re-renders
    /// don't re-ship the same set.
    @Published public internal(set) var pendingEditorDiagnostics: [UUID: [CMDiagnostic]] = [:]

    /// Called by `CodeMirrorEditorView.Coordinator` once it's pushed
    /// the diagnostics so the next `updateNSView` doesn't re-ship them.
    public func consumePendingEditorDiagnostics(forTabID id: UUID) {
        pendingEditorDiagnostics.removeValue(forKey: id)
    }

    // MARK: - CM6 LSP bridge (hover / Cmd-click definition / context menu)

    /// Save the active editor when the WKWebView loses focus. Off by
    /// default — opt-in via Settings. The CM6 host always posts
    /// `editorBlurred`; this flag gates whether Swift acts on it.
    @Published public var saveEditorOnBlur: Bool = false

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
            // NSMenu doesn't retain item targets across popUp dismissal,
            // so we park the target on the menu via objc_setAssociatedObject
            // by simply stashing in a side dict bound to menu lifetime.
            editorMenuTargets[ObjectIdentifier(goDef)] = target
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
        menu.popUp(positioning: nil, at: popPoint, in: nil)
    }

    /// Side-storage for NSMenuItem targets created in
    /// `showEditorContextMenu`. NSMenu does not retain `target`, so a
    /// closure-backed shim would deallocate before the menu action
    /// fires. Keying by `ObjectIdentifier(menuItem)` keeps lifetime
    /// scoped without leaking — the dict survives only until the next
    /// context-menu invocation drops the entry.
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

    /// Tab.id's that the user has toggled into "formatted" (pretty-
    /// printed) view. Keyed by Tab.id (not URL) so:
    ///   - opening the same file in two tabs gives them independent
    ///     format state (otherwise toggling one toggles both)
    ///   - closing a tab automatically prunes its entry below
    @Published private var formattedTabIDs: Set<UUID> = []

    /// Per-tab override of the auto-detected language. User can pick
    /// from the language badge dropdown to force a `.txt` file into
    /// JSON mode (or whatever). Keyed by Tab.id so two tabs of the
    /// same file can have independent overrides.
    @Published private var languageOverrides: [UUID: HighlightLanguage] = [:]

    /// Effective language for a given tab — override wins over
    /// auto-detection. Public so the ModeBar dropdown + the source
    /// view both read the same source of truth.
    public func effectiveLanguage(forTabID id: UUID, url: URL) -> HighlightLanguage {
        languageOverrides[id] ?? HighlightLanguage.detect(from: url)
    }

    /// Set or clear the override for the current tab. Passing the
    /// auto-detected language clears the override (so a follow-up
    /// rename still does the right thing).
    public func setCurrentLanguage(_ lang: HighlightLanguage) {
        guard let id = tabs.selected?.id,
              let i = tabs.tabs.firstIndex(where: { $0.id == id }),
              let url = tabs.tabs[i].url else { return }
        let auto = HighlightLanguage.detect(from: url)
        if lang == auto {
            languageOverrides.removeValue(forKey: id)
        } else {
            languageOverrides[id] = lang
        }
        // Kick a re-highlight by touching the tab's state without
        // mutating it (no-op assignment). The publish triggers the
        // source view's highlightRuns recompute downstream.
        let t = tabs.tabs[i]
        tabs.replace(at: i, with: t)
    }

    /// True if a manual override is set for the current tab.
    public var hasLanguageOverride: Bool {
        guard let id = tabs.selected?.id else { return false }
        return languageOverrides[id] != nil
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
        guard let id = tabs.selected?.id else { return false }
        return formattedTabIDs.contains(id)
    }

    public func toggleFormat() {
        guard let id = tabs.selected?.id, supportsFormatToggle else { return }
        if formattedTabIDs.contains(id) {
            formattedTabIDs.remove(id)
        } else {
            formattedTabIDs.insert(id)
        }
    }

    // MARK: Editor mode (Phase 6.x — editable plain-text buffer)
    //
    // PoC: one EditorBuffer per tab id, keyed off the same `tabs.tabs`
    // identity used by every other per-tab cache. The buffer is lazy
    // — created on first read for the tab in `.editor` view mode and
    // dropped on tab close (see closeTab / closeOthers / closeToRight).

    @Published public private(set) var editorBuffers: [UUID: EditorBuffer] = [:]

    /// Result of `confirmCloseIfDirty(...)`. Plain enum so view code
    /// (NSAlert response handler) can switch without leaking AppKit
    /// types into the model.
    public enum DirtyClosePrompt {
        /// User chose Save; the caller should call `saveActiveEditor`
        /// (or `saveEditor(forTabID:)`) and then close on success.
        case save
        /// User chose Don't Save; discard the buffer + close.
        case discard
        /// User chose Cancel; abort the close.
        case cancel
    }

    /// True when any open tab has unsaved editor edits. Used by the
    /// app delegate's terminate path + window-close confirmation.
    public var hasAnyUnsavedEdits: Bool {
        tabs.tabs.contains(where: { $0.isDirty })
    }

    /// Returns the active tab's buffer (creating it on demand if the
    /// tab's state is `.loaded`). Returns nil for binary / empty /
    /// error tabs — `.editor` mode is only meaningful when there's
    /// loaded text to seed the buffer with.
    public func editorBuffer(forTabID id: UUID) -> EditorBuffer? {
        if let cached = editorBuffers[id] { return cached }
        guard let tab = tabs.tabs.first(where: { $0.id == id }),
              case .loaded(let file) = tab.state else { return nil }
        let buf = EditorBuffer(from: file)
        editorBuffers[id] = buf
        return buf
    }

    /// Seed a fresh buffer for `tabID` from `file`. Called when the
    /// view-mode switch lands on `.editor` (and on loadAsync
    /// completion when an editor-mode tab finishes materializing).
    /// Idempotent — preserves an existing buffer with unsaved edits.
    public func ensureEditorBuffer(for file: TextFile, tabID: UUID) {
        if editorBuffers[tabID] != nil { return }
        editorBuffers[tabID] = EditorBuffer(from: file)
    }

    /// Push a new text value into the active tab's buffer. Called from
    /// the editor view's change handler (debounced inside CodeMirror's
    /// JS bootstrap, ~200 ms after the last keystroke).
    /// Updates `Tab.isDirty` so the TabBar dot mirrors the state.
    /// O(1) — no text comparison here; the buffer's `isDirty` getter
    /// is the one place that runs the (cheap, length-short-circuited)
    /// String equality.
    public func updateEditorText(_ newText: String, forTabID id: UUID) {
        guard var buf = editorBuffer(forTabID: id) else { return }
        // Fast path: identical-string assignment is a no-op. Avoids
        // republishing `editorBuffers` for callers that fire the
        // setter on every paint (some NSTextView subclasses do).
        if buf.text == newText { return }
        buf.setText(newText)
        editorBuffers[id] = buf
        // Sync the Tab snapshot so SwiftUI re-renders the dirty dot.
        if let idx = tabs.tabs.firstIndex(where: { $0.id == id }) {
            let nowDirty = buf.isDirty
            if tabs.tabs[idx].isDirty != nowDirty {
                var t = tabs.tabs[idx]
                t.isDirty = nowDirty
                tabs.replace(at: idx, with: t)
            }
        }
    }

    /// Write the active editor buffer to disk. ⌘S handler routes here.
    /// Returns true on success, false (with an NSAlert surfaced by the
    /// caller) on encoding / write failure.
    @discardableResult
    public func saveActiveEditor() -> Bool {
        guard let id = tabs.selected?.id else { return false }
        return saveEditor(forTabID: id)
    }

    /// Save a specific tab's buffer. Used by `saveActiveEditor` and
    /// by the close-confirm path that targets a non-active tab.
    @discardableResult
    public func saveEditor(forTabID id: UUID) -> Bool {
        guard var buf = editorBuffers[id] else { return false }
        // File-watcher reload during save would race the write — pause
        // it for the moment the write is in flight + the immediate
        // post-write watcher event we'd otherwise re-enter on.
        // Caller resumes watching when control returns.
        let wasWatchingURL = watchedURL
        pauseFileWatcher()
        defer {
            if wasWatchingURL == currentURL { startWatchingCurrentFile() }
        }
        do {
            let stamp = try EditorWriter.save(buf.text, to: buf.url, encoding: buf.encoding)
            buf.markSaved(diskMTime: stamp.mtime, diskSize: stamp.size)
            editorBuffers[id] = buf
            // Clear the dirty dot.
            if let idx = tabs.tabs.firstIndex(where: { $0.id == id }) {
                var t = tabs.tabs[idx]
                t.isDirty = false
                tabs.replace(at: idx, with: t)
            }
            // Refresh the loaded TextFile so the rest of the app sees
            // the new bytes (sidebar diff marks, formatted cache, etc.
            // all key off URL + length and would otherwise serve stale
            // content if the user flips back to `.source`).
            if let idx = tabs.tabs.firstIndex(where: { $0.id == id }) {
                var t = tabs.tabs[idx]
                if case .loaded(let oldFile) = t.state {
                    let bytes = buf.text.data(using: buf.encoding)?.count ?? oldFile.byteCount
                    // We just wrote the file — re-stat its mtime so the
                    // rendered-HTML / highlight caches pick up the new
                    // identity even when the rewrite happens to be the
                    // same byte length. Falling back to `Date()` keeps
                    // the cache invariant ("mtime differs after a write")
                    // intact if the filesystem can't report attrs.
                    let mtime: Date? = {
                        if let attrs = try? FileManager.default
                            .attributesOfItem(atPath: oldFile.url.path),
                           let d = attrs[.modificationDate] as? Date {
                            return d
                        }
                        return Date()
                    }()
                    let newFile = TextFile(
                        url: oldFile.url,
                        contents: buf.text,
                        encoding: oldFile.encoding,
                        byteCount: bytes,
                        modifiedTime: mtime
                    )
                    t.state = .loaded(newFile)
                    tabs.replace(at: idx, with: t)
                }
            }
            return true
        } catch {
            // Surface failure to the user. Stay dirty so the next
            // ⌘S retries instead of silently dropping the edit.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save \(buf.url.lastPathComponent)"
            alert.informativeText = "\(error)"
            alert.runModal()
            return false
        }
    }

    /// Drop the buffer for a tab. Called by the close paths after the
    /// user has confirmed discard, and as part of normal close cleanup
    /// (no-op when the buffer isn't present).
    public func discardEditorBuffer(forTabID id: UUID) {
        editorBuffers.removeValue(forKey: id)
        if let idx = tabs.tabs.firstIndex(where: { $0.id == id }), tabs.tabs[idx].isDirty {
            var t = tabs.tabs[idx]
            t.isDirty = false
            tabs.replace(at: idx, with: t)
        }
    }

    /// If the tab at `index` has unsaved edits, run the
    /// Save / Don't Save / Cancel NSAlert and return the user's
    /// choice. Returns `nil` when the tab is clean (caller proceeds
    /// directly to close). Modal on the main thread by design —
    /// matches every other AppKit close-confirm flow.
    public func confirmCloseIfDirty(at index: Int) -> DirtyClosePrompt? {
        guard tabs.tabs.indices.contains(index) else { return nil }
        let tab = tabs.tabs[index]
        guard tab.isDirty else { return nil }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let name = tab.url?.lastPathComponent ?? tab.title
        alert.messageText = "Save changes to \(name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")          // .alertFirstButtonReturn
        alert.addButton(withTitle: "Don't Save")    // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")        // .alertThirdButtonReturn
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .save
        case .alertSecondButtonReturn: return .discard
        default:                       return .cancel
        }
    }

    /// Returns the text that should be shown in the source view for
    /// the currently selected tab and `file`: either pretty-printed
    /// (when toggled and supported) or the raw contents.
    ///
    /// Memoizes the formatter output per tab id. Without this, every
    /// SwiftUI body re-eval (and there are many — find keystrokes,
    /// selection changes, scroll) reruns `Formatter.prettyPrint` on
    /// the full file, which is O(N) text-walk per call. Cache is
    /// invalidated when the source length changes (file watcher
    /// reload).
    public func displayText(for file: TextFile) -> String {
        guard let id = tabs.selected?.id,
              formattedTabIDs.contains(id),
              let format = Formatter.SupportedFormat.detect(file.url) else {
            return file.contents
        }
        let len = file.contents.utf8.count
        if let hit = formattedTextCache[id], hit.sourceLength == len {
            return hit.formatted
        }
        let result = Formatter.prettyPrint(file.contents, as: format)
        if formattedTextCache[id] == nil {
            formattedTextCacheOrder.append(id)
        }
        formattedTextCache[id] = (sourceLength: len, formatted: result)
        if formattedTextCache.count > Self.formattedTextCacheMax {
            // S4-G: evict oldest by insertion order; same fix as the
            // renderedHTMLCache (S2-G).
            let dropCount = formattedTextCache.count - Self.formattedTextCacheMax * 2 / 3
            let toDrop = formattedTextCacheOrder.prefix(dropCount)
            for k in toDrop {
                formattedTextCache.removeValue(forKey: k)
            }
            formattedTextCacheOrder.removeFirst(toDrop.count)
        }
        return result
    }

    private var formattedTextCache: [UUID: (sourceLength: Int, formatted: String)] = [:]
    private var formattedTextCacheOrder: [UUID] = []
    private static let formattedTextCacheMax = 8

    // MARK: Syntax highlighting

    /// Cache of (file URL + content length + language) → [HighlightRun].
    /// The byte-length acts as a coarse change detector so a file
    /// watcher reload (which keeps the same URL) invalidates the
    /// cached runs. Using URL+length is O(1) per lookup; hashing the
    /// full text on every body re-eval (the prior key) was O(N) per
    /// call and dominated large-file render cost.
    ///
    /// Documented limitation: same-byte-length reloads
    /// (`# Hello\n` → `# World\n`) won't invalidate. The flagged
    /// inconsistency with renderedHTMLCache (which uses a content
    /// hash) is real but the perf cost of hashing on every body
    /// re-eval was the original motivation — leaving as-is. Run
    /// SwiftUI-level invalidation through a dedicated nonce instead
    /// when this becomes user-visible.
    public struct HighlightCacheKey: Hashable, Sendable {
        public let url: URL
        public let length: Int
        public let language: HighlightLanguage
    }
    @Published public private(set) var highlightCache: [HighlightCacheKey: [HighlightRun]] = [:]
    /// Insertion-order list mirroring `highlightCache`. Used to evict
    /// the OLDEST entries on overflow (S2-G class). Updated by
    /// `highlightRuns(forURL:text:language:)` and pruned by
    /// `purgeCaches(forURL:)`.
    private var highlightCacheOrder: [HighlightCacheKey] = []
    private var highlightInFlight: Set<HighlightCacheKey> = []

    /// Currently-active syntax theme. Computed from system appearance;
    /// re-publishes when the user flips Light/Dark. Override field is
    /// for a future "Settings → Appearance" picker.
    @Published public var themeOverride: SyntaxTheme.Name? = nil
    public var activeTheme: SyntaxTheme {
        if let o = themeOverride { return SyntaxTheme.named(o) }
        return SyntaxTheme.resolved(forAppearance: NSApp?.effectiveAppearance)
    }

    /// View-facing accessor. Returns runs immediately if cached;
    /// otherwise returns [] and kicks off an async tokenize task that
    /// will populate `highlightCache`, triggering a re-render via
    /// @Published. Calls with the same key while a task is in flight
    /// are coalesced. Safe to call from `body`.
    ///
    /// `url` is the cache key — `text` is the content to tokenize.
    /// Reloading the same file with new content invalidates because
    /// `text.utf16.count` differs.
    public func highlightRuns(
        forURL url: URL, text: String, language: HighlightLanguage
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
        let key = HighlightCacheKey(url: url, length: length, language: language)
        if let cached = highlightCache[key] { return cached }
        guard !highlightInFlight.contains(key) else { return [] }
        highlightInFlight.insert(key)
        let snapshot = text
        Task.detached(priority: .userInitiated) { [weak self] in
            let runs = TreeSitterEngine.shared.tokenize(
                snapshot, language: language
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.highlightCache[key] == nil {
                    self.highlightCacheOrder.append(key)
                }
                self.highlightCache[key] = runs
                self.highlightInFlight.remove(key)
                self.pruneHighlightCacheIfNeeded()
            }
        }
        return []
    }

    /// Cap the cache so we don't grow without bound when the user
    /// scrubs through many files. The numbers are arbitrary — enough
    /// to cover a session of normal usage.
    private static let highlightCacheMax = 32
    private func pruneHighlightCacheIfNeeded() {
        guard highlightCache.count > Self.highlightCacheMax else { return }
        // S2-G class: evict by insertion order (oldest first). The
        // prior "drop arbitrary Dictionary.keys.prefix(N)" sometimes
        // dropped the freshly-inserted entry.
        let dropCount = highlightCache.count - Self.highlightCacheMax * 2 / 3
        let toDrop = highlightCacheOrder.prefix(dropCount)
        for key in toDrop {
            highlightCache.removeValue(forKey: key)
        }
        highlightCacheOrder.removeFirst(toDrop.count)
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
    // MARK: Workspace snapshot

    /// Auto-save the current open tabs / view modes / sidebar root /
    /// prefs into the workspace store's `_last.json` slot. Call on
    /// applicationWillTerminate.
    public func saveWorkspaceAutoSlot() {
        let store = WorkspaceStore()
        let snap = WorkspaceSnapshot(
            sidebarRootPath: sidebar.rootURL?.path,
            openTabs: tabs.tabs.compactMap { t in
                guard let url = t.url else { return nil }
                return TabSnapshot(path: url.path, viewMode: t.viewMode.rawValue)
            },
            selectedTabIndex: tabs.selectedIndex,
            zoom: zoom,
            wordWrap: sourceWordWrap,
            themeOverride: themeOverride?.rawValue
        )
        store.saveAutoSlot(snap)
    }

    /// If `_last.json` exists, re-open the tabs + restore prefs.
    /// Called once at app launch (after restorePreviousFolderIfAvailable).
    /// Falls back silently if the snapshot is missing or unreadable.
    public func restoreWorkspaceAutoSlot() {
        let store = WorkspaceStore()
        guard let snap = store.loadAutoSlot() else { return }
        if let root = snap.sidebarRootPath {
            let url = URL(fileURLWithPath: root)
            if FileManager.default.fileExists(atPath: url.path) {
                sidebar.setRoot(url)
            }
        }
        // Lazy restore: every tab from the snapshot is appended with
        // state = .empty (URL only), no file contents read. The focused
        // tab (selectedTabIndex) is materialized by the explicit
        // selectTab below; the rest stay unloaded until the user
        // navigates to them. Keeps "15 open tabs from yesterday" from
        // re-reading 15 files on launch.
        for t in snap.openTabs {
            let url = URL(fileURLWithPath: t.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let mode = ViewMode(rawValue: t.viewMode)
                ?? ViewModeOptions.defaultMode(for: url)
            appendLazyTab(url: url, viewMode: mode)
        }
        if let zoom = snap.zoom { self.zoom = zoom }
        if let wrap = snap.wordWrap { self.sourceWordWrap = wrap }
        if let theme = snap.themeOverride {
            self.themeOverride = SyntaxTheme.Name(rawValue: theme)
        }
        // S3-J: distinguish nil (deliberate "no selection persisted")
        // from 0 (first tab). Previously nil collapsed to 0 and
        // restoring a workspace with an explicit empty selection
        // refocused tab 0 anyway.
        if let target = snap.selectedTabIndex, tabs.tabs.indices.contains(target) {
            selectTab(at: target)
        }
    }

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
        let state = controller.open(url: resolved)
        // Pick the per-extension default mode: .table for CSV/TSV,
        // .rendered for markdown, .source for everything else. The
        // "carry current mode" branch below overrides for the common
        // "user is in HEX, opens another file" workflow.
        let initialMode = ViewModeOptions.defaultMode(for: resolved)
        if forceNewTab {
            tabs.append(Tab(url: resolved, state: state, viewMode: initialMode))
        } else {
            // If the active tab has a non-default mode the user
            // explicitly picked (e.g. HEX, Format), carry it. Otherwise
            // use the new file's natural default.
            let carryMode: ViewMode
            if let cur = tabs.selected, cur.viewMode != .rendered, cur.viewMode != .source {
                carryMode = cur.viewMode
            } else {
                carryMode = initialMode
            }
            tabs.openOrReveal(url: resolved, state: state, viewMode: carryMode)
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
        // Both text and binary opens count as a successful "user saw this
        // file"; record either as a recent. Errors don't.
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
        startWatchingCurrentFile()
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
        let tab = tabs.tabs[i]
        if tab.isDirty, let buf = editorBuffers[tab.id] {
            let attrs = try? FileManager.default.attributesOfItem(atPath: watchedURL.path)
            let mtime = attrs?[.modificationDate] as? Date
            let size = attrs?[.size] as? Int
            if buf.hasExternalEdit(currentMTime: mtime, currentSize: size) {
                presentExternalEditConflict(forTabID: tab.id, at: i, url: watchedURL)
                return
            }
        }
        reload(url: watchedURL, at: i)
    }

    /// Modal alert presented when the file underneath an editor tab
    /// has changed on disk while the buffer is dirty. Two outcomes:
    ///   - "Keep My Edits": leave the buffer alone; just update the
    ///     saved-fingerprint so we don't re-prompt for the same change.
    ///   - "Discard & Reload": drop the buffer and load disk contents.
    private func presentExternalEditConflict(forTabID id: UUID, at index: Int, url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(url.lastPathComponent) changed on disk"
        alert.informativeText = "You have unsaved changes. Reloading will discard them."
        alert.addButton(withTitle: "Keep My Edits")
        alert.addButton(withTitle: "Discard & Reload")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            discardEditorBuffer(forTabID: id)
            reload(url: url, at: index)
        } else {
            // Refresh the fingerprint so the next watcher tick (often
            // a duplicate event from the same write) doesn't re-prompt.
            // Crucially we MUST NOT touch `originalText` — keeping the
            // pre-conflict baseline preserves `isDirty == true` and
            // leaves Revert / future "compare original" features usable.
            if var buf = editorBuffers[id] {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                buf.refreshSavedFingerprint(
                    diskMTime: attrs?[.modificationDate] as? Date,
                    diskSize: attrs?[.size] as? Int
                )
                editorBuffers[id] = buf
            }
        }
    }

    private func reload(url: URL, at index: Int) {
        let state = controller.open(url: url)
        var t = tabs.tabs[index]
        t.state = state
        tabs.replace(at: index, with: t)
        updateDerived()
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
        tabs.append(Tab())
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
        let closedTab = tabs.tabs.indices.contains(index) ? tabs.tabs[index] : nil
        tabs.close(at: index)
        if let t = closedTab {
            cancelMaterialize(forTabID: t.id)
            formattedTabIDs.remove(t.id)
            formattedTextCache.removeValue(forKey: t.id)
            languageOverrides.removeValue(forKey: t.id)
            csvFilterStates.removeValue(forKey: t.id)
            editorBuffers.removeValue(forKey: t.id)
            hexBytesPerRow.removeValue(forKey: t.id)
            purgeCaches(forURL: t.url, tabID: t.id)
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
        let closedTabs = tabs.tabs.filter { $0.id != keepID }
        tabs.closeAll(except: index)
        for t in closedTabs {
            cancelMaterialize(forTabID: t.id)
            formattedTextCache.removeValue(forKey: t.id)
            languageOverrides.removeValue(forKey: t.id)
            csvFilterStates.removeValue(forKey: t.id)
            editorBuffers.removeValue(forKey: t.id)
            hexBytesPerRow.removeValue(forKey: t.id)
            purgeCaches(forURL: t.url, tabID: t.id)
        }
        // Intersect tab-id sets with the still-open ids. Cheaper than
        // tracking every closed id and symmetric across the three
        // tab-id-keyed maps.
        let openIDs = Set(tabs.tabs.map { $0.id })
        formattedTabIDs.formIntersection(openIDs)
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
        // range construction below would trap before the
        // `tabs.tabs.indices.contains(index)` check on line ~2061
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
        let closedTabs = tabs.tabs.indices.contains(index)
            ? Array(tabs.tabs.suffix(from: index + 1))
            : []
        tabs.closeAllToRight(of: index)
        for t in closedTabs {
            cancelMaterialize(forTabID: t.id)
            formattedTextCache.removeValue(forKey: t.id)
            languageOverrides.removeValue(forKey: t.id)
            csvFilterStates.removeValue(forKey: t.id)
            editorBuffers.removeValue(forKey: t.id)
            hexBytesPerRow.removeValue(forKey: t.id)
            purgeCaches(forURL: t.url, tabID: t.id)
        }
        let openIDs = Set(tabs.tabs.map { $0.id })
        formattedTabIDs.formIntersection(openIDs)
        updateDerived()
        startWatchingCurrentFile()
    }

    /// Drop all cache entries belonging to a closed tab. Highlight runs
    /// are URL-keyed (still — they're a content-addressable product
    /// shared across tabs viewing the same file); only purge the
    /// highlight cache when no remaining tab holds the URL. Rendered-
    /// HTML entries are tabID-keyed since the cache moved to
    /// `(tabID, mtime, byteCount)`; purge unconditionally on tab close
    /// because no other tab can hit the same key anyway.
    private func purgeCaches(forURL url: URL?, tabID: UUID? = nil) {
        if let url, !tabs.tabs.contains(where: { $0.url == url }) {
            let priorHighlightOrder = highlightCacheOrder
            highlightCache = highlightCache.filter { $0.key.url != url }
            let survivorHL = Set(highlightCache.keys)
            highlightCacheOrder = priorHighlightOrder.filter { survivorHL.contains($0) }
        }

        if let tabID {
            let priorOrder = renderedHTMLCacheOrder
            renderedHTMLCache = renderedHTMLCache.filter { $0.key.tabID != tabID }
            // Keep the order list in sync — drop the tab's entries while
            // preserving relative ordering of survivors (S2-G).
            let survivorKeys = Set(renderedHTMLCache.keys)
            renderedHTMLCacheOrder = priorOrder.filter { survivorKeys.contains($0) }
        }
    }

    public func moveTab(from src: Int, to dst: Int) {
        tabs.move(from: src, to: dst)
        updateDerived()
    }

    public func moveCurrentTabLeft() {
        guard let i = tabs.selectedIndex else { return }
        tabs.swapWithPrevious(at: i)
        updateDerived()
    }

    public func moveCurrentTabRight() {
        guard let i = tabs.selectedIndex else { return }
        tabs.swapWithNext(at: i)
        updateDerived()
    }


    public func selectTab(at index: Int) {
        tabs.select(at: index)
        materializeIfNeeded(at: index)
        updateDerived()
        startWatchingCurrentFile()
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
        tabs.append(Tab(url: resolved, state: .empty, viewMode: safeMode))
    }

    /// Open many URLs at once. Only the LAST URL is read into memory;
    /// the others are appended as lazy tabs (state = .empty, url set).
    /// The selection ends on the last opened tab so the user sees the
    /// file they probably care about — matches Finder's "drop several
    /// files, the last one wins focus" convention.
    public func openMultiple(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // All but the last: lazy.
        for url in urls.dropLast() {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            let mode = ViewModeOptions.defaultMode(for: resolved)
            appendLazyTab(url: resolved, viewMode: mode)
        }
        // Last one: eager open through the normal path so it gets
        // history-recorded, watcher-bound, sidebar-rooted, etc.
        if let last = urls.last {
            openPath(last)
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
        materializeTasks[tabID]?.cancel()
        var loading = t
        loading.state = .loading(url)
        tabs.replace(at: index, with: loading)
        let viewMode = t.viewMode
        let task = Task.detached(priority: .userInitiated) { [controller] in
            let state = controller.open(url: url)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Clear our slot regardless of outcome — the Task is
                // done from here on out, even if we drop the result.
                self.materializeTasks[tabID] = nil
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
                self.tabs.replace(at: idx, with: t2)
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
        materializeTasks[tabID] = task
    }

    /// Cancel + drop the materialize Task slot for `tabID`. Called from
    /// every tab-close path so a doomed tab's still-running file read
    /// doesn't waste I/O.
    private func cancelMaterialize(forTabID tabID: UUID) {
        materializeTasks[tabID]?.cancel()
        materializeTasks[tabID] = nil
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
                formattedTabIDs.insert(t.id)
            }
        case .source, .rendered, .table, .diff:
            formattedTabIDs.remove(t.id)
            if let url = t.url, case .binary = t.state {
                loadTextAsync(url: url, intoTabID: t.id)
            }
        case .editor:
            // Editor needs the text contents in memory. If the tab
            // currently holds a binary view, kick a text re-load so
            // the buffer has something to bind to; the buffer itself
            // is created lazily by `editorBuffer(forTabID:)` once
            // the file lands as `.loaded`.
            formattedTabIDs.remove(t.id)
            if let url = t.url, case .binary = t.state {
                loadTextAsync(url: url, intoTabID: t.id)
            }
            // Seed an EditorBuffer eagerly when the file is already
            // loaded so the view's first frame has real text rather
            // than an empty placeholder.
            if case .loaded(let file) = t.state {
                ensureEditorBuffer(for: file, tabID: t.id)
            }
        }
        t.viewMode = mode
        tabs.replace(at: i, with: t)
    }

    /// Off-main file read, on-main state swap. Keeps the UI
    /// responsive for multi-MB files. We re-locate the tab by id at
    /// completion time so a meanwhile-closed tab is a no-op rather
    /// than crashing.
    private func loadBinaryAsync(url: URL, intoTabID id: UUID) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = try? BinaryFileLoader().load(url: url)
            await MainActor.run { [weak self] in
                guard let self, let bin = loaded,
                      let idx = self.tabs.tabs.firstIndex(where: { $0.id == id })
                else { return }
                var tab = self.tabs.tabs[idx]
                tab.state = .binary(bin)
                self.tabs.replace(at: idx, with: tab)
            }
        }
    }

    private func loadTextAsync(url: URL, intoTabID id: UUID) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = try? TextFileLoader().load(url: url)
            await MainActor.run { [weak self] in
                guard let self, let text = loaded,
                      let idx = self.tabs.tabs.firstIndex(where: { $0.id == id })
                else { return }
                var tab = self.tabs.tabs[idx]
                tab.state = .loaded(text)
                self.tabs.replace(at: idx, with: tab)
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
        // Maintain a Set<URL> of open-tab URLs so views can answer
        // "is this URL open?" in O(1) rather than scanning the tabs
        // array per row per body re-eval. Called on every tabs
        // mutation; `openTabURLs` is the @Published observable
        // sidebar/palette read.
        let newSet = Set(tabs.tabs.compactMap { $0.url })
        if newSet != openTabURLs { openTabURLs = newSet }
        // Recompute the source-view diff stripe when the focused
        // file changes. Cheap-ish: shells `git diff` once per switch
        // (off-main); skipped when not inside a repo.
        refreshDiffMarks()
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
