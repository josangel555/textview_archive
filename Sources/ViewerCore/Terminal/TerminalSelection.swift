import Foundation

/// A text selection over a `TerminalScreen` grid — PURE logic (no AppKit),
/// so the geometry and text-extraction are headless-testable end to end.
/// The view layer (`TerminalNSView`) owns an optional value of this type,
/// updates `head` on drag, and asks it both for the per-row highlight span
/// (`columnRange`) and the copied text (`selectedText`).
///
/// Model: a linear (flowing) selection between an `anchor` cell and a
/// `head` cell — NOT a rectangular block. Coordinates are 0-based grid
/// cells (row, col), matching `TerminalScreen`. The selection is INCLUSIVE
/// of both endpoint cells (dragging from col 2 to col 5 selects 2,3,4,5),
/// so `columnRange`'s end is `endCol + 1` (exclusive range, inclusive cell).
public struct TerminalSelection: Sendable, Equatable {
    public struct Point: Sendable, Equatable, Comparable {
        public var row: Int
        public var col: Int
        public init(row: Int, col: Int) {
            self.row = row
            self.col = col
        }
        public static func < (lhs: Point, rhs: Point) -> Bool {
            lhs.row != rhs.row ? lhs.row < rhs.row : lhs.col < rhs.col
        }
    }

    public var anchor: Point
    public var head: Point

    public init(anchor: Point, head: Point) {
        self.anchor = anchor
        self.head = head
    }

    /// Endpoints in reading order (`start <= end`).
    public var ordered: (start: Point, end: Point) {
        anchor <= head ? (anchor, head) : (head, anchor)
    }

    /// True when the selection covers a single cell (anchor == head). The
    /// view treats this as "a click that hasn't dragged" and discards it;
    /// a deliberate single-cell selection (e.g. a 1-char word) is kept by
    /// the view via its own drag-tracking, not by this flag.
    public var isSinglePoint: Bool { anchor == head }

    /// The half-open column range highlighted on `row` (end exclusive,
    /// endpoint cell inclusive), or nil if `row` is outside the selection.
    /// `cols` is the grid width; the range is clamped into `0..<cols`.
    public func columnRange(forRow row: Int, cols: Int) -> Range<Int>? {
        guard cols > 0 else { return nil }
        let (s, e) = ordered
        guard row >= s.row, row <= e.row else { return nil }
        let lo = (row == s.row) ? s.col : 0
        let hi = (row == e.row) ? e.col + 1 : cols      // +1: endpoint cell inclusive
        let lower = max(0, min(lo, cols))
        let upper = max(0, min(hi, cols))
        guard lower < upper else { return nil }
        return lower..<upper
    }

    /// The selected text over an explicit grid (`rows` × `cols`), one line
    /// per selected row, with trailing spaces trimmed per line (the
    /// terminal copy convention) and rows joined by "\n". Out-of-range
    /// rows are skipped safely. This is the grid-based core — the view
    /// passes its currently-visible window (which may be scrollback), so
    /// copy works on whatever is on screen.
    public func selectedText(fromRows rows: [[TerminalCell]], cols: Int) -> String {
        let (s, e) = ordered
        var lines: [String] = []
        for row in s.row...e.row {
            guard rows.indices.contains(row),
                  let range = columnRange(forRow: row, cols: cols) else { continue }
            let rowCells = rows[row]
            let clamped = range.clamped(to: 0..<rowCells.count)
            guard !clamped.isEmpty else { lines.append(""); continue }
            var seg = String(rowCells[clamped].map(\.char))
            while seg.hasSuffix(" ") { seg.removeLast() }
            lines.append(seg)
        }
        return lines.joined(separator: "\n")
    }

    /// Convenience: extract from a live screen's grid.
    public func selectedText(from screen: TerminalScreen) -> String {
        selectedText(fromRows: screen.cells, cols: screen.cols)
    }

    // MARK: - Constructors for double / triple-click

    /// The whole `rows × cols` grid (Select All).
    public static func all(rows: Int, cols: Int) -> TerminalSelection {
        TerminalSelection(
            anchor: Point(row: 0, col: 0),
            head: Point(row: max(0, rows - 1), col: max(0, cols - 1))
        )
    }

    public static func all(in screen: TerminalScreen) -> TerminalSelection {
        all(rows: screen.rows, cols: screen.cols)
    }

    /// The contiguous run of non-space cells containing `p` (double-click
    /// word select) over an explicit grid. If `p` is on a blank cell,
    /// returns a single-cell selection at `p`.
    public static func word(at p: Point, inRows rows: [[TerminalCell]]) -> TerminalSelection {
        guard rows.indices.contains(p.row) else {
            return TerminalSelection(anchor: p, head: p)
        }
        let row = rows[p.row]
        let n = row.count
        guard n > 0 else { return TerminalSelection(anchor: p, head: p) }
        let col = min(max(0, p.col), n - 1)
        func isWord(_ c: Character) -> Bool { c != " " }
        guard isWord(row[col].char) else {
            return TerminalSelection(anchor: Point(row: p.row, col: col),
                                     head: Point(row: p.row, col: col))
        }
        var lo = col
        while lo > 0 && isWord(row[lo - 1].char) { lo -= 1 }
        var hi = col
        while hi < n - 1 && isWord(row[hi + 1].char) { hi += 1 }
        return TerminalSelection(anchor: Point(row: p.row, col: lo),
                                 head: Point(row: p.row, col: hi))
    }

    public static func word(at p: Point, in screen: TerminalScreen) -> TerminalSelection {
        word(at: p, inRows: screen.cells)
    }

    /// The entire `row` (triple-click line select), full `cols` width.
    public static func line(_ row: Int, cols: Int) -> TerminalSelection {
        let r = max(0, row)
        return TerminalSelection(anchor: Point(row: r, col: 0),
                                 head: Point(row: r, col: max(0, cols - 1)))
    }

    public static func line(_ row: Int, in screen: TerminalScreen) -> TerminalSelection {
        line(min(max(0, row), max(0, screen.rows - 1)), cols: screen.cols)
    }
}
