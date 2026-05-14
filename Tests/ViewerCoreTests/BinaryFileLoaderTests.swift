import XCTest
@testable import ViewerCore

final class BinaryFileLoaderTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BinaryFileLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeBytes(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func test_loadsSmallBinaryFile() throws {
        let bytes: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 0x00, 0xFF]
        let url = try writeBytes("elf.bin", bytes)
        let bin = try BinaryFileLoader().load(url: url)
        XCTAssertEqual(Array(bin.data), bytes)
        XCTAssertEqual(bin.byteCount, 6)
        XCTAssertEqual(bin.totalByteCount, 6)
        XCTAssertFalse(bin.isTruncated)
    }

    func test_throwsOnMissingFile() {
        let url = tmpDir.appendingPathComponent("nope.bin")
        XCTAssertThrowsError(try BinaryFileLoader().load(url: url)) { error in
            XCTAssertEqual(error as? FileLoadError, .fileNotFound)
        }
    }

    func test_truncatesAtMaxBytes() throws {
        let bytes = Array(repeating: UInt8(0xAA), count: 10_000)
        let url = try writeBytes("big.bin", bytes)
        let loader = BinaryFileLoader(maxBytes: 1024)
        let bin = try loader.load(url: url)
        XCTAssertEqual(bin.byteCount, 1024)
        XCTAssertEqual(bin.totalByteCount, 10_000)
        XCTAssertTrue(bin.isTruncated)
    }

    // DocumentController seamlessly falls back to the hex viewer when the
    // text loader rejects a file as binary.
    func test_documentController_binaryFile_landsInBinaryState() throws {
        let bytes: [UInt8] = [0x00, 0x01, 0x02, 0x03]  // NUL byte → triggers binary path
        let url = try writeBytes("nul.bin", bytes)
        let state = DocumentController().open(url: url)
        guard case .binary(let bin) = state else {
            return XCTFail("expected .binary state, got \(state)")
        }
        XCTAssertEqual(Array(bin.data), bytes)
    }
}
