import Foundation

/// A parsed Graphviz `.dot` / `.gv` graph — the structure (directedness,
/// name, nodes, edges) extracted from the source so a viewer can show an
/// outline / node+edge summary without a layout engine (TSK-290, phase 1).
///
/// This is the host-testable *model core*. Actual graph LAYOUT/rendering is
/// a separate concern (needs a layout engine / dep — phase 2, VM-validated);
/// nothing here draws. The parser is dependency-free and pure so it's fully
/// unit-testable, mirroring `DiffParser` / `IndentDetector`.
public struct DotGraph: Equatable, Sendable {
    /// `true` for `digraph` (directed, `->` edges); `false` for `graph`
    /// (undirected, `--` edges).
    public var isDirected: Bool
    /// The optional graph id after the `graph`/`digraph` keyword.
    public var name: String?
    /// Every distinct node id, in first-seen order (a node referenced only
    /// inside an edge statement still appears here).
    public var nodes: [String]
    /// Edges in source order. Direction is `from`→`to` as written; for an
    /// undirected graph the order is just the textual order of the endpoints.
    public var edges: [DotEdge]

    public init(isDirected: Bool, name: String?, nodes: [String], edges: [DotEdge]) {
        self.isDirected = isDirected
        self.name = name
        self.nodes = nodes
        self.edges = edges
    }
}

public struct DotEdge: Equatable, Sendable {
    public var from: String
    public var to: String
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Bounded-subset Graphviz DOT parser. Supports the constructs that appear in
/// the overwhelming majority of hand-written `.dot` files:
///
///   - `strict`? `graph`|`digraph` `name`? `{ … }` header
///   - node statements: `a;` / `a [color=red]`
///   - edge chains: `a -> b -> c` (digraph) / `a -- b` (graph), optional
///     trailing `[ … ]` attribute list
///   - quoted ids (`"a b"`, with `\"` escapes) and bare ids (`[A-Za-z0-9_.]+`,
///     incl. leading-`-` numerals like `-3`)
///   - `//`, `#`, and `/* … */` comments
///   - `subgraph`/nested `{ … }` blocks — their nodes and edges are FLATTENED
///     into the top-level result (cluster grouping is not modeled in phase 1)
///   - default-attr statements (`node […]`, `edge […]`, `graph […]`) and
///     `key = value` graph attributes are skipped, not treated as nodes
///
/// NOT modeled (phase-1 bounds, documented so callers don't over-trust):
/// HTML-like `<…>` labels (skipped), ports (`a:f0`), subgraph endpoints in
/// edges (`{a b} -> c`), and attribute *values* (we keep structure, not style).
///
/// Returns `nil` when the source has no `graph`/`digraph` header (i.e. it
/// isn't a DOT document) so callers can fall back to plain text.
public enum DotGraphParser {

    public static func parse(_ source: String) -> DotGraph? {
        let tokens = tokenize(stripComments(source))
        var i = 0

        // Header: optional `strict`, then graph|digraph, optional name, `{`.
        if case .id(let kw)? = tokens[safe: i], kw.lowercased() == "strict" { i += 1 }
        guard case .id(let kind)? = tokens[safe: i] else { return nil }
        let isDirected: Bool
        switch kind.lowercased() {
        case "digraph": isDirected = true
        case "graph":   isDirected = false
        default:        return nil
        }
        i += 1

        var name: String?
        if case .id(let n)? = tokens[safe: i] { name = n; i += 1 }
        guard case .lbrace? = tokens[safe: i] else { return nil }
        i += 1   // consume `{`

        var nodes: [String] = []
        var seen = Set<String>()
        var edges: [DotEdge] = []

        func addNode(_ id: String) {
            if seen.insert(id).inserted { nodes.append(id) }
        }

        // Walk the statement stream. Subgraphs/clusters are flattened by simply
        // continuing to scan through their braces (depth tracked only so a
        // closing `}` doesn't end parsing prematurely).
        while i < tokens.count {
            switch tokens[i] {
            case .rbrace, .lbrace, .semicolon, .comma:
                i += 1
            case .lbracket:
                i = skipBracket(tokens, from: i)   // stray attr list
            case .id(let raw):
                let word = raw.lowercased()
                // Default-attr / subgraph keywords are not nodes.
                if word == "node" || word == "edge" || word == "graph" || word == "subgraph" {
                    i += 1
                    // `subgraph name` — drop the optional name too; the `{` that
                    // follows is handled by the loop (statements flatten in).
                    if word == "subgraph", case .id? = tokens[safe: i] { i += 1 }
                    if case .lbracket? = tokens[safe: i] { i = skipBracket(tokens, from: i) }
                    continue
                }
                // `id = value` graph attribute → skip both sides.
                if case .equals? = tokens[safe: i + 1] {
                    i += 2
                    if case .id? = tokens[safe: i] { i += 1 }
                    continue
                }
                // Edge chain: id (edgeOp id)+  → record each consecutive pair.
                if case .edgeOp? = tokens[safe: i + 1] {
                    addNode(raw)
                    var prev = raw
                    while case .edgeOp? = tokens[safe: i + 1],
                          case .id(let next)? = tokens[safe: i + 2] {
                        addNode(next)
                        edges.append(DotEdge(from: prev, to: next))
                        prev = next
                        i += 2
                    }
                    i += 1
                    if case .lbracket? = tokens[safe: i] { i = skipBracket(tokens, from: i) }
                    continue
                }
                // Plain node statement, optional attr list.
                addNode(raw)
                i += 1
                if case .lbracket? = tokens[safe: i] { i = skipBracket(tokens, from: i) }
            default:
                i += 1
            }
        }

        return DotGraph(isDirected: isDirected, name: name, nodes: nodes, edges: edges)
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case id(String)
        case edgeOp          // -> or --
        case lbrace, rbrace
        case lbracket, rbracket
        case semicolon, comma, equals
    }

