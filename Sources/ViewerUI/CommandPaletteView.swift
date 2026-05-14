import SwiftUI
import ViewerCore

struct CommandPaletteView: View {
    @ObservedObject var model: DocumentModel
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var filtered: [(item: HistoryEntry, match: FuzzyMatcher.Match)] = []
    @FocusState private var fieldFocused: Bool

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
                                    isSelected: index == selectedIndex
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
                        withAnimation(.linear(duration: 0.05)) {
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
        .background(Color(nsColor: .windowBackgroundColor))
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
            recomputeFiltered()
        }
        .onChange(of: model.recents) { _, _ in recomputeFiltered() }
    }

    private func recomputeFiltered() {
        filtered = FuzzyMatcher.filterWithMatches(model.recents, query: query) {
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: entry.kind == .folder ? "folder" : "doc.text")
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributedName)
                        .font(.system(size: 13))
                    Text(entry.url.path)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
