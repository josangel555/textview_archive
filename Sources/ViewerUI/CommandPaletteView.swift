import SwiftUI
import ViewerCore

struct CommandPaletteView: View {
    @ObservedObject var model: DocumentModel
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
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
                    .onChange(of: query) { _, _ in selectedIndex = 0 }
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
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                                PaletteRow(
                                    entry: entry,
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
        .onAppear { fieldFocused = true; selectedIndex = 0 }
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

    private var filtered: [HistoryEntry] {
        FuzzyMatcher.filter(model.recents, query: query) { $0.displayName }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let count = filtered.count
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func openSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        let entry = filtered[selectedIndex]
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
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: entry.kind == .folder ? "folder" : "doc.text")
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
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
}
