import SwiftUI
import ViewerCore

/// Shared body factory for a single sidebar/tool-window panel (UX-E /
/// #227).
///
/// One panel kind renders the SAME content whether it lives in the LEFT
/// accordion (`SidebarView`) or in a free-standing docked tool window on
/// the RIGHT / BOTTOM rail (`DockedToolWindow`). Before UX-E that switch
/// lived inline in `SidebarView.panelView(for:)`; extracting it here is
/// the single-source-of-truth move — the accordion and the docked
/// containers can't drift in how they construct e.g. the Git panel's
/// `forcedShown` flag or the LSP panels' jump callbacks.
///
/// OBSERVATION DISCIPLINE (load-bearing, unchanged): this is a value-type
/// `@ViewBuilder` factory, NOT a `View`. The dependencies it threads
/// (`model` / `sidebar` / `trackedRepos` / `panelLayout`) are observed by
/// the panel sections themselves via their own `@ObservedObject`
/// properties — exactly as they were when the switch lived in
/// `SidebarView`. The factory adds no new observation surface.
///
/// `bodyHeight` is injected into each section via the existing
/// `\.sidebarSectionBodyHeight` environment value (the accordion's resize
/// channel). A docked tool window passes its own resolved fixed body
/// height through the same key, so the section's inner ScrollView sizes
/// to the tool window instead of the accordion clamp — no section code
/// changes.
@MainActor
enum SidebarPanelBody {

    /// Build the content for `kind`. Returns `EmptyView` for `.files`
    /// (the FILES tree is rendered inline by `SidebarView`, never docked)
    /// — the FILES tree is the flex-fill accordion root, not a fixed-size
    /// tool window, so it is intentionally not dockable.
    @ViewBuilder
    static func make(
        for kind: SidebarPanelKind,
        model: DocumentModel,
        sidebar: SidebarModel,
        trackedRepos: TrackedReposChannel,
        panelLayout: PanelLayoutStore,
        bodyHeight: CGFloat
    ) -> some View {
        switch kind {
        case .bookmarks:
            BookmarksSection(model: model)
                .environment(\.sidebarSectionBodyHeight, bodyHeight)
        case .searchAnywhere:
            SearchAnywhereSection(model: model, sidebar: sidebar)
                .environment(\.sidebarSectionBodyHeight, bodyHeight)
        case .git:
            GitPanelSection(model: model, sidebar: sidebar, trackedRepos: trackedRepos,
                            forcedShown: panelLayout.override(for: .git) == .shown)
                .environment(\.sidebarSectionBodyHeight, bodyHeight)
        case .claudeTimeline:
            ClaudeTimelineSection(model: model, sidebar: sidebar,
                                  forcedShown: panelLayout.override(for: .claudeTimeline) == .shown)
                .environment(\.sidebarSectionBodyHeight, bodyHeight)
        case .lspOutline:
            LSPOutlineWrapper(model: model,
                              forcedShown: panelLayout.override(for: .lspOutline) == .shown)
                .environment(\.sidebarSectionBodyHeight, bodyHeight)
        case .lspNavigation:
            LSPNavigationPanel(
                store: model.lspNavigation,
                onJump: { loc in
                    guard let url = URL(string: loc.uri) else { return }
                    if !model.selectTab(forURL: url) {
                        model.openPath(url)
                    }
                    model.scrollSource(toLine: loc.range.start.line + 1)
                },
                onSearchWorkspaceSymbols: { query in
                    SidebarPanelBody.runWorkspaceSymbolQuery(query, model: model)
                },
                uiSize: model.uiSize
            )
            .environment(\.sidebarSectionBodyHeight, bodyHeight)
        case .lspProblems:
            LSPProblemsPanel(
                store: model.lspDiagnostics,
                onJump: { url, line in
                    if !model.selectTab(forURL: url) {
                        model.openPath(url)
                    }
                    model.scrollSource(toLine: line)
                },
                uiSize: model.uiSize,
                activeFileUnanalyzed: { model.activeFileUnanalyzedByLSP }
            )
            .environment(\.sidebarSectionBodyHeight, bodyHeight)
        case .recentlyOpened:
            RecentlyOpenedSection(model: model)
                .environment(\.sidebarSectionBodyHeight, bodyHeight)
        case .pluginSections:
            PluginSidebarSections(model: model)
                .environment(\.sidebarSectionBodyHeight, bodyHeight)
        case .files:
            // FILES is the flex-fill accordion root, rendered inline by
            // SidebarView. It is intentionally not dockable.
            EmptyView()
        }
    }

    /// Fire a `workspace/symbol` query against the live LSP clients.
    /// Lifted from `SidebarView.runWorkspaceSymbolQuery` so the docked LSP
    /// navigation panel drives the SAME sequenced dispatch (each new query
    /// cancels the previous) as the accordion copy.
    static func runWorkspaceSymbolQuery(_ query: String, model: DocumentModel) {
        WorkspaceSymbolDispatch.shared.cancel()
        let token = LSPCancellationToken()
        WorkspaceSymbolDispatch.shared.current = token
        let store = model.lspNavigation
        store.startLoading(mode: .workspaceSymbols, query: query)
        let pool = model.lspPool
        Task { @MainActor in
            do {
                let syms = try await pool.workspaceSymbol(query: query, token: token)
                guard !Task.isCancelled else { return }
                store.setWorkspaceSymbols(query: query, symbols: syms)
            } catch is CancellationError {
                // Newer query — leave the store alone.
            } catch {
                store.setError("\(error)")
            }
        }
    }
}
