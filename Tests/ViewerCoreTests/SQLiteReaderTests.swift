import XCTest
@testable import ViewerCore

final class SQLiteReaderTests: XCTestCase {

    private var tmpDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-sqlite-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        dbURL = tmpDir.appendingPathComponent("t.sqlite")
        try createFixtureDB(at: dbURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Build a tiny SQLite file by SHELLING OUT to the system
    /// `sqlite3` binary. Avoids round-tripping sqlite3.dylib via our
    /// reader's API (which is read-only) just to populate fixtures.
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

    func testOpenAndListTables() throws {
        let r = try SQLiteReader(url: dbURL)
        let tables = try r.tableNames()
        XCTAssertEqual(Set(tables), Set(["users", "orders"]))
    }

    func testViewsListed() throws {
        let r = try SQLiteReader(url: dbURL)
        XCTAssertEqual(try r.viewNames(), ["adult_users"])
    }

    func testIndexesListed() throws {
        let r = try SQLiteReader(url: dbURL)
        XCTAssertTrue(try r.indexNames().contains("idx_users_age"))
    }

    func testTableColumns() throws {
        let r = try SQLiteReader(url: dbURL)
        let cols = try r.columns(of: "users")
        XCTAssertEqual(cols.map { $0.name }, ["id", "name", "age"])
        let nameCol = cols.first(where: { $0.name == "name" })
        XCTAssertEqual(nameCol?.type, "TEXT")
        XCTAssertTrue(nameCol?.notNull ?? false)
        let idCol = cols.first(where: { $0.name == "id" })
        XCTAssertTrue(idCol?.primaryKey ?? false)
    }

    func testRowCount() throws {
        let r = try SQLiteReader(url: dbURL)
        XCTAssertEqual(try r.rowCount(of: "users"), 3)
    }

    func testQueryReturnsRowsAndColumns() throws {
        let r = try SQLiteReader(url: dbURL)
        let result = try r.query("SELECT name, age FROM users ORDER BY age;")
        XCTAssertEqual(result.columns, ["name", "age"])
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.rows[0][0], "bob")
        XCTAssertEqual(result.rows[0][1], "25")
        XCTAssertFalse(result.truncated)
    }

    func testQueryRespectsMaxRows() throws {
        let r = try SQLiteReader(url: dbURL)
        let result = try r.query("SELECT * FROM users;", maxRows: 2)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertTrue(result.truncated)
    }

    func testQueryNullValues() throws {
        let r = try SQLiteReader(url: dbURL)
        // age is NULL-able? In our schema it isn't constrained NOT
        // NULL, but values are all set. Force a null via expression.
        let result = try r.query("SELECT NULL as x, 'y' as y;")
        XCTAssertEqual(result.rows[0][0], nil)
        XCTAssertEqual(result.rows[0][1], "y")
    }

    func testSchemaForTable() throws {
        let r = try SQLiteReader(url: dbURL)
        let sql = try r.schemaFor("users")
        XCTAssertNotNil(sql)
        XCTAssertTrue(sql?.contains("CREATE TABLE users") ?? false)
    }

    func testReadOnlyByConstruction() throws {
        let r = try SQLiteReader(url: dbURL)
        // Any write should fail.
        do {
            _ = try r.query("DELETE FROM users;")
            XCTFail("expected write to fail on read-only connection")
        } catch {
            // expected
        }
    }

    func testNonExistentFile() {
        let url = tmpDir.appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(try SQLiteReader(url: url))
    }

    // MARK: - SQL-02: authorizer denies ATTACH + writes

    /// `ATTACH DATABASE` must be denied by the authorizer so a crafted
    /// query can't open and read arbitrary files. The deny lands at
    /// prepare time (authorizer runs during compilation).
    func testAttachIsDenied() throws {
        let r = try SQLiteReader(url: dbURL)
        // Try to attach the system passwd file (or any path) — must fail.
        let target = tmpDir.appendingPathComponent("other.sqlite").path
        XCTAssertThrowsError(
            try r.query("ATTACH DATABASE '\(target)' AS evil;")
        ) { error in
            // Surfaces as prepareFailed ("not authorized").
            guard case SQLiteReader.SQLiteError.prepareFailed = error else {
                XCTFail("expected prepareFailed for denied ATTACH, got \(error)")
                return
            }
        }
    }

    /// DDL/DML is denied by the authorizer (defense in depth on top of
    /// SQLITE_OPEN_READONLY). A CREATE TABLE must not compile.
    func testCreateTableIsDenied() throws {
        let r = try SQLiteReader(url: dbURL)
        XCTAssertThrowsError(
            try r.query("CREATE TABLE evil (x);")
        )
    }

    /// Plain SELECT and the PRAGMAs the viewer issues must still work
    /// under the authorizer — proves we didn't over-deny.
    func testSelectStillWorksUnderAuthorizer() throws {
        let r = try SQLiteReader(url: dbURL)
        let result = try r.query("SELECT name FROM users ORDER BY name;")
        XCTAssertEqual(result.rows.compactMap { $0.first ?? nil },
                       ["alice", "bob", "carol"])
        // columns() goes through PRAGMA table_info — must not be denied.
        XCTAssertEqual(try r.columns(of: "users").map { $0.name },
                       ["id", "name", "age"])
    }

    // MARK: - SQL-01: cooperative cancellation

    /// A query interrupted via `cancel()` from another thread aborts
    /// promptly with `.interrupted` rather than running to completion.
    /// We spin a deliberately heavy recursive CTE and cancel it.
    func testCancelInterruptsLongQuery() throws {
        let r = try SQLiteReader(url: dbURL)
        // ~100M-iteration recursive CTE: enough VM ops that the
        // progress handler (every 50k ops) polls our flag well before
        // it could finish.
        let heavy = """
        WITH RECURSIVE c(x) AS (
            SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 100000000
        )
        SELECT count(*) FROM c;
        """
        // Fire the cancel shortly after the query starts.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            r.cancel()
        }
        let start = Date()
        XCTAssertThrowsError(try r.query(heavy)) { error in
            guard case SQLiteReader.SQLiteError.interrupted = error else {
                XCTFail("expected .interrupted, got \(error)")
                return
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0,
                          "cancel should interrupt promptly (got \(elapsed)s)")
    }

    /// After a cancellation, a fresh `query(...)` resets the flag and
    /// runs normally — cancellation isn't sticky.
    func testQueryAfterCancelResetsFlag() throws {
        let r = try SQLiteReader(url: dbURL)
        r.cancel()              // pre-set the flag
        // query() must reset it at entry and complete normally.
        let result = try r.query("SELECT count(*) FROM users;")
        XCTAssertEqual(result.rows.first?.first ?? nil, "3")
    }
}
