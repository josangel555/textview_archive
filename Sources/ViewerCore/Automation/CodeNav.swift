import Foundation

/// TSK-1192 — semantic code-nav for agents: the `who_calls` flow
/// (workspace-symbol lookup → best-definition pick → references), built on
/// whatever LSP is live via injected async closures so the ORCHESTRATION is
/// host-testable without a language server. The MCP tool surface lives in
/// `MCPToolCatalog`; the live wiring in `DocumentModel+AutomationHost`.
public enum CodeNav {

    /// One code location, editor-facing (1-based line).
    public struct Location: Sendable, Equatable {
        public let path: String
        public let line: Int
        public init(path: String, line: Int) {
            self.path = path
            self.line = line
        }
    }

    /// The `who_calls` answer: where the symbol is defined and every
    /// reference the server knows (the definition itself excluded).
    public struct WhoCalls: Sendable {
        public let symbol: String
        public let definition: Location
        public let callers: [Location]
        public let truncated: Bool
        public init(symbol: String, definition: Location, callers: [Location], truncated: Bool) {
            self.symbol = symbol
            self.definition = definition
            self.callers = callers
            self.truncated = truncated
        }
    }

    /// Callers cap — agents want the seam, not a firehose; `truncated`
    /// tells them to narrow the query when it trips.
    public static let maxCallers = 200

    /// Pick the definition to chase among workspace-symbol candidates:
    /// exact name match first, then case-insensitive exact, then prefix,
    /// then the shortest name (the least-decorated candidate). Ties break
    /// to the earliest (servers rank by relevance).
    public static func pickBest(query: String, names: [String]) -> Int? {
        guard !names.isEmpty else { return nil }
        if let i = names.firstIndex(of: query) { return i }
        let lowered = query.lowercased()
        if let i = names.firstIndex(where: { $0.lowercased() == lowered }) { return i }
        if let i = names.firstIndex(where: { $0.hasPrefix(query) }) { return i }
        return names.indices.min { names[$0].count < names[$1].count }
    }

    /// The `who_calls` orchestration. `nil` = no definition found (no
    /// symbol match, or no LSP live for the workspace). Reference lookups
    /// pass the definition's LSP-native (0-based) position straight back
    /// to the server — no editor-line conversion in between.
    public static func whoCalls(
        query: String,
        workspaceSymbol: (String) async throws -> [LSPWorkspaceSymbol],
        references: (URL, Int, Int) async throws -> [LSPLocation]
    ) async -> WhoCalls? {
        guard let symbols = try? await workspaceSymbol(query), !symbols.isEmpty,
              let pick = pickBest(query: query, names: symbols.map(\.name)) else {
            return nil
        }
        let def = symbols[pick]
        guard let defURL = URL(string: def.location.uri), defURL.isFileURL else { return nil }
        let defLine = def.location.range.start.line
        let defChar = def.location.range.start.character
        let refs = (try? await references(defURL, defLine, defChar)) ?? []
        var callers: [Location] = []
        for r in refs {
            guard let u = URL(string: r.uri), u.isFileURL else { continue }
            // The definition itself comes back with includeDeclaration —
            // drop it; the agent asked who CALLS.
            if u.path == defURL.path && r.range.start.line == defLine { continue }
            callers.append(Location(path: u.path, line: r.range.start.line + 1))
            if callers.count == maxCallers { break }
        }
        return WhoCalls(
            symbol: def.name,
            definition: Location(path: defURL.path, line: defLine + 1),
            callers: callers,
            truncated: refs.count > maxCallers)
    }

    /// Shape the answer for the MCP wire.
    public static func format(_ w: WhoCalls) -> MCP.Value {
        .object([
            "symbol": .string(w.symbol),
            "definition": .string("\(w.definition.path):\(w.definition.line)"),
            "callerCount": .int(w.callers.count),
            "truncated": .bool(w.truncated),
            "callers": .array(w.callers.map { .string("\($0.path):\($0.line)") }),
        ])
    }

