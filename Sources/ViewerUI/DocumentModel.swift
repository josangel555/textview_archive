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

    /// Chrome font scaling (sidebar / tabs / status bar / mode bar).
    /// Distinct from `zoom` which only affects document content.
    /// Defaults to 1.0; range 0.85 – 1.6.
    @Published public var uiScale: Double {
        didSet { preferences.uiScale = uiScale }
    }
    /// Helper for view code: scale a base font size by uiScale.
    public func uiSize(_ base: CGFloat) -> CGFloat { base * CGFloat(uiScale) }

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
    public let sidebar: SidebarModel

    private let controller: DocumentController
    public let history: HistoryStore
    public let bookmarksStore: BookmarksStore
    private let preferences: PreferencesStore
    private var fileWatcher: FileWatcher?
    private var watchedURL: URL?

    public init(
        controller: DocumentController = DocumentController(),
        history: HistoryStore = HistoryStore(storeURL: HistoryStore.defaultStoreURL()),
        bookmarks: BookmarksStore = BookmarksStore(storeURL: BookmarksStore.defaultStoreURL()),
        sidebar: SidebarModel = SidebarModel(),
        preferences: PreferencesStore = PreferencesStore()
    ) {
        self.controller = controller
        self.history = history
        self.bookmarksStore = bookmarks
        self.sidebar = sidebar
        self.preferences = preferences
        self.recents = history.recent()
        self.bookmarks = bookmarks.all()
        self.sidebarWidth = preferences.sidebarWidth
        self.zoom = preferences.zoom
        self.sourceWordWrap = preferences.sourceWordWrap
        self.showInvisibleChars = preferences.showInvisibleChars
        self.uiScale = preferences.uiScale
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
    public func openPath(_ url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
           isDir.boolValue {
            openFolder(url)
        } else {
            open(url: url)
        }
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
        bookmarks = bookmarksStore.all(); invalidateBookmarkedLinesCache()
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

    public func dismissCrossSearch() {
        isCrossSearchPresented = false
        crossSearchQuery = ""
        crossSearchResults = []
        crossSearchIsRunning = false
        crossSearchGeneration &+= 1  // invalidate any in-flight search
    }

    /// Runs a cross-file search using the sidebar's current root. If no
    /// folder is open, this is a no-op (sets results to empty).
    public func runCrossSearch() {
        guard let root = sidebar.rootURL else {
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
    /// Human-readable "n/N" or "" — published by the TextDisplayView
    /// coordinator after it recomputes match ranges. The find bar
    /// renders this directly.
    @Published public var sourceFindMatchSummary: String = ""

    public func showSourceFindBar() {
        isSourceFindBarPresented = true
        sourceFindFocusRequest &+= 1
    }
    public func dismissSourceFindBar() {
        isSourceFindBarPresented = false
        sourceFindQuery = ""
        sourceFindMatchSummary = ""
    }
    public func sourceFindNext() { sourceFindNextRequest &+= 1 }
    public func sourceFindPrev() { sourceFindPrevRequest &+= 1 }
    public func renderedFindNext() { renderedFindNextRequest &+= 1 }
    public func renderedFindPrev() { renderedFindPrevRequest &+= 1 }

    // MARK: Pretty-print / Format

    /// Tab.id's that the user has toggled into "formatted" (pretty-
    /// printed) view. Keyed by Tab.id (not URL) so:
    ///   - opening the same file in two tabs gives them independent
    ///     format state (otherwise toggling one toggles both)
    ///   - closing a tab automatically prunes its entry below
    @Published private var formattedTabIDs: Set<UUID> = []

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

    /// Returns the text that should be shown in the source view for
    /// the currently selected tab and `file`: either pretty-printed
    /// (when toggled and supported) or the raw contents.
    public func displayText(for file: TextFile) -> String {
        guard let id = tabs.selected?.id,
              formattedTabIDs.contains(id),
              let format = Formatter.SupportedFormat.detect(file.url) else {
            return file.contents
        }
        return Formatter.prettyPrint(file.contents, as: format)
    }

    // MARK: Syntax highlighting

    /// Cache of (file URL + content length + language) → [HighlightRun].
    /// The byte-length acts as a coarse change detector so a file
    /// watcher reload (which keeps the same URL) invalidates the
    /// cached runs. Using URL+length is O(1) per lookup; hashing the
    /// full text on every body re-eval (the prior key) was O(N) per
    /// call and dominated large-file render cost.
    public struct HighlightCacheKey: Hashable, Sendable {
        public let url: URL
        public let length: Int
        public let language: HighlightLanguage
    }
    @Published public private(set) var highlightCache: [HighlightCacheKey: [HighlightRun]] = [:]
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
        guard language != .plainText else { return [] }
        let length = (text as NSString).length
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
        // Drop a third of entries (oldest first by insertion order is
        // hard with a plain Dictionary; we drop arbitrary entries).
        let dropCount = highlightCache.count - Self.highlightCacheMax * 2 / 3
        for key in highlightCache.keys.prefix(dropCount) {
            highlightCache.removeValue(forKey: key)
        }
    }

    // MARK: Rendered markdown cache

    /// Memoizes `HTMLRenderer.renderPage` output keyed by content hash.
    /// Without this, ContentView.body re-runs renderPage on every model
    /// mutation — and renderPage now drives TreeSitter highlighting
    /// for every fenced code block, which is expensive enough to be
    /// visible as latency. Stylesheet doesn't enter the key because it
    /// only changes between app launches.
    public struct RenderedHTMLKey: Hashable, Sendable {
        public let url: URL
        public let length: Int
    }
    private var renderedHTMLCache: [RenderedHTMLKey: String] = [:]
    private static let renderedHTMLCacheMax = 16

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
        for t in snap.openTabs {
            let url = URL(fileURLWithPath: t.path)
            if FileManager.default.fileExists(atPath: url.path) {
                openPath(url)
                if let mode = ViewMode(rawValue: t.viewMode), mode != currentViewMode {
                    setCurrentViewMode(mode)
                }
            }
        }
        if let zoom = snap.zoom { self.zoom = zoom }
        if let wrap = snap.wordWrap { self.sourceWordWrap = wrap }
        if let theme = snap.themeOverride {
            self.themeOverride = SyntaxTheme.Name(rawValue: theme)
        }
        if let i = snap.selectedTabIndex, tabs.tabs.indices.contains(i) {
            selectTab(at: i)
        }
    }

    public func renderedHTML(
        forURL url: URL,
        contents: String,
        renderer: HTMLRenderer,
        stylesheet: String
    ) -> String {
        let key = RenderedHTMLKey(url: url, length: (contents as NSString).length)
        if let hit = renderedHTMLCache[key] { return hit }
        let html = renderer.renderPage(contents, stylesheet: stylesheet)
        renderedHTMLCache[key] = html
        if renderedHTMLCache.count > Self.renderedHTMLCacheMax {
            let drop = renderedHTMLCache.count - Self.renderedHTMLCacheMax * 2 / 3
            for k in renderedHTMLCache.keys.prefix(drop) {
                renderedHTMLCache.removeValue(forKey: k)
            }
        }
        return html
    }

    // MARK: Derived from current tab

    public var currentState: DocumentState { tabs.selected?.state ?? .empty }
    public var currentURL: URL? { tabs.selected?.url }
    public var currentViewMode: ViewMode { tabs.selected?.viewMode ?? .rendered }

    public var supportsViewModeToggle: Bool {
        guard let url = currentURL else { return false }
        return FileTypeDetector.category(for: url) == .markdown
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
            case .binary, .empty: break
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
        case .empty, .error:
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
    private func reloadCurrentFile(matching watchedURL: URL) {
        guard let i = tabs.selectedIndex,
              tabs.tabs.indices.contains(i),
              tabs.tabs[i].url == watchedURL else { return }
        reload(url: watchedURL, at: i)
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

    // MARK: Tab management

    public func newTab() {
        tabs.append(Tab())
        updateDerived()
    }

    public func closeTab(at index: Int) {
        let closedID = tabs.tabs.indices.contains(index) ? tabs.tabs[index].id : nil
        tabs.close(at: index)
        if let id = closedID { formattedTabIDs.remove(id) }
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
        tabs.closeAll(except: index)
        // Prune any formattedTabIDs entries that no longer correspond
        // to an open tab. Cheaper than tracking every closed id.
        formattedTabIDs = keepID.map { Set([$0]) }.flatMap { kept in
            formattedTabIDs.intersection(kept)
        } ?? []
        updateDerived()
        startWatchingCurrentFile()
    }

    public func closeTabsToRight(of index: Int) {
        tabs.closeAllToRight(of: index)
        let openIDs = Set(tabs.tabs.map { $0.id })
        formattedTabIDs.formIntersection(openIDs)
        updateDerived()
        startWatchingCurrentFile()
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
        updateDerived()
        startWatchingCurrentFile()
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
                case .binary, .empty: break
                case .loaded, .preview, .error:
                    loadBinaryAsync(url: url, intoTabID: t.id)
                }
            }
        case .formatted:
            if let url = t.url, Formatter.SupportedFormat.detect(url) != nil {
                formattedTabIDs.insert(t.id)
            }
        case .source, .rendered, .table:
            formattedTabIDs.remove(t.id)
            if let url = t.url, case .binary = t.state {
                loadTextAsync(url: url, intoTabID: t.id)
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
        // Recompute the source-view diff stripe when the focused
        // file changes. Cheap-ish: shells `git diff` once per switch
        // (off-main); skipped when not inside a repo.
        refreshDiffMarks()
    }
}
