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
                ScrollViewReader { proxy in
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
                    // CRIT-6: keep keyboard-selected row visible.
                    .onChange(of: sidebar.selectedURL) { _, new in
                        if let url = new { proxy.scrollTo(url, anchor: .center) }
                    }
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
        .background(
            SidebarKeyMonitor(
                isActive: sidebar.isVisible && !model.isPalettePresented
            ) { key in
                switch key {
                case .up:    sidebar.selectPrevious()
                case .down:  sidebar.selectNext()
                case .left:  sidebar.collapseOrFocusParent()
                case .right: sidebar.expandOrFocusFirstChild()
                case .ret:
                    if let url = sidebar.selectedURL {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                           isDir.boolValue {
                            sidebar.toggleExpansion(url)
                        } else {
                            model.open(url: url)
                        }
                    }
                case .escape:
                    return false  // let other handlers (palette dismiss) see it
                }
                return true
            }
        )
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

private struct FileRowContextMenu: View {
    let node: FileNode
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var model: DocumentModel

    var body: some View {
        if !node.isDirectory {
            Button("Open") { model.open(url: node.url) }
            Button("Open in New Tab") { model.openInNewTab(node.url) }
            Divider()
        } else {
            Button(sidebar.isExpanded(node.url) ? "Collapse" : "Expand") {
                sidebar.toggleExpansion(node.url)
            }
            Divider()
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
        Button("Copy Relative Path") {
            let rel: String
            if let root = sidebar.rootURL,
               node.url.path.hasPrefix(root.path) {
                rel = String(node.url.path.dropFirst(root.path.count + 1))
            } else {
                rel = node.url.lastPathComponent
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rel, forType: .string)
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
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
            Button(action: activate) {
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
                .background(rowBackground)
            }
            .buttonStyle(.plain)
            .id(node.url)  // for ScrollViewReader.scrollTo
            .help(node.url.path)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .contextMenu {
                FileRowContextMenu(node: node, sidebar: sidebar, model: model)
            }

            if node.isDirectory && sidebar.isExpanded(node.url) {
                ForEach(sidebar.children(of: node.url)) { child in
                    FileRowView(node: child, depth: depth + 1,
                                sidebar: sidebar, model: model)
                }
            }
        }
    }

    private func activate() {
        sidebar.setSelected(node.url)
        if node.isDirectory {
            sidebar.toggleExpansion(node.url)
        } else {
            model.open(url: node.url)
        }
    }

    /// Selected (keyboard) and current (opened) get distinct shading so users
    /// can tell at a glance which row is about to be activated by ↵.
    private var rowBackground: Color {
        let isSelected = sidebar.selectedURL == node.url
        if isCurrent { return Color.accentColor.opacity(0.20) }
        if isSelected { return Color(nsColor: .alternateSelectedControlColor).opacity(0.25) }
        return Color.clear
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if node.isDirectory {
            parts.append(sidebar.isExpanded(node.url) ? "Folder expanded" : "Folder collapsed")
        } else {
            parts.append("File")
        }
        parts.append(node.name)
        if let s = sidebar.gitStatus(for: node.url) {
            parts.append("git: \(s.rawValue)")
        }
        if isCurrent { parts.append("currently open") }
        return parts.joined(separator: ", ")
    }

    private var isCurrent: Bool {
        model.currentURL == node.url
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
