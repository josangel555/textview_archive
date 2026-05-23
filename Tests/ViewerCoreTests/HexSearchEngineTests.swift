import XCTest
@testable import ViewerCore

/// Pure-logic coverage for `HexSearchEngine` and `HexLayout`.
/// These tests intentionally do NOT touch any AppKit / SwiftUI
/// surface — they run on the host without spinning up an app.
final class HexSearchEngineTests: XCTestCase {

    // MARK: Hex query parsing

    func testParseHex_spaceSeparated() {
        XCTAssertEqual(
            HexSearchEngine.parse("de ad be ef", mode: .hex),
            [0xDE, 0xAD, 0xBE, 0xEF]
        )
    }

    func testParseHex_singleToken() {
        XCTAssertEqual(
            HexSearchEngine.parse("DEADBEEF", mode: .hex),
            [0xDE, 0xAD, 0xBE, 0xEF]
        )
    }

    func testParseHex_mixedCaseAndExtraWhitespace() {
        XCTAssertEqual(
            HexSearchEngine.parse("  De  adBE\tef  ", mode: .hex),
            [0xDE, 0xAD, 0xBE, 0xEF]
        )
    }

    func testParseHex_empty() {
        XCTAssertEqual(HexSearchEngine.parse("", mode: .hex), [])
        XCTAssertEqual(HexSearchEngine.parse("   ", mode: .hex), [])
    }

    func testParseHex_rejectsOddNibbleToken() {
        XCTAssertNil(HexSearchEngine.parse("de a", mode: .hex))
        XCTAssertNil(HexSearchEngine.parse("abc", mode: .hex))
    }

    func testParseHex_rejectsNonHex() {
        XCTAssertNil(HexSearchEngine.parse("zz", mode: .hex))
        XCTAssertNil(HexSearchEngine.parse("de gg", mode: .hex))
    }

    // MARK: ASCII query parsing

    func testParseAscii_basic() {
        XCTAssertEqual(
            HexSearchEngine.parse("hello", mode: .ascii),
            Array("hello".utf8)
        )
    }

    func testParseAscii_empty() {
        XCTAssertEqual(HexSearchEngine.parse("", mode: .ascii), [])
    }

    func testParseAscii_utf8MultiByte() {
        // "é" is two bytes in UTF-8; we expose UTF-8 bytes verbatim.
        XCTAssertEqual(
            HexSearchEngine.parse("é", mode: .ascii),
            [0xC3, 0xA9]
        )
    }

    // MARK: find()

    func testFind_emptyPattern() {
        XCTAssertEqual(HexSearchEngine.find(pattern: [], in: Data([0x01, 0x02])), [])
    }

    func testFind_patternLargerThanData() {
        XCTAssertEqual(
            HexSearchEngine.find(pattern: [0x01, 0x02, 0x03], in: Data([0x01])),
            []
        )
    }

    func testFind_noMatches() {
        XCTAssertEqual(
            HexSearchEngine.find(pattern: [0xFF], in: Data([0x01, 0x02, 0x03])),
            []
        )
    }

    func testFind_multipleNonOverlapping() {
        let data = Data([0xDE, 0xAD, 0x00, 0xDE, 0xAD, 0xFF, 0xDE, 0xAD])
        XCTAssertEqual(
            HexSearchEngine.find(pattern: [0xDE, 0xAD], in: data),
            [0, 3, 6]
        )
    }

    /// `AA AA AA` searched for `AA AA` -> `[0]` per non-overlapping rule
    /// (matches Sublime / VSCode).
    func testFind_overlappingPatternIsNonOverlapping() {
        let data = Data([0xAA, 0xAA, 0xAA])
        XCTAssertEqual(
            HexSearchEngine.find(pattern: [0xAA, 0xAA], in: data),
            [0]
        )
    }

    func testFind_matchAtEnd() {
        let data = Data([0x00, 0x01, 0x02, 0xDE, 0xAD])
        XCTAssertEqual(
            HexSearchEngine.find(pattern: [0xDE, 0xAD], in: data),
            [3]
        )
    }

    func testFind_singleByteRepeated() {
        let data = Data([0xFF, 0x01, 0xFF, 0xFF, 0x00, 0xFF])
        XCTAssertEqual(
            HexSearchEngine.find(pattern: [0xFF], in: data),
            [0, 2, 3, 5]
        )
    }

    // MARK: search() convenience + ASCII roundtrip

    func testSearchAscii_findsInBinary() {
        let bytes = Array("XX hello YY".utf8)
        let offsets = HexSearchEngine.search("hello",
                                             mode: .ascii,
                                             in: Data(bytes))
        XCTAssertEqual(offsets, [3])
    }

    func testSearch_invalidHexReturnsEmpty() {
        XCTAssertEqual(
            HexSearchEngine.search("zz", mode: .hex, in: Data([0x00])),
            []
        )
    }

    // MARK: offsets(ofByte:)

    func testOffsetsOfByte() {
        let data = Data([0x00, 0xFF, 0x01, 0xFF, 0xFF])
        XCTAssertEqual(HexSearchEngine.offsets(ofByte: 0xFF, in: data),
                       [1, 3, 4])
        XCTAssertEqual(HexSearchEngine.offsets(ofByte: 0xAA, in: data), [])
    }
}
