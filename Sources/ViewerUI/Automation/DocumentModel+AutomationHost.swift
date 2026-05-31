import AppKit
import Foundation
import ViewerCore
import ViewerKit

/// `DocumentModel` is the live SwiftUI view model — it already owns
/// every state-mutating verb the MCP layer needs. This file just
/// re-exposes those methods through the `AutomationHost` protocol so
/// `MCPServer` can call them without importing AppKit/SwiftUI itself.
///
/// Nothing here is policy: argument validation (path-in-home, size
/// limits, etc.) lives in `MCPToolCatalog`. Conformance is mechanical.
@MainActor
extension DocumentModel: AutomationHost {

    public func automationOpenPath(_ url: URL, newTab: Bool) -> UUID {
        if newTab {
            openInNewTab(url)
        } else {
            open(url: url)
        }
        // `open(url:)` / `openInNewTab(_:)` always end with a valid
        // selected tab — the one we just opened. Returning its id
        // lets clients chain `select_tab` calls against it later.
        return tabs.selected?.id ?? UUID()
    }

    @discardableResult
    public func automationSelectTab(byIndex index: Int?, byId id: UUID?) -> Bool {
        if let id {
            guard let i = tabs.tabs.firstIndex(where: { $0.id == id }) else { return false }
            if tabs.selectedIndex == i { return false }
            selectTab(at: i)
            return true
        }
        if let index {
            // External API is 1-based; internal is 0-based.
            let zero = index - 1
            guard tabs.tabs.indices.contains(zero) else { return false }
            if tabs.selectedIndex == zero { return false }
            selectTab(at: zero)
            return true
        }
        return false
    }

    public func automationSetViewMode(_ mode: ViewMode) {
        setCurrentViewMode(mode)
    }

    public func automationGotoLine(_ line: Int, column: Int?) {
        // Column isn't honoured by `scrollSource(toLine:)` — the
        // scroll target is line-granular. We accept the arg for
        // forward-compat; ignoring is documented behaviour.
        _ = column
        scrollSource(toLine: line)
    }

    public func automationFind(_ query: FindQuery) -> [FindMatch] {
        // Pull the source text out of the currently-selected tab.
        // For non-text tabs (binary / preview / error / empty) there's
        // nothing to search.
        guard let tab = tabs.selected else { return [] }
        let text: String
        switch tab.state {
        case .loaded(let f):     text = f.contents
        case .binary, .preview, .error, .empty, .loading, .hostedView:
            return []
        }
        // FindEngine throws only on invalid regex — surface as an
        // empty result here; the catalog can be enhanced later to
        // round-trip a tool-error response.
        return (try? FindEngine().search(in: text, query: query)) ?? []
    }

    public func automationVisibleText() -> String {
        guard let tab = tabs.selected else { return "" }
        switch tab.state {
        case .loaded(let f): return f.contents
        case .binary, .preview, .error, .empty, .loading, .hostedView:
            return ""
        }
    }

    public func automationCurrentState() -> AutomationState {
        let descriptors: [AutomationState.TabDescriptor] = tabs.tabs.map { t in
            .init(
                id: t.id.uuidString,
                path: t.url?.path,
                title: t.title,
                viewMode: t.viewMode.rawValue
            )
        }
        return AutomationState(
            tabs: descriptors,
            selectedTabIndex: tabs.selectedIndex,
            viewMode: currentViewMode.rawValue,
            zoom: zoom,
            sidebarRoot: sidebar.rootURL?.path,
            isPalettePresented: isPalettePresented
        )
    }

    public func automationToggleBookmark(line: Int?) {
        if let line {
            // Mirror the menu path: toggleCurrentLineBookmark uses the
            // caret line. For arbitrary line bookmarks we go through
            // the store directly with the current URL.
            guard let url = currentURL else { return }
            let display = "\(url.lastPathComponent):\(line)"
            _ = bookmarksStore.toggle(url: url, displayName: display, line: line)
            refreshBookmarks()
        } else {
            toggleCurrentTabBookmark()
        }
    }

    public func automationListBookmarks() -> [BookmarkEntry] {
        bookmarks
    }

    public func automationSnapshotPNG() throws -> Data {
        // Find the key/main window for the app. In headless `--mcp-stdio`
        // mode there isn't one, so this throws — the tool dispatcher
        // surfaces it as a `tools/call` error.
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        guard let win = window, let content = win.contentView else {
            throw MCPError.toolFailed("no window available for snapshot")
        }
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw MCPError.toolFailed("could not create bitmap representation")
        }
        content.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw MCPError.toolFailed("PNG encode failed")
        }
        return data
    }
}
