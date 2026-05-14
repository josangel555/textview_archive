import SwiftUI
import ViewerCore

struct SidebarView: View {
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let root = sidebar.rootURL {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        FileRowView(
                            node: FileNode(url: root, name: root.lastPathComponent, isDirectory: true),
                            depth: 0,
                            sidebar: sidebar,
                            model: model
                        )
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Spacer()
                Text("No folder open")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            }
        }
        .frame(minWidth: 180, idealWidth: 240)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text(sidebar.rootURL?.lastPathComponent ?? "Files")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Toggle("Show hidden", isOn: $sidebar.includeHidden)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
                .help("Show files starting with '.'")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct GitStatusBadge: View {
    let status: GitStatusEntry.Status

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 12, height: 12)
            .help(label)
    }

    private var color: Color {
        switch status {
        case .modified:   return .orange
        case .added:      return .green
        case .deleted:    return .red
        case .renamed, .copied: return .blue
        case .untracked, .ignored: return .secondary
        case .conflicted: return .red
        }
    }

    private var label: String {
        switch status {
        case .modified:   return "Modified"
        case .added:      return "Added"
        case .deleted:    return "Deleted"
        case .renamed:    return "Renamed"
        case .copied:     return "Copied"
        case .untracked:  return "Untracked"
        case .ignored:    return "Ignored"
        case .conflicted: return "Conflict"
        }
    }
}

private struct FileRowView: View {
    let node: FileNode
    let depth: Int
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if node.isDirectory {
                    Image(systemName: sidebar.isExpanded(node.url) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 12)
                        .foregroundStyle(.secondary)
                } else {
                    Spacer().frame(width: 12)
                }
                Image(systemName: icon(for: node))
                    .font(.system(size: 11))
                    .frame(width: 14)
                    .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                Text(node.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let status = sidebar.gitStatus(for: node.url) {
                    GitStatusBadge(status: status)
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .padding(.vertical, 3)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
            .onTapGesture(count: 2) {
                if node.isDirectory {
                    sidebar.toggleExpansion(node.url)
                } else {
                    model.open(url: node.url)
                }
            }
            .onTapGesture {
                if node.isDirectory {
                    sidebar.toggleExpansion(node.url)
                } else {
                    model.open(url: node.url)
                }
            }

            if node.isDirectory && sidebar.isExpanded(node.url) {
                ForEach(sidebar.children(of: node.url)) { child in
                    FileRowView(node: child, depth: depth + 1,
                                sidebar: sidebar, model: model)
                }
            }
        }
    }

    private var isCurrent: Bool {
        model.currentURL == node.url
    }

    private func gitColor(_ status: GitStatusEntry.Status) -> Color {
        switch status {
        case .modified:   return .orange
        case .added:      return .green
        case .deleted:    return .red
        case .renamed:    return .blue
        case .copied:     return .blue
        case .untracked:  return .secondary
        case .ignored:    return .secondary
        case .conflicted: return .red
        }
    }

    private func icon(for node: FileNode) -> String {
        if node.isDirectory {
            return sidebar.isExpanded(node.url) ? "folder.fill" : "folder"
        }
        let ext = node.url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdown", "mkd": return "doc.richtext"
        case "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "hpp":
            return "chevron.left.forwardslash.chevron.right"
        case "html", "htm": return "globe"
        case "json", "yaml", "yml", "toml", "xml": return "curlybraces"
        default: return "doc.plaintext"
        }
    }
}
