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
}
