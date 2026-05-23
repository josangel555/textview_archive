import SwiftUI
import ViewerCore

/// Sidebar section that renders `textDocument/documentSymbol` for the
/// currently-active file. Visibility is **language-gated**: if the file
/// has no registered LSP server (e.g. `.md`, `.txt`), the section is
/// not shown at all. This avoids "Outline" forever appearing empty for
/// the markdown-viewer's primary use case.
///
/// Refresh policy: the section requests symbols once per `fileURL` and
/// caches the result. The viewer is read-only so we don't track edits.
/// Callers can manually invalidate via the model's `reload()` if they
/// re-open a file from disk.
@MainActor
public final class LSPOutlineModel: ObservableObject {
    @Published public private(set) var symbols: [LSPDocumentSymbol] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isSupported: Bool = false

    private let pool: LSPPool
    private let registry: LSPLanguageRegistry
    private var currentFile: URL?
    private var inflightTask: Task<Void, Never>?

    public init(
        pool: LSPPool,
        registry: LSPLanguageRegistry = .default
    ) {
        self.pool = pool
        self.registry = registry
    }

    /// Set the active file. Triggers a documentSymbol request if the
    /// file's language has a registered LSP entry. Pass nil to clear.
    public func setFile(_ url: URL?, text: String?) {
        inflightTask?.cancel()
        currentFile = url
        guard let url = url, let text = text else {
            self.isSupported = false
            self.symbols = []
            self.errorMessage = nil
            return
        }
        guard registry.language(for: url) != nil else {
            self.isSupported = false
            self.symbols = []
            self.errorMessage = nil
            return
        }
        self.isSupported = true
        self.isLoading = true
        self.errorMessage = nil
        let pool = self.pool
        inflightTask = Task { @MainActor [weak self] in
            do {
                // ensureOpened is a no-op if the file was previously
                // opened via this pool; in that case the server still
                // holds the stale text. didChange(_:_:) sends a
                // version-bumped full-text update so subsequent
                // requests (documentSymbol, hover, etc.) read the
                // latest contents. Safe to call before any didOpen —
                // pool no-ops when the file isn't tracked.
                try await pool.ensureOpened(fileURL: url, text: text)
                try await pool.didChange(fileURL: url, text: text)
                // Pool-routed call records request count + latency for
                // the diagnostics panel.
                let syms = try await pool.documentSymbol(fileURL: url)
                guard let self = self, self.currentFile == url else { return }
                self.symbols = syms
                self.isLoading = false
            } catch {
                guard let self = self, self.currentFile == url else { return }
                self.symbols = []
                self.isLoading = false
                self.errorMessage = "LSP unavailable"
            }
        }
    }

    public func reload() {
        // Best effort — caller must re-supply file + text.
        guard let url = currentFile else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        setFile(url, text: text)
    }
}

/// SwiftUI rendering of the outline tree. Renders a header row in the
/// standard sidebar-section style (chevron + uppercase label) followed
/// by a fixed-height scrollable body. Matches Bookmarks / Search / Git
/// for visual consistency in the accordion.
public struct LSPOutlineSection: View {

    @ObservedObject var model: LSPOutlineModel
    let onJump: (LSPDocumentSymbol) -> Void
    @State private var isExpanded: Bool = true
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    public init(
        model: LSPOutlineModel,
        onJump: @escaping (LSPDocumentSymbol) -> Void
    ) {
        self.model = model
        self.onJump = onJump
    }

    public var body: some View {
        if model.isSupported {
            VStack(spacing: 0) {
                header
                if isExpanded {
                    ScrollView {
                        outlineBody
                    }
                    .frame(height: bodyHeight)
                }
            }
            .sidebarSectionContainer()
            .accessibilityIdentifier("mdv.lspOutline")
        } else {
            EmptyView()
        }
    }

    private var header: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 4) {
                SidebarSectionHeaderLabel(
                    title: "Outline",
                    isExpanded: isExpanded
                )
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.mini)
                } else if !model.symbols.isEmpty {
                    Text("\(model.symbols.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarHeaderRow()
    }

    @ViewBuilder
    private var outlineBody: some View {
        if model.isLoading {
            SidebarEmptyPlaceholder(message: "Loading symbols…")
        } else if let msg = model.errorMessage {
            SidebarEmptyPlaceholder(message: msg)
        } else if model.symbols.isEmpty {
            SidebarEmptyPlaceholder(message: "No symbols.")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                OutlineGroup(model.symbols, id: \.self, children: \.maybeChildren) { sym in
                    SymbolRow(symbol: sym)
                        .onTapGesture(count: 1) {
                            onJump(sym)
                        }
                }
            }
        }
    }
}

private struct SymbolRow: View {
    let symbol: LSPDocumentSymbol

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: symbol.kind))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(symbol.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = symbol.detail, !detail.isEmpty {
                Text(detail)
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func iconName(for kind: LSPSymbolKind) -> String {
        switch kind {
        case .file, .module, .package, .namespace: return "shippingbox"
        case .class:        return "c.square"
        case .struct:       return "s.square"
        case .enum:         return "e.square"
        case .interface:    return "i.square"
        case .method, .function, .constructor: return "function"
        case .property, .field: return "circle.grid.cross"
        case .variable, .constant: return "v.square"
        case .enumMember:   return "circle.dotted"
        case .typeParameter: return "t.square"
        case .event:        return "bolt"
        case .operator:     return "plus.slash.minus"
        default:            return "questionmark.square.dashed"
        }
    }
}

private extension LSPDocumentSymbol {
    /// OutlineGroup wants `nil` for leaf rows (otherwise it always
    /// shows a disclosure caret). Map empty-children → nil here.
    var maybeChildren: [LSPDocumentSymbol]? {
        children.isEmpty ? nil : children
    }
}
