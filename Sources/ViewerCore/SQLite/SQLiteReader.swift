import Foundation
import SQLite3

/// Read-only SQLite client over the system `libsqlite3.dylib`. No
/// third-party SwiftPM dependency. Designed for a viewer — we open
/// databases with `SQLITE_OPEN_READONLY` and don't expose any
/// mutating verbs.
///
/// Tradeoffs vs swift-stresslite or GRDB:
///   - We control the API surface; can't accidentally write
///   - No prepared statement caching; users typing in the query
///     editor are one-shot anyway
///   - Threading: each `SQLiteReader` owns its own connection. Don't
///     share across threads.
public final class SQLiteReader {
    private var db: OpaquePointer?
    public let url: URL

    public enum SQLiteError: Error, CustomStringConvertible {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)

        public var description: String {
            switch self {
            case .openFailed(let m):    return "Open failed: \(m)"
            case .prepareFailed(let m): return "Prepare failed: \(m)"
            case .stepFailed(let m):    return "Step failed: \(m)"
            }
        }
    }

    public init(url: URL) throws {
        self.url = url
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            db = nil
            throw SQLiteError.openFailed(msg)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema queries

    /// Lists table names (excluding `sqlite_*` internal tables).
    public func tableNames() throws -> [String] {
        try execScalarColumn(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        )
    }

    public func viewNames() throws -> [String] {
        try execScalarColumn(
            "SELECT name FROM sqlite_master WHERE type='view' ORDER BY name;"
        )
    }

    public func indexNames() throws -> [String] {
        try execScalarColumn(
            "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        )
    }

    public func triggerNames() throws -> [String] {
        try execScalarColumn(
            "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name;"
        )
    }

    /// Schema (CREATE statement) for a named table / view / etc.
    public func schemaFor(_ name: String) throws -> String? {
        let stmt = try prepare("SELECT sql FROM sqlite_master WHERE name=?;")
        defer { sqlite3_finalize(stmt) }
        let bytes = Array(name.utf8CString)
        bytes.withUnsafeBufferPointer { buf in
            _ = sqlite3_bind_text(stmt, 1, buf.baseAddress, -1, nil)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                return String(cString: cstr)
            }
        }
        return nil
    }

    /// Column descriptions for a table via PRAGMA table_info(...).
    public struct ColumnInfo: Equatable, Sendable {
        public let name: String
        public let type: String
        public let notNull: Bool
        public let primaryKey: Bool
    }
    public func columns(of table: String) throws -> [ColumnInfo] {
        // PRAGMA can't be parameterized; embed escaped name.
        // PRAGMA table_info columns (positional):
        //   0: cid, 1: name, 2: type, 3: notnull, 4: dflt_value, 5: pk
        let escaped = table.replacingOccurrences(of: "\"", with: "\"\"")
        let sql = "PRAGMA table_info(\"\(escaped)\");"
        let result = try query(sql)
        return result.rows.compactMap { row in
            guard row.count >= 6 else { return nil }
            return ColumnInfo(
                name:       row[1] ?? "",
                type:       row[2] ?? "",
                notNull:    (row[3] ?? "0") != "0",
                primaryKey: (row[5] ?? "0") != "0"
            )
        }
    }

    /// Approximate row count via SELECT COUNT(*). For huge tables
    /// this scans — fast enough for most viewer cases.
    public func rowCount(of table: String) throws -> Int {
        let escaped = table.replacingOccurrences(of: "\"", with: "\"\"")
        let sql = "SELECT COUNT(*) FROM \"\(escaped)\";"
        let result = try query(sql)
        if let first = result.rows.first, let raw = first.first {
            return Int(raw ?? "0") ?? 0
        }
        return 0
    }

    // MARK: - Arbitrary queries

    public struct QueryResult: Equatable, Sendable {
        public let columns: [String]
        /// Each row is an array of String? values, one per column.
        /// We render every cell as text for the viewer — saves
        /// dealing with bind-type variance at the SwiftUI layer.
        public let rows: [[String?]]
        public let truncated: Bool
    }

    /// Runs an arbitrary SELECT. Capped at `maxRows` to protect the
    /// UI from accidentally fetching 10M rows. `truncated` reports
    /// whether the cap was hit.
    public func query(_ sql: String, maxRows: Int = 1_000) throws -> QueryResult {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let cols = Int(sqlite3_column_count(stmt))
        var columnNames: [String] = []
        for i in 0..<cols {
            if let cstr = sqlite3_column_name(stmt, Int32(i)) {
                columnNames.append(String(cString: cstr))
            } else {
                columnNames.append("col\(i)")
            }
        }
        var rows: [[String?]] = []
        var truncated = false
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW {
                throw SQLiteError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
            if rows.count >= maxRows { truncated = true; break }
            var row: [String?] = []
            for i in 0..<cols {
                let type = sqlite3_column_type(stmt, Int32(i))
                if type == SQLITE_NULL {
                    row.append(nil)
                } else if let cstr = sqlite3_column_text(stmt, Int32(i)) {
                    row.append(String(cString: cstr))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return QueryResult(columns: columnNames, rows: rows, truncated: truncated)
    }

    // MARK: - private

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed(msg)
        }
        return stmt
    }

    private func execScalarColumn(_ sql: String) throws -> [String] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                out.append(String(cString: cstr))
            }
        }
        return out
    }

}
