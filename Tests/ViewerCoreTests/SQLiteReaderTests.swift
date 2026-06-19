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

    // MARK: - L-eh2(c): a DB that OPENS but can't enumerate must THROW (TSK-1008)

    /// A file with a valid 16-byte SQLite magic header but a corrupt body
    /// OPENS lazily (sqlite3_open_v2 reads no pages) yet FAILS the first
    /// `sqlite_master` read. The SQLiteBrowser view-model wrapped each
    /// schema listing in `(try? r.tableNames()) ?? []`, so this corruption
    /// was hidden behind an EMPTY browser — indistinguishable from a
    /// genuinely empty DB, with zero signal to the user. The fix lets the
    /// enumeration THROW into the open-error catch; this test pins that the
    /// enumeration does raise (so the swallow was masking a real error).
    func testCorruptBodyOpensButEnumerationThrows() throws {
        let corrupt = tmpDir.appendingPathComponent("corrupt.sqlite")
        // 16-byte magic "SQLite format 3\0" + garbage page bytes.
        var bytes = Array("SQLite format 3".utf8)
        bytes.append(0)                              // NUL terminator of the magic
        bytes.append(contentsOf: Array(repeating: UInt8(0xEE), count: 4096))
        try Data(bytes).write(to: corrupt)

        // Opening succeeds (header magic matches; pages are read lazily).
        let r = try SQLiteReader(url: corrupt)
        // ...but enumerating the schema raises rather than returning [].
        XCTAssertThrowsError(try r.tableNames(),
            "a header-valid but corrupt DB must surface the read error, not return []")
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

    // MARK: - SQL-03: sqlite3_bind_text use-after-free regression

    /// `schemaFor` binds the name with SQLITE_TRANSIENT so SQLite copies
    /// the bytes before `sqlite3_step` runs. Asserting the CORRECT schema
    /// for every table AND view is the durable teeth: under the old
    /// SQLITE_STATIC bind, the bound pointer dangled after the
    /// `withUnsafeBufferPointer` closure returned, so SQLite read
    /// reclaimed heap and the WHERE name=? filter matched the wrong row
    /// (or none) — a wrong/nil schema rather than the exact CREATE text.
    func testSchemaForEachObjectReturnsCorrectSchema() throws {
        let r = try SQLiteReader(url: dbURL)

        let usersSchema = try r.schemaFor("users")
        XCTAssertNotNil(usersSchema)
        XCTAssertTrue(usersSchema?.contains("CREATE TABLE users") ?? false,
                      "users schema must round-trip its own CREATE TABLE, got: \(String(describing: usersSchema))")
        XCTAssertTrue(usersSchema?.contains("name TEXT NOT NULL") ?? false)
        // Must be the users CREATE, not a different object's row.
        XCTAssertFalse(usersSchema?.contains("orders") ?? true)

        let ordersSchema = try r.schemaFor("orders")
        XCTAssertNotNil(ordersSchema)
        XCTAssertTrue(ordersSchema?.contains("CREATE TABLE orders") ?? false,
                      "orders schema must round-trip its own CREATE TABLE, got: \(String(describing: ordersSchema))")
        XCTAssertFalse(ordersSchema?.contains("CREATE TABLE users") ?? true)

        let viewSchema = try r.schemaFor("adult_users")
        XCTAssertNotNil(viewSchema)
        XCTAssertTrue(viewSchema?.contains("CREATE VIEW adult_users") ?? false,
                      "view schema must round-trip its own CREATE VIEW, got: \(String(describing: viewSchema))")

        // A name that doesn't exist must return nil (not a stale match).
        XCTAssertNil(try r.schemaFor("no_such_object"))
    }

    /// Drive `schemaFor` over names sourced from `tableNames()` /
    /// `viewNames()` (the real call path) in a tight loop with heap
    /// churn between iterations, so the dangling-pointer read is far more
    /// likely to surface garbage on the unfixed (SQLITE_STATIC) build.
    /// Each result must still be the OBJECT'S OWN schema — the assertion
    /// is what fails if the bind dangles.
    func testSchemaForUnderHeapChurnReturnsOwnSchema() throws {
        let r = try SQLiteReader(url: dbURL)
        let tableNames = try r.tableNames()
        let viewNames = try r.viewNames()
        XCTAssertFalse(tableNames.isEmpty)

        for _ in 0..<200 {
            for name in tableNames {
                // Churn the heap so a dangling baseAddress is likely to
                // point at clobbered bytes by the time sqlite3_step reads.
                let scratch = Array(repeating: UInt8(0xAB), count: 4096)
                _ = scratch.reduce(0, &+)
                guard let schema = try r.schemaFor(name) else {
                    XCTFail("schemaFor(\(name)) returned nil under churn")
                    continue
                }
                // The returned CREATE statement must name THIS object.
                XCTAssertTrue(schema.contains(name),
                              "schemaFor(\(name)) returned a schema not naming it: \(schema)")
            }
            for name in viewNames {
                let scratch = Array(repeating: UInt8(0xCD), count: 4096)
                _ = scratch.reduce(0, &+)
                guard let schema = try r.schemaFor(name) else {
                    XCTFail("schemaFor(\(name)) returned nil under churn")
                    continue
                }
                XCTAssertTrue(schema.contains(name),
                              "schemaFor(\(name)) returned a schema not naming it: \(schema)")
            }
        }
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
