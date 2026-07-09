import SwiftUI
import ViewerCore

/// TSK-1475 — the terminal-favorites management editor: rename (inline),
/// reorder (up/down), and remove the curated command shortlist, bound to the
/// host-tested TerminalFavoritesEditorModel. A filter box narrows a long
/// list. Self-contained so it can drop into a settings sub-page or a sheet;
/// the mount point + on-screen validation are the render tail.
struct TerminalFavoritesEditor: View {

    @ObservedObject var model: TerminalFavoritesEditorModel
    var uiScale: CGFloat = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Terminal favorites")
                    .font(.system(size: 12 * uiScale, weight: .semibold))
                Spacer()
                Text("\(model.rows.count)")
                    .font(.system(size: 11 * uiScale))
                    .foregroundStyle(.secondary)
            }
            if !model.isEmpty {
                filterField
            }
            Divider()
            if model.isEmpty {
                Text("No favorites yet. Add commands from the terminal command palette.")
                    .font(.system(size: 11 * uiScale))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.visibleRows) { fav in
                            row(fav)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .accessibilityIdentifier("mdv.terminalFavorites.editor")
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 10 * uiScale)).foregroundStyle(.tertiary)
            TextField("Filter favorites", text: $model.filterQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11 * uiScale))
                .accessibilityIdentifier("mdv.terminalFavorites.filter")
        }
    }

    private func row(_ fav: TerminalFavoritesStore.Favorite) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // Inline rename: edit the title, commit on submit.
                TextField("Title (optional)", text: Binding(
                    get: { fav.title },
                    set: { model.rename(command: fav.command, to: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12 * uiScale, weight: .medium))
                .accessibilityIdentifier("mdv.terminalFavorites.title.\(fav.command)")
                Text(fav.command)
                    .font(.system(size: 10 * uiScale, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { model.moveUp(command: fav.command) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("mdv.terminalFavorites.up.\(fav.command)")
            Button { model.moveDown(command: fav.command) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("mdv.terminalFavorites.down.\(fav.command)")
            Button(role: .destructive) { model.remove(command: fav.command) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("mdv.terminalFavorites.remove.\(fav.command)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
