import SwiftUI
import ViewerCore

/// Trees sub-tab: worktree manager. Click a non-current row to open its
/// path in the sidebar (switching active session would need more
/// plumbing; v1 just navigates the file tree).
struct GitWorktreesTab: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject var doc: DocumentModel

    var body: some View {
        if model.worktreeEntries.isEmpty {
            Text("No additional worktrees.")
                .font(.system(size: doc.uiSize(11)))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.worktreeEntries, id: \.path) { row($0) }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private func row(_ w: GitClient.WorktreeEntry) -> some View {
        Button(action: { open(w) }) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(displayPath(w.path))
                        .font(.system(size: doc.uiSize(12), design: .monospaced))
                        .foregroundStyle(w.state == .current ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    chip(for: w.state)
                }
                if let branch = w.branch {
                    Text("⎇ \(branch)")
                        .font(.system(size: doc.uiSize(10)))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 18)
                } else {
                    Text("(detached \(w.head))")
                        .font(.system(size: doc.uiSize(10), design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 18)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(w.state == .current ? Color.accentColor.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(w.path.path)
    }

    @ViewBuilder
    private func chip(for state: GitClient.WorktreeEntry.State) -> some View {
        switch state {
        case .current:
            chipText("CURRENT", color: .accentColor)
        case .locked:
            chipText("LOCKED", color: .orange)
        case .prunable:
            chipText("PRUNABLE", color: .red)
        case .normal:
            EmptyView()
        }
    }

    private func chipText(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.system(size: doc.uiSize(8), weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 2))
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private func open(_ w: GitClient.WorktreeEntry) {
        guard w.state != .prunable else { return }
        doc.openPath(w.path)
    }
}
