import SwiftUI
import ViewerCore

/// Sidebar accordion wrapper for `GitPanelView`. Provides the collapsible
/// "GIT" header consistent with Bookmarks / Search / Claude sections.
/// Hidden when the current root is outside a repo.
///
/// To host the panel elsewhere (right rail, detached window) instantiate
/// `GitPanelView` directly without this wrapper.
struct GitPanelSection: View {
    @ObservedObject var model: DocumentModel
    /// PERF #1: observe sidebar directly so `sidebar.rootURL` is fed
    /// to `.onChange` by the sidebar's own publisher rather than the
    /// (removed) DocumentModel forwarding.
    @ObservedObject var sidebar: SidebarModel
    /// The multi-repo registry. Observed directly so the panel re-syncs
    /// (follows the focused repo) on a `version` bump WITHOUT routing
    /// through DocumentModel.objectWillChange.
    @ObservedObject var trackedRepos: TrackedReposChannel
    @StateObject private var panel = GitPanelModel()
    @AppStorage("MarkdownViewer.sidebar.gitExpanded") private var isExpanded: Bool = true

    var body: some View {
        Group {
            if panel.repoRoot != nil {
                VStack(spacing: 0) {
                    header
                    if isExpanded {
                        GitPanelView(model: panel, doc: model, trackedRepos: trackedRepos)
                    }
                }
                .sidebarSectionContainer()
            } else {
                EmptyView()
            }
        }
        .onAppear { syncRepo() }
        // The registry drives the focused repo now; re-sync on its version
        // tick (status / tracked-root-set change) and on the current-file
        // change (focus may have moved to a tab in a different repo). The
        // sidebar.rootURL trigger stays so a folder reopen re-syncs even
        // before the registry settles.
        .onChange(of: trackedRepos.version) { _, _ in syncRepo() }
        .onChange(of: sidebar.rootURL) { _, _ in syncRepo() }
        .onChange(of: model.currentURL) { _, _ in syncRepo() }
        // Menu-triggered focus: expand the section + switch tab.
        .onChange(of: model.gitPanelFocusRequest) { _, _ in
            isExpanded = true
            switch model.gitPanelDesiredTab {
            case .status:  panel.selectTab(.status)
            case .log:     panel.selectTab(.log)
            case .stash:   panel.selectTab(.stash)
            case .trees:   panel.selectTab(.trees)
            case .remotes: panel.selectTab(.remotes)
            }
        }
        .accessibilityIdentifier("mdv.gitPanel")
    }

    private var header: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 4) {
                SidebarSectionHeaderLabel(
                    title: "Git",
                    isExpanded: isExpanded,
                    uiSize: model.uiSize
                )
                if let branch = panel.head?.branch {
                    Text(branch)
                        .font(.system(size: model.uiSize(10), design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let ahead = panel.head?.ahead, ahead > 0 {
                    Text("↑\(ahead)")
                        .font(.system(size: model.uiSize(9)))
                        .foregroundStyle(.tertiary)
                }
                if let behind = panel.head?.behind, behind > 0 {
                    Text("↓\(behind)")
                        .font(.system(size: model.uiSize(9)))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .sidebarHeaderRow()
        }
        .buttonStyle(.plain)
    }

    private func syncRepo() {
        // Follow the registry's focused root (selected tab's repo →
        // sidebar folder's repo → single tracked → most-recently-touched),
        // honoring an explicit picker pin until focus moves to a different
        // tracked repo. Replaces the old single-root `discoverRepo` path.
        panel.followFocus(
            model.repoFocus.focusedRoot,
            tracked: trackedRepos.trackedRoots
        )
    }
}
