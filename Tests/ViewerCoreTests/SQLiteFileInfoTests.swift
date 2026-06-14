import XCTest
@testable import ViewerCore

/// TSK-807 — the SQLite "Database" summary for the file-info panel. Builds a
/// real fixture DB (shelling out to the system `sqlite3`, like SQLiteReaderTests)
/// and asserts the extracted rows. Host-safe.
final class SQLiteFileInfoTests: XCTestCase {
    private var tmpDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-sqlite-info-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        dbURL = tmpDir.appendingPathComponent("t.sqlite")
        try createFixtureDB(at: dbURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// users: 3 rows, orders: 0 rows, one view, one index, no triggers.
    private func createFixtureDB(at url: URL) throws {
        let script = """
        CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER);
        INSERT INTO users (name, age) VALUES ('alice', 30), ('bob', 25), ('carol', 42);
        CREATE INDEX idx_users_age ON users(age);
        CREATE VIEW adult_users AS SELECT * FROM users WHERE age >= 18;
        CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER, total REAL);
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [url.path]
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        pipe.fileHandleForWriting.write(Data(script.utf8))
        try pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "sqlite3 fixture creation failed")
    }

    private func value(_ rows: [SQLiteFileInfo.Row], _ label: String) -> String? {
        rows.first(where: { $0.label == label })?.value
    }

    func test_summary_objectCountsAndTotalRows() {
        let rows = SQLiteFileInfo.summaryRows(for: dbURL)
        XCTAssertEqual(value(rows, "Tables"), "2", "users + orders")
        XCTAssertEqual(value(rows, "Views"), "1", "adult_users")
        XCTAssertEqual(value(rows, "Indexes"), "1", "idx_users_age")
        XCTAssertEqual(value(rows, "Total rows"), 3.formatted(),
                       "3 in users + 0 in orders, locale-grouped")
    }

    func test_summary_omitsZeroTriggers() {
        let rows = SQLiteFileInfo.summaryRows(for: dbURL)
        XCTAssertNil(value(rows, "Triggers"), "no triggers ⇒ the row is omitted")
    }

    func test_summary_encodingAndPageSize() {
        let rows = SQLiteFileInfo.summaryRows(for: dbURL)
        XCTAssertEqual(value(rows, "Encoding")?.uppercased(), "UTF-8")
        // page_size is a power-of-two byte count rendered "<n> bytes".
        let pageSize = value(rows, "Page size")
        XCTAssertNotNil(pageSize)
        XCTAssertTrue(pageSize?.hasSuffix(" bytes") ?? false)
        let n = Int(pageSize?.replacingOccurrences(of: " bytes", with: "") ?? "")
        XCTAssertNotNil(n)
        XCTAssertGreaterThanOrEqual(n ?? 0, 512, "SQLite page size is ≥ 512")
    }

    func test_nonDatabaseFile_yieldsEmpty() throws {
        // A plain text file with a .sqlite extension can't be opened as a DB.
        let bogus = tmpDir.appendingPathComponent("not-a.sqlite")
        try "hello, not a database\n".write(to: bogus, atomically: true, encoding: .utf8)
        XCTAssertTrue(SQLiteFileInfo.summaryRows(for: bogus).isEmpty,
                      "a non-SQLite file degrades to no rows")
    }
}
