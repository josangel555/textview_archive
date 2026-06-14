import Foundation

/// Summary metadata for a SQLite database file, for the file-info panel's
/// "Database" section (TSK-807 — that section was previously empty). Read-only
/// (`SQLiteReader` opens `SQLITE_OPEN_READONLY`); returns `[]` when the file
/// can't be opened as a SQLite database, so a misdetected file degrades quietly.
///
/// Pure-ish (filesystem + system libsqlite3) and host-testable against a real
/// fixture DB — see `SQLiteFileInfoTests`.
public enum SQLiteFileInfo {

    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Object counts (tables / views / indexes / triggers), total row count
    /// across user tables, and the on-disk encoding + page size. Views,
    /// indexes, and triggers rows are omitted when zero, to keep the panel tight.
    public static func summaryRows(for url: URL) -> [Row] {
        guard let reader = try? SQLiteReader(url: url) else { return [] }
        // SQLite opens lazily, so a non-DB / corrupt file (or a misdetected
        // `.sqlite`) only fails on the FIRST real read. Treat that as "no
        // database info" rather than emitting a misleading "Tables: 0".
        guard let tables = try? reader.tableNames() else { return [] }
        var out: [Row] = []
        out.append(Row("Tables", "\(tables.count)"))

        if let views = try? reader.viewNames(), !views.isEmpty {
            out.append(Row("Views", "\(views.count)"))
        }
        if let indexes = try? reader.indexNames(), !indexes.isEmpty {
            out.append(Row("Indexes", "\(indexes.count)"))
        }
        if let triggers = try? reader.triggerNames(), !triggers.isEmpty {
            out.append(Row("Triggers", "\(triggers.count)"))
        }

        // Total rows across user tables. Each COUNT(*) is bounded by its table;
        // the panel loads this off-main. Omitted if any table fails to count
        // (so we never show a misleadingly-low total).
        if !tables.isEmpty {
            var total = 0
            var complete = true
            for table in tables {
                if let n = try? reader.rowCount(of: table) { total += n }
                else { complete = false; break }
            }
            if complete { out.append(Row("Total rows", total.formatted())) }
        }

        if let encoding = scalar(reader, "PRAGMA encoding;") {
            out.append(Row("Encoding", encoding))
        }
        if let pageSize = scalar(reader, "PRAGMA page_size;") {
            out.append(Row("Page size", "\(pageSize) bytes"))
        }
        return out
    }

    /// First cell of the first row of a scalar query, or `nil`.
    private static func scalar(_ reader: SQLiteReader, _ sql: String) -> String? {
        guard let result = try? reader.query(sql),
              let firstRow = result.rows.first,
              let cell = firstRow.first else { return nil }
        return cell
    }
}
