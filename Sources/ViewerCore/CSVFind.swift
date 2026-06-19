import Foundation

/// Find-in-table for `CSVParser.Result` — the pure matcher behind the CSV
/// grid's Cmd-F find (TSK-303). Distinct from `CSVFilter`, which REMOVES
/// non-matching rows: find KEEPS the whole table and reports the coordinates
/// of every matching CELL so the UI can highlight each and jump next/prev.
///
/// Pure value logic, no UI: given the parsed table + a query it returns the
/// matching cells in reading order — header first (when `includeHeader`),
/// then data rows top-to-bottom, each row left-to-right. That is exactly the
/// order `step(...)` cycles through for next/prev navigation.
///
/// Matching is case-insensitive substring (mirrors `CSVFilter`'s global query
/// and the rendered-view find), so the user has one mental model across views.
public struct CSVFind: Sendable, Equatable {

    /// A single matching cell. `row == CSVFind.headerRow` (-1) marks a header
    /// cell; data cells carry their 0-based index into `result.rows`.
    public struct Match: Sendable, Equatable, Hashable {
        public let row: Int
        public let column: Int
        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
        /// True when this match is in the header row (`row == headerRow`).
        public var isHeader: Bool { row == CSVFind.headerRow }
    }

    /// Sentinel `Match.row` value for a header-cell match. Negative so it can
    /// never collide with a real `result.rows` index.
    public static let headerRow = -1

    /// The literal query. Case is folded at match time; the query is NOT
    /// trimmed — a whitespace query searches for whitespace (find is literal).
    public var query: String
    /// `.all` searches every column; `.column(i)` restricts to column `i`
    /// (an out-of-range column yields no matches).
    public var scope: CSVFilter.Scope
    /// Whether header cells participate in the search.
    public var includeHeader: Bool

    public init(query: String = "",
                scope: CSVFilter.Scope = .all,
                includeHeader: Bool = true) {
        self.query = query
        self.scope = scope
        self.includeHeader = includeHeader
    }

    /// Only a truly-empty query is "no search". A whitespace-only query is a
    /// real (literal) search, unlike `CSVFilter` where it would be a no-op.
    public var isEmpty: Bool { query.isEmpty }

    /// The matching cells in reading order. Empty query → no matches.
    ///
    /// Performance: O(cells × |query|) — one full sweep. The caller debounces
    /// (typical: re-run on query change, cache the result for next/prev).
    public func matches(in result: CSVParser.Result) -> [Match] {
        matches(header: result.header, rows: result.rows)
    }

    /// Search the supplied `header` + `rows` directly, rather than a parsed
    /// `CSVParser.Result`. This is the overload the GRID UI uses: it passes the
    /// *displayed* rows (after filter + sort), so each returned `Match.row` /
    /// `.column` is an index into what's actually on screen — the coordinates
    /// line up with the rendered cells for highlighting and scroll-to. Header
    /// matches still carry `row == headerRow`.
    ///
    /// Same reading order and matching semantics as `matches(in:)`: header
    /// first (when `includeHeader`), then data rows top-to-bottom, each row
    /// left-to-right; case-insensitive substring; column scope honored.
    public func matches(header: [String], rows: [[String]]) -> [Match] {
        if query.isEmpty { return [] }
        let needle = query.lowercased()
        let scopeColumn: Int?
        switch scope {
        case .all: scopeColumn = nil
        case .column(let c): scopeColumn = c
        }

        var out: [Match] = []
        func scan(row: Int, cells: [String]) {
            for (col, cell) in cells.enumerated() {
                if let only = scopeColumn, only != col { continue }
                if cell.lowercased().contains(needle) {
                    out.append(Match(row: row, column: col))
                }
            }
        }
        if includeHeader { scan(row: CSVFind.headerRow, cells: header) }
        for (i, row) in rows.enumerated() { scan(row: i, cells: row) }
        return out
    }

    /// Per-cell highlight verdict for the grid. Pure mapping from a cell
    /// coordinate + the current match set to one of three render states, so
    /// the view layer is a thin lookup and the logic is host-testable.
    public enum Highlight: Sendable, Equatable {
        /// No find match in this cell — render it normally.
        case none
        /// A find match, but NOT the one the cursor is on — dim wash.
        case match
        /// The current (cursor) match — strong wash + scroll target.
        case current
    }

    /// Classify the cell at (`row`, `column`) against `matches` and the
    /// `current` cursor index (an index into `matches`, or nil = none active).
    ///
    /// O(|matches|) — fine for the typical handful-to-hundreds of hits a user
    /// pages through; the caller can pre-build a `Set`/dictionary if a table
    /// has pathologically many matches, but the straight scan keeps the common
    /// case allocation-free.
    public static func highlight(row: Int, column: Int,
                                 matches: [Match],
                                 current: Int?) -> Highlight {
        guard !matches.isEmpty else { return .none }
        let target = Match(row: row, column: column)
        var isMatch = false
        for m in matches where m == target { isMatch = true; break }
        guard isMatch else { return .none }
        if let cur = current, matches.indices.contains(cur),
           matches[cur] == target {
            return .current
        }
        return .match
    }

    /// The number of matches without materializing the array — same sweep,
    /// useful for a "N matches" badge when the coordinates aren't needed.
    public func count(in result: CSVParser.Result) -> Int {
        matches(in: result).count
    }

    /// Cycle to the next (`forward`) or previous match index, with wraparound.
    ///
    /// `current` is an index into a `matches(...)` array (nil = nothing
    /// selected yet). From nil, forward starts at the first match and backward
    /// at the last. Returns nil only when `count == 0`. Pure arithmetic — the
    /// caller owns the match array; this just advances the cursor.
    public static func step(count: Int, from current: Int?, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let cur = current else { return forward ? 0 : count - 1 }
        let clamped = min(max(cur, 0), count - 1)
        if forward { return (clamped + 1) % count }
        return (clamped - 1 + count) % count
    }
}
