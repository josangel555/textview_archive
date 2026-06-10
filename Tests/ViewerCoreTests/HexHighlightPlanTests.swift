import XCTest
@testable import ViewerCore

/// TSK-267 — the HEX highlight scoped-clear planner and the small-file
/// sync-build threshold. These pin the pure seams the view controller's
/// painter relies on; the planner MUST agree with the painter's
/// HexLayout-based offset math or a clear leaves stale yellow behind.
final class HexHighlightPlanTests: XCTestCase {

    // MARK: charRanges

    /// Byte 0 at width 16, no header: hex pair at the row's hex column
    /// start, ascii glyph at the ascii column start.
    func test_charRanges_firstByte_matchesHexLayoutMath() {
        let ranges = HexHighlightPlan.charRanges(
            offset: 0, patternLength: 1, width: 16,
            headerCharCount: 0, byteCount: 64)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0],
                       NSRange(location: HexLayout.hexCharOffset(inRowColumn: 0),
                               length: 2))
        XCTAssertEqual(ranges[1],
                       NSRange(location: HexLayout.asciiCharOffset(inRowColumn: 0,
                                                                   width: 16),
                               length: 1))
    }

    /// A pattern spanning a row boundary lands its second byte on the
    /// NEXT row's character base — the planner must use row*rowLength.
    func test_charRanges_spansRowBoundary() {
        let width = 16
        let rowLength = HexLayout.renderedRowLength(width: width)
        let header = 7
        // Bytes 15 (row 0, col 15) and 16 (row 1, col 0).
        let ranges = HexHighlightPlan.charRanges(
            offset: 15, patternLength: 2, width: width,
            headerCharCount: header, byteCount: 64)
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(
            ranges[0].location,
            header + HexLayout.hexCharOffset(inRowColumn: 15))
        XCTAssertEqual(
            ranges[2].location,
            header + rowLength + HexLayout.hexCharOffset(inRowColumn: 0))
    }

    /// The trailing edge clamps to byteCount — a match near EOF paints
    /// (and therefore clears) only the existing bytes.
    func test_charRanges_clampsAtByteCount() {
        let ranges = HexHighlightPlan.charRanges(
            offset: 62, patternLength: 8, width: 16,
            headerCharCount: 0, byteCount: 64)
        XCTAssertEqual(ranges.count, 4, "bytes 62 and 63 only — 2 ranges each")
    }

    func test_charRanges_degenerateInputs_empty() {
        XCTAssertTrue(HexHighlightPlan.charRanges(
            offset: 0, patternLength: 0, width: 16,
            headerCharCount: 0, byteCount: 64).isEmpty, "zero-length pattern")
        XCTAssertTrue(HexHighlightPlan.charRanges(
            offset: -1, patternLength: 2, width: 16,
            headerCharCount: 0, byteCount: 64).isEmpty, "negative offset")
        XCTAssertTrue(HexHighlightPlan.charRanges(
            offset: 64, patternLength: 2, width: 16,
            headerCharCount: 0, byteCount: 64).isEmpty, "offset past EOF")
        XCTAssertTrue(HexHighlightPlan.charRanges(
            offset: 0, patternLength: 2, width: 16,
            headerCharCount: 0, byteCount: 0).isEmpty, "empty file")
    }

    // MARK: clearRanges

    /// The flattened clear-set covers every painted occurrence — clearing
    /// it leaves zero stale ranges from the prior paint.
    func test_clearRanges_coversAllOffsets() {
        let offsets = [0, 5, 33]
        let ranges = HexHighlightPlan.clearRanges(
            offsets: offsets, patternLength: 2, width: 16,
            headerCharCount: 0, byteCount: 64)
        // 3 occurrences × 2 bytes × 2 ranges (hex + ascii).
        XCTAssertEqual(ranges.count, 12)
        // And each occurrence's set equals its own charRanges.
        let single = HexHighlightPlan.charRanges(
            offset: 5, patternLength: 2, width: 16,
            headerCharCount: 0, byteCount: 64)
        XCTAssertEqual(Array(ranges[4..<8]), single)
    }

    func test_clearRanges_zeroPattern_empty() {
        XCTAssertTrue(HexHighlightPlan.clearRanges(
            offsets: [0, 1, 2], patternLength: 0, width: 16,
            headerCharCount: 0, byteCount: 64).isEmpty)
    }

    // MARK: HexRenderPlan threshold

    func test_useSyncBuild_thresholdBoundary() {
        XCTAssertTrue(HexRenderPlan.useSyncBuild(renderedByteCount: 0))
        XCTAssertTrue(HexRenderPlan.useSyncBuild(renderedByteCount: 6 * 1024),
                      "the #218 6KB case MUST take the sync path")
        XCTAssertTrue(HexRenderPlan.useSyncBuild(
            renderedByteCount: HexRenderPlan.syncBuildByteLimit))
        XCTAssertFalse(HexRenderPlan.useSyncBuild(
            renderedByteCount: HexRenderPlan.syncBuildByteLimit + 1))
        XCTAssertFalse(HexRenderPlan.useSyncBuild(renderedByteCount: 1_048_576),
                       "1MB keeps the chunked background build")
    }
}