    // MARK: - position-based nav (TSK-1560: goto_definition / find_references)

    /// The position-nav answer: the resolved locations, capped.
    public struct NavLocations: Sendable, Equatable {
        public let locations: [Location]
        public let truncated: Bool
        public init(locations: [Location], truncated: Bool) {
            self.locations = locations
            self.truncated = truncated
        }
    }

    /// Convert LSP locations (0-based lines, uri strings) into editor-facing
    /// `Location`s (1-based lines, paths): non-file URIs are skipped, and the
    /// list caps at [`maxCallers`] with `truncated` set when the cap cut real
    /// results (skipped non-file URIs don't count as truncation).
    public static func navLocations(from lsp: [LSPLocation]) -> NavLocations {
        var out: [Location] = []
        var truncated = false
        for l in lsp {
            guard let u = URL(string: l.uri), u.isFileURL else { continue }
            if out.count == maxCallers {
                truncated = true
                break
            }
            out.append(Location(path: u.path, line: l.range.start.line + 1))
        }
        return NavLocations(locations: out, truncated: truncated)
    }

    /// The `goto_definition` / `find_references` tool payload.
    public static func formatNav(_ n: NavLocations) -> MCP.Value {
        .object([
            "count": .int(n.locations.count),
            "truncated": .bool(n.truncated),
            "locations": .array(n.locations.map { .string("\($0.path):\($0.line)") }),
        ])
    }

    // MARK: - rename (TSK-1561: rename_symbol, dry-run default)

    /// The `rename_symbol` answer. Dry-run carries the WorkspaceEdit
    /// SUMMARY only (what WOULD change); an applied run additionally says
    /// which files' open buffers took the edits and which files were
    /// SKIPPED because they aren't open (the standard rename policy:
    /// unopened files are never written — the agent can `open_path` them
    /// and re-run).
    public struct RenameOutcome: Sendable, Equatable {
        public struct FileEdits: Sendable, Equatable {
            public let path: String
            public let editCount: Int
            public init(path: String, editCount: Int) {
                self.path = path
                self.editCount = editCount
            }
        }
        public let files: [FileEdits]
        public let applied: Bool
        public let appliedPaths: [String]
        public let skippedPaths: [String]
        public init(files: [FileEdits], applied: Bool,
                    appliedPaths: [String] = [], skippedPaths: [String] = []) {
            self.files = files
            self.applied = applied
            self.appliedPaths = appliedPaths
            self.skippedPaths = skippedPaths
        }
    }

    /// Summarize a WorkspaceEdit (uri → edits) into per-file edit counts:
    /// file URIs only, sorted by path for a stable payload.
    public static func renameSummary(
        from workspaceEdit: [String: [LSPTextEdit]]
    ) -> [RenameOutcome.FileEdits] {
        workspaceEdit.compactMap { uri, edits -> RenameOutcome.FileEdits? in
            guard !edits.isEmpty, let u = URL(string: uri), u.isFileURL else { return nil }
            return RenameOutcome.FileEdits(path: u.path, editCount: edits.count)
        }
        .sorted { $0.path < $1.path }
    }

    /// The `rename_symbol` tool payload.
    public static func formatRename(_ r: RenameOutcome) -> MCP.Value {
        var obj: [String: MCP.Value] = [
            "applied": .bool(r.applied),
            "fileCount": .int(r.files.count),
            "totalEdits": .int(r.files.reduce(0) { $0 + $1.editCount }),
            "files": .array(r.files.map {
                .object(["path": .string($0.path), "edits": .int($0.editCount)])
            }),
        ]
        if r.applied {
            obj["appliedFiles"] = .array(r.appliedPaths.map { .string($0) })
            obj["skippedFiles"] = .array(r.skippedPaths.map { .string($0) })
        }
        return .object(obj)
    }
}
