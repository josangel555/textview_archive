import Foundation

/// Spreadsheet-style cell cursor for the CSV grid (TSK-302) — the pure,
/// host-testable focus model behind arrow-key cell navigation and
/// single-keystroke "copy whole cell". The view owns rendering (highlight the
/// focused cell), key routing, and the pasteboard write; this owns only the
/// `(row, column)` position and the clamped movement rules, so the navigation
/// behaviour is testable without a window.
///
/// Coordinates address the DATA grid: `row ∈ [0, rowCount)`, `column ∈
/// [0, columnCount)`. The header is separate chrome the view draws above the
/// grid; if a front-end wants the header focusable it maps its own offset.
///
/// Movement is **clamped, never wrapping** (the spreadsheet convention): an
/// arrow at an edge leaves the cursor put. Each mover returns whether the
/// cursor actually moved, so the view can decide whether to consume the key
/// event (and, e.g., let an edge arrow fall through to scroll).
public struct CSVCellCursor: Sendable, Equatable {

    public private(set) var row: Int
    public private(set) var column: Int
    public let rowCount: Int
    public let columnCount: Int

    /// Build a cursor over a `rowCount × columnCount` grid, starting at
    /// (`row`, `column`) clamped into range. A grid with zero rows OR zero
    /// columns is *empty*: the cursor pins to (0, 0) and every mover is a
    /// no-op (`isEmpty` is true).
    public init(rowCount: Int, columnCount: Int, row: Int = 0, column: Int = 0) {
        let rc = max(0, rowCount)
        let cc = max(0, columnCount)
        self.rowCount = rc
        self.columnCount = cc
        if rc == 0 || cc == 0 {
            self.row = 0
            self.column = 0
        } else {
            self.row = min(max(row, 0), rc - 1)
            self.column = min(max(column, 0), cc - 1)
        }
    }

    /// True when the grid has no addressable cells (no rows or no columns).
    public var isEmpty: Bool { rowCount == 0 || columnCount == 0 }

    // MARK: - Movement (clamped, non-wrapping)

    @discardableResult public mutating func moveUp() -> Bool { setRow(row - 1) }
    @discardableResult public mutating func moveDown() -> Bool { setRow(row + 1) }
    @discardableResult public mutating func moveLeft() -> Bool { setColumn(column - 1) }
    @discardableResult public mutating func moveRight() -> Bool { setColumn(column + 1) }

    /// Home: jump to the first column of the current row.
    @discardableResult public mutating func moveToRowStart() -> Bool { setColumn(0) }
    /// End: jump to the last column of the current row.
    @discardableResult public mutating func moveToRowEnd() -> Bool { setColumn(columnCount - 1) }
    /// Cmd-Up / top: first row, current column.
    @discardableResult public mutating func moveToTop() -> Bool { setRow(0) }
    /// Cmd-Down / bottom: last row, current column.
    @discardableResult public mutating func moveToBottom() -> Bool { setRow(rowCount - 1) }

    /// PageUp: jump up by `pageRows` (one viewport of rows), clamped to the
    /// first row. The view supplies its visible-row count so a page matches
    /// what the user sees; a non-positive `pageRows` is treated as a single
    /// row so the verb is never a silent no-op away from an edge. Column is
    /// unchanged.
    @discardableResult
    public mutating func movePageUp(pageRows: Int) -> Bool {
        setRow(row - max(1, pageRows))
    }

    /// PageDown: jump down by `pageRows` (one viewport of rows), clamped to
    /// the last row. See `movePageUp(pageRows:)` for the `pageRows`
    /// normalization. Column is unchanged.
    @discardableResult
    public mutating func movePageDown(pageRows: Int) -> Bool {
        setRow(row + max(1, pageRows))
    }

    /// Jump to an arbitrary cell (e.g. a click), clamped into range. No-op on
    /// an empty grid. Returns whether the position changed.
    @discardableResult
    public mutating func move(toRow newRow: Int, column newColumn: Int) -> Bool {
        guard !isEmpty else { return false }
        let r = min(max(newRow, 0), rowCount - 1)
        let c = min(max(newColumn, 0), columnCount - 1)
        let changed = (r != row) || (c != column)
        row = r
        column = c
        return changed
    }

    // MARK: - Cell access

    /// The value at the cursor in `rows`, or nil if the cursor is out of range
    /// for the supplied data (empty grid, or a ragged row shorter than the
    /// cursor column). Safe bounded read — what the view hands to the
    /// pasteboard on Cmd-C.
    public func cell(in rows: [[String]]) -> String? {
        guard !isEmpty, row >= 0, row < rows.count else { return nil }
        let r = rows[row]
        guard column >= 0, column < r.count else { return nil }
        return r[column]
    }

    /// The exact text to put on the pasteboard for a whole-cell ⌘C of the
    /// focused cell — the **unescaped** cell value. `CSVParser` already
    /// decodes RFC-4180 escaping during tokenization (a quoted `"a,""b"""`
    /// is stored as the literal `a,"b"`, with surrounding quotes and `""`
    /// escapes removed), so this is just the bounded read of the parsed
    /// cell: no re-escaping, no surrounding quotes, no markup. Returns nil
    /// when the cursor doesn't address a real cell (empty grid / ragged
    /// row / stale data) so the view can no-op the copy rather than write
    /// garbage to the pasteboard.
    public func copyText(from rows: [[String]]) -> String? {
        cell(in: rows)
    }

    // MARK: - Private

    private mutating func setRow(_ target: Int) -> Bool {
        guard !isEmpty else { return false }
        let clamped = min(max(target, 0), rowCount - 1)
        guard clamped != row else { return false }
        row = clamped
        return true
    }

    private mutating func setColumn(_ target: Int) -> Bool {
        guard !isEmpty else { return false }
        let clamped = min(max(target, 0), columnCount - 1)
        guard clamped != column else { return false }
        column = clamped
        return true
    }
}
