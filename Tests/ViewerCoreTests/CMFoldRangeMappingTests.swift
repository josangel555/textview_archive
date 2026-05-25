import XCTest
@testable import ViewerCore

/// Unit tests for `CMFoldRangeMapping`: LSP line/column folds →
/// CM6 doc-offset folds.
final class CMFoldRangeMappingTests: XCTestCase {

    private let doc = """
    line0
    line1
    line2
    line3
    line4
    """

    // MARK: - Empty / null

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertEqual(
            CMFoldRangeMapping.cmFoldRanges(from: [], documentText: doc),
            []
        )
    }

    // MARK: - Basic line→offset conversion

    func testWholeLinesFoldUsesEndOfStartLineAsFrom() {
        // LSP fold: lines 0..1 inclusive. CM6 / VSCode convention says
        // the fold opens at the END of the start line (so the header
        // line stays visible). Our doc has line "line0" with length 5
        // — `from` should land at offset 5.
        let result = CMFoldRangeMapping.cmFoldRanges(
            from: [LSPFoldingRange(startLine: 0, endLine: 1)],
            documentText: doc
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.from, 5)
        // End at end of line 1 — "line0\nline1" is 11 UTF-16 units.
        XCTAssertEqual(result.first?.to, 11)
    }

    func testStartCharacterOverridesEndOfLine() {
        // When `startCharacter` is present, use that column on the
        // start line — caller-supplied "fold from this brace" point.
        let result = CMFoldRangeMapping.cmFoldRanges(
            from: [LSPFoldingRange(
                startLine: 0, endLine: 1,
                startCharacter: 2, endCharacter: nil
            )],
            documentText: doc
        )
        XCTAssertEqual(result.first?.from, 2)
    }

    func testMultipleFoldsSurvivePreservingOrder() {
        let result = CMFoldRangeMapping.cmFoldRanges(
            from: [
                LSPFoldingRange(startLine: 0, endLine: 1),
                LSPFoldingRange(startLine: 2, endLine: 3, kind: "comment"),
            ],
            documentText: doc
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].kind, "comment")
    }

    // MARK: - Defensive cases

    func testZeroSpanRangesAreDropped() {
        // A fold whose computed `to <= from` is meaningless; CM's fold
        // gutter would render nothing. Drop rather than ship junk.
        let result = CMFoldRangeMapping.cmFoldRanges(
            from: [LSPFoldingRange(
                startLine: 0, endLine: 0,
                startCharacter: 3, endCharacter: 3
            )],
            documentText: doc
        )
        XCTAssertEqual(result, [])
    }

    func testRangesPastEndOfDocClampToEndAndStaySafe() {
        // Server lies and claims a fold ending on line 999; clamp to
        // doc length without crashing.
        let result = CMFoldRangeMapping.cmFoldRanges(
            from: [LSPFoldingRange(startLine: 0, endLine: 999)],
            documentText: doc
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.to, doc.utf16.count)
    }

    // MARK: - LSPClient decoder

    func testDecodeFoldingRangeAcceptsValidEntries() throws {
        let arr: [[String: Any]] = [
            ["startLine": 1, "endLine": 5, "kind": "region"],
            ["startLine": 10, "endLine": 12,
             "startCharacter": 4, "endCharacter": 8],
        ]
        let data = try JSONSerialization.data(withJSONObject: arr)
        let folds = LSPClient.decodeFoldingRange(data)
        XCTAssertEqual(folds.count, 2)
        XCTAssertEqual(folds[0].startLine, 1)
        XCTAssertEqual(folds[0].endLine, 5)
        XCTAssertEqual(folds[0].kind, "region")
        XCTAssertEqual(folds[1].startCharacter, 4)
        XCTAssertEqual(folds[1].endCharacter, 8)
    }

    func testDecodeFoldingRangeDropsMalformedEntries() throws {
        // Missing `startLine` → drop that entry but keep others.
        let arr: [[String: Any]] = [
            ["endLine": 5],                            // no startLine
            ["startLine": 2, "endLine": 1],             // end < start
            ["startLine": 7, "endLine": 9],
        ]
        let data = try JSONSerialization.data(withJSONObject: arr)
        let folds = LSPClient.decodeFoldingRange(data)
        XCTAssertEqual(folds.count, 1)
        XCTAssertEqual(folds[0].startLine, 7)
    }

    func testDecodeFoldingRangeNullReturnsEmpty() throws {
        let data = try JSONSerialization.data(
            withJSONObject: NSNull(), options: [.fragmentsAllowed]
        )
        XCTAssertEqual(LSPClient.decodeFoldingRange(data), [])
    }
}
