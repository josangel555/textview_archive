import Foundation

/// Ranks a markdown document's headings against a palette `@` query (TSK-727
/// slice 4) so the palette can jump to a heading by name. Pure — the heading
/// source (`MarkdownOutline.headings`) and the fuzzy matcher are both
/// host-tested; this composes them. The palette `@`-mode hint / jump render is
/// the view tail.
public enum SymbolJump {

    /// Rank `headings` for the `@` operator: an empty/blank query returns every
    /// heading in document order; otherwise fuzzy-rank by title (best first),
    /// dropping non-matches. Routed through the shared fuzzy adapter so it
    /// matches the palette's command/file ranking behaviour.
    public static func rank(headings: [MarkdownHeading], query: String) -> [MarkdownHeading] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return headings }
        return RustFuzzyAdapter.filterWithMatches(headings, query: q) { $0.title }
            .map { $0.item }
    }

    /// One `@`-mode jump target sourced from an LSP `documentSymbol` tree
    /// (TSK-727 code-file `@`). Flattened from the hierarchical
    /// `LSPDocumentSymbol` into the same shape the palette's `JumpRow` consumes:
    /// a display `name`, a `detail` secondary label (kind + container path), and
    /// a 1-based `line` to jump to.
    public struct CodeSymbol: Equatable, Sendable {
        /// The symbol's own name (leaf, not qualified — qualification lives in
        /// `container` so fuzzy matching keys on the short name the user types).
        public let name: String
        /// Dotted container path of enclosing symbols (e.g. `Foo.Bar` for a
        /// method nested two deep), or empty for a top-level symbol.
        public let container: String
        /// Human-readable kind label (e.g. `func`, `struct`) for the secondary
        /// row label. Derived from `LSPSymbolKind`.
        public let kindLabel: String
        /// 1-based line to scroll to — the symbol's `selectionRange` start
        /// (where the name sits), converted from LSP's 0-based line.
        public let line: Int

        public init(name: String, container: String, kindLabel: String, line: Int) {
            self.name = name
            self.container = container
            self.kindLabel = kindLabel
            self.line = line
        }

        /// Secondary label for the palette row: kind, plus the container path
        /// when nested (e.g. `func · Foo.Bar`).
        public var detail: String {
            container.isEmpty ? kindLabel : "\(kindLabel) · \(container)"
        }
    }

    /// Flatten an LSP `documentSymbol` tree into an ordered, flat list of
    /// `CodeSymbol` jump targets. Pre-order DFS preserves document/nesting
    /// order (parent before its children), so an empty query lists symbols the
    /// way they appear in the file. Each child carries its ancestor names as a
    /// dotted `container` for disambiguation, while `name` stays the short leaf
    /// the user fuzzy-matches against.
    ///
    /// The jump line is `selectionRange.start.line` (the identifier location),
    /// converted from LSP's 0-based line to the viewer's 1-based line.
    public static func flatten(_ symbols: [LSPDocumentSymbol]) -> [CodeSymbol] {
        var out: [CodeSymbol] = []
        func walk(_ syms: [LSPDocumentSymbol], container: String) {
            for s in syms {
                let trimmed = s.name.trimmingCharacters(in: .whitespaces)
                // Skip anonymous / empty-named entries — they'd render as a
                // blank, un-jumpable row. (Some servers emit empty names for
                // synthetic scopes.)
                if !trimmed.isEmpty {
                    out.append(CodeSymbol(
                        name: trimmed,
                        container: container,
                        kindLabel: kindLabel(s.kind),
                        line: s.selectionRange.start.line + 1))
                }
                if !s.children.isEmpty {
                    let childContainer = trimmed.isEmpty
                        ? container
                        : (container.isEmpty ? trimmed : "\(container).\(trimmed)")
                    walk(s.children, container: childContainer)
                }
            }
        }
        walk(symbols, container: "")
        return out
    }

    /// Rank flattened code symbols for the `@` operator: an empty/blank query
    /// returns every symbol in document order; otherwise fuzzy-rank by the
    /// short `name` (best first), dropping non-matches. Mirrors `rank(headings:)`
    /// so the palette's `#`/`@` behaviour is uniform across markdown and code.
    public static func rank(symbols: [CodeSymbol], query: String) -> [CodeSymbol] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return symbols }
        return RustFuzzyAdapter.filterWithMatches(symbols, query: q) { $0.name }
            .map { $0.item }
    }

    /// Convenience: flatten an LSP `documentSymbol` tree and rank it in one
    /// step — the exact composition the palette's code-file `@` mode performs.
    public static func rank(documentSymbols: [LSPDocumentSymbol], query: String) -> [CodeSymbol] {
        rank(symbols: flatten(documentSymbols), query: query)
    }

    /// A short, stable kind label for the secondary palette row. Lowercase
    /// keyword-ish where a language keyword fits; generic words otherwise.
    /// Unknown/server-vendored kinds collapse to `symbol`.
    static func kindLabel(_ kind: LSPSymbolKind) -> String {
        switch kind {
        case .file:          return "file"
        case .module:        return "module"
        case .namespace:     return "namespace"
        case .package:       return "package"
        case .class:         return "class"
        case .method:        return "method"
        case .property:      return "property"
        case .field:         return "field"
        case .constructor:   return "init"
        case .enum:          return "enum"
        case .interface:     return "interface"
        case .function:      return "func"
        case .variable:      return "var"
        case .constant:      return "const"
        case .string:        return "string"
        case .number:        return "number"
        case .boolean:       return "bool"
        case .array:         return "array"
        case .object:        return "object"
        case .key:           return "key"
        case .null:          return "null"
        case .enumMember:    return "case"
        case .struct:        return "struct"
        case .event:         return "event"
        case .operator:      return "operator"
        case .typeParameter: return "typeparam"
        case .other:         return "symbol"
        }
    }
}
