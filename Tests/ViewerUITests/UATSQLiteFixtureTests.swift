import XCTest
import Foundation
@testable import ViewerCore

/// Host-safe behavior guard for `UATSQLiteFixture` (TSK-1021).
///
/// The four UAT suites build their SQLite browser fixtures through this helper.
/// The SQLite browser (`SQLiteBrowserView`) mounts its `NSSplitView` only if
/// `SQLiteReader.tableNames()` SUCCEEDS — TSK-1008 made an unenumerable DB
/// surface an open error instead of silently mounting an empty browser. So the
/// load-bearing property is: **the fixture is a real, enumerable database.**
///
/// These tests exercise the EXACT enumeration path the browser uses
/// (`SQLiteReader` from `ViewerCore`) so a regression of the fixture back to a
/// malformed/zeroed b-tree fails here on the host gate — long before the
/// VM-only T4 `PV_04` render assertion would catch it.
///
/// TEETH: the old hand-stamped fixture (canonical header + zeroed page-0)
/// throws `malformed database` from `tableNames()`; `test_malformed_header_only_db_fails_enumeration`
/// pins that, so we know the success assertions below aren't vacuous.
final class UATSQLiteFixtureTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UATSQLiteFixtureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try super.tearDownWithError()
    }

    /// The fixture file exists, is non-trivial, and carries the SQLite v3 magic
    /// header (so it still ROUTES to the sqlite preview identically — superset).
    func test_fixture_is_written_with_sqlite_magic_header() throws {
        let url = try UATSQLiteFixture.write("app.db", in: tmpDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(data.count, 512, "a real DB has at least the 100-byte header + page content")
        let magic = Array("SQLite format 3\u{0}".utf8)
        XCTAssertEqual(Array(data.prefix(magic.count)), magic,
                       "fixture must carry the canonical SQLite v3 header so routing to sqlite-preview is unchanged")
    }

    /// The CORE guard: the fixture is a REAL, ENUMERABLE database. This is the
    /// exact path `SQLiteBrowserView.load()` runs — if it throws, the browser
    /// surfaces an open error and never mounts its `NSSplitView`.
    func test_fixture_is_enumerable_by_SQLiteReader() throws {
        let url = try UATSQLiteFixture.write("app.db", in: tmpDir)
        let reader = try SQLiteReader(url: url)

        // tableNames() must NOT throw (the malformed-fixture regression) AND
        // must surface the seeded table.
        let tables = try reader.tableNames()
        XCTAssertEqual(tables, ["demo"], "fixture should enumerate exactly the seeded `demo` table")

        // The other schema enumerations the browser also calls must not throw.
        XCTAssertNoThrow(try reader.viewNames())
        XCTAssertNoThrow(try reader.indexNames())
        XCTAssertNoThrow(try reader.triggerNames())
    }

    /// The seeded rows are real and queryable — confirms the INSERTs landed,
    /// not just the schema, so the browser's first SELECT returns data.
    func test_fixture_rows_are_queryable() throws {
        let url = try UATSQLiteFixture.write("app.db", in: tmpDir)
        let reader = try SQLiteReader(url: url)
        let result = try reader.query("SELECT name FROM demo ORDER BY id;")
        let names = result.rows.compactMap { $0.first.flatMap { $0 } }
        XCTAssertEqual(names, ["alpha", "beta", "gamma"])
    }

    /// Re-creating over an existing file at the same path succeeds (the helper
    /// removes the stale file first), so repeated UAT runs don't accrete a
    /// poisoned fixture.
    func test_overwrites_preexisting_file() throws {
        let url = tmpDir.appendingPathComponent("app.db")
        try Data("stale garbage not a database".utf8).write(to: url)

        let created = try UATSQLiteFixture.write("app.db", in: tmpDir)
        XCTAssertEqual(created.path, url.path)
        let reader = try SQLiteReader(url: created)
        XCTAssertEqual(try reader.tableNames(), ["demo"])
    }

    /// TEETH: the OLD hand-stamped fixture (header + zeroed page-0) is malformed
    /// and `tableNames()` throws. This proves the success assertions above are
    /// not vacuous — a regression back to that style fails the enumeration guard.
    func test_malformed_header_only_db_fails_enumeration() throws {
        let url = tmpDir.appendingPathComponent("malformed.db")
        var page = Data(count: 4096)
        let magic = Array("SQLite format 3\u{0}".utf8)
        page.replaceSubrange(0..<magic.count, with: magic)
        page[16] = 0x10; page[17] = 0x00
        page[18] = 1; page[19] = 1
        page[21] = 64; page[22] = 32; page[23] = 32
        page[56] = 0; page[57] = 0; page[58] = 0; page[59] = 1
        try page.write(to: url)

        // The reader may open (the header parses) but enumerating the zeroed
        // sqlite_master b-tree must throw "malformed database".
        let reader = try SQLiteReader(url: url)
        XCTAssertThrowsError(try reader.tableNames(),
            "a zeroed-b-tree DB must NOT enumerate — that is the bug TSK-1021 fixes")
    }
}
