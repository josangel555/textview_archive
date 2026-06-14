import Foundation

/// The mode a "Goto Anything" palette query routes to, chosen by a leading
/// operator character (TSK-727). Mirrors the Sublime/VS Code convention so the
/// operators are already in users' muscle memory:
///
///   - (no operator) → `.files`   fuzzy over recent files / bookmarks
///   - `>`           → `.command` run a registered command (already shipped)
///   - `@`           → `.symbol`  jump to a symbol in the active file
///   - `:`           → `.line`    go to `line[:column]` in the active file
///   - `#`           → `.text`    search text within the active file
public enum GotoMode: String, Equatable, Sendable, CaseIterable {
    case files
    case command
    case symbol
    case line
    case text
}

/// What the palette should DO when the user presses Return on a query —
/// the pure routing decision (TSK-727), so the view's submit dispatch is
/// host-tested rather than re-deriving the rules inline.
public enum PaletteSubmitAction: Equatable, Sendable {
    /// Jump to a 1-based line in the active editor (`:42`).
    case goToLine(Int)
    /// Run the selected registered command (`>`).
    case runCommand
    /// Open the selected file result (bare query).
    case openFile
    /// Nothing actionable yet (e.g. a bare `:` with no number) — dismiss.
    case none
}

/// A parsed palette query: the routed `mode`, the residual `term` after the
/// operator, and (for `.line`) the parsed 1-based `line`/`column`.
public struct GotoQuery: Equatable, Sendable {
    public let mode: GotoMode
    /// The query text AFTER the operator character. NOT trimmed — the user's
    /// spaces are preserved for fuzzy/text matching. For `.files` it is the
    /// whole raw input (no operator was consumed).
    public let term: String
    /// 1-based line, parsed when `mode == .line` and a positive leading integer
    /// is present; `nil` for a bare/non-numeric `:`.
    public let line: Int?
    /// 1-based column, parsed from `:line:column`; `nil` otherwise.
    public let column: Int?

    public init(mode: GotoMode, term: String, line: Int? = nil, column: Int? = nil) {
        self.mode = mode
        self.term = term
        self.line = line
        self.column = column
    }

    /// The action the palette fires on Return. `.line` with a valid number →
    /// `.goToLine`; a bare/invalid `:` → `.none` (dismiss, nothing to jump to).
    /// `.command` → `.runCommand`. Everything else (`.files`, and the not-yet-
    /// surfaced `.symbol`/`.text`) → `.openFile`, preserving today's behaviour
    /// until those modes get their own result handling.
    public var submitAction: PaletteSubmitAction {
        switch mode {
        case .line:
            return line.map(PaletteSubmitAction.goToLine) ?? .none
        case .command:
            return .runCommand
        case .files, .symbol, .text:
            return .openFile
        }
    }
}

/// Pure classifier for the unified palette input (TSK-727). Host-testable: it
/// is a total function `String -> GotoQuery` with no I/O — the palette feeds it
/// every keystroke and routes results by `mode`; the result rendering for the
/// new operators is the view/VM tail.
public enum GotoQueryParser {

    /// Classify `raw` by its leading operator. The operator must be the FIRST
    /// character (leading whitespace disables it → `.files`, matching VS Code),
    /// so a normal filename search is never hijacked.
    public static func parse(_ raw: String) -> GotoQuery {
        guard let first = raw.first else {
            return GotoQuery(mode: .files, term: "")
        }
        let rest = String(raw.dropFirst())
        switch first {
        case ">":
            return GotoQuery(mode: .command, term: rest)
        case "@":
            return GotoQuery(mode: .symbol, term: rest)
        case "#":
            return GotoQuery(mode: .text, term: rest)
        case ":":
            let (line, column) = parseLineColumn(rest)
            return GotoQuery(mode: .line, term: rest, line: line, column: column)
        default:
            // No operator — the whole input is the file-search term.
            return GotoQuery(mode: .files, term: raw)
        }
    }

    /// Parse the text after a `:` into `(line, column)`. Accepts `42`,
    /// `42:10`, `42:`, ``; only positive integers count (a non-numeric or
    /// non-positive part yields `nil` for that field). The first `:` splits
    /// line from column; further colons stay in the column substring and fail
    /// the `Int` parse (→ `nil`), which is the right "no usable column" answer.
    private static func parseLineColumn(_ s: String) -> (Int?, Int?) {
        let parts = s.split(
            separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let line = parts.first.flatMap { positiveInt(String($0)) }
        let column = parts.count > 1 ? positiveInt(String(parts[1])) : nil
        return (line, column)
    }

    /// `Int(s)` restricted to strictly-positive values (1-based positions);
    /// rejects empty, non-numeric, zero, and negative.
    private static func positiveInt(_ s: String) -> Int? {
        guard let n = Int(s), n >= 1 else { return nil }
        return n
    }
}
