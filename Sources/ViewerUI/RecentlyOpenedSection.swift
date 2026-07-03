import SwiftUI
import ViewerCore

/// Collapsible "Recent" sidebar panel (item8): lists recently-opened
/// files/folders newest-first from the global `HistoryStore`
/// (`model.recents`). Click a row to reopen. Global (not root-scoped) —
/// the per-session-filtered variant rides session independence later.
///
/// Mirrors `BookmarksSection`'s chrome so the accordion stays consistent.
struct RecentlyOpenedSection: View {
    /// Stable placeholder — pinned by `BookmarksSectionEmptyTests`. Carries
    /// the what-fills-this hint (TSK-1464).
    static let emptyPlaceholder = "No recent files yet — files and folders you open appear here."

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
        HStack(spacing: 4) {
            Button(action: { isExpanded.toggle() }) {
                SidebarSectionHeaderLabel(
                    title: "Recent",
                    isExpanded: isExpanded,
                    uiSize: model.uiSize,
                    dragKind: .recentlyOpened
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if !model.recents.isEmpty {
                Text("\(model.recents.count)")
                    .font(.system(size: model.uiSize(10), weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            // TSK-1464 — clean-up menu: drop entries whose files are gone.
            // A SIBLING of the expand button (matching BookmarksSection's
            // header layout) so it actually receives clicks.
            Menu {
                Button("Remove Missing Entries") {
                    _ = model.pruneMissingRecents()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: model.uiSize(9)))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .helpInfo(title: "Clean up",
                      description: "Remove recents whose files no longer exist")
            .accessibilityIdentifier("mdv.recentlyOpened.cleanup")
        }
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
            // TSK-1256 "Copy Reference": mdv:// agent reference (file form).
            Button("Copy Reference") {
                Pasteboard.copy(ElementRef.file(path: entry.url.path, line: nil, endLine: nil).serialized)
            }
            Button("Reveal in Finder") { Finder.reveal(entry.url) }
            Divider()
            // TSK-1464 — drop just this entry (the store API existed with no UI).
            Button("Remove from Recents") { model.removeRecent(entry.url) }
        }
        .accessibilityIdentifier("mdv.recentlyOpened.row")
    }
}
