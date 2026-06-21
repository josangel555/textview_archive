import XCTest
import ViewerKit
@testable import ViewerCore

/// TSK-1036 (RTF slice) — teeth for routing .rtf into the viewer as a READ-ONLY
/// extracted-text view. The category sends it to the source view; the loader
/// substitutes RtfTextExtractor output (not raw `{\rtf1...}`) and flags it
/// read-only (TSK-1204) so a save can't overwrite the source.
final class RtfViewerRoutingTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RtfRoute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_rtf_categorizedAsPlainText() {
        XCTAssertEqual(
            FileTypeDetector.category(for: tmp.appendingPathComponent("doc.rtf")),
            .plainText, "an .rtf routes to the source/plainText view")
    }

    func test_rtf_load_extractsPlainText_andIsReadOnly() throws {
        let url = tmp.appendingPathComponent("doc.rtf")
        try "{\\rtf1\\ansi\\deff0 Hello \\b World\\b0 !}".write(
            to: url, atomically: true, encoding: .utf8)

        let tf = try TextFileLoader(maxBytes: 10_000_000).load(url: url)

        XCTAssertTrue(tf.isExtractedReadOnly,
                      "an .rtf loads as a READ-ONLY extracted view (no save-corruption)")
        XCTAssertTrue(tf.contents.contains("Hello"), "extracted body text shows")
        XCTAssertTrue(tf.contents.contains("World"))
        XCTAssertFalse(tf.contents.contains("\\rtf1"),
                       "raw RTF control words must NOT appear in the view")
        XCTAssertFalse(tf.contents.contains("deff0"))
    }

    func test_docx_categorizedAsPlainText() {
        XCTAssertEqual(
            FileTypeDetector.category(for: tmp.appendingPathComponent("doc.docx")),
            .plainText, "a .docx routes to the source/plainText view")
    }

    func test_docx_load_extractsParagraphs_andIsReadOnly() throws {
        let documentXML = """
        <?xml version="1.0"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p>
        <w:p><w:r><w:t>World</w:t></w:r></w:p></w:body></w:document>
        """
        let url = try makeDocx(documentXML)
        let tf = try TextFileLoader(maxBytes: 10_000_000).load(url: url)

        XCTAssertTrue(tf.isExtractedReadOnly,
                      "a .docx loads as a READ-ONLY extracted view (no save-corruption)")
        XCTAssertTrue(tf.contents.contains("Hello"), "extracted paragraph text shows")
        XCTAssertTrue(tf.contents.contains("World"))
    }

    /// Build a minimal `.docx` (ZIP with `word/document.xml`) via /usr/bin/zip —
    /// host-safe, the same approach as `MultiFormatLoadTests`.
    private func makeDocx(_ documentXML: String) throws -> URL {
        let stage = tmp.appendingPathComponent("stage-\(UUID().uuidString)")
        let wordDir = stage.appendingPathComponent("word")
        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try documentXML.data(using: .utf8)!.write(to: wordDir.appendingPathComponent("document.xml"))
        let zipURL = tmp.appendingPathComponent("doc.docx")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = stage
        p.arguments = ["-r", zipURL.path, "word"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "zip the .docx fixture")
        return zipURL
    }

    func test_tabSeparated_joinsRowsAndCells() {
        XCTAssertEqual(TextFileLoader.tabSeparated([["a", "b"], ["c", "d"]]), "a\tb\nc\td")
    }

    func test_ods_categorizedAsPlainText() {
        XCTAssertEqual(
            FileTypeDetector.category(for: tmp.appendingPathComponent("book.ods")),
            .plainText, "an .ods routes to the source/plainText view")
    }

    func test_ods_load_extractsGridAsTSV_andIsReadOnly() throws {
        let content = """
        <?xml version="1.0"?>
        <office:document-content \
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
        <office:body><office:spreadsheet><table:table>
        <table:table-row><table:table-cell><text:p>Name</text:p></table:table-cell>
        <table:table-cell><text:p>Age</text:p></table:table-cell></table:table-row>
        <table:table-row><table:table-cell><text:p>Jos</text:p></table:table-cell>
        <table:table-cell><text:p>42</text:p></table:table-cell></table:table-row>
        </table:table></office:spreadsheet></office:body></office:document-content>
        """
        let url = try makeOds(content)
        let tf = try TextFileLoader(maxBytes: 10_000_000).load(url: url)

        XCTAssertTrue(tf.isExtractedReadOnly,
                      "an .ods loads as a READ-ONLY extracted view")
        XCTAssertTrue(tf.contents.contains("Name"), "cell text shows")
        XCTAssertTrue(tf.contents.contains("Jos"))
        XCTAssertTrue(tf.contents.contains("\t"), "cells are TAB-separated")
    }

    private func makeOds(_ contentXML: String) throws -> URL {
        let stage = tmp.appendingPathComponent("ods-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try contentXML.data(using: .utf8)!.write(to: stage.appendingPathComponent("content.xml"))
        let zipURL = tmp.appendingPathComponent("book.ods")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = stage
        p.arguments = ["-r", zipURL.path, "content.xml"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "zip the .ods fixture")
        return zipURL
    }
}
