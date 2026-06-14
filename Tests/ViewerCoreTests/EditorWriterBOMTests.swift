import XCTest
@testable import ViewerCore

/// TSK-861: `EditorWriter.save` must re-emit the byte-order mark for
/// explicit-endianness UTF-16, or a re-saved SHORT UTF-16 file mis-decodes on
/// reopen (the read-side BOM-less UTF-16 fallback needs ≥32 bytes + NUL-parity,
/// which short files fail → CP1252/Latin-1 garble).
///
/// The round-trip tests are the regression guard with teeth: drop the BOM
/// re-emission in `withByteOrderMark` and they fail (decoded text + encoding
/// both drift). Pure ViewerCore — host-testable, no UI.
final class EditorWriterBOMTests: XCTestCase {

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-bom-\(UUID().uuidString)-\(name)")
    }

    /// Build an original on-disk UTF-16 file (BOM + endianness-specific body),
    /// exactly as a real UTF-16 editor would emit it.
    private func writeOriginalUTF16(_ text: String, littleEndian: Bool, to url: URL) throws {
        var data = Data(littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF])
        data.append(text.data(using: littleEndian ? .utf16LittleEndian : .utf16BigEndian)!)
        try data.write(to: url)
    }

    func testUTF16LE_shortFileRoundTripsAcrossSaveAndReopen() throws {
        let url = tempURL("le.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeOriginalUTF16("Hi", littleEndian: true, to: url)

        // Open: the loader detects UTF-16 LE from the BOM and strips it.
        let loaded = try TextFileLoader().load(url: url)
        XCTAssertEqual(loaded.encoding, .utf16LittleEndian)
        XCTAssertEqual(loaded.contents, "Hi")

        // Edit + save back with the file's recorded encoding — short on purpose
        // (8 UTF-16 bytes < the read side's 32-byte BOM-less heuristic).
        let edited = "Bye"
        _ = try EditorWriter.save(edited, to: url, encoding: loaded.encoding)

        // Reopen: must still be UTF-16 LE and decode to the edited text.
        let reopened = try TextFileLoader().load(url: url)
        XCTAssertEqual(reopened.encoding, .utf16LittleEndian, "lost UTF-16 LE on reopen")
        XCTAssertEqual(reopened.contents, edited, "short UTF-16 file mis-decoded on reopen")
    }

    func testUTF16BE_shortFileRoundTripsAcrossSaveAndReopen() throws {
        let url = tempURL("be.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeOriginalUTF16("Yo", littleEndian: false, to: url)

        let loaded = try TextFileLoader().load(url: url)
        XCTAssertEqual(loaded.encoding, .utf16BigEndian)
        XCTAssertEqual(loaded.contents, "Yo")

        _ = try EditorWriter.save("OK!", to: url, encoding: loaded.encoding)

        let reopened = try TextFileLoader().load(url: url)
        XCTAssertEqual(reopened.encoding, .utf16BigEndian, "lost UTF-16 BE on reopen")
        XCTAssertEqual(reopened.contents, "OK!", "short UTF-16 BE file mis-decoded on reopen")
    }

    func testSavedUTF16LEFileStartsWithBOMBytes() throws {
        let url = tempURL("bom-bytes.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try EditorWriter.save("x", to: url, encoding: .utf16LittleEndian)
        let raw = try Data(contentsOf: url)
        XCTAssertEqual(Array(raw.prefix(2)), [0xFF, 0xFE], "UTF-16 LE save must lead with the LE BOM")
    }

    // MARK: - withByteOrderMark unit behaviour

    func testWithByteOrderMarkPrependsForExplicitEndianUTF16() {
        let body = Data([0x41, 0x00]) // "A" in UTF-16 LE, BOM-less
        XCTAssertEqual(
            Array(EditorWriter.withByteOrderMark(body, encoding: .utf16LittleEndian)),
            [0xFF, 0xFE, 0x41, 0x00]
        )
        let beBody = Data([0x00, 0x41]) // "A" in UTF-16 BE
        XCTAssertEqual(
            Array(EditorWriter.withByteOrderMark(beBody, encoding: .utf16BigEndian)),
            [0xFE, 0xFF, 0x00, 0x41]
        )
    }

    func testWithByteOrderMarkLeavesOtherEncodingsUntouched() {
        let body = Data([0x68, 0x69]) // "hi"
        for enc: String.Encoding in [.utf8, .windowsCP1252, .isoLatin1] {
            XCTAssertEqual(
                EditorWriter.withByteOrderMark(body, encoding: enc), body,
                "\(enc) must not gain a BOM"
            )
        }
    }

    func testWithByteOrderMarkDoesNotDoubleBOMForBOMfulUTF16() {
        // `.utf16` already carries a BOM (added by data(using:)); the helper
        // must NOT prepend a second one (that branch falls to default).
        let bomful = "hi".data(using: .utf16)!
        XCTAssertEqual(EditorWriter.withByteOrderMark(bomful, encoding: .utf16), bomful)
    }

    func testUTF8SaveRemainsBOMless() throws {
        // Guard: the fix must not leak a BOM into the common UTF-8 path.
        let url = tempURL("utf8.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try EditorWriter.save("hello", to: url, encoding: .utf8)
        let raw = try Data(contentsOf: url)
        XCTAssertEqual(Array(raw), Array("hello".utf8), "UTF-8 save must not gain a BOM")
    }
}
