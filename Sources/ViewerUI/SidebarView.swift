import SwiftUI
import ViewerCore

struct SidebarView: View {
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var model: DocumentModel

    /// File-tree accordion state. Persisted across the session via
    /// `@AppStorage` so the user's last collapse choice survives a
    /// tab switch (DocumentModel sub-views recreate this view).
    @AppStorage("MarkdownViewer.sidebar.filesExpanded") private var filesExpanded: Bool = true

    // MARK: - Resizable section divider
    //
    // One `@AppStorage`-backed height per resizable section. The
    // `ResizableSectionDivider` between two sections mutates the
    // binding for the section above it; the section reads its
    // override via `\.sidebarSectionBodyHeight` (Environment) and
    // sizes its body accordingly. FILES at the bottom keeps the
    // flex-fill behaviour (`maxHeight: .infinity`) and intentionally
    // does NOT get an entry here.
    //
    // Keys are sourced from `SidebarSection` (ViewerCore) so the
    // string constants live in one place — easier to audit, easier
    // to migrate on rename.
    @AppStorage(SidebarPanel.bookmarks.appStorageKey)
    private var bookmarksHeight: Double = Double(SidebarPanel.bookmarks.defaultHeight)
    @AppStorage(SidebarPanel.searchAnywhere.appStorageKey)
    private var searchHeight: Double = Double(SidebarPanel.searchAnywhere.defaultHeight)
    @AppStorage(SidebarPanel.gitPanel.appStorageKey)
    private var gitHeight: Double = Double(SidebarPanel.gitPanel.defaultHeight)
    @AppStorage(SidebarPanel.claudeTimeline.appStorageKey)
    private var claudeHeight: Double = Double(SidebarPanel.claudeTimeline.defaultHeight)
    @AppStorage(SidebarPanel.lspOutline.appStorageKey)
    private var lspHeight: Double = Double(SidebarPanel.lspOutline.defaultHeight)
    @AppStorage(SidebarPanel.lspNavigation.appStorageKey)
    private var lspNavHeight: Double = Double(SidebarPanel.lspNavigation.defaultHeight)
    @AppStorage(SidebarPanel.lspProblems.appStorageKey)
    private var lspProblemsHeight: Double = Double(SidebarPanel.lspProblems.defaultHeight)
    @AppStorage(SidebarPanel.pluginSections.appStorageKey)
    private var pluginHeight: Double = Double(SidebarPanel.pluginSections.defaultHeight)

    /// `CGFloat` binding adapter — `@AppStorage` only natively stores
    /// `Double`; the divider expects `Binding<CGFloat>` so we project
    /// + clamp on the way through.
    private func heightBinding(_ source: Binding<Double>) -> Binding<CGFloat> {
        Binding(
            get: { SidebarPanelHeights.clamp(CGFloat(source.wrappedValue)) },
            set: { source.wrappedValue = Double(SidebarPanelHeights.clamp($0)) }
        )
    }

    var body: some View {
        sidebarBody
            .walkthroughAnchor(.sidebar)
    }

