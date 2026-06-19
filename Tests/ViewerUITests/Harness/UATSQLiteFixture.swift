import Foundation
import XCTest

/// Shared UAT test-support: materialize a **real, valid, enumerable** SQLite v3
/// database on disk so the SQLite browser (`SQLiteBrowserView`) actually mounts.
///
/// ## Why this exists (TSK-1021)
///
/// Four UAT suites (`PreviewsUATTests`, `ViewModesUATTests`,
/// `TabsAndWindowChromeUATTests`, `ViewModeMatrixSmokeTests`) each carried an
/// identical `writeSQLiteFixture(_:)` that hand-stamped a 4096-byte page-0 with
/// the canonical `SQLite format 3\0` header but left the `sqlite_master` b-tree
/// (bytes 100+) ZEROED. That is a **malformed** database — b-tree page type `0`
/// is invalid, schema format `0` is invalid — so `SQLiteReader.tableNames()`
/// throws `malformed database`.
///
/// Before TSK-1008, `SQLiteBrowserView` swallowed that error
/// (`(try? r.tableNames()) ?? []`) and mounted an empty browser, so the fixture
/// "worked" by accident. TSK-1008 (correctly) changed that to `try r.tableNames()`
/// so an unenumerable DB surfaces an open error instead of silently mounting an
/// empty `NSSplitView`. That exposed the malformed fixture: `PV_04`'s
/// `assertSplitBrowserRendered` (for the VALID `app.db`) started failing on the
/// VM GUI lane.
///
/// The fix is to make the fixture a REAL database. We shell out to the
/// system `/usr/bin/sqlite3` (present on the macOS host AND the macOS VM),
/// creating one table with a handful of rows so the browser enumerates the
/// schema and mounts. A real `.db` with the same extension + `SQLite format 3`
/// header routes to the sqlite preview identically to the old fixture — this is
/// a strict superset, so the existing routing-only tests still pass.
enum UATSQLiteFixture {
    /// Path to the system SQLite CLI (host + macOS VM both ship this).
    private static let sqlite3Path = "/usr/bin/sqlite3"

    /// The DDL the fixture seeds: one table with a primary key + a text column
    /// and three rows, which is enough for `tableNames()` / schema enumeration.
    static let seedSQL = """
        CREATE TABLE demo(id INTEGER PRIMARY KEY, name TEXT);
        INSERT INTO demo(name) VALUES('alpha'),('beta'),('gamma');
        """

    /// Create a real, valid, enumerable SQLite database at `tmpDir/name`.
    ///
    /// - Removes any pre-existing file (and its rollback journal sidecar) at the
    ///   target path first, so a stale fixture can't poison the result.
    /// - Spawns `/usr/bin/sqlite3 <path> "<DDL>"` (default rollback journal — no
    ///   persistent `-wal`/`-shm` sidecar to clean up).
    /// - Guards `terminationStatus == 0` AND that the file was actually written.
    ///
    /// - Returns: the URL of the created database.
    /// - Throws: `XCTSkip` if the system `sqlite3` is unavailable (so a missing
    ///   tool degrades to a skip, not a hard failure), or an `XCTestError` if
    ///   creation fails despite the tool being present.
    @discardableResult
    static func write(_ name: String, in tmpDir: URL) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        let fm = FileManager.default

        // Clear any pre-existing file + its default rollback-journal sidecar.
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: url.appendingPathExtension("journal"))

        guard fm.isExecutableFile(atPath: sqlite3Path) else {
            throw XCTSkip("system sqlite3 unavailable at \(sqlite3Path) — cannot build a real SQLite fixture")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: sqlite3Path)
        proc.arguments = [url.path, seedSQL]
        // Capture stderr so a failure message is visible in the assertion.
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        try proc.run()
        proc.waitUntilExit()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""

        guard proc.terminationStatus == 0 else {
            throw NSError(
                domain: "UATSQLiteFixture", code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "sqlite3 exited \(proc.terminationStatus) building \(name): \(errText)"])
        }
        guard fm.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "UATSQLiteFixture", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "sqlite3 exited 0 but no file at \(url.path): \(errText)"])
        }
        return url
    }
}
