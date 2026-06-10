import XCTest
@testable import ViewerCore

/// Teeth for the multi-comment → combined-diff-regions resolver (TSK-532):
/// grouping by (file, side), range merging (overlap + adjacency), separation of
/// old/new sides, and deterministic ordering.
final class CommentDiffSelectionTests: XCTestCase {

    private func comment(
        _ file: String, side: LineAnchor.Side, _ start: Int, _ end: Int? = nil
    ) -> ReviewComment {
        ReviewComment(
            id: "c-\(file)-\(side.rawValue)-\(start)",
            filePath: file,
            anchor: LineAnchor(side: side, startLine: start, endLine: end ?? start, blobSha: nil),
            severity: .issue,
            body: "x",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            hunkContext: HunkContext(hunkHeader: "@@", preLines: [], anchoredLines: [], postLines: [])
        )
    }

    func test_empty_returnsEmpty() {
        XCTAssertTrue(CommentDiffSelection.regions(from: []).isEmpty)
    }

    func test_singleComment_oneRegionOneRange() {
        let r = CommentDiffSelection.regions(from: [comment("a.swift", side: .new, 10, 12)])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].filePath, "a.swift")
        XCTAssertEqual(r[0].side, .new)
        XCTAssertEqual(r[0].ranges, [10...12])
    }

    func test_overlappingRanges_sameFileSide_merge() {
        let r = CommentDiffSelection.regions(from: [
            comment("a.swift", side: .new, 10, 15),
            comment("a.swift", side: .new, 13, 20),
        ])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].ranges, [10...20])   // overlap coalesces
    }

    func test_adjacentRanges_merge() {
        let r = CommentDiffSelection.regions(from: [
            comment("a.swift", side: .new, 10, 12),
            comment("a.swift", side: .new, 13, 14),   // touches 12 (gap 1)
        ])
        XCTAssertEqual(r[0].ranges, [10...14])
    }

    func test_disjointRanges_sameFileSide_kept_sorted() {
        let r = CommentDiffSelection.regions(from: [
            comment("a.swift", side: .new, 40, 42),
            comment("a.swift", side: .new, 10, 12),   // out of order
        ])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].ranges, [10...12, 40...42])   // gap > 1 stays split, sorted
    }

    func test_oldAndNewSide_keptSeparate() {
        let r = CommentDiffSelection.regions(from: [
            comment("a.swift", side: .new, 50, 50),
            comment("a.swift", side: .old, 50, 50),
        ])
        XCTAssertEqual(r.count, 2)   // same line number, different coordinate systems
        XCTAssertEqual(Set(r.map(\.side)), [.old, .new])
    }

    func test_multipleFiles_sortedByPath() {
        let r = CommentDiffSelection.regions(from: [
            comment("z.swift", side: .new, 1, 1),
            comment("a.swift", side: .new, 1, 1),
        ])
        XCTAssertEqual(r.map(\.filePath), ["a.swift", "z.swift"])
    }

    func test_reversedAnchorBounds_normalised() {
        // A comment whose endLine < startLine (corrupt/disk) still produces a
        // valid lo...hi range rather than trapping.
        let r = CommentDiffSelection.regions(from: [comment("a.swift", side: .new, 20, 10)])
        XCTAssertEqual(r[0].ranges, [10...20])
    }

    func test_merge_helper_threeWayChain() {
        // 1-3, 4-6, 7-9 all chain (each touches the next) → one range.
        XCTAssertEqual(CommentDiffSelection.merge([1...3, 7...9, 4...6]), [1...9])
    }
}
