import Foundation

/// TSK-1439 — serialize a `SQLiteReader.QueryResult` for export, reusing the
/// existing `CsvConvert` writers so the SQLite browser, the CSV viewer, and any
/// future grid share one code path (and one set of teeth).
///
/// The reader renders every cell as `String?` (a genuine SQL `NULL` is `nil`);
/// export flattens `nil` to `nullPlaceholder` — empty by default, matching the
/// CSV/JSON convention where an absent value is an empty field. Pure +
/// host-testable: no UI, no clipboard, no file IO.
public enum SQLiteResultExport {

    public enum Format: String, CaseIterable, Sendable {
        case csv
        case markdown
        case json

        /// User-facing menu label ("Copy as CSV").
        public var menuLabel: String {
            switch self {
            case .csv:      return "CSV"
            case .markdown: return "Markdown Table"
            case .json:     return "JSON"
            }
        }

        /// File extension for a "Save as…" panel.
        public var fileExtension: String {
            switch self {
            case .csv:      return "csv"
            case .markdown: return "md"
            case .json:     return "json"
            }
        }
    }

    /// Flatten the result's `[[String?]]` rows to `[[String]]` (NULL → placeholder)
    /// then hand off to the matching `CsvConvert` writer.
    public static func serialize(
        _ result: SQLiteReader.QueryResult,
        as format: Format,
        nullPlaceholder: String = ""
    ) -> String {
        let rows = result.rows.map { row in row.map { $0 ?? nullPlaceholder } }
        switch format {
        case .csv:      return CsvConvert.toCSV(header: result.columns, rows: rows)
        case .markdown: return CsvConvert.toMarkdownTable(header: result.columns, rows: rows)
        case .json:     return CsvConvert.toJSON(header: result.columns, rows: rows)
        }
    }
}
