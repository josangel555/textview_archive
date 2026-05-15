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
                            .font(.system(size: 10, weight: .semibold))
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
                .frame(maxHeight: rowsHeightCap)
            }
        }
        .accessibilityIdentifier("mdv.bookmarks")
    }

    /// Cap the bookmarks panel so a huge list doesn't push the file
    /// tree off-screen. ~6 rows visible by default; the panel scrolls
    /// past that.
    private var rowsHeightCap: CGFloat {
        let count = max(1, min(model.bookmarks.count, 6))
        return CGFloat(count) * 22
    }
}

private struct BookmarkRow: View {
    let entry: BookmarkEntry
    @ObservedObject var model: DocumentModel

    private var isFolder: Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: entry.url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private var isCurrent: Bool { model.currentURL == entry.url }

    var body: some View {
        Button(action: { model.openPath(entry.url) }) {
            HStack(spacing: 6) {
                Image(systemName: isFolder ? "folder.fill" : "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(entry.displayName)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .contentShape(Rectangle())
            .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(entry.url.path)
        .contextMenu {
            Button("Remove Bookmark") {
                model.removeBookmark(entry.url)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }
    }
}
