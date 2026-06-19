import Foundation

/// TSK-924 — clipboard serialization for CSV multi-cell copy. Pure +
/// host-testable; the table view wires these to context-menu actions. Output is
/// tab/newline-delimited (TSV) so it pastes cleanly into a spreadsheet: a row is
/// its cells joined by TAB; a column is its cells joined by NEWLINE.
public enum CSVCopy {

    /// A whole row as one TSV line (cells joined by TAB).
    public static func rowTSV(_ row: [String]) -> String {
        row.joined(separator: "\t")
    }

    /// A whole column (the `column`-th cell of every row, in order) joined by
    /// NEWLINE. Rows shorter than `column+1` contribute an empty cell so the
    /// column stays row-aligned. Out-of-any-range column ⇒ "".
    public static func columnText(_ column: Int, in rows: [[String]]) -> String {
        guard column >= 0 else { return "" }
        return rows.map { row in
            (column < row.count) ? row[column] : ""
        }.joined(separator: "\n")
    }
}
