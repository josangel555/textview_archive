import SwiftUI
import ViewerCore

struct CommandPaletteView: View {
    @ObservedObject var model: DocumentModel
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var filtered: [(item: HistoryEntry, match: FuzzyMatcher.Match)] = []
    @FocusState private var fieldFocused: Bool
    /// A11Y-06: honor the system Reduce Motion setting. When set, the
    /// scroll-to-selection animation is suppressed (instant jump).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search recent files…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit { openSelected() }
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

            if filtered.isEmpty {
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
                        // Reduce Motion → nil animation → instant jump.
                        withAnimation(MotionGate.animation(.linear(duration: 0.05),
                                                           reduceMotion: reduceMotion)) {
                            proxy.scrollTo(new, anchor: .center)
                        }
                    }
                }
            }
            // Keyboard-shortcut hint footer (U-tier).
            if !filtered.isEmpty {
                Divider()
                HStack(spacing: 12) {
                    Text("↑↓ navigate").font(.caption2).foregroundStyle(.secondary)
                    Text("↵ open").font(.caption2).foregroundStyle(.secondary)
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

    private func recomputeFiltered() {
        filtered = FuzzyMatcher.filterWithMatches(merged(), query: query) {
            $0.displayName
        }
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
        guard !filtered.isEmpty else { return }
        let count = filtered.count
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

    /// Builds an AttributedString where matched characters are bolded and
    /// accent-colored. Single forward pass over the characters — O(N), not
    /// the previous O(N²) where each matched index re-walked from startIndex.
    /// `matchedIndices` index into the original `displayName` (the matcher's
    /// new contract — see FuzzyMatcher.match docs).
    private var attributedName: AttributedString {
        let name = entry.displayName
        var out = AttributedString(name)
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
