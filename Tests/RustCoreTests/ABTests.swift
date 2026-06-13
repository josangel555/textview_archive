import XCTest

@testable import RustCore
import ViewerCore

/// The A/B: the Rust core vs the SHIPPING Swift `CSVParser` / `CSVFilter` (the
/// real ones in ViewerCore — not a vendored copy, unlike the PoC). Two
/// dimensions:
///   1. CORRECTNESS parity — same delimiter / header / rows on shared inputs.
///   2. PERFORMANCE — wall-clock parse of a generated CSV, both impls, ratio
///      logged.
///
/// NOTE: the Rust path here includes the FULL FFI cost (handle alloc + parse +
/// MessagePack encode + length-framing + Swift-side MessagePack decode), so it
/// is a pessimistic, whole-pipeline comparison — not just the raw parse loop.
/// Deliberate: it measures what a real projection pays.
final class ABTests: XCTestCase {

    /// Inputs where both impls must agree exactly.
    static let sharedCases: [String] = [
        "a,b,c\n1,2,3\n4,5,6\n",
        "a;b;c\n1;2;3\n",
        "a\tb\tc\n1\t2\t3\n",
        "a|b|c\n1|2|3\n",
        "a,b\n\"x,y\",z\n",
        "a,b\n\"she said \"\"hi\"\"\",z\n",
        "a,b\r\n1,2\r\n3,4\r\n",
        "a,b,c\n1,2,3,4\n5,6\n",  // ragged: long truncated, short padded
        "name,emoji\nJosé,🎉\n",
        "\"a,b,c\";x;y\n1;2;3\n",  // quote-aware delimiter detection
        "a,b\n\"line1\nline2\",z\n",  // quoted newline
        "a,b\r1,2\r3,4\r",  // bare CR (Mac classic)
        "a,b,c\n",  // header only
        "",  // empty input
    ]

    func testCorrectnessParity() throws {
        for input in Self.sharedCases {
            let swift = CSVParser.parse(input)
            let session = try CsvSession(csv: input)
            let rust = try session.table()

            XCTAssertEqual(
                String(swift.delimiter), rust.delimiter,
                "delimiter mismatch for input: \(input.debugDescription)")
            XCTAssertEqual(
                swift.header, rust.header,
                "header mismatch for input: \(input.debugDescription)")
            XCTAssertEqual(
                swift.rows, rust.rows,
                "rows mismatch for input: \(input.debugDescription)")
            XCTAssertEqual(
                swift.truncated, rust.truncated,
                "truncated mismatch for input: \(input.debugDescription)")
        }
    }

    /// Same correctness parity, but through the production adapter with the
    /// gate FORCED ON via env — exercises the exact code path the app runs when
    /// the flag is set, including the Table → CSVParser.Result mapping.
    func testAdapterParityWhenForcedOn() {
        let env = ["MDV_RUST_CSV": "1"]
        XCTAssertTrue(RustCSVGate.isEnabled(environment: env))
        for input in Self.sharedCases {
            let swift = CSVParser.parse(input)
            let viaAdapter = (try? RustCSVAdapter.rustParse(input))
            XCTAssertNotNil(viaAdapter, "adapter rustParse threw for \(input.debugDescription)")
            guard let rust = viaAdapter else { continue }
            XCTAssertEqual(swift.delimiter, rust.delimiter,
                           "adapter delimiter mismatch: \(input.debugDescription)")
            XCTAssertEqual(swift.header, rust.header,
                           "adapter header mismatch: \(input.debugDescription)")
            XCTAssertEqual(swift.rows, rust.rows,
                           "adapter rows mismatch: \(input.debugDescription)")
            XCTAssertEqual(swift.truncated, rust.truncated,
                           "adapter truncated mismatch: \(input.debugDescription)")
        }
    }

    /// Generate a sizeable CSV for the perf comparison.
    private func makeBigCSV(rows: Int) -> String {
        var s = "id,name,city,score,note\n"
        s.reserveCapacity(rows * 40)
        for i in 0..<rows {
            s += "\(i),Person\(i),City\(i % 100),\(i * 7 % 1000),\"a, quoted note \(i)\"\n"
        }
        return s
    }

