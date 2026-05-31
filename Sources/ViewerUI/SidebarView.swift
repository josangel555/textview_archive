import SwiftUI
import ViewerCore

struct SidebarView: View {
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var model: DocumentModel
    /// Multi-repo git registry observation surface. Observed DIRECTLY
    /// (a third independent observable alongside `sidebar` + `model`) so
    /// badge colors / repo-root glyphs / section visibility re-eval on a
    /// `version` bump WITHOUT routing through `DocumentModel.objectWillChange`
    /// — see `TrackedReposRepublishInvariantTests`.
    @ObservedObject var trackedRepos: TrackedReposChannel
    /// Shoulder-rail layout. Observed directly so the accordion's
    /// per-panel presence resolves through the SAME store the rails
    /// drive — toggling a rail button re-bodies this view and flips the
    /// matching section in/out. The explicit `.shown` / `.hidden`
    /// override is layered on top of the data-presence heuristic.
    @ObservedObject var panelLayout: PanelLayoutStore

    /// File-tree accordion state. Persisted across the session via
    /// `@AppStorage` so the user's last collapse choice survives a
    /// tab switch (DocumentModel sub-views recreate this view).
    @AppStorage("MarkdownViewer.sidebar.filesExpanded") private var filesExpanded: Bool = true

    /// Pointer-hover state for the FILES section-header row (UIRESP-13).
    /// Drives a faint hover tint + pointing-hand cursor so the collapse
    /// header reads as clickable.
    @State private var filesHeaderHovering = false

