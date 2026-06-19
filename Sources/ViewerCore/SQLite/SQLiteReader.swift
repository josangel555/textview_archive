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

    /// SQL-01/PARSE-02: cooperative cancellation. A long-running query
    /// is interrupted by setting this flag; the `sqlite3_progress_handler`
    /// polls it every N VM ops and returns non-zero, which makes
    /// `sqlite3_step` fail with `SQLITE_INTERRUPT`. The box is heap-
    /// allocated and passed to the C progress handler as its `void *`
    /// context, so the callback reads it without capturing `self`.
    private let cancelBox = _CancelBox()

    public enum SQLiteError: Error, CustomStringConvertible {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
        /// SQL-01/PARSE-02: query was interrupted (deadline hit or
        /// explicit `cancel()`), surfaced from the progress handler.
        case interrupted

        public var description: String {
            switch self {
            case .openFailed(let m):    return "Open failed: \(m)"
            case .prepareFailed(let m): return "Prepare failed: \(m)"
            case .stepFailed(let m):    return "Step failed: \(m)"
            case .interrupted:          return "Query cancelled"
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
        // SQL-01: bound time spent blocked on a locked DB (e.g. a WAL
        // checkpoint from another process). 5s is generous for a
        // read-only viewer; without it a contended file could hang the
        // step loop indefinitely.
        sqlite3_busy_timeout(db, 5_000)
        installAuthorizer()
        installProgressHandler()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Cancellation (SQL-01/PARSE-02)

    /// Request cancellation of any in-flight query on this reader. The
    /// progress handler observes the flag and aborts the next step with
    /// `SQLITE_INTERRUPT`. Safe to call from any thread (the box is
    /// lock-guarded). Idempotent.
    public func cancel() { cancelBox.cancel() }

    /// Clear a prior cancellation so the reader can run further queries.
    /// `query(...)` resets this automatically at entry.
    public func resetCancel() { cancelBox.reset() }

    /// SQL-02: deny `ATTACH DATABASE` so a crafted query can't open and
    /// read arbitrary files on disk (`ATTACH '/etc/passwd' AS x`), and
    /// belt-and-suspenders deny every write/DDL verb (the connection is
    /// already `SQLITE_OPEN_READONLY`, but the authorizer makes the
    /// read-only contract explicit and rejects writes at *prepare* time
    /// with a clear error instead of at step time). Read/select verbs
    /// and the PRAGMAs we issue (`table_info`) are allowed.
    private func installAuthorizer() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_set_authorizer(db, { _, action, _, _, _, _ in
            switch action {
            // Hard-deny: cross-file reads and any mutation/DDL.
            case SQLITE_ATTACH, SQLITE_DETACH:
                return SQLITE_DENY
            case SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE,
                 SQLITE_DROP_TABLE, SQLITE_DROP_INDEX, SQLITE_DROP_VIEW,
                 SQLITE_DROP_TRIGGER, SQLITE_DROP_TEMP_TABLE,
                 SQLITE_DROP_TEMP_INDEX, SQLITE_DROP_TEMP_VIEW,
                 SQLITE_DROP_TEMP_TRIGGER,
                 SQLITE_CREATE_TABLE, SQLITE_CREATE_INDEX,
                 SQLITE_CREATE_VIEW, SQLITE_CREATE_TRIGGER,
                 SQLITE_CREATE_TEMP_TABLE, SQLITE_CREATE_TEMP_INDEX,
                 SQLITE_CREATE_TEMP_VIEW, SQLITE_CREATE_TEMP_TRIGGER,
                 SQLITE_ALTER_TABLE, SQLITE_REINDEX, SQLITE_ANALYZE,
                 SQLITE_CREATE_VTABLE, SQLITE_DROP_VTABLE:
                return SQLITE_DENY
            // Everything else (SELECT, READ, FUNCTION, PRAGMA the viewer
            // needs, transaction control) is allowed.
            default:
                return SQLITE_OK
            }
        }, ctx)
    }

    /// SQL-01/PARSE-02: install a progress handler that fires every
    /// `instructionInterval` VM ops. It returns non-zero (→ abort) when
    /// the cancel flag is set, turning a runaway query (cross join,
    /// `WITH RECURSIVE` blowup) into a prompt `SQLITE_INTERRUPT` instead
    /// of an unbounded main-thread/off-thread spin.
    private func installProgressHandler() {
        let ctx = cancelBox.opaque()
        // ~50k ops between checks: frequent enough that cancellation is
        // snappy (sub-millisecond on modern hardware) but rare enough
        // not to measurably slow honest queries.
        sqlite3_progress_handler(db, 50_000, { raw in
            guard let raw else { return 0 }
            return _CancelBox.isCancelled(raw) ? 1 : 0
        }, ctx)
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
        // SQL-03: pass SQLITE_TRANSIENT (not nil = SQLITE_STATIC) so
        // SQLite copies the bound bytes immediately. The previous code
        // passed nil, which promises the pointer stays valid until the
        // statement is reset/finalized — but `name.utf8CString`'s buffer
        // is only valid for the duration of `withUnsafeBufferPointer`,
        // and `sqlite3_step` runs AFTER that closure returns. That was a
        // use-after-free: SQLite could read reclaimed heap, yielding the
        // wrong row / garbage / a crash. SQLITE_TRANSIENT is the constant
        // (cast of -1) SQLite documents for "make your own copy".
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let rc = name.utf8CString.withUnsafeBufferPointer { buf in
            sqlite3_bind_text(stmt, 1, buf.baseAddress, -1, SQLITE_TRANSIENT)
        }
        guard rc == SQLITE_OK else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
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
        // SQL-01: a fresh query starts un-cancelled. Caller may flip the
        // flag mid-flight (Cancel button / deadline) from another thread.
        cancelBox.reset()
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
                // SQL-01: progress-handler abort surfaces as
                // SQLITE_INTERRUPT — distinguish it from a genuine
                // step failure so the UI shows "Cancelled" not an error.
                if rc == SQLITE_INTERRUPT { throw SQLiteError.interrupted }
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

/// SQL-01/PARSE-02: heap-allocated, lock-guarded cancel flag shared
/// between the query thread and the `sqlite3_progress_handler` C
/// callback. Passed to the handler as its `void *` context so the
/// callback never captures the (`@MainActor`-unaware) Swift closure or
/// `SQLiteReader` itself. `@unchecked Sendable`: the only state is a
/// `Bool` behind `NSLock`, and the box outlives the connection (held by
/// `SQLiteReader` for its full lifetime, and we clear the progress
/// handler implicitly when `sqlite3_close` runs in deinit).
private final class _CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
    func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    /// Stable opaque pointer to this box for the C progress handler.
    /// Unretained — the box's lifetime is tied to its owning
    /// `SQLiteReader`, which always outlives the connection's progress
    /// handler (cleared by `sqlite3_close`).
    func opaque() -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    /// Read the cancel flag through an opaque pointer handed back by
    /// the C callback.
    static func isCancelled(_ raw: UnsafeMutableRawPointer) -> Bool {
        Unmanaged<_CancelBox>.fromOpaque(raw).takeUnretainedValue().isCancelled()
    }
}