    func testPerformanceAB() throws {
        let rowCount = 20_000
        let input = makeBigCSV(rows: rowCount)
        let inputBytes = [UInt8](input.utf8)

        // Warm up both paths once (allocator / code cache).
        _ = CSVParser.parse(input)
        _ = try CsvSession(bytes: inputBytes).table()

        let iterations = 5

        // --- Swift baseline (parse only) ---
        let swiftStart = DispatchTime.now()
        var swiftRows = 0
        for _ in 0..<iterations {
            let r = CSVParser.parse(input)
            swiftRows = r.rows.count
        }
        let swiftNanos = DispatchTime.now().uptimeNanoseconds - swiftStart.uptimeNanoseconds

        // --- Rust via full FFI pipeline (open + parse + wire + decode) ---
        let rustStart = DispatchTime.now()
        var rustRows = 0
        for _ in 0..<iterations {
            let session = try CsvSession(bytes: inputBytes)
            let t = try session.table()
            rustRows = t.rows.count
        }
        let rustNanos = DispatchTime.now().uptimeNanoseconds - rustStart.uptimeNanoseconds

        XCTAssertEqual(swiftRows, rowCount)
        XCTAssertEqual(rustRows, rowCount)

        let swiftMs = Double(swiftNanos) / 1_000_000 / Double(iterations)
        let rustMs = Double(rustNanos) / 1_000_000 / Double(iterations)
        let ratio = rustMs / swiftMs

        // Not an assertion on a target — we want the NUMBER in the test log.
        print(
            """
            === CSV A/B (\(rowCount) rows, \(iterations) iters avg) ===
            Swift CSVParser (parse only):        \(String(format: "%.2f", swiftMs)) ms
            Rust core (open+parse+wire+decode):  \(String(format: "%.2f", rustMs)) ms
            ratio (rust/swift, full pipeline):   \(String(format: "%.2fx", ratio))
            NOTE: rust figure includes MessagePack encode + Swift-side decode;
            the raw Rust parse is a fraction of this.
            """)
    }

    func testFilterParityWithSwiftFilter() throws {
        // The Rust session's global-query filter must agree with the shipping
        // Swift CSVFilter's global substring semantics on a shared input.
        let input = "name,city\nAlice,Paris\nBob,Parma\nCarol,Berlin\n"
        let session = try CsvSession(csv: input)
        try session.setFilter("par")
        let snap = try session.snapshot()

        // Drive the REAL CSVFilter (not a hand-rolled mirror) as the oracle.
        let parsed = CSVParser.parse(input)
        let filter = CSVFilter(globalQuery: "par", globalScope: .all)
        let expected = filter.apply(to: parsed)
        XCTAssertEqual(snap.rows, expected.rows)
        XCTAssertEqual(snap.indices.map(Int.init), expected.indices)
    }

    /// TSK-559 — the windowed snapshot + filtered-count bindings round-trip
    /// through the FFI: a consumer can page the visible viewport (O(window))
    /// and size its scrollbar from filteredCount without pulling the whole set.
    func testSnapshotWindowAndFilteredCount() throws {
        var csv = "id,name\n"
        for i in 0..<100 { csv += "\(i),row\(i)\n" }
        let session = try CsvSession(csv: csv)

        XCTAssertEqual(try session.filteredCount(), 100, "unfiltered → all rows")
        let w = try session.snapshotWindow(offset: 50, limit: 10)
        XCTAssertEqual(w.rows.count, 10)
        XCTAssertEqual(w.indices.map(Int.init), Array(50..<60), "absolute row ids")
        XCTAssertEqual(w.totalRows, 100, "table total, not window size")
        XCTAssertEqual(w.rows.first, ["50", "row50"])

        // Past the end → empty window, no throw.
        let past = try session.snapshotWindow(offset: 500, limit: 10)
        XCTAssertTrue(past.rows.isEmpty)
        XCTAssertEqual(past.totalRows, 100)

        // The window pages the FILTERED set. "row1" matches row1 + row10..19 = 11.
        try session.setFilter("row1")
        XCTAssertEqual(try session.filteredCount(), 11)
        let win = try session.snapshotWindow(offset: 0, limit: 3)
        XCTAssertEqual(win.indices.map(Int.init), [1, 10, 11])
    }
}
