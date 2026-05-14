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

    func test_fallsBackToLatin1() throws {
        // 0xC3 0x28 is invalid UTF-8 but valid Latin-1.
        let url = try writeBytes("latin.txt", [0xC3, 0x28])
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
}
