import XCTest
@testable import ViewerCore

/// Host-safe (T1m) coverage for `HexCaretMap` — the pure bidirectional
/// caret ⇄ byte+nibble mapping the editable hex view (#234) relies on.
/// No AppKit; the math is pinned directly against `HexLayout`'s row layout
/// so a future layout change that breaks addressing trips here first.
///
/// Reference layout for width=16 (from `HexLayout`):
///   `OOOOOOOO␣␣HH␣HH␣…␣HH␣␣AAAA…\n`
///   offset col = chars 0..7, two spaces, hex col starts at char 10,
///   each byte is 3 chars (`HH␣`), ascii col starts after the gutter.
final class HexCaretMapTests: XCTestCase {

    private let w = 16

    // MARK: - char → hit (hex column)

    func test_hit_firstByteHighNibble_isCol0Nibble0() {
        // Char 10 is the high nibble of byte 0.
        let hit = HexCaretMap.hit(charIndex: 10, width: w,
                                  byteCount: 32, headerCharCount: 0)
        XCTAssertEqual(hit, .hex(byte: 0, nibble: 0))
    }

    func test_hit_firstByteLowNibble_isCol0Nibble1() {
        let hit = HexCaretMap.hit(charIndex: 11, width: w,
                                  byteCount: 32, headerCharCount: 0)
        XCTAssertEqual(hit, .hex(byte: 0, nibble: 1))
    }

    func test_hit_separatorAfterByte_returnsNil() {
        // Char 12 is the space separator after byte 0 — not editable.
        XCTAssertNil(HexCaretMap.hit(charIndex: 12, width: w,
                                     byteCount: 32, headerCharCount: 0))
    }

    func test_hit_secondByte_isCol1() {
        // Byte 1 high nibble = 10 + 3 = 13.
        XCTAssertEqual(
            HexCaretMap.hit(charIndex: 13, width: w,
                            byteCount: 32, headerCharCount: 0),
            .hex(byte: 1, nibble: 0))
        XCTAssertEqual(
            HexCaretMap.hit(charIndex: 14, width: w,
                            byteCount: 32, headerCharCount: 0),
            .hex(byte: 1, nibble: 1))
    }

    func test_hit_offsetColumn_returnsNil() {
        for i in 0..<10 {  // 8 offset chars + 2 gutter spaces
            XCTAssertNil(HexCaretMap.hit(charIndex: i, width: w,
                                         byteCount: 32, headerCharCount: 0),
                         "offset/gutter char \(i) must not be editable")
        }
    }

    // MARK: - char → hit (ascii column)

    func test_hit_asciiColumn_mapsToByte() {
        let asciiStart = HexLayout.asciiCharOffset(inRowColumn: 0, width: w)
        XCTAssertEqual(
            HexCaretMap.hit(charIndex: asciiStart, width: w,
                            byteCount: 32, headerCharCount: 0),
            .ascii(byte: 0))
        XCTAssertEqual(
            HexCaretMap.hit(charIndex: asciiStart + 5, width: w,
                            byteCount: 32, headerCharCount: 0),
            .ascii(byte: 5))
    }

    // MARK: - bounds

    func test_hit_pastByteCount_returnsNil() {
        // Row 0 col 5 hex, but only 3 bytes present.
        let hi = HexCaretMap.hexCharIndex(byte: 5, nibble: 0, width: w,
                                          headerCharCount: 0)
        XCTAssertNil(HexCaretMap.hit(charIndex: hi, width: w,
                                     byteCount: 3, headerCharCount: 0))
    }

    func test_hit_secondRow_addsRowLength() {
        let rowLen = HexLayout.renderedRowLength(width: w)
        // Byte 16 = row 1, col 0 high nibble.
        XCTAssertEqual(
            HexCaretMap.hit(charIndex: rowLen + 10, width: w,
                            byteCount: 64, headerCharCount: 0),
            .hex(byte: 16, nibble: 0))
    }

    func test_hit_withHeader_shiftsByHeaderCount() {
        let header = 24
        XCTAssertEqual(
            HexCaretMap.hit(charIndex: header + 10, width: w,
                            byteCount: 32, headerCharCount: header),
            .hex(byte: 0, nibble: 0))
        // Positions inside the header are not editable.
        XCTAssertNil(HexCaretMap.hit(charIndex: header - 1, width: w,
                                     byteCount: 32, headerCharCount: header))
    }

    // MARK: - inverse (byte → char), round-trip

