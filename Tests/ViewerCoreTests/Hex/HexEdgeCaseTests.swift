import XCTest
@testable import ViewerCore

/// Edge-case coverage for `HexSearchEngine` / `HexLayout` that the
/// base `HexSearchEngineTests` / `HexLayoutTests` don't exercise.
///
/// Adds:
///   - Empty Data + single-byte data search
///   - Hex pattern that spans row boundaries (16-byte + 32-byte rows)
///   - ASCII patterns containing control / unprintable bytes
///   - `offsets(ofByte:)` — empty input + every-byte-matches case
///   - `clampWidth` round-trip from arbitrary garbage
final class HexEdgeCaseTests: XCTestCase {

    // MARK: - Search against empty / tiny inputs

    func test_search_emptyData_returnsNoMatches() {
        XCTAssertEqual(HexSearchEngine.search("DE AD", mode: .hex, in: Data()), [])
        XCTAssertEqual(HexSearchEngine.search("hi", mode: .ascii, in: Data()), [])
    }

    func test_search_patternLongerThanData_returnsEmpty() {
        let data = Data([0x01, 0x02])
        XCTAssertEqual(
            HexSearchEngine.search("01 02 03 04", mode: .hex, in: data), [])
    }

    func test_search_singleByteData_matchesExactValue() {
        let data = Data([0x42])
        XCTAssertEqual(
            HexSearchEngine.search("42", mode: .hex, in: data), [0])
        XCTAssertEqual(
            HexSearchEngine.search("43", mode: .hex, in: data), [])
    }

    func test_search_singleByteData_asciiMode() {
        let data = Data("X".utf8)
        XCTAssertEqual(HexSearchEngine.search("X", mode: .ascii, in: data), [0])
        XCTAssertEqual(HexSearchEngine.search("Y", mode: .ascii, in: data), [])
    }

    // MARK: - Cross-row spans

    /// A 6-byte hex pattern starting at offset 14 spans the end of row
    /// 0 (cols 14, 15) into the start of row 1 (cols 0..3) at width=16.
    /// Search is byte-oriented so it must succeed regardless of the
    /// virtual row grid.
    func test_search_patternSpansRowBoundary_16wide() {
        // Build 32 bytes; rows are width-16. Place the pattern at
        // offset 14 so it crosses into row 1.
        var data = Data((0..<32).map { UInt8($0) })
        // Pattern: bytes 14..19 = 0x0E 0x0F 0x10 0x11 0x12 0x13
        let pat = Array(data[14..<20])
        _ = data  // suppress unused-mutation lint
        let hits = HexSearchEngine.find(pattern: pat, in: data)
        XCTAssertEqual(hits, [14])
    }

    func test_search_patternSpansRowBoundary_32wide() {
        // Same idea, but row width = 32 — pattern at offset 30 crosses
        // into row 1 at width-32.
        let data = Data((0..<64).map { UInt8($0) })
        let pat = Array(data[30..<36])
        let hits = HexSearchEngine.find(pattern: pat, in: data)
        XCTAssertEqual(hits, [30])
    }

    // MARK: - ASCII control / non-printable bytes

    func test_ascii_parsesNewlineAndTab() {
        // \n = 0x0A, \t = 0x09 — both legal UTF-8.
        XCTAssertEqual(
            HexSearchEngine.parse("a\nb", mode: .ascii),
            [0x61, 0x0A, 0x62])
        XCTAssertEqual(
            HexSearchEngine.parse("a\tb", mode: .ascii),
            [0x61, 0x09, 0x62])
    }

    func test_ascii_findsControlSequence() {
        let data = Data([0x00, 0x68, 0x69, 0x0A, 0x77, 0x6F, 0x72, 0x6C, 0x64])
        // Search for the literal newline + 'w'.
        XCTAssertEqual(
            HexSearchEngine.search("\nw", mode: .ascii, in: data),
            [3])
    }

    func test_hex_parsesNullByte() {
        XCTAssertEqual(HexSearchEngine.parse("00", mode: .hex), [0x00])
        let data = Data([0x01, 0x00, 0x02])
        XCTAssertEqual(
            HexSearchEngine.search("00", mode: .hex, in: data), [1])
    }

    func test_hex_parsesFFByte() {
        XCTAssertEqual(HexSearchEngine.parse("FF ff", mode: .hex), [0xFF, 0xFF])
        let data = Data([0xFF, 0xFF, 0xFE])
        XCTAssertEqual(
            HexSearchEngine.search("FF FF", mode: .hex, in: data), [0])
    }

    // MARK: - offsets(ofByte:)

    func test_offsetsOfByte_emptyData() {
        XCTAssertEqual(HexSearchEngine.offsets(ofByte: 0x00, in: Data()), [])
    }

    func test_offsetsOfByte_allMatching() {
        let data = Data(repeating: 0x42, count: 10)
        XCTAssertEqual(
            HexSearchEngine.offsets(ofByte: 0x42, in: data),
            Array(0..<10))
    }

    func test_offsetsOfByte_noMatches() {
        let data = Data([0x01, 0x02, 0x03])
        XCTAssertEqual(HexSearchEngine.offsets(ofByte: 0xFF, in: data), [])
    }

    // MARK: - clampWidth

    func test_clampWidth_belowMin_clampsTo16() {
        XCTAssertEqual(HexLayout.clampWidth(0),  16)
        XCTAssertEqual(HexLayout.clampWidth(-5), 16)
        XCTAssertEqual(HexLayout.clampWidth(8),  16)
        XCTAssertEqual(HexLayout.clampWidth(16), 16)
    }

    func test_clampWidth_betweenAllowed_picksUpperBucket() {
        XCTAssertEqual(HexLayout.clampWidth(17), 32)
        XCTAssertEqual(HexLayout.clampWidth(31), 32)
        XCTAssertEqual(HexLayout.clampWidth(32), 32)
    }

    func test_clampWidth_aboveMax_clampsTo64() {
        XCTAssertEqual(HexLayout.clampWidth(33),  64)
        XCTAssertEqual(HexLayout.clampWidth(64),  64)
        XCTAssertEqual(HexLayout.clampWidth(128), 64)
        XCTAssertEqual(HexLayout.clampWidth(.max),64)
    }

    func test_clampWidth_isIdempotent_onAllowedValues() {
        for w in HexLayout.allowedWidths {
            XCTAssertEqual(HexLayout.clampWidth(w), w,
                           "clampWidth should be idempotent on allowed value \(w)")
        }
    }

    // MARK: - rowCount/row/column boundaries

    func test_rowCount_atExactWidthBoundary() {
        XCTAssertEqual(HexLayout.rowCount(byteCount: 16, width: 16), 1)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 17, width: 16), 2)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 32, width: 16), 2)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 33, width: 16), 3)
    }

    func test_rowCount_emptyOrInvalid() {
        XCTAssertEqual(HexLayout.rowCount(byteCount: 0, width: 16), 0)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 100, width: 0), 0)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 100, width: -1), 0)
    }

    func test_rowAndColumn_atEndOfRow() {
        // Last byte of a 16-byte row sits at row 0, col 15.
        XCTAssertEqual(HexLayout.row(forOffset: 15, width: 16), 0)
        XCTAssertEqual(HexLayout.column(forOffset: 15, width: 16), 15)
        // First byte of next row.
        XCTAssertEqual(HexLayout.row(forOffset: 16, width: 16), 1)
        XCTAssertEqual(HexLayout.column(forOffset: 16, width: 16), 0)
    }
}
