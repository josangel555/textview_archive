import XCTest

@testable import RustCore

/// Cross-language tests: Swift calling the ACTUAL Rust `extern "C"` symbols via
/// the RustCore bridge, asserting the round-trips. Headless (no SwiftUI / no
/// NSApplication), so per the project's testing rules they are safe on the
/// host. Carried over from the validated PoC (`poc-snap-final`), adapted to the
/// shipping `mdvcore_*` symbols.
final class BridgeTests: XCTestCase {

    let csv = "name,city\nAlice,Paris\nBob,Parma\nCarol,Berlin\n"

    func testStage0Add() {
        XCTAssertEqual(mdvCoreAdd(2, 3), 5)
        // wrapping add over the boundary.
        XCTAssertEqual(mdvCoreAdd(Int32.max, 1), Int32.min)
    }

    func testForcePanicMapsToError() {
        // The core panics; the boundary catches it and returns .panic. The test
        // process must NOT crash (proves catch_unwind end-to-end into Swift,
        // and that the dist/unwind profile is the one being linked).
        XCTAssertEqual(mdvCoreForcePanic(), .panic)
        // Still alive:
        XCTAssertEqual(mdvCoreAdd(1, 1), 2)
    }

    func testOpenAndTableRoundTrip() throws {
        let session = try CsvSession(csv: csv)
        let table = try session.table()
        XCTAssertEqual(table.delimiter, ",")
        XCTAssertEqual(table.header, ["name", "city"])
        XCTAssertEqual(table.rows, [["Alice", "Paris"], ["Bob", "Parma"], ["Carol", "Berlin"]])
        XCTAssertFalse(table.truncated)
    }

    func testBadUTF8Throws() {
        let bad: [UInt8] = [0x61, 0xFF, 0x62]
        XCTAssertThrowsError(try CsvSession(bytes: bad)) { error in
            XCTAssertEqual(error as? CoreError, .badUTF8)
        }
    }

    func testSetFilterAndSnapshot() throws {
        let session = try CsvSession(csv: csv)

        let snap0 = try session.snapshot()
        XCTAssertEqual(snap0.totalRows, 3)
        XCTAssertEqual(snap0.rows.count, 3)
        XCTAssertEqual(snap0.version, 1)

        try session.setFilter("par")
        let snap1 = try session.snapshot()
        XCTAssertEqual(snap1.rows.count, 2)  // Paris, Parma
        XCTAssertEqual(snap1.indices, [0, 1])
        XCTAssertEqual(snap1.totalRows, 3)
        XCTAssertEqual(snap1.version, 2)
        XCTAssertEqual(snap1.query, "par")
    }

    func testColumnScopedFilter() throws {
        let session = try CsvSession(csv: csv)
        try session.setFilter("a", scope: .column(0))  // name col: Alice, Carol
        let snap = try session.snapshot()
        XCTAssertEqual(snap.indices, [0, 2])
    }

    func testLevelTriggeredSnapshotIsFullState() throws {
        // Successive filter changes; the snapshot reflects ONLY the latest
        // query as complete current state, not an accumulation of deltas.
        let session = try CsvSession(csv: csv)
        try session.setFilter("par")
        try session.setFilter("berlin")
        let snap = try session.snapshot()
        XCTAssertEqual(snap.query, "berlin")
        XCTAssertEqual(snap.rows.count, 1)
        XCTAssertEqual(snap.rows.first?.last, "Berlin")

        // Re-pulling without a mutation yields an identical snapshot.
        let again = try session.snapshot()
        XCTAssertEqual(snap, again)
    }

    func testEmptyInputOpens() throws {
        let session = try CsvSession(bytes: [])
        let table = try session.table()
        XCTAssertTrue(table.header.isEmpty)
        XCTAssertTrue(table.rows.isEmpty)
    }

    func testHandleLifecycleManyOpens() throws {
        // ARC frees each handle in deinit; a leak/double-free would surface
        // under ASan. Here we just prove the loop is stable.
        for _ in 0..<500 {
            let session = try CsvSession(csv: csv)
            _ = try session.snapshot()
        }
    }

    func testQuotedAndCRLF() throws {
        let session = try CsvSession(csv: "a,b\r\n\"x,y\",z\r\n")
        let table = try session.table()
        XCTAssertEqual(table.rows, [["x,y", "z"]])
    }
}
