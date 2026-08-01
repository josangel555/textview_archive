import SwiftUI
import ViewerCore

struct CommandPaletteView: View {
    @ObservedObject var model: DocumentModel
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    /// True only when selection moved via the keyboard (↑/↓). Hovering a row
    /// also moves `selectedIndex` (so Return opens what the pointer is over),
    /// but must NOT auto-scroll the list — otherwise moving the mouse over rows
    /// re-centers the list under the pointer ("scrolls on mouse-over"). The
    /// scroll-to-selection `onChange` honors this flag and clears it.
    @State private var scrollOnSelectionChange = false
    @State private var filtered: [(item: HistoryEntry, match: FuzzyMatcher.Match)] = []
    /// Command-mode results (UX-M / #232). Populated only when the query
    /// is prefixed with `>` — the VS Code convention for "run a command"
    /// vs "open a file". Keeps the default file/bookmark finder behaviour
    /// untouched when the user is just typing a filename.
    @State private var filteredCommands: [(item: CommandDescriptor, match: FuzzyMatcher.Match)] = []
    @FocusState private var fieldFocused: Bool

    /// Unified search routing (TSK-677): one classifier maps the leading
    /// operator to a SearchSource so the palette is the single front door for
    /// every search type — `>` commands, `?` global cross-file search, `#`
    /// in-file text, `@` Markdown-heading jump, `:` go-to-line, bare → recents.
    /// `route.goto` carries the legacy `GotoQuery` the in-file modes still use.
    private var route: SearchRouter.Route { SearchRouter.route(query) }
    /// The parsed goto-query (line/column, in-file term). Kept as the name the
    /// existing in-file/symbol/line code paths read, sourced from the router.
    private var parsed: GotoQuery { route.goto }
    /// `true` when the user is searching across files (`?term`) — TSK-677.
    private var isGlobalSearchMode: Bool { route.source == .globalText }
    /// `true` when the user is in command mode (query starts with `>`).
    private var isCommandMode: Bool { parsed.mode == .command }
    /// `true` when the user is entering a `:line[:col]` jump.
    private var isLineMode: Bool { parsed.mode == .line }
    /// `true` when the user is searching the active file's text (`#term`).
    private var isInFileSearchMode: Bool { parsed.mode == .text }
    /// `true` when the user is jumping to a markdown heading (`@term`).
    private var isSymbolMode: Bool { parsed.mode == .symbol }
    /// The command-mode query with the leading `>` stripped + trimmed.
    private var commandQuery: String {
        parsed.term.trimmingCharacters(in: .whitespaces)
    }
    /// A11Y-06: honor the system Reduce Motion setting. When set, the
    /// scroll-to-selection animation is suppressed (instant jump).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: paletteIcon)
                    .foregroundStyle(.secondary)
                TextField("Search recent files… (› cmds · ? all files · : line · # in file · @ heading)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    // AX ids (2026-08-01): the palette had NONE — invisible to
                    // the AX tier and assistive clients alike. mdv.palette.*
                    .accessibilityIdentifier("mdv.palette.field")
                    .onSubmit { submit() }
                    .onChange(of: query) { _, _ in
                        recomputeFiltered()
                        selectedIndex = 0
                    }
                Button(action: { model.dismissPalette() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityIdentifier("mdv.palette.close")
                .accessibilityLabel("Close Command Palette")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if isCommandMode {
                commandList
            } else if isGlobalSearchMode {
                globalSearchHint
            } else if isLineMode {
                lineModeHint
            } else if isInFileSearchMode {
                if jumpRows.isEmpty { inFileSearchHint } else { jumpList }
            } else if isSymbolMode {
                if jumpRows.isEmpty { symbolHint } else { jumpList }
            } else if filtered.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.item.id) { index, hit in
                                PaletteRow(
                                    entry: hit.item,
                                    matchedIndices: hit.match.matchedIndices,
                                    isSelected: index == selectedIndex,
                                    isBookmark: bookmarkURLSet.contains(hit.item.url),
                                    onUnbookmark: {
                                        model.removeBookmark(hit.item.url)
                                    },
                                    // UIRESP-13: hovering a row moves the
                                    // keyboard selection to it, so mouse +
                                    // keyboard navigation stay in sync and
                                    // Return opens whatever the pointer is
                                    // over.
                                    onHoverChanged: { hovering in
                                        if hovering { selectedIndex = index }
                                    }
                                ) {
                                    selectedIndex = index
                                    openSelected()
                                }
                                .id(index)
                                .accessibilityIdentifier("mdv.palette.row.\(index)")
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selectedIndex) { _, new in
                        // Only auto-scroll for keyboard nav, not hover — else the
                        // list re-centers under the pointer on mouse-over.
                        guard scrollOnSelectionChange else { return }
                        scrollOnSelectionChange = false
                        // Reduce Motion → nil animation → instant jump.
                        withAnimation(MotionGate.animation(.linear(duration: 0.05),
                                                           reduceMotion: reduceMotion)) {
                            proxy.scrollTo(new, anchor: .center)
                        }
                    }
                }
            }
            // Keyboard-shortcut hint footer (U-tier).
            if footerActionable {
                Divider()
                HStack(spacing: 12) {
                    // All modes except the single-target line jump are now
                    // arrow-navigable (`#`/`@` show a list).
                    if !isLineMode {
                        Text("↑↓ navigate").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(footerActionLabel)
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("esc cancel").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 540)
        .background(Palette.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(radius: 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mdv.palette.panel")
        .background(keyboardShortcuts)
        // TSK-1592: reliable Esc-dismiss in EVERY mode — a query field holding
        // `#`/`@` text otherwise swallows Esc in its field editor before the ✕
        // button's key-equivalent fires. Alive only while the palette is up.
        .background(PaletteEscMonitor { model.dismissPalette() })
        .onAppear {
            fieldFocused = true
            selectedIndex = 0
            bookmarkURLSet = Set(model.bookmarks.map { $0.url })
            recomputeFiltered()
        }
        .onChange(of: model.recents) { _, _ in recomputeFiltered() }
        .onChange(of: model.bookmarks) { _, _ in
            bookmarkURLSet = Set(model.bookmarks.map { $0.url })
            recomputeFiltered()
        }
        // TSK-727: lazily fetch LSP `documentSymbol`s the first time the user
        // enters `@` mode on a code file. Keyed on `isCodeSymbolMode` so the
        // fetch fires on transition into the mode (and re-fires if the user
        // leaves and re-enters); `loadCodeSymbols` is idempotent once loaded.
        .task(id: isCodeSymbolMode) {
            await loadCodeSymbols()
        }
    }

    /// Pre-computed lookup table for `isBookmark` row state. Without
    /// it, every palette row ran `model.bookmarks.contains { $0.url ==
    /// hit.item.url }` per body re-eval — O(rows × bookmarks). With
    /// 100+ bookmarks × 50 filtered rows per keystroke, that's 5K+
    /// URL comparisons. Recomputed only when the bookmarks list
    /// changes (rare).
    @State private var bookmarkURLSet: Set<URL> = []

    /// In-file (`#`) search matches for the active file (TSK-727). Drives the
    /// hint count + the Return-jumps-to-first-match action.
    @State private var inFileMatches: [InFileMatch] = []

    /// Markdown heading matches for the `@` symbol-jump (TSK-727). Drives the
    /// hint count + the Return-jumps-to-best-heading action.
    @State private var symbolMatches: [MarkdownHeading] = []

    /// TSK-887: memoizes the `@`-mode heading parse so a large file isn't
    /// re-parsed on every keystroke (the parse is query-independent; only the
    /// rank below depends on the query).
    @State private var headingMemo = ParseMemo<[MarkdownHeading]>([])

    /// `@`-mode CODE-symbol matches (TSK-727 code-file `@`): the ranked subset
    /// of `codeSymbols` for the current query. Empty for non-code files (which
    /// use `symbolMatches` headings) or before the async fetch lands.
    @State private var codeSymbolMatches: [SymbolJump.CodeSymbol] = []

    /// The active code file's flattened LSP `documentSymbol` list, fetched once
    /// per palette presentation (query-independent — only the rank depends on
    /// the query, like `headingMemo`). `nil` until the async fetch resolves.
    @State private var codeSymbols: [SymbolJump.CodeSymbol]?

    /// True while the code-symbol fetch is in flight — drives the loading hint.
    @State private var codeSymbolsLoading = false

    /// `true` when the `@` operator is active on a CODE file (LSP-backed
    /// symbols) rather than a Markdown file (heading-backed). Drives which
    /// source `recomputeFiltered` / `jumpRows` read.
    private var isCodeSymbolMode: Bool {
        isSymbolMode && model.activeFileHasLSPSymbols && model.currentCategory != .markdown
    }

    /// One navigable jump target (TSK-727 slice 5): unifies `#` in-file matches
    /// and `@` headings into a single arrow-navigable list with a jump line.
    private struct JumpRow: Identifiable {
        let id: Int
        let primary: String
        let secondary: String
        let line: Int
    }

    /// The navigable rows for the active `#`/`@` mode (empty otherwise).
    private var jumpRows: [JumpRow] {
        if isInFileSearchMode {
            return inFileMatches.enumerated().map {
                JumpRow(id: $0.offset, primary: $0.element.line.isEmpty ? " " : $0.element.line,
                        secondary: "line \($0.element.lineNumber)", line: $0.element.lineNumber)
            }
        }
        if isCodeSymbolMode {
            return codeSymbolMatches.enumerated().map {
                JumpRow(id: $0.offset, primary: $0.element.name,
                        secondary: $0.element.detail, line: $0.element.line)
            }
        }
        if isSymbolMode {
            return symbolMatches.enumerated().map {
                JumpRow(id: $0.offset, primary: $0.element.title,
                        secondary: "H\($0.element.level)", line: $0.element.line)
            }
        }
        return []
    }

    /// Show bookmarks at the top of the palette (in store order),
    /// followed by recents that aren't already shown as bookmarks. The
    /// fuzzy filter applies to both. PaletteRow renders the
    /// star.fill icon when `isBookmark` is true — no need to prefix
    /// the displayName here.
    private func merged() -> [HistoryEntry] {
        // Dedup logic lives in the host-tested PaletteCandidates.merge (TSK-1179);
        // caching this query-independent list across keystrokes is the render-tail
        // perf slice (PaletteCandidateCache keyed on a palette-open generation).
        let bookmarkAsEntries = model.bookmarks.map {
            HistoryEntry(url: $0.url, kind: .file, lastOpenedAt: $0.addedAt,
                         displayName: $0.displayName)
        }
        return PaletteCandidates.merge(bookmarkEntries: bookmarkAsEntries, recents: model.recents)
    }

    private var paletteIcon: String {
        if isCommandMode { return "command" }
        if isGlobalSearchMode { return "folder.badge.questionmark" }
        if isLineMode { return "number" }
        if isInFileSearchMode { return "doc.text.magnifyingglass" }
        if isSymbolMode { return "list.bullet" }
        return "magnifyingglass"
    }

    /// Whether the footer has an actionable Return for the current mode.
    private var footerActionable: Bool {
        if isGlobalSearchMode {
            // Actionable once there's a term to hand to the cross-file engine.
            if case .runGlobalSearch = route.submit { return true }
            return false
        }
        if isLineMode { return parsed.line != nil }
        if isInFileSearchMode { return !inFileMatches.isEmpty }
        if isCodeSymbolMode { return !codeSymbolMatches.isEmpty }
        if isSymbolMode { return !symbolMatches.isEmpty }
        if isCommandMode { return !filteredCommands.isEmpty }
        return !filtered.isEmpty
    }

    private var footerActionLabel: String {
        if isGlobalSearchMode { return "↵ search all files" }
        if isLineMode { return "↵ go to line" }
        if isInFileSearchMode { return "↵ jump to match" }
        if isCodeSymbolMode { return "↵ jump to symbol" }
        if isSymbolMode { return "↵ jump to heading" }
        if isCommandMode { return "↵ run" }
        return "↵ open"
    }

    /// Dispatch the routed query's submit action (TSK-677). The routing rules
    /// (`SearchRouter.route`) are host-tested in ViewerCore; this is only the
    /// thin view-side dispatch into the model.
    private func submit() {
        // In-file search (`#`) / symbol (`@`) jump to the SELECTED row (Return
        // after arrow-navigating); the router's `.jumpInFile` can't carry the
        // selection, so the view owns it here.
        if isInFileSearchMode || isSymbolMode {
            jumpToSelectedRow()
            return
        }
        switch route.submit {
        case .runGlobalSearch(let term):
            // Hand off to the cross-file engine via the unified front door.
            model.dismissPalette()
            model.openGlobalSearch(query: term)
        case .goToLine(let line):
            model.scrollSource(toLine: line)
            model.dismissPalette()
        case .runCommand:
            runSelectedCommand()
        case .openFile:
            openSelected()
        case .jumpInFile:
            // Reached only if a future in-file route bypasses the early return.
            jumpToSelectedRow()
        case .none:
            model.dismissPalette()
        }
    }

    /// Hint shown in global-search mode (`?term`) — TSK-677. The actual results
    /// render in the dedicated cross-file overlay after Return (it has its own
    /// scope picker, regex/case toggles, and replace flow), so the palette only
    /// frames the action here rather than duplicating that surface.
    @ViewBuilder private var globalSearchHint: some View {
        VStack(spacing: 6) {
            Spacer().frame(height: 24)
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22)).foregroundStyle(.secondary)
            if route.term.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Search across all files…").foregroundStyle(.secondary).font(.callout)
            } else {
                Text("↵ to search all files for “\(route.term.trimmingCharacters(in: .whitespaces))”")
                    .foregroundStyle(.secondary).font(.callout)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 24)
            }
            Spacer().frame(height: 24)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var lineModeHint: some View {
        VStack(spacing: 6) {
            Spacer().frame(height: 24)
            Image(systemName: "number")
                .font(.system(size: 22)).foregroundStyle(.secondary)
            if let line = parsed.line {
                Text("Go to line \(line)").font(.callout)
            } else {
                Text("Type a line number").foregroundStyle(.secondary).font(.callout)
            }
            Spacer().frame(height: 24)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var inFileSearchHint: some View {
        VStack(spacing: 6) {
            Spacer().frame(height: 24)
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22)).foregroundStyle(.secondary)
            // Shown only when there are no matches (matches render as `jumpList`).
            if parsed.term.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Search this file…").foregroundStyle(.secondary).font(.callout)
            } else {
                Text("No matches in this file").foregroundStyle(.secondary).font(.callout)
            }
            Spacer().frame(height: 24)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var symbolHint: some View {
        VStack(spacing: 6) {
            Spacer().frame(height: 24)
            Image(systemName: "list.bullet")
                .font(.system(size: 22)).foregroundStyle(.secondary)
            // Shown only when there are no rows (matches render as `jumpList`).
            symbolHintText
            Spacer().frame(height: 24)
        }
        .frame(maxWidth: .infinity)
    }

    /// The `@`-mode empty-state copy. Branches by source: a CODE file pulls
    /// symbols from the language server (TSK-727), a Markdown file uses its
    /// heading outline, and any other file type has no `@` source.
    @ViewBuilder private var symbolHintText: some View {
        let blank = parsed.term.trimmingCharacters(in: .whitespaces).isEmpty
        if isCodeSymbolMode {
            if codeSymbolsLoading {
                Text("Loading symbols…").foregroundStyle(.secondary).font(.callout)
            } else if blank {
                Text("Jump to a symbol…").foregroundStyle(.secondary).font(.callout)
            } else {
                Text("No matching symbol").foregroundStyle(.secondary).font(.callout)
            }
        } else if model.currentCategory == .markdown {
            if blank {
                Text("Jump to a heading…").foregroundStyle(.secondary).font(.callout)
            } else {
                Text("No matching heading").foregroundStyle(.secondary).font(.callout)
            }
        } else {
            Text("Symbols need Markdown headings or a code language")
                .foregroundStyle(.secondary).font(.callout)
        }
    }

    /// Arrow-navigable list of `#`/`@` jump targets (TSK-727 slice 5). Mirrors
    /// the command/file lists: ↑↓ + hover move `selectedIndex`, Return / click
    /// jumps to the selected target's line.
    @ViewBuilder private var jumpList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(jumpRows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 8) {
                            Text(row.primary).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(row.secondary).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == selectedIndex
                            ? Color.accentColor.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                        .onHover { if $0 { selectedIndex = index } }
                        .onTapGesture { selectedIndex = index; jumpToSelectedRow() }
                        .id(index)
                        .accessibilityIdentifier("mdv.palette.jump.\(index)")
                    }
                }
            }
            .frame(maxHeight: 360)
            .onChange(of: selectedIndex) { _, new in
                guard scrollOnSelectionChange else { return }
                scrollOnSelectionChange = false
                withAnimation(MotionGate.animation(.linear(duration: 0.05),
                                                   reduceMotion: reduceMotion)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private func jumpToSelectedRow() {
        if jumpRows.indices.contains(selectedIndex) {
            model.scrollSource(toLine: jumpRows[selectedIndex].line)
        }
        model.dismissPalette()
    }

    private func recomputeFiltered() {
        // Reset every mode-specific result store; the active branch repopulates
        // its own. (TSK-727: modes are `>` command, `:` line [hint-only], `#`
        // in-file, `@` heading/symbol, bare → files.)
        filtered = []
        filteredCommands = []
        inFileMatches = []
        symbolMatches = []
        codeSymbolMatches = []
        if isGlobalSearchMode {
            // Hint-only — results live in the cross-file overlay after Return.
        } else if isInFileSearchMode {
            inFileMatches = InFileSearch.matches(
                in: model.activeFileText ?? "", query: parsed.term)
        } else if isCodeSymbolMode {
            // `@` on a CODE file jumps to an LSP `documentSymbol` (TSK-727).
            // The flattened symbol list is fetched async (see `loadCodeSymbols`);
            // only the rank runs synchronously per keystroke, like the heading
            // path. `nil` ⇒ fetch hasn't landed yet → empty rows + loading hint.
            codeSymbolMatches = SymbolJump.rank(
                symbols: codeSymbols ?? [], query: parsed.term)
        } else if isSymbolMode {
            // `@` on a Markdown file jumps to a heading; headings() on a code
            // file would mis-read `#` comments as ATX headings, so gate to
            // Markdown (the code path above handles LSP-language files).
            if model.currentCategory == .markdown {
                // TSK-887: memoize the query-independent heading parse so a
                // large file isn't re-parsed on every keystroke; only rank runs.
                let headings = headingMemo.resolve(model.activeFileText ?? "") {
                    MarkdownOutline.headings(in: $0)
                }
                symbolMatches = SymbolJump.rank(headings: headings, query: parsed.term)
            }
        } else if isLineMode {
            // Hint-only — nothing to populate.
        } else if isCommandMode {
            // Command mode (UX-M / #232): every registered command, fuzzy-
            // filtered on the post-`>` query (routed through the `.fuzzy` gate).
            filteredCommands = RustFuzzyAdapter.filterWithMatches(
                model.commandRegistry.commands, query: commandQuery
            ) { $0.title }
        } else {
            filtered = RustFuzzyAdapter.filterWithMatches(merged(), query: query) {
                $0.displayName
            }
        }
    }

    /// Fetch the active code file's LSP symbols once (query-independent), then
    /// re-rank for the current query (TSK-727). Idempotent: skips if already
    /// loaded or not in code-symbol mode. The model's `fetchActiveCodeSymbols`
    /// returns `[]` on any LSP failure, so the palette degrades to the
    /// "no symbols" hint rather than hanging on the spinner forever.
    private func loadCodeSymbols() async {
        guard isCodeSymbolMode, codeSymbols == nil, !codeSymbolsLoading else { return }
        codeSymbolsLoading = true
        let syms = await model.fetchActiveCodeSymbols()
        codeSymbols = syms
        codeSymbolsLoading = false
        recomputeFiltered()
    }

    // MARK: - Command mode list

    @ViewBuilder private var commandList: some View {
        if filteredCommands.isEmpty {
            VStack {
                Spacer().frame(height: 30)
                Text("No matching commands")
                    .foregroundStyle(.secondary).font(.callout)
                Spacer().frame(height: 30)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredCommands.enumerated()), id: \.element.item.id) { index, hit in
                            CommandRow(
                                command: hit.item,
                                matchedIndices: hit.match.matchedIndices,
                                isSelected: index == selectedIndex,
                                onHoverChanged: { hovering in
                                    if hovering { selectedIndex = index }
                                }
                            ) {
                                selectedIndex = index
                                runSelectedCommand()
                            }
                            .id(index)
                            .accessibilityIdentifier("mdv.palette.command.\(index)")
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: selectedIndex) { _, new in
                    guard scrollOnSelectionChange else { return }
                    scrollOnSelectionChange = false
                    withAnimation(MotionGate.animation(.linear(duration: 0.05),
                                                       reduceMotion: reduceMotion)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
    }

    private func runSelectedCommand() {
        guard filteredCommands.indices.contains(selectedIndex) else { return }
        let cmd = filteredCommands[selectedIndex].item
        // Dismiss FIRST so a command that itself presents an overlay
        // (e.g. show-cross-search, show-goto) isn't immediately hidden
        // behind the palette's own dismissal.
        model.dismissPalette()
        query = ""
        selectedIndex = 0
        model.invokeCommand(id: cmd.id)
    }

    // Invisible buttons that catch ↑ / ↓ globally inside the palette without
    // stealing them from the focused TextField for left/right cursor motion.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("", action: { moveSelection(-1) })
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("", action: { moveSelection(1) })
                .keyboardShortcut(.downArrow, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func moveSelection(_ delta: Int) {
        let count: Int
        if isInFileSearchMode || isSymbolMode {
            count = jumpRows.count
        } else if isCommandMode {
            count = filteredCommands.count
        } else {
            count = filtered.count
        }
        guard count > 0 else { return }
        scrollOnSelectionChange = true   // keyboard nav scrolls; hover does not
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func openSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        let entry = filtered[selectedIndex].item
        model.open(url: entry.url)
        model.dismissPalette()
        query = ""
        selectedIndex = 0
    }

    private var emptyState: some View {
        VStack {
            Spacer().frame(height: 30)
            Text(model.recents.isEmpty ? "No recent files" : "No matches")
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer().frame(height: 30)
        }
    }
}

private struct PaletteRow: View {
    let entry: HistoryEntry
    let matchedIndices: [Int]
    let isSelected: Bool
    let isBookmark: Bool
    let onUnbookmark: () -> Void
    var onHoverChanged: (Bool) -> Void = { _ in }
    let action: () -> Void
    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if isBookmark {
                        Image(systemName: "star.fill")
                            .foregroundStyle(isSelected ? .white : Color.yellow)
                            .frame(width: 16)
                    } else {
                        // Bookmarks aside, use the two-system file icon
                        // (chips + glyphs) for visual parity with the
                        // sidebar and tabs.
                        FileIconView(
                            url: entry.url,
                            isDirectory: entry.kind == .folder,
                            isExpanded: entry.kind == .folder,
                            size: .tree
                        )
                        .frame(width: 16, height: 16)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributedName)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(entry.url.path)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if isBookmark && isHovering {
                    Button(action: onUnbookmark) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(isSelected ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove bookmark")
                    .accessibilityLabel("Remove bookmark for \(entry.displayName)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        // UIRESP-04/13: hover affordance + pointing-hand cursor. The
        // accent-selected row paints its own background, so suppress the
        // style's hover fill there to avoid muddying the accent colour;
        // the cursor + pressed feedback still apply.
        .buttonStyle(RowHoverButtonStyle(cornerRadius: 0, suppressesHoverFill: isSelected))
        .onHover {
            isHovering = $0
            onHoverChanged($0)
        }
    }

    private var iconName: String {
        if isBookmark { return "star.fill" }
        return entry.kind == .folder ? "folder" : "doc.text"
    }

    /// Matched-glyph bolding via the shared `FuzzyHighlight` helper
    /// (TSK-282 extracted it so the sidebar filter renders identically).
    private var attributedName: AttributedString {
        FuzzyHighlight.attributed(
            entry.displayName,
            matchedIndices: matchedIndices,
            size: 13,
            regular: isSelected ? .white : .primary,
            highlight: isSelected ? .white : .accentColor
        )
    }
}

/// One row in the palette's command mode (UX-M / #232). Shows the
/// command title (with fuzzy-match highlighting), its category, and its
/// effective keyboard shortcut as macOS glyphs. Commands with no script
/// verb (window/NSApp-coupled — see the GAP list) render dimmed and
/// non-actionable.
private struct CommandRow: View {
    let command: CommandDescriptor
    let matchedIndices: [Int]
    let isSelected: Bool
    var onHoverChanged: (Bool) -> Void = { _ in }
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .foregroundStyle(isSelected ? .white
                        : (command.isPaletteInvokable ? Color.accentColor : .secondary))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributedTitle)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(command.category.title)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let glyphs = command.defaultShortcut?.glyphString {
                    Text(glyphs)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
            .opacity(command.isPaletteInvokable ? 1.0 : 0.55)
        }
        .buttonStyle(RowHoverButtonStyle(cornerRadius: 0, suppressesHoverFill: isSelected))
        .disabled(!command.isPaletteInvokable)
        .help(command.isPaletteInvokable ? command.title
            : "\(command.title) — available from the menu only")
        .onHover { onHoverChanged($0) }
    }

    private var attributedTitle: AttributedString {
        var out = AttributedString(command.title)
        let regular: Color = isSelected ? .white : .primary
        let highlight: Color = isSelected ? .white : .accentColor
        out.foregroundColor = regular
        let matchedSet = Set(matchedIndices)
        var charIndex = 0
        var cur = out.startIndex
        while cur < out.endIndex {
            let next = out.characters.index(after: cur)
            if matchedSet.contains(charIndex) {
                out[cur..<next].foregroundColor = highlight
                out[cur..<next].font = .system(size: 13, weight: .semibold)
            }
            cur = next
            charIndex += 1
        }
        return out
    }
}

extension Shortcut {
    /// macOS menu-glyph rendering of the shortcut (e.g. `⌘⇧F`, `⌥⌘[`).
    /// Modifier order matches the platform convention (⌃⌥⇧⌘). Symbolic
    /// keys map to their arrow / whitespace glyphs.
    var glyphString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += Self.keyGlyph(key)
        return s
    }

    private static func keyGlyph(_ key: String) -> String {
        switch key {
        case "left":   return "←"
        case "right":  return "→"
        case "up":     return "↑"
        case "down":   return "↓"
        case "tab":    return "⇥"
        case "space":  return "␣"
        case "escape": return "⎋"
        case "return": return "↩"
        case "delete": return "⌫"
        case "backslash": return "\\"
        default:       return key.uppercased()
        }
    }
}
