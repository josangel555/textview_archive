import XCTest
@testable import ViewerCore

/// TSK-1144 — teeth for the .docx exporter. Store-ZIP entries are uncompressed,
/// so the embedded XML is byte-recoverable: we assert on the ZIP framing + the
/// WordprocessingML content directly.
final class DocxExporterTests: XCTestCase {

    private func ascii(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func test_export_isAStoreZipWithTheOOXMLParts() {
        let data = DocxExporter.export(RichTextParser.parse("Hello"))
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04], "ZIP local-header magic")
        // End-of-central-directory present.
        XCTAssertTrue(containsSubsequence(bytes, [0x50, 0x4b, 0x05, 0x06]), "EOCD present")
        let s = ascii(data)
        XCTAssertTrue(s.contains("[Content_Types].xml"))
        XCTAssertTrue(s.contains("word/document.xml"))
    }

    func test_documentXML_mapsHeadingsParagraphsAndEmphasis() {
        let xml = DocxExporter.documentXML(RichTextParser.parse("# Title\n\nHello **bold** and *it*"))
        XCTAssertTrue(xml.contains("<w:pStyle w:val=\"Heading1\"/>"), "heading style")
        XCTAssertTrue(xml.contains("Title"))
        XCTAssertTrue(xml.contains("<w:b/>"), "bold run property")
        XCTAssertTrue(xml.contains("<w:i/>"), "italic run property")
        XCTAssertTrue(xml.contains("bold"))
    }

    func test_documentXML_escapesAndOrdersList() {
        let xml = DocxExporter.documentXML(RichTextParser.parse("1. a < b\n2. c"))
        XCTAssertTrue(xml.contains("a &lt; b"), "XML-escaped text")
        XCTAssertTrue(xml.contains("1.\u{00A0}") && xml.contains("2.\u{00A0}"), "ordered prefixes")
    }

    func test_crc32_knownVector() {
        // CRC32("123456789") == 0xCBF43926 (standard IEEE check value).
        XCTAssertEqual(StoreZip.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    private func containsSubsequence(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= hay.count else { return false }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<i + needle.count]) == needle {
            return true
        }
        return false
    }
}
