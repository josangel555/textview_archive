import XCTest
@testable import ViewerCore

/// Unified document-text extraction dispatch. Host-tested with real fixtures.
final class MultiFormatReaderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mfreader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func shell(_ launch: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    private func makeZip(_ name: String, entry: String, content: String) throws -> URL {
        let entryURL = dir.appendingPathComponent(entry)
        try FileManager.default.createDirectory(at: entryURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: entryURL)
        let zip = dir.appendingPathComponent(name)
        XCTAssertEqual(try shell("/usr/bin/zip", ["-r", zip.path, entry]), 0)
        return zip
    }

    func test_isSupported() {
        XCTAssertTrue(MultiFormatReader.isSupported(URL(fileURLWithPath: "/x/a.docx")))
        XCTAssertTrue(MultiFormatReader.isSupported(URL(fileURLWithPath: "/x/a.RTF")))
        XCTAssertFalse(MultiFormatReader.isSupported(URL(fileURLWithPath: "/x/a.png")))
    }

    func test_extract_docx() throws {
        let url = try makeZip("d.docx", entry: "word/document.xml", content:
            #"<?xml version="1.0"?><w:document xmlns:w="urn:w"><w:body><w:p><w:r><w:t>Hi</w:t></w:r></w:p><w:p><w:r><w:t>There</w:t></w:r></w:p></w:body></w:document>"#)
        XCTAssertEqual(MultiFormatReader.extractedText(for: url), "Hi\nThere")
    }

    func test_extract_ods() throws {
        let url = try makeZip("s.ods", entry: "content.xml", content:
            #"<?xml version="1.0"?><office:document-content xmlns:office="urn:o" xmlns:table="urn:t" xmlns:text="urn:x"><office:body><office:spreadsheet><table:table><table:table-row><table:table-cell><text:p>A</text:p></table:table-cell><table:table-cell><text:p>B</text:p></table:table-cell></table:table-row></table:table></office:spreadsheet></office:body></office:document-content>"#)
        XCTAssertEqual(MultiFormatReader.extractedText(for: url), "A\tB")
    }

    func test_extract_rtf() throws {
        let url = dir.appendingPathComponent("note.rtf")
        try #"{\rtf1\ansi Hello \b world\b0}"#.data(using: .utf8)!.write(to: url)
        XCTAssertEqual(MultiFormatReader.extractedText(for: url), "Hello world")
    }

    func test_unsupportedExtension_returnsNil() {
        XCTAssertNil(MultiFormatReader.extractedText(for: URL(fileURLWithPath: "/x/a.png")))
    }
}
