import SwiftUI
import ViewerCore

// MARK: - Symbol mode (LSP workspace symbols)
//
// Sidebar section that hosts both `textDocument/references` results
// and `workspace/symbol` search. Same row layout for both; the only
// per-mode difference is the header label and the data source.
//
// Why a single panel for two LSP routes? `LSPNavigationStore`
// normalizes both to the same `Row` shape. The user shouldn't have
// to learn two panels with identical mechanics.
//
// Coexistence note: when the parallel
// `feat/search-scope-and-folder-context` agent lands a unified search
// panel with mode pills, the workspace-symbol mode here becomes a
// sixth pill in that panel — wire via `LSPNavigationStore`. Until
// that arrives, this section stands on its own.

/// Sidebar section that lists LSP navigation results (references or
/// workspace symbols).
public struct LSPNavigationPanel: View {

    @ObservedObject var store: LSPNavigationStore
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight
    @State private var isExpanded: Bool = true
    @State private var symbolQuery: String = ""

    let onJump: (LSPLocation) -> Void
    let onSearchWorkspaceSymbols: (String) -> Void
    /// Closure that scales a base font size by the active UI-zoom
    /// factor. Threaded from the host (`DocumentModel.uiSize(_:)`) so
    /// the section's header tracks user-controlled UI zoom. Defaults
    /// to identity for call sites without a document model. Not
    /// `@Sendable` — the host's `uiSize` is `@MainActor`-isolated.
    let uiSize: (CGFloat) -> CGFloat

    public init(
        store: LSPNavigationStore,
        onJump: @escaping (LSPLocation) -> Void,
        onSearchWorkspaceSymbols: @escaping (String) -> Void,
        uiSize: @escaping (CGFloat) -> CGFloat = { $0 }
    ) {
        self.store = store
        self.onJump = onJump
        self.onSearchWorkspaceSymbols = onSearchWorkspaceSymbols
        self.uiSize = uiSize
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                VStack(spacing: 0) {
                    if store.mode == .workspaceSymbols {
                        searchField
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    // No inner `Divider()` between the search field and
                    // the result list — the section already has a
                    // bottom edge supplied by `ResizableSectionDivider`
                    // (the sole "one delimiter per panel"). An inner
                    // divider here read as a duplicate hairline.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if let msg = store.errorMessage {
                                placeholder(msg)
                            } else if store.isLoading && store.rows.isEmpty {
                                placeholder("Searching…")
                            } else if store.rows.isEmpty {
                                placeholder(emptyMessage)
                            } else {
                                ForEach(store.rows) { row in
                                    NavigationRow(row: row, uiSize: uiSize)
                                        .onTapGesture { onJump(row.location) }
                                        .accessibilityIdentifier("mdv.lspNav.row.\(row.id)")
                                }
                            }
                        }
                    }
                    .frame(height: bodyHeight)
                }
            }
        }
        // Match the trailing breathing room of BOOKMARKS / SEARCH /
        // GIT — otherwise the panel ended flush with the next
        // divider and read as unfinished compared to its siblings.
        .sidebarSectionContainer()
        .accessibilityIdentifier("mdv.lspNav")
    }

    private var header: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 4) {
                SidebarSectionHeaderLabel(
                    title: headerTitle,
                    isExpanded: isExpanded,
                    uiSize: uiSize,
                    dragKind: .lspNavigation
                )
                if let ctx = store.contextDescription, store.mode == .references {
                    Text("· \(ctx)")
                        .font(.system(size: uiSize(10)))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                modePicker
                if !store.rows.isEmpty {
                    Text("\(store.rows.count)")
                        .font(.system(size: uiSize(10), weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarHeaderRow(uiSize: uiSize)
    }

    private var modePicker: some View {
        Menu {
            Button("Workspace Symbols") {
                store.setWorkspaceSymbols(query: symbolQuery, symbols: [])
                if !symbolQuery.isEmpty {
                    onSearchWorkspaceSymbols(symbolQuery)
                }
            }
            // No "References" entry: references mode requires an origin symbol,
            // which only the source-view context menu ("Find References") can
            // supply — a picker entry here was permanently disabled dead UI
            // (TSK-468). The empty-state hint documents the real entry point.
        } label: {
            Text(store.mode == .references ? "Refs" : "Symbols")
                .font(.system(size: uiSize(10)))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("mdv.lspNav.modePicker")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: uiSize(10)))
                .foregroundStyle(.secondary)
            TextField("Workspace symbol query", text: $symbolQuery)
                .textFieldStyle(.plain)
                .font(.system(size: uiSize(12)))
                .onSubmit {
                    onSearchWorkspaceSymbols(symbolQuery)
                }
                .accessibilityIdentifier("mdv.lspNav.symbolField")
            if !symbolQuery.isEmpty {
                Button(action: {
                    symbolQuery = ""
                    store.clear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: uiSize(10)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear symbol query")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var headerTitle: String {
        switch store.mode {
        case .references:        return "REFERENCES"
        case .workspaceSymbols:  return "WORKSPACE SYMBOLS"
        }
    }

    private var emptyMessage: String {
        switch store.mode {
        case .references:
            return "Right-click an identifier → Find References."
        case .workspaceSymbols:
            return symbolQuery.isEmpty
                ? "Type a query above to search."
                : "No symbols match."
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: uiSize(11)))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}

private struct NavigationRow: View {
    let row: LSPNavigationStore.Row
    /// UX-F (#228): zoom-scale helper threaded from `LSPNavigationPanel`
    /// (`DocumentModel.uiSize`). Defaults to identity for previews.
    var uiSize: (CGFloat) -> CGFloat = { $0 }

    var body: some View {
        HStack(spacing: uiSize(6)) {
            Image(systemName: row.kindIconName ?? "arrow.right.circle")
                .font(.system(size: uiSize(11)))
                .foregroundStyle(.secondary)
                .frame(width: uiSize(14))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: uiSize(4)) {
                    Text(row.displayName)
                        .font(.system(size: uiSize(12)))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let c = row.containerName, !c.isEmpty {
                        Text(c)
                            .font(.system(size: uiSize(10)))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                if let preview = row.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: uiSize(10), design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, uiSize(10))
        .padding(.vertical, uiSize(4))
        .contentShape(Rectangle())
    }
}