    func test_roundTrip_hex_everyByteAndNibble() {
        let byteCount = 40
        for byte in 0..<byteCount {
            for nibble in 0...1 {
                let idx = HexCaretMap.hexCharIndex(byte: byte, nibble: nibble,
                                                   width: w, headerCharCount: 0)
                XCTAssertEqual(
                    HexCaretMap.hit(charIndex: idx, width: w,
                                    byteCount: byteCount, headerCharCount: 0),
                    .hex(byte: byte, nibble: nibble),
                    "hex round-trip failed for byte \(byte) nibble \(nibble)")
            }
        }
    }

    func test_roundTrip_ascii_everyByte() {
        let byteCount = 40
        for byte in 0..<byteCount {
            let idx = HexCaretMap.asciiCharIndex(byte: byte, width: w,
                                                 headerCharCount: 0)
            XCTAssertEqual(
                HexCaretMap.hit(charIndex: idx, width: w,
                                byteCount: byteCount, headerCharCount: 0),
                .ascii(byte: byte))
        }
    }

    func test_roundTrip_widths_32_and_64() {
        for width in [32, 64] {
            let byteCount = width * 3
            for byte in stride(from: 0, to: byteCount, by: 7) {
                let idx = HexCaretMap.hexCharIndex(byte: byte, nibble: 1,
                                                   width: width, headerCharCount: 0)
                XCTAssertEqual(
                    HexCaretMap.hit(charIndex: idx, width: width,
                                    byteCount: byteCount, headerCharCount: 0),
                    .hex(byte: byte, nibble: 1),
                    "width \(width) byte \(byte)")
            }
        }
    }

    // MARK: - nibble / byte advance

    func test_advanceHex_lowToNextHigh() {
        XCTAssertEqual(
            HexCaretMap.advanceHex(byte: 0, nibble: 1, by: 1, byteCount: 4).map { [$0.byte, $0.nibble] },
            [1, 0])
    }

    func test_advanceHex_highToLow() {
        XCTAssertEqual(
            HexCaretMap.advanceHex(byte: 2, nibble: 0, by: 1, byteCount: 4).map { [$0.byte, $0.nibble] },
            [2, 1])
    }

    func test_advanceHex_clampsAtEnd_doesNotWrap() {
        // Last nibble of last byte; +1 clamps in place.
        XCTAssertEqual(
            HexCaretMap.advanceHex(byte: 3, nibble: 1, by: 1, byteCount: 4).map { [$0.byte, $0.nibble] },
            [3, 1])
    }

    func test_advanceHex_clampsAtStart() {
        XCTAssertEqual(
            HexCaretMap.advanceHex(byte: 0, nibble: 0, by: -1, byteCount: 4).map { [$0.byte, $0.nibble] },
            [0, 0])
    }

    func test_advanceHex_byTwo_movesWholeByte() {
        XCTAssertEqual(
            HexCaretMap.advanceHex(byte: 1, nibble: 0, by: 2, byteCount: 8).map { [$0.byte, $0.nibble] },
            [2, 0])
    }

    func test_advanceHex_emptyBuffer_nil() {
        XCTAssertNil(HexCaretMap.advanceHex(byte: 0, nibble: 0, by: 1, byteCount: 0))
    }

    func test_advanceAscii_clamps() {
        XCTAssertEqual(HexCaretMap.advanceAscii(byte: 0, by: -1, byteCount: 4), 0)
        XCTAssertEqual(HexCaretMap.advanceAscii(byte: 3, by: 1, byteCount: 4), 3)
        XCTAssertEqual(HexCaretMap.advanceAscii(byte: 1, by: 1, byteCount: 4), 2)
        XCTAssertNil(HexCaretMap.advanceAscii(byte: 0, by: 1, byteCount: 0))
    }

    // MARK: - cross-check against the read-only viewer's byte mapping

    func test_hit_byteMatches_layoutColumnRow() {
        // Independent of the read-only `charIndexToByteOffset`, confirm
        // the byte a hex hit reports equals row*width+col.
        let rowLen = HexLayout.renderedRowLength(width: w)
        // Row 2, col 7, low nibble.
        let charIdx = 2 * rowLen + HexLayout.hexCharOffset(inRowColumn: 7) + 1
        XCTAssertEqual(
            HexCaretMap.hit(charIndex: charIdx, width: w,
                            byteCount: 64, headerCharCount: 0),
            .hex(byte: 2 * w + 7, nibble: 1))
    }
}
