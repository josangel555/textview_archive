import Foundation

/// TSK-711 — in-memory editable-cell model for the CSV/TSV grid (foundation
/// slice of the editable-CSV epic; the live grid is read-only today).
///
/// Holds the parsed grid as an immutable BASE plus an OVERLAY of pending cell
/// edits keyed by `(row, column)`. The base is never mutated; an edit records
/// the new value in the overlay (and, when it restores the original value, the
/// overlay entry is dropped so the cell is clean again). This gives us:
///   - cheap `dirty` detection (overlay non-empty after coalescing),
///   - O(1) `getCell` / `setCell`,
///   - a per-edit undo/redo stack that restores the exact prior grid, and
///   - a `serialize()` that round-trips back to RFC-4180 CSV preserving the
///     delimiter the parser detected and quoting exactly the cells that need it.
///
/// ## Coordinate space
/// The model addresses the **full grid**: row 0 is the header, rows `1...`
/// are the body. This matches how the file is laid out on disk and lets the
/// header be edited like any other row (a real spreadsheet edits header cells).
/// `rowCount` therefore counts the header row; `bodyRowCount` excludes it.
///
/// ## Why an overlay (not a mutable `[[String]]`)
/// The view already caches `CSVParser.Result` and re-derives filtered/sorted
/// views from it. Keeping the parse immutable means the model never has to
/// re-detect column widths or invalidate the parse cache on an edit; the
/// overlay is a thin diff the serializer folds in at write time. It also makes
/// `dirty` and undo trivial — they're properties of the diff, not the grid.
///
/// Pure + host-testable; the table view wires `setCell` to a double-click cell
/// editor (behind a flag) and `serialize()` to the eventual save path.
public struct EditableCSVModel: Equatable, Sendable {

    /// A cell address in the FULL grid: `row == 0` is the header, `row >= 1`
    /// are body rows. `column` is the field index within that row.
    public struct Cell: Hashable, Sendable {
        public let row: Int
        public let column: Int
        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    /// The immutable parsed grid, header as row 0 then body rows. Built once
    /// from the parser result and never mutated — edits live in `overlay`.
    private let base: [[String]]

    /// Pending edits: `cell -> new value`. An entry is present ONLY when the
    /// value differs from `base` (setting a cell back to its base value drops
    /// the entry), so `overlay.isEmpty == !dirty` always holds.
    private var overlay: [Cell: String]

    /// The delimiter to emit on `serialize()` — the one the parser detected, so
    /// a TSV round-trips as TSV and a `;`-delimited file stays `;`-delimited.
    public let delimiter: Character

    /// `true` when the input parse hit a resource cap and was truncated. A
    /// truncated parse is NOT a faithful representation of the file, so callers
    /// should refuse to save (or warn) rather than clobber the original with a
    /// partial grid. The model still edits/serializes the truncated grid for
    /// preview, but exposes this so the save path can gate.
    public let wasTruncated: Bool

    // MARK: Undo / redo

    /// One recorded mutation: the cell and its overlay value BEFORE and AFTER
    /// the edit (nil = "no overlay entry", i.e. equal to base). Undo restores
    /// `before`; redo re-applies `after`.
    private struct EditRecord: Equatable {
        let cell: Cell
        let before: String?
        let after: String?
    }

    private var undoStack: [EditRecord] = []
    private var redoStack: [EditRecord] = []

    // MARK: Init

    /// Build from a parsed result. The header becomes grid row 0; body rows
    /// follow. Rows are NOT padded/normalized here beyond what the parser
    /// already did (the parser pads ragged body rows to the header width).
    public init(_ result: CSVParser.Result) {
        var grid: [[String]] = []
        grid.reserveCapacity(result.rows.count + 1)
        grid.append(result.header)
        grid.append(contentsOf: result.rows)
        self.base = grid
        self.overlay = [:]
        self.delimiter = result.delimiter
        self.wasTruncated = result.truncated
    }

    /// Convenience: parse `text` (routing through whatever engine the gate
    /// selects) and build an editable model over the result.
    public init(parsing text: String) {
        self.init(RustCSVAdapter.parse(text))
    }

    // MARK: Geometry

