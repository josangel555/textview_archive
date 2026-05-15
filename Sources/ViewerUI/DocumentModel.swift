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
    @Published public private(set) var windowTitle: String = "MarkdownViewer"
    @Published public private(set) var recents: [HistoryEntry] = []
    /// Width of the sidebar in points. Mutated frequently during a drag —
    /// see `setSidebarWidthLive` (no persistence) vs `setSidebarWidth`
    /// (persists immediately).
    @Published public var sidebarWidth: Double

    /// Zoom multiplier applied to both the rendered view (`WKWebView.pageZoom`)
    /// and the source view (font-size). 1.0 = system default.
    @Published public var zoom: Double {
        didSet { preferences.zoom = zoom }
    }
    @Published public var isPalettePresented: Bool = false
    public let sidebar: SidebarModel

    private let controller: DocumentController
    public let history: HistoryStore
    private let preferences: PreferencesStore
    private var fileWatcher: FileWatcher?
    private var watchedURL: URL?

    public init(
        controller: DocumentController = DocumentController(),
        history: HistoryStore = HistoryStore(storeURL: HistoryStore.defaultStoreURL()),
        sidebar: SidebarModel = SidebarModel(),
        preferences: PreferencesStore = PreferencesStore()
    ) {
        self.controller = controller
        self.history = history
        self.sidebar = sidebar
        self.preferences = preferences
        self.recents = history.recent()
        self.sidebarWidth = preferences.sidebarWidth
        self.zoom = preferences.zoom
    }

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

    public func showRenderedFindBar() { isRenderedFindBarPresented = true }
    public func dismissRenderedFindBar() {
        isRenderedFindBarPresented = false
        renderedFindQuery = ""
    }
    public func renderedFindNext() { renderedFindNextRequest &+= 1 }
    public func renderedFindPrev() { renderedFindPrevRequest &+= 1 }

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
    public var currentFilePath: String? {
        guard let url = currentURL else { return nil }
        let home = NSHomeDirectory()
        let path = url.path
        if !home.isEmpty, path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
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
        if forceNewTab {
            tabs.append(Tab(url: resolved, state: state, viewMode: .rendered))
        } else {
            tabs.openOrReveal(url: resolved, state: state, viewMode: currentViewMode)
        }
        updateDerived()
        // Both text and binary opens count as a successful "user saw this
        // file"; record either as a recent. Errors don't.
        switch state {
        case .loaded, .binary:
            history.record(url: resolved, kind: .file)
            recents = history.recent()
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
        tabs.close(at: index)
        updateDerived()
        startWatchingCurrentFile()
    }

    public func closeCurrentTab() {
        if let i = tabs.selectedIndex {
            closeTab(at: i)
        }
    }

    public func closeOtherTabs(keeping index: Int) {
        tabs.closeAll(except: index)
        updateDerived()
        startWatchingCurrentFile()
    }

    public func closeTabsToRight(of index: Int) {
        tabs.closeAllToRight(of: index)
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
        t.viewMode = mode
        tabs.replace(at: i, with: t)
    }

    // MARK: Recents

    public func clearRecents() {
        history.clear()
        recents = []
    }

    // MARK: Internal

    private func updateDerived() {
        windowTitle = tabs.selected?.title ?? "MarkdownViewer"
    }
}
