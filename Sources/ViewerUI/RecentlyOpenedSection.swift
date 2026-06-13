import SwiftUI
import ViewerCore

/// Collapsible "Recent" sidebar panel (item8): lists recently-opened
/// files/folders newest-first from the global `HistoryStore`
/// (`model.recents`). Click a row to reopen. Global (not root-scoped) —
/// the per-session-filtered variant rides session independence later.
///
/// Mirrors `BookmarksSection`'s chrome so the accordion stays consistent.
struct RecentlyOpenedSection: View {
    /// Stable placeholder — pinned by `RecentlyOpenedSectionTests`.
    static let emptyPlaceholder = "No recently-opened files."

    @ObservedObject var model: DocumentModel
    @State private var isExpanded = true
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.recents) { entry in
                            RecentRow(entry: entry, model: model)
                        }
                        if model.recents.isEmpty {
                            SidebarEmptyPlaceholder(message: Self.emptyPlaceholder)
                        }
                    }
                }
                .frame(height: bodyHeight)
            }
        }
        .sidebarSectionContainer()
        .accessibilityIdentifier("mdv.recentlyOpened")
    }

    private var header: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 4) {
                SidebarSectionHeaderLabel(
                    title: "Recent",
                    isExpanded: isExpanded,
                    uiSize: model.uiSize,
                    dragKind: .recentlyOpened
                )
                Spacer()
                if !model.recents.isEmpty {
                    Text("\(model.recents.count)")
                        .font(.system(size: model.uiSize(10), weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarHeaderRow(uiSize: model.uiSize)
    }
}

private struct RecentRow: View {
    let entry: HistoryEntry
    @ObservedObject var model: DocumentModel

    var body: some View {
        Button(action: { model.openPath(entry.url) }) {
            HStack(spacing: model.uiSize(6)) {
                FileIconView(url: entry.url,
                             isDirectory: entry.kind == .folder,
                             size: .tree,
                             scale: CGFloat(model.zoom))
                    .frame(width: FileIconView.side(for: .tree, scale: CGFloat(model.zoom)),
                           height: FileIconView.side(for: .tree, scale: CGFloat(model.zoom)))
                Text(entry.displayName)
                    .font(.system(size: model.uiSize(11)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)   // the name wins space over the folder hint
                // Grey containing-folder hint (TSK-763) — disambiguates
                // same-named recents (IntelliJ style). Omitted when there's
                // no meaningful parent.
                if let folder = entry.parentFolderLabel {
                    Text(folder)
                        .font(.system(size: model.uiSize(10)))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("mdv.recentlyOpened.row.folder")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, model.uiSize(10))
            .padding(.vertical, model.uiSize(3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .helpInfo(title: entry.displayName, description: entry.url.path)
        .contextMenu {
            Button("Copy Path") { Pasteboard.copy(entry.url.path) }
            Button("Reveal in Finder") { Finder.reveal(entry.url) }
        }
        .accessibilityIdentifier("mdv.recentlyOpened.row")
    }
}