    // MARK: - Recency mode dropdown (file-tree-recency agent)
    //
    // Drives the left-edge color stripe on each `FileRowView`.
    // Persisted as the raw String of `FileTreeRecency.RecencyMode`;
    // unknown values (manual user edits, future renames) fall back
    // to the type's `.default` (`.modified`) via the rawValue init.
    @AppStorage("MarkdownViewer.sidebar.recencyMode")
    private var recencyModeRaw: String = FileTreeRecency.RecencyMode.default.rawValue
    private var recencyMode: FileTreeRecency.RecencyMode {
        FileTreeRecency.RecencyMode(rawValue: recencyModeRaw)
            ?? FileTreeRecency.RecencyMode.default
    }

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
    @AppStorage(SidebarPanelKind.bookmarks.appStorageKey)
    private var bookmarksHeight: Double = Double(SidebarPanelKind.bookmarks.defaultHeight)
    @AppStorage(SidebarPanelKind.searchAnywhere.appStorageKey)
    private var searchHeight: Double = Double(SidebarPanelKind.searchAnywhere.defaultHeight)
    @AppStorage(SidebarPanelKind.git.appStorageKey)
    private var gitHeight: Double = Double(SidebarPanelKind.git.defaultHeight)
    @AppStorage(SidebarPanelKind.claudeTimeline.appStorageKey)
    private var claudeHeight: Double = Double(SidebarPanelKind.claudeTimeline.defaultHeight)
    @AppStorage(SidebarPanelKind.lspOutline.appStorageKey)
    private var lspHeight: Double = Double(SidebarPanelKind.lspOutline.defaultHeight)
    @AppStorage(SidebarPanelKind.lspNavigation.appStorageKey)
    private var lspNavHeight: Double = Double(SidebarPanelKind.lspNavigation.defaultHeight)
    @AppStorage(SidebarPanelKind.lspProblems.appStorageKey)
    private var lspProblemsHeight: Double = Double(SidebarPanelKind.lspProblems.defaultHeight)
    @AppStorage(SidebarPanelKind.recentlyOpened.appStorageKey)
    private var recentsHeight: Double = Double(SidebarPanelKind.recentlyOpened.defaultHeight)
    @AppStorage(SidebarPanelKind.pluginSections.appStorageKey)
    private var pluginHeight: Double = Double(SidebarPanelKind.pluginSections.defaultHeight)

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
            // MARK: - Panel order
            //
            // FILES leads (matches VSCode / Xcode / IntelliJ
            // expectations — file tree on top, ancillary panels
            // below). The accordion below FILES is the legacy order
            // (Bookmarks → Search → Git → Claude → LSP → plugins).
            // Canonical order lives in
            // `SidebarPanelRegistry.defaultOrder` (ViewerCore); the
            // ordering pin-test there enforces FILES-first.
            //
            // Each panel ABOVE FILES previously got:
            //   - an environment-injected body height (read by the
            //     section's inner ScrollView via
            //     `\.sidebarSectionBodyHeight`)
            //   - a `ResizableSectionDivider` after it, whose drag
            //     binds to the same @AppStorage-backed height.
            // FILES sits at the top now and keeps its flex-fill
            // (`maxHeight: .infinity`) behaviour, so it absorbs
            // any leftover vertical space.
            filesPanel
            // Divider placement is now driven by `SidebarSectionPlanner`
            // (ViewerCore) — a hidden panel (no git repo, no Claude
            // transcripts, non-LSP file) drops both itself AND the
            // divider that would have sat below it. Previously the
            // dividers were rendered unconditionally and stacked up
            // (the "3-4 lines bunched below GIT" bug).
            accordionStack
            // Plugin-contributed sidebar sections. Self-managing
            // collapse state; appears above FILES regardless of
            // whether a folder is open (a plugin may not need one).
            //
            // bug5: gate on the resolved visibility so the rail's
            // `.pluginSections` toggle actually works. This panel was
            // mounted unconditionally, bypassing `panelLayout.isVisible`
            // entirely — so its rail button's `.hidden` override was
            // computed but never read, leaving the "ROW COUNTS" window
            // permanently visible with a dead toggle. `dataPresent` is
            // always `true` for `.pluginSections` (a plugin section shows
            // regardless of folder), so only an explicit `.hidden` override
            // hides it — which is exactly the path the rail button drives.
            if panelLayout.isVisible(
                .pluginSections,
                dataPresent: SidebarDataPresence.isPresent(.pluginSections, presenceInputs)
            ) {
                PluginSidebarSections(model: model)
                    .environment(\.sidebarSectionBodyHeight,
                                 SidebarPanelHeights.clamp(CGFloat(pluginHeight)))
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

    // MARK: - Accordion stack (visibility-aware divider placement)
    //
    // Below FILES sits an ordered run of panels; each one is either
    // unconditionally visible (BOOKMARKS, plugin sections) or self-
    // gates on some condition (GIT only when in a repo, CLAUDE only
    // when transcripts exist, OUTLINE only when the file has an LSP
    // server). Previously the parent rendered a
    // `ResizableSectionDivider` between every pair regardless — so
    // any run of hidden panels produced multiple stacked hairlines.
    //
    // Fix: compute visibility per panel up front, hand the list to
    // `SidebarSectionPlanner` (pure logic in ViewerCore, unit-tested),
    // and render exactly the panels + dividers it returns.

    /// Resolved visibility for each accordion panel, in accordion order.
    ///
    /// `dataPresent` is the shared `SidebarDataPresence` heuristic (the
    /// same one the rail reads, so the rail button's filled-state and
    /// the accordion's presence can't diverge); the explicit
    /// `.auto` / `.shown` / `.hidden` override is layered on top via
    /// `panelLayout.isVisible(_:dataPresent:)`. Fresh-install (`.auto`
    /// everywhere) resolves === today's data-presence behavior.
    ///
    /// FILES + plugin sections render OUTSIDE this accordion stack, so
    /// they're excluded here. The bookmarks panel is data-present
    /// always (its fixed "(empty)" envelope is intentional); LSP
    /// navigation + problems are present whenever a root is open (they
    /// hold cross-file state useful even when the active tab isn't an
    /// LSP language) — all encoded in `SidebarDataPresence`.
    /// Single source for the `SidebarDataPresence.Inputs` so the accordion
    /// (`panelVisibility`), the plugin-section gate, and any other presence
    /// read all derive from one heuristic — the file's single-source-of-truth
    /// discipline. Lifted out of `panelVisibility` so #4/#5 don't recompute it
    /// independently and drift.
    private var presenceInputs: SidebarDataPresence.Inputs {
        SidebarDataPresence.Inputs(
            hasRoot: sidebar.rootURL != nil,
            // Multi-repo: the git accordion shows when ANY repo is
            // tracked, not just a single auto-discovered sidebar-root.
            hasRepo: trackedRepos.trackedRoots.isEmpty == false,
            hasLSPLanguage: model.currentURL.flatMap {
                LSPLanguageRegistry.default.language(for: $0)
            } != nil,
            claudeHasTranscripts: sidebar.claudeHasTranscripts,
            hasRecents: !model.recents.isEmpty
        )
    }

    private var panelVisibility: [(panel: SidebarPanelKind, isVisible: Bool)] {
        let presence = SidebarDataPresence.evaluate(presenceInputs)
        let accordionOrder: [SidebarPanelKind] = [
            .bookmarks, .searchAnywhere, .git, .claudeTimeline,
            .lspOutline, .lspNavigation, .lspProblems, .recentlyOpened,
        ]
        return accordionOrder.map { kind in
            (kind, panelLayout.isVisible(kind, dataPresent: presence[kind] ?? false))
        }
    }

    @ViewBuilder
    private var accordionStack: some View {
        let plan = SidebarSectionPlanner.plan(panelVisibility)
        ForEach(plan, id: \.panel) { entry in
            panelView(for: entry.panel)
            if entry.drawTrailingDivider {
                divider(below: entry.panel)
            }
        }
        // Claude-transcript presence now lives on `SidebarModel`
        // (refreshed in `setRoot`) so the rail + accordion read one
        // source of truth. The old `@State` + `.onAppear` /
        // `.onChange(of: rootURL)` refresh plumbing that lived here was
        // removed — `sidebar.claudeHasTranscripts` is observed directly.
    }

    @ViewBuilder
    private func panelView(for kind: SidebarPanelKind) -> some View {
        switch kind {
        case .bookmarks:
            BookmarksSection(model: model)
                .environment(\.sidebarSectionBodyHeight,
                             SidebarPanelHeights.clamp(CGFloat(bookmarksHeight)))
        case .searchAnywhere:
            SearchAnywhereSection(model: model, sidebar: sidebar)
                .environment(\.sidebarSectionBodyHeight,
                             SidebarPanelHeights.clamp(CGFloat(searchHeight)))
        case .git:
            // bug4: pass the forced-`.shown` override so the section renders
            // a "Not a git repository" placeholder (instead of EmptyView)
            // when the rail button forces it on in a non-repo folder.
            GitPanelSection(model: model, sidebar: sidebar, trackedRepos: trackedRepos,
                            forcedShown: panelLayout.override(for: .git) == .shown)
                .environment(\.sidebarSectionBodyHeight,
                             SidebarPanelHeights.clamp(CGFloat(gitHeight)))
        case .claudeTimeline:
            ClaudeTimelineSection(model: model, sidebar: sidebar,
                                  forcedShown: panelLayout.override(for: .claudeTimeline) == .shown)
                .environment(\.sidebarSectionBodyHeight,
                             SidebarPanelHeights.clamp(CGFloat(claudeHeight)))
        case .lspOutline:
            LSPOutlineWrapper(model: model,
                              forcedShown: panelLayout.override(for: .lspOutline) == .shown)
                .environment(\.sidebarSectionBodyHeight,
                             SidebarPanelHeights.clamp(CGFloat(lspHeight)))
        case .lspNavigation:
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
                },
                uiSize: model.uiSize
            )
            .environment(\.sidebarSectionBodyHeight,
                         SidebarPanelHeights.clamp(CGFloat(lspNavHeight)))
        case .lspProblems:
            LSPProblemsPanel(
                store: model.lspDiagnostics,
                onJump: { url, line in
                    if !model.selectTab(forURL: url) {
                        model.openPath(url)
                    }
                    model.scrollSource(toLine: line)
                },
                uiSize: model.uiSize
            )
            .environment(\.sidebarSectionBodyHeight,
                         SidebarPanelHeights.clamp(CGFloat(lspProblemsHeight)))
        case .recentlyOpened:
            RecentlyOpenedSection(model: model)
                .environment(\.sidebarSectionBodyHeight,
                             SidebarPanelHeights.clamp(CGFloat(recentsHeight)))
        case .files, .pluginSections:
            // FILES is rendered inline at the top of the sidebar
            // (above this accordion stack). pluginSections is below.
            EmptyView()
        }
    }

    @ViewBuilder
    private func divider(below kind: SidebarPanelKind) -> some View {
        switch kind {
        case .bookmarks:
            ResizableSectionDivider(heightAbove: heightBinding($bookmarksHeight))
        case .searchAnywhere:
            ResizableSectionDivider(heightAbove: heightBinding($searchHeight))
        case .git:
            ResizableSectionDivider(heightAbove: heightBinding($gitHeight))
        case .claudeTimeline:
            ResizableSectionDivider(heightAbove: heightBinding($claudeHeight))
        case .lspOutline:
            ResizableSectionDivider(heightAbove: heightBinding($lspHeight))
        case .lspNavigation:
            ResizableSectionDivider(heightAbove: heightBinding($lspNavHeight))
        case .lspProblems:
            ResizableSectionDivider(heightAbove: heightBinding($lspProblemsHeight))
        case .recentlyOpened:
            ResizableSectionDivider(heightAbove: heightBinding($recentsHeight))
        case .files, .pluginSections:
            EmptyView()
        }
    }

    // MARK: - FILES panel
    //
    // The FILES tree sits at the top of the accordion (was at the
    // bottom prior to the activity-bar groundwork refactor). Keeps
    // its own collapsible chevron header + sort/lock controls.
    //
    // When the section is expanded it gets a `frame(maxHeight:
    // .infinity)` so it absorbs all leftover vertical space — the
    // other panels are fixed-height (via `@AppStorage` per-panel
    // heights), FILES is the flex-fill in the layout.
    //
    // When there's no folder open the FILES panel collapses to a
    // single "No folder open" placeholder line; the sections below
    // (Bookmarks, etc.) still render normally so the user can pick
    // a bookmarked folder without first opening one.
    @ViewBuilder
    private var filesPanel: some View {
        if let root = sidebar.rootURL {
            VStack(spacing: 0) {
                filesHeader
                if filesExpanded {
                    ScrollViewReader { proxy in
                        ScrollView {
                            // PERF #6: flatten the visible tree once and
                            // enumerate it inside a single LazyVStack so
                            // virtualization kicks in for deep trees.
                            // The prior shape recursed `FileRowView` ->
                            // `ForEach` -> child `FileRowView`, which
                            // SwiftUI materialized eagerly past the
                            // outer LazyVStack — defeating it as soon
                            // as the root expanded.
                            //
                            // `flatVisibleRows()` is memoized on
                            // SidebarModel; reading it from the body is
                            // O(1) on cache-hit (the common case) and
                            // O(visible-row-count) on miss. It does no
                            // IO either way.
                            let rows = sidebar.flatVisibleRows()
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(rows) { row in
                                    FileRowView(
                                        node: row.node,
                                        depth: row.depth,
                                        sidebar: sidebar,
                                        model: model,
                                        trackedRepos: trackedRepos,
                                        recencyMode: recencyMode
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        // CRIT-6: keep keyboard-selected row visible.
                        .onChange(of: sidebar.selectedURL) { _, new in
                            if let url = new {
                                proxy.scrollTo(url, anchor: .center)
                            }
                        }
                    }
                    // Flex-fill so FILES (now the top panel) eats
                    // the leftover vertical space below the other
                    // fixed-height accordion sections. Without this
                    // the tree would collapse to its intrinsic
                    // height and leave a gap at the sidebar bottom.
                    .frame(maxHeight: .infinity)
                }
            }
        } else {
            HStack {
                Text("No folder open")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    /// FILES section header — chevron + label + sort menu + lock.
    /// Visually consistent with every other section's header row.
    private var filesHeader: some View {
        HStack(spacing: 4) {
            Button(action: {
                // Animate the collapse so the section-header chevron
                // (driven by `isExpanded`) eases rather than snaps
                // (UIRESP-13).
                withAnimation(.easeInOut(duration: 0.15)) {
                    filesExpanded.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    SidebarSectionHeaderLabel(
                        title: "Files",
                        isExpanded: filesExpanded,
                        uiSize: model.uiSize
                    )
                    Spacer()
                }
                .contentShape(Rectangle())
                // UIRESP-13: faint hover tint on the header row.
                .background(filesHeaderHovering
                            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.10)
                            : Color.clear)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                filesHeaderHovering = hovering
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
            // Sort mode picker. Folders always sort before files
            // (Finder-like); the chosen mode applies within each
            // group.
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
            // 0c: uniform HelpInfo — bubble title + status-bar description.
            .helpInfo(title: "Sort",
                      description: "Sort folder contents by name, date, or kind")
            .accessibilityIdentifier("mdv.sidebar.sort")
            // MARK: - Recency mode dropdown (file-tree-recency agent)
            //
            // Picks which timestamp drives the left-edge color stripe
            // on each file row. Persisted in `@AppStorage` via
            // `recencyModeRaw`; the active mode is read by
            // `FileRowView` through the constructor.
            Menu {
                ForEach(FileTreeRecency.RecencyMode.allCases) { mode in
                    Button {
                        recencyModeRaw = mode.rawValue
                    } label: {
                        HStack {
                            Text(mode.rawValue)
                            if recencyMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 9))
                    Text(recencyMode.rawValue)
                        .font(.system(size: model.uiSize(10)))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .helpInfo(title: "Recency colors",
                      description: "Color-code file rows by recency (Modified / Added / Created)")
            .accessibilityIdentifier("mdv.sidebar.recencyMode")
            // Lock toggle. When locked, auto-reveal-on-click +
            // tab-reveal won't change the sidebar root; the user's
            // chosen folder stays put.
            Button(action: { model.toggleSidebarLock() }) {
                Image(systemName: model.isSidebarLocked
                      ? "lock.fill" : "lock.open")
                    .font(.system(size: 10))
                    .foregroundStyle(model.isSidebarLocked
                                     ? Color.accentColor
                                     : .secondary)
            }
            .buttonStyle(.plain)
            .helpInfo(title: model.isSidebarLocked ? "Unlock sidebar" : "Lock sidebar",
                      description: model.isSidebarLocked
                        ? "Sidebar root locked — click to unlock"
                        : "Lock sidebar root (prevent auto-navigation)")
            // item9: pin / follow-active-tab. When on, switching tabs reveals
            // the active file in the tree (select + expand, no re-root).
            Button(action: { model.toggleSidebarFollowsActiveTab() }) {
                Image(systemName: model.sidebarFollowsActiveTab
                      ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(model.sidebarFollowsActiveTab
                                     ? Color.accentColor
                                     : .secondary)
            }
            .buttonStyle(.plain)
            .helpInfo(title: model.sidebarFollowsActiveTab ? "Following active tab" : "Follow active tab",
                      description: model.sidebarFollowsActiveTab
                        ? "Sidebar follows the active tab — click to stop"
                        : "Reveal the active tab's file in the sidebar on every tab switch")
            .accessibilityIdentifier("mdv.sidebar.followActiveTab")
        }
        .sidebarHeaderRow()
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
    @ObservedObject var trackedRepos: TrackedReposChannel

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
            // Pin a repo into the tracked set so its badges / gutter /
            // panel stay live even with no open tab inside it (monorepo
            // subdir, submodule, or a repo you're about to work in). The
            // multi-pin successor to the old single-slot "Set as Git
            // Root" override.
            if trackedRepos.isRepoRoot(node.url) {
                Button(model.repoFocus.pinned.contains(TrackedReposReducer.normalize(node.url))
                       ? "Unpin Repo" : "Pin Repo") {
                    model.repoFocus.togglePin(node.url)
                }
                Divider()
            }
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
        if trackedRepos.trackedRoots.isEmpty == false {
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
    @ObservedObject var trackedRepos: TrackedReposChannel
    /// Active recency mode — chosen via the FILES header dropdown,
    /// stored in `@AppStorage` on the parent. Threaded through here
    /// so every child row paints stripes in the same mode without
    /// each row touching `@AppStorage` independently.
    let recencyMode: FileTreeRecency.RecencyMode

    /// Cached file attributes (mtime + ctime) for this row's URL.
    /// Loaded once on `.onAppear` via the bounded LRU in
    /// `FileTreeRecencyCache`; the lookup is a syscall on cache miss
    /// only. Re-loaded when FolderWatcher invalidates the URL.
    @State private var recencyAttrs: FileTreeRecencyAttributes?

    /// Pointer-hover state for the row affordance (UIRESP-01/13). Drives
    /// a faint hover tint (below the selection/current/other-tab tints)
    /// and a pointing-hand cursor so file rows read as clickable.
    @State private var isHovering = false

    var body: some View {
        // PERF #6: renders exactly *this* row — children live as
        // sibling rows in the parent `LazyVStack`, fed by
        // `SidebarModel.flatVisibleRows()`. The previous shape
        // wrapped the child enumeration in a non-lazy `VStack`
        // inside each row's body, which forced SwiftUI to
        // materialize every descendant of an expanded root in one
        // pass (defeating the outer LazyVStack's virtualization).
        //
        // FolderWatcher publishes via `expanded`; observing it
        // here would re-fire on every collapse/expand too, which
        // is wasteful. We accept that the stripe is "as of first
        // render" — `FileTreeRecencyCache.invalidate(_:)` is the
        // public escape hatch for callers that touch a file from
        // within the app (Save, Git apply, etc.) and want the
        // stripe refreshed on the next body pass.
        Button(action: activate) {
            HStack(spacing: 0) {
                // MARK: - Recency stripe (file-tree-recency agent)
                //
                // 3 px vertical bar at the leading edge of the row.
                // The `padding(.leading, depth*14 + 8)` previously
                // hugged the chevron; we move the indent + the
                // existing HStack into an inner HStack and prepend
                // the stripe so it always touches the row's left
                // edge regardless of depth.
                recencyStripe
                HStack(spacing: 4) {
                    if node.isDirectory {
                        // UIRESP: animate the disclosure chevron via a
                        // rotation on a single glyph (collapsed = 0°,
                        // expanded = 90°) instead of swapping two SF
                        // symbols — gives a smooth spin on expand/collapse.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 12)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(sidebar.isExpanded(node.url) ? 90 : 0))
                            .animation(.easeInOut(duration: 0.15),
                                       value: sidebar.isExpanded(node.url))
                    } else {
                        Spacer().frame(width: 12)
                    }
                    FileIconView(
                        url: node.url,
                        isDirectory: node.isDirectory,
                        isExpanded: sidebar.isExpanded(node.url),
                        isGitRoot: repoRootKind == .repo,
                        isNestedRoot: repoRootKind == .nested,
                        size: .tree
                    )
                    .frame(width: 16, height: 16)
                    // Active-repo treatment: a filled dot when this repo
                    // root is LIVE in the tracked set (cheap stat said
                    // it's a repo; the tracked-set membership says it's
                    // actively being observed). Lets the user see WHICH
                    // repo roots are live vs merely on-disk.
                    .overlay(alignment: .bottomTrailing) {
                        if repoRootKind != .none && trackedRepos.isTrackedRoot(node.url) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 4, height: 4)
                                .offset(x: 1, y: 1)
                                .accessibilityHidden(true)
                        }
                    }
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
                    if let status = trackedRepos.status(for: node.url) {
                        GitStatusBadge(status: status)
                    }
                }  // inner HStack(spacing: 4)
                .padding(.leading, CGFloat(depth) * 14 + 8)
                .padding(.vertical, 3)
                .padding(.trailing, 8)
            }  // outer HStack(spacing: 0) — stripe + content
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
            FileRowContextMenu(
                node: node, sidebar: sidebar, model: model,
                trackedRepos: trackedRepos
            )
        }
        .onAppear {
            if recencyAttrs == nil {
                recencyAttrs = FileTreeRecencyCache.attributes(for: node.url)
            }
        }
        // RWC-3: re-load the stripe attributes when the model signals a
        // recency change (FolderWatcher fire / in-app save). The cache
        // entry for this URL was already invalidated by the bump source,
        // so this re-read sees fresh mtime/ctime. Cheap: cache-hit unless
        // *this* URL was the one that changed.
        .onChange(of: sidebar.recencyVersion) { _, _ in
            recencyAttrs = FileTreeRecencyCache.attributes(for: node.url)
        }
        // UIRESP-01/13: pointer affordance for file rows. Hover updates
        // the tint (via `rowBackground`) and shows the pointing-hand
        // cursor so rows read as clickable.
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }

    // MARK: - Recency stripe rendering
    //
    // 3 px-wide vertical bar at the leading edge. Width fixed regardless
    // of depth so it always touches the sidebar's edge (the row's
    // indentation lives inside the inner HStack via `.padding(.leading)`).
    //
    // Folder policy: folders render a stripe based on the folder's own
    // mtime — not muted-out — so the user can scan "this directory
    // changed recently" at a glance (matches Finder's Date Modified
    // column for directories). Trade-off accepted: directory mtime
    // updates whenever any direct child is added/removed, so folder
    // stripes are noisier than file stripes. If that proves visually
    // distracting we can flip this to a muted-grey constant for folders
    // here without touching FileTreeRecency.
    @ViewBuilder
    private var recencyStripe: some View {
        let tier = currentRecencyTier
        Rectangle()
            .fill(Color(nsColor: FileTreeRecency.color(for: tier)))
            .frame(width: 3)
            // Fill the row's vertical extent — the parent HStack stretches
            // this to match the tallest sibling.
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
            .accessibilityIdentifier("mdv.sidebar.fileRow.recencyStripe.\(tier.rawValue)")
    }

    /// The tier to paint for this row, given the active mode and the
    /// cached file attributes. Falls through to `.older` (barely-visible
    /// stripe) until `.onAppear` populates the cache; that one-frame
    /// flash is invisible at scroll speeds and avoids a synchronous
    /// stat during the SwiftUI body re-eval.
    private var currentRecencyTier: FileTreeRecency.RecencyTier {
        guard let date = recencyAttrs?.date(for: recencyMode) else {
            return .older
        }
        return FileTreeRecency.tier(for: date)
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
        // UIRESP-01/13: faint hover tint, strictly below the
        // selection / current / other-tab tints so it never masks a
        // stronger state. Uses the system control-accent at low alpha
        // for theme consistency.
        if isHovering {
            return Color(nsColor: .selectedContentBackgroundColor).opacity(0.12)
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
        if let s = trackedRepos.status(for: node.url) {
            parts.append("git: \(s.rawValue)")
        }
        if isCurrent { parts.append("currently open") }
        return parts.joined(separator: ", ")
    }

    private var isCurrent: Bool {
        model.currentURL == node.url
    }

    /// Repo-root classification for this row's directory (cheap cached
    /// `.git`-existence stat, NOT git status). `.none` for files and
    /// ordinary folders. Drives the folder glyph.
    private var repoRootKind: RepoRootKind {
        guard node.isDirectory else { return .none }
        return trackedRepos.repoRootKind(node.url)
    }

}

/// Sidebar wrapper for the LSP outline section. Owns the
/// `LSPOutlineModel` so it persists across body re-evals + reacts to
/// the active tab changing. Self-gates: returns empty content when
/// the current file's language has no LSP server.
@MainActor
struct LSPOutlineWrapper: View {
    @ObservedObject var model: DocumentModel
    /// True when the rail button forced the OUTLINE panel on
    /// (`PanelOverride.shown`) even though the current file has no language
    /// server. Renders a placeholder instead of nothing so the toggle
    /// visibly works (bug4).
    var forcedShown: Bool = false
    @StateObject private var outline: LSPOutlineModel

    init(model: DocumentModel, forcedShown: Bool = false) {
        self.model = model
        self.forcedShown = forcedShown
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
            } else if forcedShown {
                SidebarEmptyPlaceholder(message: "No language server for this file.")
                    .sidebarSectionContainer()
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
