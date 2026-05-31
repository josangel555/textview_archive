import XCTest
@testable import ViewerCore

final class TextFileLoaderTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownViewerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFile(_ name: String, _ contents: String, encoding: String.Encoding = .utf8) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func writeBytes(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func test_loadsUTF8File() throws {
        let url = try writeFile("hello.txt", "hello, world\n")
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.contents, "hello, world\n")
        XCTAssertEqual(file.encoding, .utf8)
        XCTAssertEqual(file.byteCount, 13)
        XCTAssertEqual(file.url, url)
    }

    func test_loadsEmptyFile() throws {
        let url = try writeFile("empty.txt", "")
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.contents, "")
        XCTAssertEqual(file.byteCount, 0)
    }

    func test_throwsOnMissingFile() {
        let url = tmpDir.appendingPathComponent("nope.txt")
        XCTAssertThrowsError(try TextFileLoader().load(url: url)) { error in
            XCTAssertEqual(error as? FileLoadError, .fileNotFound)
        }
    }

    func test_fallsBackToWindowsCP1252() throws {
        // 0xC3 0x28 is invalid UTF-8. Both bytes are defined in
        // Windows-1252, so I18N-01 now reports CP1252 (the superset of
        // Latin-1 that decodes the smart-quote / em-dash bytes Windows
        // text actually uses). 0xC3 maps to Ã in both, so the decoded
        // text is unchanged — only the surfaced encoding is more accurate.
        let url = try writeBytes("cp1252.txt", [0xC3, 0x28])
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.encoding, .windowsCP1252)
        XCTAssertEqual(file.contents, "Ã(")
    }

    func test_fallsBackToLatin1_forCP1252UndefinedByte() throws {
        // 0x81 is undefined in CP1252, so String(.windowsCP1252) fails
        // and the total Latin-1 fallback catches it (I18N-01 keeps the
        // Latin-1 backstop).
        let url = try writeBytes("latin.txt", [0x41, 0x81, 0x42])
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.encoding, .isoLatin1)
    }

    func test_rejectsOversizedFile() throws {
        let url = try writeFile("big.txt", String(repeating: "x", count: 100))
        let loader = TextFileLoader(maxBytes: 10)
        XCTAssertThrowsError(try loader.load(url: url)) { error in
            guard case .tooLarge(let bytes) = error as? FileLoadError else {
                return XCTFail("expected .tooLarge, got \(error)")
            }
            XCTAssertEqual(bytes, 100)
        }
    }

    // MARK: B4 — UTF-16 BOM detection

    func test_loadsUTF16LE_withBOM() throws {
        let bom: [UInt8] = [0xFF, 0xFE]
        // "hi" in UTF-16-LE: h = 0x68, 0x00, i = 0x69, 0x00
        let body: [UInt8] = [0x68, 0x00, 0x69, 0x00]
        let url = try writeBytes("u16le.txt", bom + body)
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.contents, "hi")
        XCTAssertEqual(file.encoding, .utf16LittleEndian)
    }

    func test_loadsUTF16BE_withBOM() throws {
        let bom: [UInt8] = [0xFE, 0xFF]
        let body: [UInt8] = [0x00, 0x68, 0x00, 0x69]
        let url = try writeBytes("u16be.txt", bom + body)
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.contents, "hi")
        XCTAssertEqual(file.encoding, .utf16BigEndian)
    }

    func test_loadsUTF8_withBOM() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let body = Array("héllo".utf8)
        let url = try writeBytes("u8bom.txt", bom + body)
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.contents, "héllo")
        XCTAssertEqual(file.encoding, .utf8)
    }

    // MARK: B5 — binary blob guard

    func test_binaryFile_isRejected() throws {
        let bytes: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01, 0x00, 0x00] // ELF-like
        let url = try writeBytes("binary.bin", bytes)
        XCTAssertThrowsError(try TextFileLoader().load(url: url)) { error in
            XCTAssertEqual(error as? FileLoadError, .binaryFile)
        }
    }

    func test_textFileWithoutNUL_loadsCleanly() throws {
        let url = try writeFile("clean.txt", "no NULs here, just text\n")
        XCTAssertNoThrow(try TextFileLoader().load(url: url))
    }

    func test_binaryGuard_onlySamplesFirst8KB() throws {
        // 8 KB of clean text + a NUL way past the sample boundary -> still accepted
        // (we trade some false negatives for fast, allocation-free sniffing).
        let prefix = String(repeating: "a", count: 9000)
        let url = try writeBytes("late-nul.txt", Array(prefix.utf8) + [0x00])
        XCTAssertNoThrow(try TextFileLoader().load(url: url))
    }
}
