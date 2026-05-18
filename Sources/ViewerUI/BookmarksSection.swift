import SwiftUI
import ViewerCore

/// Collapsible "Bookmarks" panel at the top of the sidebar. Lists
/// every pinned file/folder; click to open. Each entry has a context
/// menu for unpinning and reveal-in-Finder.
struct BookmarksSection: View {
    @ObservedObject var model: DocumentModel
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10)
                        Text("BOOKMARKS")
                            .font(.system(size: model.uiSize(10), weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(model.bookmarks.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.bookmarks) { entry in
                            BookmarkRow(entry: entry, model: model)
                        }
                    }
                }
                .frame(height: SidebarConstants.sectionBodyHeight)
            }
        }
        .accessibilityIdentifier("mdv.bookmarks")
    }

}

private struct BookmarkRow: View {
    let entry: BookmarkEntry
    @ObservedObject var model: DocumentModel

    /// `FileManager.fileExists` is a syscall. As a computed property
    /// this fired per row per body re-eval (every model mutation —
    /// every keystroke in a focused find bar). Cache the result on
    /// `.onAppear`; the bookmark target is stable for the row's life.
    @State private var isFolder: Bool = false

    private var isCurrent: Bool { model.currentURL == entry.url }

    var body: some View {
        Button(action: { model.openBookmark(entry) }) {
            HStack(spacing: 6) {
                FileIconView(
                    url: entry.url,
                    isDirectory: isFolder,
                    isExpanded: isFolder,
                    size: .tree
                )
                .frame(width: 16, height: 16)
                Text(entry.displayName)
                    .font(.system(size: model.uiSize(12), weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let line = entry.line {
                    // Line bookmarks: show the line number as a chip so
                    // the row reads "file.swift :42" at a glance.
                    Text(":\(line)")
                        .font(.system(size: model.uiSize(10), design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .contentShape(Rectangle())
            .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(entry.line.map { "\(entry.url.path):\($0)" } ?? entry.url.path)
        .contextMenu {
            Button("Remove Bookmark") {
                model.removeBookmark(url: entry.url, line: entry.line)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }
        .onAppear { isFolder = Self.statIsFolder(entry.url) }
    }

    private static func statIsFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }
}