    /// Advance past a balanced `[ … ]` attribute list; returns the index just
    /// after the matching `]` (or end). Tolerates nested brackets.
    private static func skipBracket(_ t: [Token], from start: Int) -> Int {
        var i = start, depth = 0
        while i < t.count {
            if t[i] == .lbracket { depth += 1 }
            else if t[i] == .rbracket { depth -= 1; if depth == 0 { return i + 1 } }
            i += 1
        }
        return i
    }

    private static func tokenize(_ s: String) -> [Token] {
        var out: [Token] = []
        let scalars = Array(s.unicodeScalars)
        var i = 0
        let n = scalars.count

        func isBareIDScalar(_ u: Unicode.Scalar) -> Bool {
            (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") ||
            (u >= "0" && u <= "9") || u == "_" || u == "." ||
            u.value >= 0x80   // permit unicode (Graphviz allows \200-\377+)
        }

        while i < n {
            let u = scalars[i]
            switch u {
            case " ", "\t", "\n", "\r":
                i += 1
            case "{": out.append(.lbrace); i += 1
            case "}": out.append(.rbrace); i += 1
            case "[": out.append(.lbracket); i += 1
            case "]": out.append(.rbracket); i += 1
            case ";": out.append(.semicolon); i += 1
            case ",": out.append(.comma); i += 1
            case "=": out.append(.equals); i += 1
            case "\"":
                // Quoted id with \" escapes.
                i += 1
                var buf = String.UnicodeScalarView()
                while i < n, scalars[i] != "\"" {
                    if scalars[i] == "\\", i + 1 < n {
                        buf.append(scalars[i + 1]); i += 2
                    } else {
                        buf.append(scalars[i]); i += 1
                    }
                }
                if i < n { i += 1 }   // closing quote
                out.append(.id(String(buf)))
            case "<":
                // HTML-like label: skip to the matching `>` (depth-balanced).
                var depth = 0
                while i < n {
                    if scalars[i] == "<" { depth += 1 }
                    else if scalars[i] == ">" { depth -= 1; if depth == 0 { i += 1; break } }
                    i += 1
                }
            case "-":
                // Edge op (`->`, `--`) vs a leading-`-` numeral id (`-3`, `-.5`).
                let next = scalars[safe: i + 1]
                if next == ">" || next == "-" {
                    out.append(.edgeOp); i += 2
                } else {
                    var buf = String.UnicodeScalarView()
                    buf.append(u); i += 1
                    while i < n, isBareIDScalar(scalars[i]) { buf.append(scalars[i]); i += 1 }
                    out.append(.id(String(buf)))
                }
            default:
                if isBareIDScalar(u) {
                    var buf = String.UnicodeScalarView()
                    while i < n, isBareIDScalar(scalars[i]) { buf.append(scalars[i]); i += 1 }
                    out.append(.id(String(buf)))
                } else {
                    i += 1   // unknown punctuation (`:` ports etc.) — skip
                }
            }
        }
        return out
    }

    /// Strip `//`, `#`, and `/* … */` comments, preserving quoted strings so a
    /// `#`/`//` inside `"…"` (a legal node label) is not treated as a comment.
    private static func stripComments(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        var i = 0
        let n = scalars.count
        while i < n {
            let u = scalars[i]
            if u == "\"" {
                out.append(u); i += 1
                while i < n {
                    out.append(scalars[i])
                    if scalars[i] == "\\", i + 1 < n { out.append(scalars[i + 1]); i += 2; continue }
                    if scalars[i] == "\"" { i += 1; break }
                    i += 1
                }
            } else if u == "/", scalars[safe: i + 1] == "/" {
                while i < n, scalars[i] != "\n" { i += 1 }
            } else if u == "#" {
                while i < n, scalars[i] != "\n" { i += 1 }
            } else if u == "/", scalars[safe: i + 1] == "*" {
                i += 2
                while i < n, !(scalars[i] == "*" && scalars[safe: i + 1] == "/") { i += 1 }
                i += 2
            } else {
                out.append(u); i += 1
            }
        }
        return String(out)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Array where Element == Unicode.Scalar {
    subscript(safe index: Int) -> Unicode.Scalar? {
        indices.contains(index) ? self[index] : nil
    }
}
