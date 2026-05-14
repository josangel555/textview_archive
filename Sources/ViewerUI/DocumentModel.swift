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
    @Published public var sidebarWidth: Double {
        didSet { preferences.setSidebarWidth(sidebarWidth) }
    }
    @Published public var isPalettePresented: Bool = false
    public let sidebar: SidebarModel

    private let controller: DocumentController
    public let history: HistoryStore
    private let preferences: PreferencesStore

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
    }

    public func openFolder(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        sidebar.setRoot(resolved)
        history.record(url: resolved, kind: .folder)
        recents = history.recent()
        preferences.lastFolderURL = resolved
    }

    /// Restores the most recently opened folder (if any). Call from app launch.
    public func restorePreviousFolderIfAvailable() {
        guard let url = preferences.lastFolderURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        openFolder(url)
    }

    public func setSidebarWidth(_ width: Double) {
        let clamped = min(max(width, PreferencesStore.minSidebarWidth),
                          PreferencesStore.maxSidebarWidth)
        sidebarWidth = clamped
    }

    public func showPalette() { isPalettePresented = true }
    public func dismissPalette() { isPalettePresented = false }

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
            get: { [unowned self] in self.currentViewMode },
            set: { [unowned self] in self.setCurrentViewMode($0) }
        )
    }

    // MARK: Opening files

    /// Opens a URL into the current tab if it's blank, switches to an existing
    /// tab that shows the URL, or appends a new tab.
    public func open(url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let state = controller.open(url: resolved)
        let viewMode = currentViewMode
        tabs.openOrReveal(url: resolved, state: state, viewMode: viewMode)
        updateDerived()
        if case .loaded = state {
            history.record(url: resolved, kind: .file)
            recents = history.recent()
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
    }

    public func closeCurrentTab() {
        if let i = tabs.selectedIndex {
            closeTab(at: i)
        }
    }

    public func selectTab(at index: Int) {
        tabs.select(at: index)
        updateDerived()
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
        // Manually publish — tabs is @Published but mutating a property of a
        // value in an array doesn't always re-emit. Re-assign explicitly.
        let snapshot = tabs
        tabs = snapshot
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
