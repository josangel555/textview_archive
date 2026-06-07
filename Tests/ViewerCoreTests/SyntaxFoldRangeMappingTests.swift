import XCTest
@testable import ViewerCore

/// Pure coverage for `SyntaxFoldRangeMapping` — TreeSitter `FoldRegion`
/// (1-based lines) → CM6 `CMFoldRange` (UTF-16 doc offsets), the
/// design-agnostic core of editor folding (TSK-466).
final class SyntaxFoldRangeMappingTests: XCTestCase {

    /// UTF-16 offset of the END of `line1`'s content (before its newline),
    /// computed independently of the converter so the assertions pin the
    /// 1-based→offset contract, not the converter's internals.
    private func endOfLine(_ line1: Int, in text: String) -> Int {
        let lines = text.components(separatedBy: "\n")
        var off = 0
        for i in 0..<(line1 - 1) { off += lines[i].utf16.count + 1 } // + newline
        return off + lines[line1 - 1].utf16.count
    }

    private let doc = "line1\nline2\nline3\nline4\nline5\n"

    func test_empty_returnsEmpty() {
        XCTAssertTrue(SyntaxFoldRangeMapping.cmFoldRanges(from: [], documentText: doc).isEmpty)
    }

    func test_mapsStartAndEndLinesToContentEndOffsets() {
        let region = FoldRegion(startLine: 2, endLine: 4, kind: .function)
        let out = SyntaxFoldRangeMapping.cmFoldRanges(from: [region], documentText: doc)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].from, endOfLine(2, in: doc), "fold opens at end of startLine content")
        XCTAssertEqual(out[0].to, endOfLine(4, in: doc), "fold closes at end of endLine content")
        XCTAssertEqual(out[0].kind, "function")
        XCTAssertLessThan(out[0].from, out[0].to)
    }

    func test_forwardsKindRawValue() {
        let kinds: [FoldRegion.Kind] = [.object, .array, .type, .codeFence, .comment]
        for k in kinds {
            let out = SyntaxFoldRangeMapping.cmFoldRanges(
                from: [FoldRegion(startLine: 1, endLine: 3, kind: k)], documentText: doc)
            XCTAssertEqual(out.first?.kind, k.rawValue)
        }
    }

    func test_dropsDegenerateRange_sameLine() {
        // start == end ⇒ from == to (end-of-same-line) ⇒ dropped.
        let out = SyntaxFoldRangeMapping.cmFoldRanges(
            from: [FoldRegion(startLine: 3, endLine: 3, kind: .object)], documentText: doc)
        XCTAssertTrue(out.isEmpty)
    }

    func test_clampsEndLineBeyondDocument() {
        // endLine past EOF clamps to docUTF16Count, still a valid fold.
        let region = FoldRegion(startLine: 2, endLine: 999, kind: .object)
        let out = SyntaxFoldRangeMapping.cmFoldRanges(from: [region], documentText: doc)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].to, doc.utf16.count)
        XCTAssertLessThan(out[0].from, out[0].to)
    }

    func test_multipleRegions_allMapped_inOrder() {
        let regions = [
            FoldRegion(startLine: 1, endLine: 2, kind: .object),
            FoldRegion(startLine: 3, endLine: 5, kind: .array),
        ]
        let out = SyntaxFoldRangeMapping.cmFoldRanges(from: regions, documentText: doc)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].from, endOfLine(1, in: doc))
        XCTAssertEqual(out[1].from, endOfLine(3, in: doc))
        XCTAssertLessThan(out[0].to, out[1].from, "non-overlapping regions stay ordered")
    }

    func test_utf16_multibyteContent_offsetsAreUTF16() {
        // An emoji (UTF-16 surrogate pair) on line 1 shifts later offsets
        // by 2 code units — the mapping must count UTF-16, not characters.
        let t = "a😀b\nxx\nyy\n"
        let region = FoldRegion(startLine: 1, endLine: 2, kind: .object)
        let out = SyntaxFoldRangeMapping.cmFoldRanges(from: [region], documentText: t)
        XCTAssertEqual(out.first?.from, endOfLine(1, in: t)) // "a😀b" = 4 UTF-16 units
    }
}