    private var sidebarBody: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // MARK: - Resizable section divider
            //
            // Each panel ABOVE the FILES tree gets:
            //   - an environment-injected body height (read by the
            //     section's inner ScrollView via
            //     `\.sidebarSectionBodyHeight`)
            //   - a `ResizableSectionDivider` after it, whose drag
            //     binds to the same @AppStorage-backed height.
            // FILES keeps `Spacer()`/`maxHeight: .infinity` flex.
            // BookmarksSection is always rendered (even with zero
            // bookmarks) — the section's fixed envelope + "(empty)"
            // placeholder is the whole point of the resizable
            // accordion. Hiding it on empty was the old behaviour and
            // caused the layout to jump every time the user toggled a
            // bookmark.
            BookmarksSection(model: model)
                .environment(\.sidebarSectionBodyHeight,
                             SidebarPanelHeights.clamp(CGFloat(bookmarksHeight)))
            ResizableSectionDivider(heightAbove: heightBinding($bookmarksHeight))
            if sidebar.rootURL != nil {
                SearchAnywhereSection(model: model)
                    .environment(\.sidebarSectionBodyHeight,
                                 SidebarPanelHeights.clamp(CGFloat(searchHeight)))
                ResizableSectionDivider(heightAbove: heightBinding($searchHeight))
                GitPanelSection(model: model)
                    .environment(\.sidebarSectionBodyHeight,
                                 SidebarPanelHeights.clamp(CGFloat(gitHeight)))
                ResizableSectionDivider(heightAbove: heightBinding($gitHeight))
                ClaudeTimelineSection(model: model)
                    .environment(\.sidebarSectionBodyHeight,
                                 SidebarPanelHeights.clamp(CGFloat(claudeHeight)))
                ResizableSectionDivider(heightAbove: heightBinding($claudeHeight))
                // LSP outline of the currently-open file. The section
                // self-gates: returns EmptyView when the file's
                // language has no registered LSP server (e.g. `.md`,
                // `.txt`), so the divider sits flush against the
                // previous section in that case.
                LSPOutlineWrapper(model: model)
                    .environment(\.sidebarSectionBodyHeight,
                                 SidebarPanelHeights.clamp(CGFloat(lspHeight)))
                ResizableSectionDivider(heightAbove: heightBinding($lspHeight))
                // MARK: - Symbol mode (LSP workspace symbols)
                //
                // Hosts both `textDocument/references` results (from a
                // right-click on the source view) and `workspace/symbol`
                // search (from the inline query field). One panel, two
                // routes — `LSPNavigationStore` switches modes.
                LSPNavigationPanel(
                    store: model.lspNavigation,
                    onJump: { loc in
                        guard let url = URL(string: loc.uri) else { return }
                        if !model.selectTab(forURL: url) {
                            model.openPath(url)
                        }
                        model.scrollSource(toLine: loc.range.start.line + 1)
                    },
                    onSearchWorkspaceSymbols: { query in
                        runWorkspaceSymbolQuery(query)
                    }
                )
                .environment(\.sidebarSectionBodyHeight,
                             SidebarPanelHeights.clamp(CGFloat(lspNavHeight)))
                ResizableSectionDivider(heightAbove: heightBinding($lspNavHeight))
                // MARK: - Problems (LSP diagnostics) section
                //
                // Server-pushed `textDocument/publishDiagnostics`
                // collected per-URL by `LSPDiagnosticsStore`. Click a
                // row to open the file at the offending line.
                LSPProblemsPanel(
                    store: model.lspDiagnostics,
                    onJump: { url, line in
                        if !model.selectTab(forURL: url) {
                            model.openPath(url)
                        }
                        model.scrollSource(toLine: line)
                    }
                )
                .environment(\.sidebarSectionBodyHeight,
                             SidebarPanelHeights.clamp(CGFloat(lspProblemsHeight)))
            }
            // Plugin-contributed sidebar sections. Self-managing
            // collapse state; appears above FILES regardless of
            // whether a folder is open (a plugin may not need one).
            PluginSidebarSections(model: model)
                .environment(\.sidebarSectionBodyHeight,
                             SidebarPanelHeights.clamp(CGFloat(pluginHeight)))
            if let root = sidebar.rootURL {
                // FILES accordion header — gives the tree the same
                // collapsible chevron + heading treatment as the
                // other sections so the sidebar reads as a uniform
                // accordion.
                HStack(spacing: 4) {
                    Button(action: { filesExpanded.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: filesExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 10)
                            Text("FILES")
                                .font(.system(size: model.uiSize(10), weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Sort mode picker. Folders always sort before
                    // files (Finder-like); the chosen mode applies
                    // within each group.
                    Menu {
                        ForEach(SidebarModel.FolderSortMode.allCases) { mode in
                            Button {
                                sidebar.sortMode = mode
                            } label: {
                                HStack {
                                    Text(mode.rawValue)
                                    if sidebar.sortMode == mode {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 9))
                            Text(sidebar.sortMode.rawValue)
                                .font(.system(size: model.uiSize(10)))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Sort folder contents")
                    .accessibilityIdentifier("mdv.sidebar.sort")
                    // Lock toggle. When locked, auto-reveal-on-click +
                    // tab-reveal won't change the sidebar root; the
                    // user's chosen folder stays put.
                    Button(action: { model.toggleSidebarLock() }) {
                        Image(systemName: model.isSidebarLocked
                              ? "lock.fill" : "lock.open")
                            .font(.system(size: 10))
                            .foregroundStyle(model.isSidebarLocked
                                             ? Color.accentColor
                                             : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(model.isSidebarLocked
                          ? "Sidebar root locked — click to unlock"
                          : "Lock sidebar root (prevent auto-navigation)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                if filesExpanded {
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
        // Top-align: without this, a short content stack centers
        // vertically in the available window height, leaving sections
        // floating in the middle. maxHeight:.infinity claims all the
        // height; alignment:.top pins content to the top.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.textBackground)
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
        HStack(spacing: 6) {
            if canGoUp {
                Button(action: goUp) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: model.uiSize(10), weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Open parent folder")
                .accessibilityLabel("Open parent folder")
            }
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

    /// True when the current root has a parent we can navigate to (not `/`).
    private var canGoUp: Bool {
        guard let root = sidebar.rootURL else { return false }
        let parent = root.deletingLastPathComponent()
        return parent.path != root.path  // false at filesystem root
    }

    private func goUp() {
        guard let root = sidebar.rootURL else { return }
        let parent = root.deletingLastPathComponent()
        if parent.path != root.path {
            model.openFolder(parent)
        }
    }

    /// Fire a `workspace/symbol` query against the live LSP clients.
    /// Sequenced via a small in-flight token so a fast typer doesn't
    /// pile up requests (each new query cancels the previous).
    private func runWorkspaceSymbolQuery(_ query: String) {
        // Cancel prior query.
        WorkspaceSymbolDispatch.shared.cancel()
        let token = LSPCancellationToken()
        WorkspaceSymbolDispatch.shared.current = token
        let store = model.lspNavigation
        store.startLoading(mode: .workspaceSymbols, query: query)
        let pool = model.lspPool
        Task { @MainActor in
            do {
                let syms = try await pool.workspaceSymbol(query: query, token: token)
                guard !Task.isCancelled else { return }
                store.setWorkspaceSymbols(query: query, symbols: syms)
            } catch is CancellationError {
                // Newer query — leave the store alone.
            } catch {
                store.setError("\(error)")
            }
        }
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
            Button("Open in Split") { model.openInSplit(node.url) }
            Divider()
            Button(model.bookmarksStore.contains(node.url)
                   ? "Remove Bookmark" : "Bookmark File") {
                _ = model.bookmarksStore.toggle(
                    url: node.url,
                    displayName: node.url.lastPathComponent
                )
                model.refreshBookmarks()
            }
            Divider()
        } else {
            Button(sidebar.isExpanded(node.url) ? "Collapse" : "Expand") {
                sidebar.toggleExpansion(node.url)
            }
            Button("Open Folder") { model.openFolder(node.url) }
            if let openInNewSession = model.openFolderInNewSession {
                Button("Open in New Session") {
                    openInNewSession(node.url)
                }
            }
            Divider()
            // Bookmark / unbookmark — works on folders too. Cmd+D in
            // the global menu only bookmarks the current TAB; folder
            // bookmarks need an explicit context-menu entry.
            Button(model.bookmarksStore.contains(node.url)
                   ? "Remove Bookmark" : "Bookmark Folder") {
                _ = model.bookmarksStore.toggle(
                    url: node.url,
                    displayName: node.url.lastPathComponent
                )
                model.refreshBookmarks()
            }
            // Override the auto-discovered git root. Useful for nested
            // worktrees or submodules where the user wants TextView
            // to treat a subfolder as the repo root.
            Button(sidebar.gitRootOverride == node.url
                   ? "Clear Git Root Override" : "Set as Git Root") {
                if sidebar.gitRootOverride == node.url {
                    sidebar.gitRootOverride = nil
                } else {
                    sidebar.gitRootOverride = node.url
                }
                sidebar.refreshGitStatus()
            }
            Divider()
        }
        Button("Copy Path") { Pasteboard.copy(node.url.path) }
        Button("Copy Relative Path") { Pasteboard.copy(relativePath) }
        Button("Reveal in Finder") { Finder.reveal(node.url) }
        if node.isDirectory {
            Button("Open in Terminal") { openInTerminal(node.url) }
            // MARK: - Search in Folder (folder-context agent)
            // Presents the unified search panel with the scope picker
            // pre-set to this folder (pickedFolder), bypassing the
            // sidebar root. Keeps the existing showCrossSearch() path
            // intact for callers that want sidebar-root behavior.
            Button("Search in Folder") {
                model.showCrossSearch(scope: .pickedFolder(node.url))
            }
        }
        if model.sidebar.gitRepoRoot != nil {
            Divider()
            if !node.isDirectory {
                Button("Show File History") {
                    model.showGitLog(forPath: node.url, scope: .file)
                }
            } else {
                Button("Show Folder History") {
                    model.showGitLog(forPath: node.url, scope: .folder)
                }
            }
        }
    }

    /// Launches a new Terminal.app window with cwd set to `url`.
    /// `/usr/bin/open -a Terminal <path>` honors the user's default
    /// terminal-application setting via Launch Services *only* when
    /// they've explicitly remapped Terminal's UTI; most users get
    /// system Terminal. Future polish: detect iTerm2 and prefer it.
    private func openInTerminal(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", url.path]
        try? p.run()
    }

    /// Path relative to the sidebar root. Falls back to the filename when
    /// `node.url` isn't under the root (shouldn't happen via the UI, but
    /// it's defensive).
    private var relativePath: String {
        guard let root = sidebar.rootURL else { return node.url.lastPathComponent }
        let rootComponents = root.standardizedFileURL.pathComponents
        let nodeComponents = node.url.standardizedFileURL.pathComponents
        if nodeComponents.count > rootComponents.count,
           Array(nodeComponents.prefix(rootComponents.count)) == rootComponents {
            return nodeComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }
        return node.url.lastPathComponent
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
                    FileIconView(
                        url: node.url,
                        isDirectory: node.isDirectory,
                        isExpanded: sidebar.isExpanded(node.url),
                        isGitRoot: node.isDirectory && sidebar.gitRepoRoot == node.url,
                        size: .tree
                    )
                    .frame(width: 16, height: 16)
                    Text(node.name)
                        // Bold the file's name if it's the currently-
                        // visible tab — matches the bold treatment in
                        // the tab bar so the "current document" is
                        // obvious in both surfaces.
                        .font(.system(size: model.uiSize(12), weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.bookmarksStore.contains(node.url) {
                        Image(systemName: "star.fill")
                            .font(.system(size: model.uiSize(8)))
                            .foregroundStyle(.yellow)
                            .help("Bookmarked")
                            .accessibilityLabel("Bookmarked")
                    }
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

    /// Selected (keyboard), current (active tab), and other-open
    /// (has a non-active tab) get distinct shading so users can tell
    /// at a glance: which row is about to be activated by ↵, which
    /// file is in front, and which other files are already open.
    private var rowBackground: Color {
        let isSelected = sidebar.selectedURL == node.url
        if isCurrent  { return Color.accentColor.opacity(0.22) }
        if isSelected { return Color(nsColor: .alternateSelectedControlColor).opacity(0.25) }
        if isOpenInOtherTab {
            return Color.accentColor.opacity(0.08)
        }
        return Color.clear
    }

    /// True if this file is loaded in some tab other than the current
    /// one. Lets us mark "you have this open elsewhere" without
    /// stealing the stronger highlight from the actually-current tab.
    /// Reads from `model.openTabURLs` (O(1) Set lookup) instead of
    /// scanning `model.tabs.tabs` per row per body re-eval.
    private var isOpenInOtherTab: Bool {
        guard !node.isDirectory else { return false }
        return model.openTabURLs.contains(node.url)
            && node.url != model.currentURL
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

}

/// Sidebar wrapper for the LSP outline section. Owns the
/// `LSPOutlineModel` so it persists across body re-evals + reacts to
/// the active tab changing. Self-gates: returns empty content when
/// the current file's language has no LSP server.
@MainActor
struct LSPOutlineWrapper: View {
    @ObservedObject var model: DocumentModel
    @StateObject private var outline: LSPOutlineModel

    init(model: DocumentModel) {
        self.model = model
        _outline = StateObject(
            wrappedValue: LSPOutlineModel(pool: model.lspPool)
        )
    }

    var body: some View {
        Group {
            if outline.isSupported {
                LSPOutlineSection(model: outline) { symbol in
                    // Jump callback: scroll the source view to the
                    // symbol's start line + select that tab if it
                    // isn't already the active one.
                    if let url = currentFileURL,
                       !model.selectTab(forURL: url) {
                        model.openPath(url)
                    }
                    let line = symbol.selectionRange.start.line + 1
                    model.scrollSource(toLine: line)
                }
            }
        }
        .onAppear { refresh() }
        .onChange(of: model.currentURL) { _, _ in refresh() }
    }

    private var currentFileURL: URL? { model.currentURL }

    private func refresh() {
        guard let url = model.currentURL,
              case .loaded(let file) = model.currentState else {
            outline.setFile(nil, text: nil)
            return
        }
        outline.setFile(url, text: file.contents)
    }
}

/// Singleton holder for the most-recent workspace-symbol query's
/// cancellation token. SidebarView is a value type so it can't own
/// mutable state across body re-evals; this @MainActor singleton sits
/// alongside it and lets each call to `runWorkspaceSymbolQuery` cancel
/// its predecessor.
@MainActor
final class WorkspaceSymbolDispatch {
    static let shared = WorkspaceSymbolDispatch()
    var current: LSPCancellationToken?
    func cancel() { current?.cancel(); current = nil }
    private init() {}
}
