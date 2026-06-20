import XCTest
@testable import ViewerCore

/// File-load wrappers for the .ods / .docx readers (ZIP → content part → parse).
/// Builds real ZIP fixtures via /usr/bin/zip (host-safe, like ArchiveCatalogTests).
final class MultiFormatLoadTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mfload-\(UUID().uuidString)")
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

    /// ZIP `entry` (relative path) holding `content` into `name`.
    private func makeZip(_ name: String, entry: String, content: String) throws -> URL {
        let entryURL = dir.appendingPathComponent(entry)
        try FileManager.default.createDirectory(at: entryURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: entryURL)
        let zip = dir.appendingPathComponent(name)
        XCTAssertEqual(try shell("/usr/bin/zip", ["-r", zip.path, entry]), 0, "zip the fixture")
        return zip
    }

    func test_load_ods_extractsGrid() throws {
        let content = """
        <?xml version="1.0"?><office:document-content xmlns:office="urn:o" xmlns:table="urn:t" xmlns:text="urn:x">
        <office:body><office:spreadsheet><table:table>
        <table:table-row><table:table-cell><text:p>A</text:p></table:table-cell><table:table-cell><text:p>B</text:p></table:table-cell></table:table-row>
        </table:table></office:spreadsheet></office:body></office:document-content>
        """
        let url = try makeZip("book.ods", entry: "content.xml", content: content)
        XCTAssertEqual(try ODSContentParser.load(url), [["A", "B"]])
    }

    func test_load_docx_extractsParagraphs() throws {
        let content = """
        <?xml version="1.0"?><w:document xmlns:w="urn:w"><w:body>
        <w:p><w:r><w:t>Hello</w:t></w:r></w:p><w:p><w:r><w:t>World</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let url = try makeZip("doc.docx", entry: "word/document.xml", content: content)
        XCTAssertEqual(try DocxTextExtractor.load(url), ["Hello", "World"])
    }

    func test_load_missingContentPart_throws() throws {
        let url = try makeZip("empty.ods", entry: "other.xml", content: "<x/>")
        XCTAssertThrowsError(try ODSContentParser.load(url)) { error in
            XCTAssertEqual(error as? MultiFormatLoadError, .missingContentPart)
        }
    }
}
