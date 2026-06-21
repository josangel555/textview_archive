/// TSK-1187 — clipboard ↔ CSV grid conversion for rectangular copy/paste. The
/// inverse of `CSVRectSelection.tsv`: parse a tab/newline-delimited clipboard
/// string (the spreadsheet convention) into a cell grid. Pure + host-testable.
public enum CSVClipboard {
    public static func parseTSV(_ text: String) -> [[String]] {
        guard !text.isEmpty else { return [] }
        var rows = text
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "\t") }
        // Drop a single trailing empty row produced by a terminal newline.
        if let last = rows.last, last == [""] { rows.removeLast() }
        return rows
    }
}