    /// Total rows including the header (row 0).
    public var rowCount: Int { base.count }

    /// Body rows (excludes the header). Zero when the file is header-only.
    public var bodyRowCount: Int { max(0, base.count - 1) }

    /// Column count taken from the header row (row 0). Body rows are padded to
    /// this width by the parser, so this is the grid's logical column count.
    public var columnCount: Int { base.first?.count ?? 0 }

    /// `true` when there are no addressable cells.
    public var isEmpty: Bool { base.isEmpty || columnCount == 0 }

    // MARK: Read / write

    /// The CURRENT value at `cell` (overlay if edited, else base). Returns nil
    /// for an out-of-range address (row/column beyond the grid). A ragged base
    /// row shorter than `column` also yields nil for the missing trailing cell.
    public func getCell(row: Int, column: Int) -> String? {
        guard row >= 0, row < base.count, column >= 0 else { return nil }
        let cell = Cell(row: row, column: column)
        if let edited = overlay[cell] { return edited }
        let baseRow = base[row]
        guard column < baseRow.count else { return nil }
        return baseRow[column]
    }

    /// `true` when `cell` has a pending edit that differs from its base value.
    public func isEdited(row: Int, column: Int) -> Bool {
        overlay[Cell(row: row, column: column)] != nil
    }

    /// Set `cell` to `value`. Records an undo step and clears the redo stack
    /// (a fresh edit forks any redo future, matching standard editor undo).
    /// Setting a cell back to its base value DROPS the overlay entry, so the
    /// dirty flag and serialization reflect "no change". Out-of-range or no-op
    /// (same as current) writes are ignored and record nothing.
    ///
    /// Returns whether the model actually changed.
    @discardableResult
    public mutating func setCell(row: Int, column: Int, to value: String) -> Bool {
        guard row >= 0, row < base.count, column >= 0 else { return false }
        // Column must be addressable against the header width; we don't grow
        // rows in this slice (column insert/delete is a later slice).
        guard column < columnCount else { return false }
        let cell = Cell(row: row, column: column)

        let before = overlay[cell]
        let baseValue = baseValueAt(cell)
        // Coalesce: store an overlay entry only when it differs from base.
        let after: String? = (value == baseValue) ? nil : value
        guard after != before else { return false }   // genuine no-op

        applyOverlay(cell, after)
        undoStack.append(EditRecord(cell: cell, before: before, after: after))
        redoStack.removeAll(keepingCapacity: true)
        return true
    }

    /// TSK-1187 — paste a cell grid with its top-left at `(row, column)`. Cells
    /// falling outside the current bounds are skipped (no auto-grow, matching
    /// `setCell`). Returns the number of cells actually changed.
    @discardableResult
    public mutating func paste(_ grid: [[String]], atRow row: Int, column: Int) -> Int {
        var changed = 0
        for (dr, cells) in grid.enumerated() {
            for (dc, value) in cells.enumerated() where setCell(row: row + dr, column: column + dc, to: value) {
                changed += 1
            }
        }
        return changed
    }

    // MARK: Dirty

    /// `true` when there is at least one pending edit differing from the base
    /// grid. Coalescing guarantees an entry exists only for a genuine change.
    public var isDirty: Bool { !overlay.isEmpty }

    /// The set of cells currently carrying a pending edit (for the view to
    /// decorate). Order is unspecified.
    public var editedCells: [Cell] { Array(overlay.keys) }

    /// Drop all pending edits and the undo/redo history, returning to the
    /// pristine parsed grid. (E.g. after a successful save, or a "revert".)
    public mutating func discardEdits() {
        overlay.removeAll(keepingCapacity: false)
        undoStack.removeAll(keepingCapacity: false)
        redoStack.removeAll(keepingCapacity: false)
    }

    // MARK: Undo / redo

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Undo the most recent edit, restoring the cell's prior overlay state.
    /// Returns the cell that changed (so the view can refocus it), or nil if
    /// there was nothing to undo.
    @discardableResult
    public mutating func undo() -> Cell? {
        guard let record = undoStack.popLast() else { return nil }
        applyOverlay(record.cell, record.before)
        redoStack.append(record)
        return record.cell
    }

