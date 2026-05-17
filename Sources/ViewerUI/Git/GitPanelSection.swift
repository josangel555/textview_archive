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
    @StateObject private var panel = GitPanelModel()
    @AppStorage("MarkdownViewer.sidebar.gitExpanded") private var isExpanded: Bool = true

    var body: some View {
        Group {
            if panel.repoRoot != nil {
                VStack(spacing: 0) {
                    header
                    if isExpanded {
                        GitPanelView(model: panel, doc: model)
                    }
                }
            } else {
                EmptyView()
            }
        }
        .onAppear { syncRepo() }
        .onChange(of: model.sidebar.rootURL) { _, _ in syncRepo() }
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
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text("GIT")
                    .font(.system(size: model.uiSize(10), weight: .semibold))
                    .foregroundStyle(.secondary)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func syncRepo() {
        let discovered = RecentChangesSection.discoverRepo(
            sidebarRoot: model.sidebar.rootURL,
            currentURL: model.currentURL
        )
        panel.setRepoRoot(discovered)
    }
}
