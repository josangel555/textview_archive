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
    /// Stable placeholder strings — pinned via `BookmarksSectionEmptyTests`
    /// so a casual edit doesn't blank the empty-state envelope.
    static let emptyPlaceholder = "No bookmarks yet."
    static let emptyFilterPlaceholder = "No bookmarks match this filter."

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
    /// TSK-307: when on, show only bookmarks under the current sidebar root
    /// folder (a no-op when no folder is open).
    @State private var rootScopeOnly = false

    enum SortMode: String, CaseIterable, Identifiable {
        case recent = "Recent"
        case name = "Name"
        case created = "Created"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isExpanded {
                if let warning = model.lastBookmarkOpenWarning {
                    bookmarkWarningBanner(warning)
                }
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

    /// Inline warning shown when `openBookmark` refused a target whose
    /// filesystem identity no longer matches what was captured at add time
    /// (TSK-309 — a TOCTOU symlink/dir swap or a deleted target). A dismiss
    /// (X) clears it. The refused file is NOT opened.
    private func bookmarkWarningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: model.uiSize(11)))
            Text(message)
                .font(.system(size: model.uiSize(11)))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: { model.dismissBookmarkOpenWarning() }) {
                Image(systemName: "xmark")
                    .font(.system(size: model.uiSize(9), weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityIdentifier("mdv.bookmarks.warning.dismiss")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.12))
        .accessibilityIdentifier("mdv.bookmarks.warning")
    }

    /// Single-row header: chevron + label on the left, F/D/L filter
    /// chips + count + sort menu all on the right. Compact enough to
    /// reach without expanding the section first; matches the user's
    /// preference for one-line section chrome.
    private var headerRow: some View {
        HStack(spacing: 4) {
            Button(action: { isExpanded.toggle() }) {
                SidebarSectionHeaderLabel(
                    title: "Bookmarks",
                    isExpanded: isExpanded,
                    uiSize: model.uiSize,
                    dragKind: .bookmarks
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            filterChip("F", isOn: $showFiles, help: "Show file bookmarks")
            filterChip("D", isOn: $showFolders, help: "Show directory bookmarks")
            filterChip("L", isOn: $showLines, help: "Show line bookmarks")
            filterChip("R", isOn: $rootScopeOnly,
                       help: "Show only bookmarks under the current root folder")
            Text("\(filtered.count)/\(model.bookmarks.count)")
                .font(.system(size: model.uiSize(10), weight: .medium, design: .monospaced))
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
                    .font(.system(size: model.uiSize(9)))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .helpInfo(title: "Sort", description: "Sort by \(sortMode.rawValue)")
            .accessibilityIdentifier("mdv.bookmarks.sort")
        }
        .sidebarHeaderRow(uiSize: model.uiSize)
    }

    private func filterChip(_ label: String,
                            isOn: Binding<Bool>,
                            help: String) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            Text(label)
                .font(.system(size: model.uiSize(10), weight: .bold,
                              design: .monospaced))
                .frame(width: model.uiSize(18), height: model.uiSize(16))
                .background(isOn.wrappedValue
                            ? Color.accentColor.opacity(0.25)
                            : Color.secondary.opacity(0.08))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .helpInfo(title: label, description: help)
        .accessibilityIdentifier("mdv.bookmarks.chip.\(label)")
    }

    /// Filter + sort the bookmark list using current chip / sort state.
    /// `model.bookmarks` is already kept fresh by the bookmark store
    /// observers; we just project it.
    private var filtered: [BookmarkEntry] {
        var allowed = model.bookmarks.filter { entry in
            if entry.line != nil { return showLines }
            // The store doesn't carry directory-ness; ask the
            // filesystem. Cheap on the typical bookmark count (<50);
            // BookmarkRow already does its own per-row stat.
            let isDir = Self.isDir(entry.url)
            return isDir ? showFolders : showFiles
        }
        // TSK-307: optional root-folder scope — only bookmarks under the current
        // sidebar root (no-op when no folder is open).
        if rootScopeOnly { allowed = Self.underRoot(allowed, root: model.sidebar.rootURL) }
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

    /// TSK-307: keep only bookmarks at or under `root` (the root-folder scope
    /// filter). A nil root (no folder open) is a no-op → returns all. Pure +
    /// host-testable. Path-prefix match on standardized paths, with a trailing
    /// "/" so `/foo` doesn't spuriously match `/foobar`.
    nonisolated static func underRoot(_ entries: [BookmarkEntry], root: URL?) -> [BookmarkEntry] {
        guard let root else { return entries }
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return entries.filter { entry in
            let p = entry.url.standardizedFileURL.path
            return p == rootPath || p.hasPrefix(prefix)
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
            HStack(spacing: model.uiSize(6)) {
                FileIconView(
                    url: entry.url,
                    isDirectory: isFolder,
                    isExpanded: isFolder,
                    size: .tree,
                    scale: CGFloat(model.zoom)
                )
                .frame(width: FileIconView.side(for: .tree, scale: CGFloat(model.zoom)),
                       height: FileIconView.side(for: .tree, scale: CGFloat(model.zoom)))
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
            .padding(.horizontal, model.uiSize(10))
            .frame(height: model.uiSize(22))
            .contentShape(Rectangle())
            .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        // UIRESP-03: hover background + pointing-hand cursor so the row
        // reads as clickable. Suppress the style's hover fill on the
        // current-file row (it already carries an accent tint).
        .buttonStyle(RowHoverButtonStyle(cornerRadius: 0, suppressesHoverFill: isCurrent))
        // TSK-333: Delete-key removes a focused bookmark row (the
        // context-menu "Remove Bookmark" was the only path). The removal
        // is undoable via Edit→Undo (⌘Z, wired in TSK-330) since
        // `removeBookmark` pushes onto BookmarksStore's undo stack — so
        // an accidental Delete is one keystroke from recovery. `.delete`
        // is the Mac Backspace/⌫ key.
        .focusable()
        .onKeyPress(.delete) {
            model.removeBookmark(url: entry.url, line: entry.line)
            return .handled
        }
        // TSK-333: Delete-key removes a focused bookmark row (the
        // context-menu "Remove Bookmark" was the only path). The removal
        // is undoable via Edit→Undo (⌘Z, wired in TSK-330) since
        // `removeBookmark` pushes onto BookmarksStore's undo stack — so
        // an accidental Delete is one keystroke from recovery. `.delete`
        // is the Mac Backspace/⌫ key.
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
            // TSK-1256 / OwnerWishlist "Copy Reference": LINE-PRECISE mdv:// agent
            // reference (the bookmark's file + line) — an agent opens the exact spot.
            Button("Copy Reference") {
                Pasteboard.copy(ElementRef.file(path: entry.url.path, line: entry.line, endLine: nil).serialized)
            }
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
        return DisplayDateFormatter.string(from: date)
    }

    private static func fullDate(_ date: Date) -> String {
        DisplayDateFormatter.string(from: date)
    }
}
