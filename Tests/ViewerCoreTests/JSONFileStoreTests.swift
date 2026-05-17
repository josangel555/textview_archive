import XCTest
@testable import ViewerCore

final class JSONFileStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONFileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private struct Sample: Codable, Equatable {
        let name: String
        let when: Date
        let count: Int
    }

    // MARK: - round-trip

    func test_write_then_read_round_trips() {
        let url = dir.appendingPathComponent("sample.json")
        let value = Sample(name: "x", when: Date(timeIntervalSince1970: 1_000_000), count: 7)
        XCTAssertTrue(JSONFileStore.write(value, to: url))
        let read = JSONFileStore.read(Sample.self, from: url)
        XCTAssertEqual(read, value)
    }

    func test_read_missing_file_returns_nil() {
        let url = dir.appendingPathComponent("nope.json")
        XCTAssertNil(JSONFileStore.read(Sample.self, from: url))
    }

    func test_read_corrupt_file_returns_nil() throws {
        let url = dir.appendingPathComponent("bad.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(JSONFileStore.read(Sample.self, from: url))
    }

    // MARK: - size guard

    func test_oversize_file_returns_nil_without_decoding() throws {
        let url = dir.appendingPathComponent("big.json")
        // 1024 bytes of valid-ish padding; we set maxSize=100 to trip
        // the size guard.
        let big = String(repeating: " ", count: 1024)
        try big.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(JSONFileStore.read(Sample.self, from: url, maxSize: 100))
    }

    func test_default_max_size_does_not_block_large_valid_files() throws {
        let url = dir.appendingPathComponent("big-but-valid.json")
        let value = Sample(name: String(repeating: "a", count: 10_000),
                           when: Date(), count: 1)
        XCTAssertTrue(JSONFileStore.write(value, to: url))
        let read = JSONFileStore.read(Sample.self, from: url)
        XCTAssertNotNil(read)
    }

    // MARK: - parent dir creation + atomic write

    func test_write_creates_parent_directory() {
        let nested = dir.appendingPathComponent("a/b/c", isDirectory: true)
            .appendingPathComponent("v.json")
        let value = Sample(name: "y", when: Date(), count: 1)
        XCTAssertTrue(JSONFileStore.write(value, to: nested))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func test_write_overwrites_existing_file_atomically() throws {
        let url = dir.appendingPathComponent("v.json")
        XCTAssertTrue(JSONFileStore.write(
            Sample(name: "first", when: Date(), count: 1), to: url))
        XCTAssertTrue(JSONFileStore.write(
            Sample(name: "second", when: Date(), count: 2), to: url))
        let read = JSONFileStore.read(Sample.self, from: url)
        XCTAssertEqual(read?.name, "second")
        XCTAssertEqual(read?.count, 2)
    }

    // MARK: - shared encoder formatting

    func test_output_is_pretty_printed_and_sorted_keys() throws {
        let url = dir.appendingPathComponent("v.json")
        let v = Sample(name: "abc", when: Date(timeIntervalSince1970: 0), count: 5)
        XCTAssertTrue(JSONFileStore.write(v, to: url))
        let raw = try String(contentsOf: url, encoding: .utf8)
        // Sorted keys → "count" appears before "name" before "when".
        let c = raw.range(of: "\"count\"")!.lowerBound
        let n = raw.range(of: "\"name\"")!.lowerBound
        let w = raw.range(of: "\"when\"")!.lowerBound
        XCTAssertLessThan(c, n)
        XCTAssertLessThan(n, w)
        // Pretty-printed → has newlines.
        XCTAssertTrue(raw.contains("\n"))
    }

    func test_dates_round_trip_via_iso8601() throws {
        let url = dir.appendingPathComponent("v.json")
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let v = Sample(name: "x", when: d, count: 1)
        XCTAssertTrue(JSONFileStore.write(v, to: url))
        let raw = try String(contentsOf: url, encoding: .utf8)
        // Spot-check the ISO-8601 marker appears.
        XCTAssertTrue(raw.contains("T"))
        XCTAssertTrue(raw.contains("Z") || raw.contains("+"))
        let read = JSONFileStore.read(Sample.self, from: url)
        // Exact equality on the round-tripped date.
        XCTAssertEqual(read?.when, d)
    }
}
