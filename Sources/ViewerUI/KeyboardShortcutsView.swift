import SwiftUI
import ViewerCore

/// The Keyboard Shortcuts help page (TSK-678) — every bound shortcut, grouped by
/// category, with a live filter. Opened from Help → Keyboard Shortcuts. Reads
/// the EFFECTIVE `CommandRegistry` (built-in defaults + the user's
/// `keybinding.json` overrides), so a rebound key shows its current binding.
///
/// The catalog + glyph rendering + filter are pure (host-tested in
/// `KeyboardShortcutsCatalogTests`); this view is the thin presentation shell.
public struct KeyboardShortcutsView: View {
    private let catalog: KeyboardShortcutsCatalog
    @State private var query = ""

    public init(registry: CommandRegistry) {
        self.catalog = KeyboardShortcutsCatalog(registry: registry)
    }

    public var body: some View {
        let shown = catalog.filtered(query)
        VStack(spacing: 0) {
            searchField
            Divider()
            if shown.sections.isEmpty {
                emptyState
            } else {
                list(shown)
            }
        }
        .frame(minWidth: 360, minHeight: 280)
        .accessibilityIdentifier("mdv.keyboardShortcuts")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter shortcuts", text: $query)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("mdv.keyboardShortcuts.filter")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No shortcuts match “\(query)”.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func list(_ catalog: KeyboardShortcutsCatalog) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(catalog.sections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.title)
                                Spacer(minLength: 16)
                                Text(entry.glyph)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            Divider()
                        }
                    } header: {
                        Text(section.title)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.bar)
                    }
                }
            }
        }
    }
}
