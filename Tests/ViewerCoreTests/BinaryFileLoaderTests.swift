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

    // MARK: - PARSE-05: regular-file guard + read-derived truncation

    func test_zeroByteFile_loadsEmptyNotTruncated() throws {
        let url = try writeBytes("empty.bin", [])
        let bin = try BinaryFileLoader().load(url: url)
        XCTAssertEqual(bin.byteCount, 0)
        XCTAssertEqual(bin.totalByteCount, 0)
        XCTAssertFalse(bin.isTruncated)
    }

    /// Truncation is now derived from the read (one byte past the cap), not
    /// a pre-stat. A file exactly at the cap is *not* truncated; one byte
    /// over is. Also pins the (total > byteCount) reconciliation: when not
    /// truncated, total must equal byteCount.
    func test_truncation_isDerivedFromRead_atCapBoundary() throws {
        let cap = 256
        let exactly = Array(repeating: UInt8(0xCC), count: cap)
        let exactURL = try writeBytes("exact.bin", exactly)
        let exactBin = try BinaryFileLoader(maxBytes: cap).load(url: exactURL)
        XCTAssertEqual(exactBin.byteCount, cap)
        XCTAssertFalse(exactBin.isTruncated,
                       "file exactly at the cap must not be flagged truncated")
        XCTAssertEqual(exactBin.totalByteCount, cap,
                       "non-truncated total must equal byteCount")

        let over = Array(repeating: UInt8(0xCC), count: cap + 1)
        let overURL = try writeBytes("over.bin", over)
        let overBin = try BinaryFileLoader(maxBytes: cap).load(url: overURL)
        XCTAssertEqual(overBin.byteCount, cap)
        XCTAssertTrue(overBin.isTruncated)
        XCTAssertEqual(overBin.totalByteCount, cap + 1)
        XCTAssertGreaterThan(overBin.totalByteCount, overBin.byteCount)
    }

    func test_symlinkToRegularFile_isResolvedAndLoaded() throws {
        let target = try writeBytes("real.bin", [0xDE, 0xAD, 0xBE, 0xEF])
        let link = tmpDir.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: target)
        let bin = try BinaryFileLoader().load(url: link)
        XCTAssertEqual(Array(bin.data), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertFalse(bin.isTruncated)
    }

    func test_symlinkToDirectory_isRejectedAsNotReadable() throws {
        let dir = tmpDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let link = tmpDir.appendingPathComponent("dirlink")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: dir)
        XCTAssertThrowsError(try BinaryFileLoader().load(url: link)) { error in
            XCTAssertEqual(error as? FileLoadError, .notReadable)
        }
    }

    func test_directory_isRejectedAsNotReadable() throws {
        let dir = tmpDir.appendingPathComponent("plaindir")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try BinaryFileLoader().load(url: dir)) { error in
            XCTAssertEqual(error as? FileLoadError, .notReadable)
        }
    }

    /// A fifo passes `fileExists` but is not a regular file; the loader must
    /// reject it before opening a handle (a blind `readData` on a fifo with
    /// no writer would block forever).
    func test_fifo_isRejectedAsNotReadable() throws {
        let fifo = tmpDir.appendingPathComponent("pipe.fifo")
        let rc = mkfifo(fifo.path, 0o600)
        try XCTSkipUnless(rc == 0, "mkfifo failed (errno \(errno)); skipping")
        XCTAssertThrowsError(try BinaryFileLoader().load(url: fifo)) { error in
            XCTAssertEqual(error as? FileLoadError, .notReadable)
        }
    }
}
