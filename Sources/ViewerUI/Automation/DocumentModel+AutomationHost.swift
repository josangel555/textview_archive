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

    public func automationRunVerb(_ verbLine: String) -> Bool {
        // Same dispatch as invokeCommand / --script: ScriptVerb.apply with the
        // model + sessions coordinator. No coordinator wired (previews) → no-op.
        guard let sessions = sessionsCoordinator else { return false }
        return ScriptVerb.apply(verb: verbLine, to: self, sessions: sessions)
    }

    public func automationSetZoom(_ zoom: Double) {
        // The catalog already clamped to [minZoom, maxZoom]; assign
        // verbatim. `zoom`'s didSet persists it through PreferencesStore
        // (same path as zoomIn/zoomOut), so an automated zoom survives a
        // relaunch exactly like a menu-driven one.
        self.zoom = zoom
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
        // Routed through the `.find` gate (TSK-645): Rust core when on,
        // the Swift FindEngine otherwise. Invalid patterns surface as an
        // empty result (the historical contract); the catalog can be
        // enhanced later to round-trip a tool-error response.
        return RustFindAdapter.search(in: text, query: query)
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
                viewMode: t.viewMode.rawValue,
                isDirty: t.isDirty
            )
        }
        // Emit `selectedTabIndex` 1-based to match the `select_tab` tool,
        // which consumes a 1-based `byIndex` (`let zero = index - 1`). The
        // internal `tabs.selectedIndex` is 0-based, so we add 1 here; this
        // makes the `current_state` -> `select_tab` round-trip an identity
        // (read the index, feed it straight back) instead of off-by-one.
        // `nil` (no selection) is preserved as `nil`.
        // App-level session list — only when a coordinator is wired (the
        // main.swift launch path; nil under previews/bare-model tests → empty).
        let activeSessionID = sessionsCoordinator?.core.activeID
        let sessionDescriptors: [AutomationState.SessionDescriptor] =
            sessionsCoordinator?.core.sessions.map { snap in
                .init(
                    id: snap.id.uuidString,
                    displayName: snap.displayName,
                    isActive: activeSessionID == snap.id
                )
            } ?? []
        return AutomationState(
            tabs: descriptors,
            selectedTabIndex: tabs.selectedIndex.map { $0 + 1 },
            viewMode: currentViewMode.rawValue,
            zoom: zoom,
            sidebarRoot: sidebar.rootURL?.path,
            isPalettePresented: isPalettePresented,
            isSplitOpen: isSplitOpen,
            vimModeEnabled: vimModeEnabled,
            sessions: sessionDescriptors
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
