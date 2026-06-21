/// TSK-1187 — a rectangular multi-cell selection over a CSV grid: an anchor cell
/// and a focus cell define the rectangle (in either drag direction). Pure +
/// host-testable; the view supplies anchor/focus from its cursor + shift-drag,
/// and copies `tsv(in:)` to the pasteboard.
public struct CSVRectSelection: Sendable, Equatable {
    public let anchorRow: Int
    public let anchorCol: Int
    public let focusRow: Int
    public let focusCol: Int

    public init(anchorRow: Int, anchorCol: Int, focusRow: Int, focusCol: Int) {
        self.anchorRow = anchorRow
        self.anchorCol = anchorCol
        self.focusRow = focusRow
        self.focusCol = focusCol
    }

    /// Normalised inclusive row range (anchor/focus in either order).
    public var rowRange: ClosedRange<Int> { Swift.min(anchorRow, focusRow)...Swift.max(anchorRow, focusRow) }
    /// Normalised inclusive column range.
    public var colRange: ClosedRange<Int> { Swift.min(anchorCol, focusCol)...Swift.max(anchorCol, focusCol) }
    /// True when the selection is a single cell.
    public var isSingleCell: Bool { anchorRow == focusRow && anchorCol == focusCol }

    /// Tab/newline-delimited extract of the selected rectangle from `rows`
    /// (spreadsheet clipboard convention): columns joined by `\t`, rows by `\n`.
    /// Out-of-bounds rows/cols are clamped away (a ragged row contributes only
    /// the cells it has), so it's safe on jagged CSV.
    public func tsv(in rows: [[String]]) -> String {
        var out: [String] = []
        for r in rowRange where r >= 0 && r < rows.count {
            let row = rows[r]
            var cells: [String] = []
            for c in colRange where c >= 0 && c < row.count {
                cells.append(row[c])
            }
            out.append(cells.joined(separator: "\t"))
        }
        return out.joined(separator: "\n")
    }
}
