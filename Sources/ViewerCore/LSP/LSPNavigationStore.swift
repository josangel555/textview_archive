import Foundation

/// @MainActor store for the unified References / Workspace-Symbol
/// panel. Owns the currently-displayed result list, the mode (refs vs
/// symbols), the loading state, and the originating query string.
///
/// Why a single store for both? The result-row shape is identical
/// (location + label + optional container), so the panel only needs
/// to switch labels and the data source. Two stores would duplicate
/// the loading/error plumbing for no UX win.
@MainActor
public final class LSPNavigationStore: ObservableObject {

    public enum Mode: String, Sendable {
        case references
        case workspaceSymbols
    }

    /// One row in the panel. `containerName` is non-nil for workspace
    /// symbols (the class/module that holds the symbol). `preview` is
    /// a short line-of-context snippet for references rows (UI loads
    /// it lazily from disk; nil when not yet read).
    public struct Row: Identifiable, Sendable, Hashable {
        public let id: String
        public let displayName: String
        public let containerName: String?
        public let kindIconName: String?
        public let location: LSPLocation
        public var preview: String?

        public init(
            id: String, displayName: String,
            containerName: String?, kindIconName: String?,
            location: LSPLocation, preview: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.containerName = containerName
            self.kindIconName = kindIconName
            self.location = location
            self.preview = preview
        }
    }

    @Published public private(set) var mode: Mode = .workspaceSymbols
    @Published public private(set) var query: String = ""
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var rows: [Row] = []

    /// Cached "where the request originated" — for the references mode,
    /// this is the (file, line, col) the user was sitting at when they
    /// asked. Lets the panel re-run the query on demand.
    @Published public private(set) var contextDescription: String?

    public init() {}

    // MARK: - References

    /// Replace the rows with a references result set. `originLabel` is
    /// rendered in the panel header so the user remembers what they
    /// asked about ("References to `Foo`" or similar).
    public func setReferences(
        originLabel: String, locations: [LSPLocation]
    ) {
        mode = .references
        query = ""
        isLoading = false
        errorMessage = nil
        contextDescription = originLabel
        rows = locations.enumerated().map { (i, loc) in
            let fileName = URL(string: loc.uri)?.lastPathComponent ?? loc.uri
            let line = loc.range.start.line + 1
            return Row(
                id: "ref-\(i)-\(loc.uri)#\(loc.range.start.line):\(loc.range.start.character)",
                displayName: "\(fileName):\(line)",
                containerName: URL(string: loc.uri)?.deletingLastPathComponent().path,
                kindIconName: nil,
                location: loc)
        }
    }

    // MARK: - Workspace symbols

    public func setWorkspaceSymbols(query: String, symbols: [LSPWorkspaceSymbol]) {
        mode = .workspaceSymbols
        self.query = query
        isLoading = false
        errorMessage = nil
        contextDescription = nil
        rows = symbols.enumerated().map { (i, sym) in
            Row(
                id: "ws-\(i)-\(sym.location.uri)#\(sym.location.range.start.line):\(sym.location.range.start.character)",
                displayName: sym.name,
                containerName: sym.containerName,
                kindIconName: Self.iconName(for: sym.kind),
                location: sym.location)
        }
    }

    public func startLoading(mode: Mode, query: String) {
        self.mode = mode
        self.query = query
        self.isLoading = true
        self.errorMessage = nil
        // Don't clear rows during incremental load — feels less janky
        // when the user is typing fast in workspace-symbol mode.
    }

    public func setError(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    public func clear() {
        rows = []
        query = ""
        contextDescription = nil
        errorMessage = nil
        isLoading = false
    }

    /// SF Symbols mapping for LSP SymbolKind. Mirrors `LSPOutlineSection`'s
    /// `iconName(for:)`; lifted here so the navigation panel doesn't
    /// have to import the UI module.
    public static func iconName(for kind: LSPSymbolKind) -> String {
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
