import XCTest
@testable import ViewerCore

/// Round-trip coverage for the shared `XattrIO` helper (TSK-473 — extracted
/// from the byte-identical copies in EditorBuffer/HexEditBuffer). Uses real
/// POSIX xattr syscalls against a temp file, so it's fully host-validatable.
final class XattrIOTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xattrio-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: tmp.path, contents: Data("hello".utf8))
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func openFD() throws -> Int32 {
        let fd = open(tmp.path, O_RDONLY)
        try XCTSkipIf(fd < 0, "could not open temp file")
        return fd
    }

    func test_read_doesNotReportUnsetNames() throws {
        // NB: a freshly-created file is NOT guaranteed xattr-empty — modern
        // macOS auto-stamps com.apple.provenance — so assert the meaningful
        // invariant: read() succeeds and reports none of OUR names yet.
        let fd = try openFD(); defer { close(fd) }
        let names = Set(XattrIO.read(fd: fd).map(\.name))
        XCTAssertFalse(names.contains("com.example.alpha"))
        XCTAssertFalse(names.contains("com.example.beta"))
    }

    func test_applyThenRead_roundTripsNameAndValue() throws {
        let entries: [XattrIO.Entry] = [
            ("com.example.alpha", Data([0x01, 0x02, 0x03])),
            ("com.example.beta", Data("xyz".utf8)),
        ]
        XattrIO.apply(entries, toPath: tmp.path)

        let fd = try openFD(); defer { close(fd) }
        let read = XattrIO.read(fd: fd)
        let dict = Dictionary(uniqueKeysWithValues: read.map { ($0.name, $0.value) })
        XCTAssertEqual(dict["com.example.alpha"], Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(dict["com.example.beta"], Data("xyz".utf8))
    }

    func test_emptyValue_roundTrips() throws {
        XattrIO.apply([("com.example.empty", Data())], toPath: tmp.path)
        let fd = try openFD(); defer { close(fd) }
        let read = XattrIO.read(fd: fd)
        let v = read.first { $0.name == "com.example.empty" }?.value
        XCTAssertEqual(v, Data())
    }

    func test_readOne_missingAttr_isNil() throws {
        let fd = try openFD(); defer { close(fd) }
        XCTAssertNil(XattrIO.readOne(fd: fd, name: "com.example.does.not.exist"))
    }

    func test_largeValue_roundTrips() throws {
        // Exercises the two-call size-then-fill path with a non-trivial blob.
        let big = Data((0..<4096).map { UInt8($0 & 0xFF) })
        XattrIO.apply([("com.example.big", big)], toPath: tmp.path)
        let fd = try openFD(); defer { close(fd) }
        let v = XattrIO.read(fd: fd).first { $0.name == "com.example.big" }?.value
        XCTAssertEqual(v, big)
    }
}
