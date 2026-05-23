import SwiftUI
import ViewerCore

/// Collapsible "Bookmarks" panel at the top of the sidebar. Lists
/// every pinned file/folder; click to open. Each entry has a context
/// menu for unpinning and reveal-in-Finder.
///
/// Filter chips and sort dropdown live in the header row so they're
/// reachable without expanding the section first:
///   - `F` (file) / `D` (directory) / `L` (line) toggle which kinds
///     of bookmarks appear. All on by default.
///   - The "Recent / Name / Created" menu picks the sort order.
struct BookmarksSection: View {
    @ObservedObject var model: DocumentModel
    @State private var isExpanded = true
    /// Height the body should occupy when expanded. Driven by
    /// `SidebarView`'s resizable-section divider; falls back to
    /// `SidebarConstants.sectionBodyHeight` outside that container.
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight
    @State private var showFiles = true
    @State private var showFolders = true
    @State private var showLines = true
    @State private var sortMode: SortMode = .recent

    enum SortMode: String, CaseIterable, Identifiable {
        case recent = "Recent"
        case name = "Name"
        case created = "Created"
        var id: String { rawValue }
    }

    /// Stable placeholder string for the empty state — read by the
    /// pure-logic test `BookmarksSectionEmptyTests`. Keep as a static
    /// so callers (and tests) can reach it without instantiating a
    /// View on the host.
    static let emptyPlaceholder: String = "No bookmarks yet."
    static let emptyFilterPlaceholder: String = "No bookmarks match this filter."

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { entry in
                            BookmarkRow(entry: entry, model: model)
                        }
                        if filtered.isEmpty {
                            SidebarEmptyPlaceholder(
                                message: model.bookmarks.isEmpty
                                    ? Self.emptyPlaceholder
                                    : Self.emptyFilterPlaceholder
                            )
                        }
                    }
                }
                .frame(height: bodyHeight)
            }
        }
        .sidebarSectionContainer()
        .accessibilityIdentifier("mdv.bookmarks")
    }

    /// Single-row header: chevron + label on the left, F/D/L filter
    /// chips + count + sort menu all on the right. Compact enough to
    /// reach without expanding the section first; matches the user's
    /// preference for one-line section chrome.
    private var headerRow: some View {
        HStack(spacing: 4) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text("BOOKMARKS")
                        .font(.system(size: model.uiSize(10), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            filterChip("F", isOn: $showFiles, help: "Show file bookmarks")
            filterChip("D", isOn: $showFolders, help: "Show directory bookmarks")
            filterChip("L", isOn: $showLines, help: "Show line bookmarks")
            Text("\(filtered.count)/\(model.bookmarks.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            Menu {
                ForEach(SortMode.allCases) { m in
                    Button {
                        sortMode = m
                    } label: {
                        HStack {
                            Text(m.rawValue)
                            if sortMode == m {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort by \(sortMode.rawValue)")
            .accessibilityIdentifier("mdv.bookmarks.sort")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func filterChip(_ label: String,
                            isOn: Binding<Bool>,
                            help: String) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            Text(label)
                .font(.system(size: model.uiSize(10), weight: .bold,
                              design: .monospaced))
                .frame(width: 18, height: 16)
                .background(isOn.wrappedValue
                            ? Color.accentColor.opacity(0.25)
                            : Color.secondary.opacity(0.08))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier("mdv.bookmarks.chip.\(label)")
    }

    /// Filter + sort the bookmark list using current chip / sort state.
    /// `model.bookmarks` is already kept fresh by the bookmark store
    /// observers; we just project it.
    private var filtered: [BookmarkEntry] {
        let allowed = model.bookmarks.filter { entry in
            if entry.line != nil { return showLines }
            // The store doesn't carry directory-ness; ask the
            // filesystem. Cheap on the typical bookmark count (<50);
            // BookmarkRow already does its own per-row stat.
            let isDir = Self.isDir(entry.url)
            return isDir ? showFolders : showFiles
        }
        switch sortMode {
        case .recent:
            // Sort by addedAt descending. Was relying on the store's
            // array order, but BookmarksStore.move(from:to:) lets the
            // user reorder manually — so the store's order is "user-
            // arranged", not "most recent."
            return allowed.sorted { $0.addedAt > $1.addedAt }
        case .name:
            return allowed.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
        case .created:
            return allowed.sorted { $0.addedAt < $1.addedAt }
        }
    }

    /// Bounded-size FS-stat cache for the directory-ness predicate.
    /// Bookmark URLs are stable for the row's life; the result rarely
    /// changes. Refreshed on app restart.
    nonisolated(unsafe) private static var dirCache: [URL: Bool] = [:]
    private static let dirCacheLock = NSLock()
    private static func isDir(_ url: URL) -> Bool {
        dirCacheLock.lock()
        if let hit = dirCache[url] {
            dirCacheLock.unlock()
            return hit
        }
        if dirCache.count > 512 { dirCache.removeAll(keepingCapacity: true) }
        dirCacheLock.unlock()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let value = isDir.boolValue
        dirCacheLock.lock()
        dirCache[url] = value
        dirCacheLock.unlock()
        return value
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
                    .font(.system(size: model.uiSize(12),
                                  weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let line = entry.line {
                    // Line bookmarks: show the line number as a chip
                    // so the row reads "file.swift :42" at a glance.
                    Text(":\(line)")
                        .font(.system(size: model.uiSize(10),
                                      design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                // Right-aligned relative date in the same row as the
                // name. Tertiary color + small monospaced font so it
                // reads as metadata, not content.
                Text(Self.relativeDate(entry.addedAt))
                    .font(.system(size: model.uiSize(10),
                                  design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .contentShape(Rectangle())
            .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .contextMenu {
            Button("Remove Bookmark") {
                model.removeBookmark(url: entry.url, line: entry.line)
            }
            // Folder-only: open this bookmark as a fresh session via
            // the coordinator. Gated on isFolder + the closure being
            // wired so non-folder bookmarks and test contexts don't
            // see a misleading menu item.
            if isFolder, let openInNewSession = model.openFolderInNewSession {
                Button("Open in New Session") {
                    openInNewSession(entry.url)
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            Divider()
            Button("Copy Path") { Pasteboard.copy(entry.url.path) }
        }
        .onAppear { isFolder = Self.statIsFolder(entry.url) }
    }

    private var tooltip: String {
        let pathSuffix = entry.line.map { ":\($0)" } ?? ""
        return entry.url.path + pathSuffix + "\nAdded " + Self.fullDate(entry.addedAt)
    }

    private static func statIsFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    /// "5m ago", "3h ago", "Yesterday", "Mar 12". Cheap enough to call
    /// per row per body — RelativeDateTimeFormatter is hoisted to a
    /// shared instance below.
    private static func relativeDate(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86400 { return "\(Int(secs / 3600))h ago" }
        if secs < 604800 { return "\(Int(secs / 86400))d ago" }
        return shortDateFormatter.string(from: date)
    }

    private static func fullDate(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