    /// Redo the most recently undone edit. Returns the changed cell or nil.
    @discardableResult
    public mutating func redo() -> Cell? {
        guard let record = redoStack.popLast() else { return nil }
        applyOverlay(record.cell, record.after)
        undoStack.append(record)
        return record.cell
    }

    // MARK: Serialization

    /// Round-trip the current grid (base + overlay folded in) back to RFC-4180
    /// CSV using the detected `delimiter`. Each row is its cells joined by the
    /// delimiter; rows are joined (and terminated) by `\r\n` per RFC-4180.
    ///
    /// A cell is QUOTED iff it contains the delimiter, a double-quote, a CR, or
    /// a LF; embedded double-quotes are escaped by doubling (`"` → `""`). A
    /// cell needing no quoting is emitted verbatim. This mirrors exactly what
    /// `CSVParser.parse` will read back, so `parse(serialize(parse(x)))`
    /// round-trips the grid.
    public func serialize() -> String {
        guard !base.isEmpty else { return "" }
        var out = String()
        // Rough capacity hint: assume ~16 chars/cell; avoids repeated growth on
        // large grids without over-allocating for small ones.
        out.reserveCapacity(base.count * columnCount * 16)
        var first = true
        for r in base.indices {
            if !first { out += "\r\n" }
            first = false
            serializeRow(r, into: &out)
        }
        return out
    }

    // MARK: - Private

    /// The base (un-edited) value at `cell`, or "" if the base row is ragged
    /// short there. Used by the coalescing logic in `setCell`.
    private func baseValueAt(_ cell: Cell) -> String {
        guard cell.row >= 0, cell.row < base.count else { return "" }
        let baseRow = base[cell.row]
        guard cell.column >= 0, cell.column < baseRow.count else { return "" }
        return baseRow[cell.column]
    }

    /// Set or clear the overlay entry for `cell` (nil clears).
    private mutating func applyOverlay(_ cell: Cell, _ value: String?) {
        if let value {
            overlay[cell] = value
        } else {
            overlay.removeValue(forKey: cell)
        }
    }

    /// Append row `r`'s serialized form (current values, delimiter-joined,
    /// each cell RFC-4180-quoted as needed) to `out`. Honors the grid's logical
    /// column count so a ragged-short base row emits the right number of empty
    /// trailing cells (matching how the parser pads it on the way in).
    private func serializeRow(_ r: Int, into out: inout String) {
        let cols = columnCount
        // Header (row 0) defines the width; body rows are parser-padded to it,
        // but a header-only or zero-col edge still works via `cols`.
        let n = (r == 0) ? base[0].count : cols
        guard n > 0 else { return }
        for c in 0..<n {
            if c > 0 { out.unicodeScalars.append(delimiter.unicodeScalars.first!) }
            let value = getCell(row: r, column: c) ?? ""
            appendQuoted(value, into: &out)
        }
    }

    /// Append `value` to `out`, RFC-4180-quoting iff it contains the delimiter,
    /// a quote, CR, or LF (doubling embedded quotes).
    private func appendQuoted(_ value: String, into out: inout String) {
        if Self.needsQuoting(value, delimiter: delimiter) {
            out.append("\"")
            for ch in value {
                if ch == "\"" { out.append("\"") }   // double it
                out.append(ch)
            }
            out.append("\"")
        } else {
            out += value
        }
    }

    /// Does `value` require RFC-4180 quoting for this delimiter? `internal
    /// static` so tests can exercise the predicate directly.
    static func needsQuoting(_ value: String, delimiter: Character) -> Bool {
        for ch in value {
            if ch == delimiter || ch == "\"" || ch == "\n" || ch == "\r" {
                return true
            }
        }
        return false
    }

    // Equatable: two models are equal when their current grids, delimiter, and
    // truncation flag match. Undo history is intentionally excluded — equality
    // is about observable grid state, which is what tests compare. (Synthesized
    // conformance would compare the private stacks too; we provide it.)
    public static func == (lhs: EditableCSVModel, rhs: EditableCSVModel) -> Bool {
        lhs.delimiter == rhs.delimiter
            && lhs.wasTruncated == rhs.wasTruncated
            && lhs.base == rhs.base
            && lhs.overlay == rhs.overlay
    }
}
