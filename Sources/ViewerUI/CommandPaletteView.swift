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

    /// Unified palette routing (TSK-727): one classifier maps the leading
    /// operator to a mode — `>` command, `:` go-to-line, `#` in-file text
    /// search, bare → files. (`@` symbol jump is the remaining slice.)
    private var parsed: GotoQuery { GotoQueryParser.parse(query) }
    /// `true` when the user is in command mode (query starts with `>`).
    private var isCommandMode: Bool { parsed.mode == .command }
    /// `true` when the user is entering a `:line[:col]` jump.
    private var isLineMode: Bool { parsed.mode == .line }
    /// `true` when the user is searching the active file's text (`#term`).
    private var isInFileSearchMode: Bool { parsed.mode == .text }
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
                TextField("Search recent files… (› commands · : line · # in file)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if isCommandMode {
                commandList
            } else if isLineMode {
                lineModeHint
            } else if isInFileSearchMode {
                inFileSearchHint
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
                    if !isLineMode && !isInFileSearchMode {
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
        .background(keyboardShortcuts)
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

    /// Show bookmarks at the top of the palette (in store order),
    /// followed by recents that aren't already shown as bookmarks. The
    /// fuzzy filter applies to both. PaletteRow renders the
    /// star.fill icon when `isBookmark` is true — no need to prefix
    /// the displayName here.
    private func merged() -> [HistoryEntry] {
        let bookmarkURLs = Set(model.bookmarks.map { $0.url })
        let bookmarkAsEntries = model.bookmarks.map {
            HistoryEntry(url: $0.url, kind: .file, lastOpenedAt: $0.addedAt,
                         displayName: $0.displayName)
        }
        let extraRecents = model.recents.filter { !bookmarkURLs.contains($0.url) }
        return bookmarkAsEntries + extraRecents
    }

    private var paletteIcon: String {
        if isCommandMode { return "command" }
        if isLineMode { return "number" }
        if isInFileSearchMode { return "doc.text.magnifyingglass" }
        return "magnifyingglass"
    }

    /// Whether the footer has an actionable Return for the current mode.
    private var footerActionable: Bool {
        if isLineMode { return parsed.line != nil }
        if isInFileSearchMode { return !inFileMatches.isEmpty }
        if isCommandMode { return !filteredCommands.isEmpty }
        return !filtered.isEmpty
    }

    private var footerActionLabel: String {
        if isLineMode { return "↵ go to line" }
        if isInFileSearchMode { return "↵ jump to match" }
        if isCommandMode { return "↵ run" }
        return "↵ open"
    }

    /// Dispatch the parsed query's submit action (TSK-727). The routing rules
    /// (`GotoQuery.submitAction`) are host-tested in ViewerCore; this is only
    /// the thin view-side dispatch into the model.
    private func submit() {
        // In-file search (`#`) jumps to the first match (the parser's
        // submitAction can't compute matches — it has no file text).
        if isInFileSearchMode {
            if let first = inFileMatches.first {
                model.scrollSource(toLine: first.lineNumber)
            }
            model.dismissPalette()
            return
        }
        switch parsed.submitAction {
        case .goToLine(let line):
            model.scrollSource(toLine: line)
            model.dismissPalette()
        case .runCommand:
            runSelectedCommand()
        case .openFile:
            openSelected()
        case .none:
            model.dismissPalette()
        }
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
            if parsed.term.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Search this file…").foregroundStyle(.secondary).font(.callout)
            } else if let first = inFileMatches.first {
                Text("\(inFileMatches.count) match\(inFileMatches.count == 1 ? "" : "es") — ↵ goes to line \(first.lineNumber)")
                    .font(.callout)
            } else {
                Text("No matches in this file").foregroundStyle(.secondary).font(.callout)
            }
            Spacer().frame(height: 24)
        }
        .frame(maxWidth: .infinity)
    }

    private func recomputeFiltered() {
        if isInFileSearchMode {
            // In-file (`#`) search over the active file's text — no file/command
            // list; the hint shows the count + the first match's line.
            inFileMatches = InFileSearch.matches(
                in: model.activeFileText ?? "", query: parsed.term)
            filtered = []
            filteredCommands = []
        } else if isLineMode {
            // Line mode shows a single "go to line" hint — no list to filter.
            filtered = []
            filteredCommands = []
            inFileMatches = []
        } else if isCommandMode {
            // Command mode (UX-M / #232): list EVERY registered command,
            // fuzzy-filtered on the post-`>` query. Empty query lists all.
            // Routed through the `.fuzzy` gate (TSK-646): Rust core when
            // on, the Swift FuzzyMatcher otherwise.
            filteredCommands = RustFuzzyAdapter.filterWithMatches(
                model.commandRegistry.commands, query: commandQuery
            ) { $0.title }
            filtered = []
            inFileMatches = []
        } else {
            filtered = RustFuzzyAdapter.filterWithMatches(merged(), query: query) {
                $0.displayName
            }
            filteredCommands = []
            inFileMatches = []
        }
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
        let count = isCommandMode ? filteredCommands.count : filtered.count
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
