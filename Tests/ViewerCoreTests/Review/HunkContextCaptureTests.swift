import XCTest
@testable import ViewerCore

/// Stage 1 (§7): the frozen-context capture. These pin the two landmines
/// (§3.3, §9): (1) `.noNewline` lines are DROPPED in the mapper; (2)
/// pre/post context is up-to-3, CLIPPED to the hunk — never fabricated past
/// an edge. An off-by-one here bakes wrong context into the export forever.
final class HunkContextCaptureTests: XCTestCase {

    // Build a hunk from a compact line spec. Each tuple is
    // (kind, oldNo?, newNo?, content). Real diffs come from DiffParser; we
    // hand-build so the windowing is unambiguous.
    private func hunk(
        oldStart: Int = 10, oldCount: Int = 5,
        newStart: Int = 10, newCount: Int = 6,
        header: String = "func foo()",
        _ lines: [(UnifiedDiff.Line.Kind, Int?, Int?, String)]
    ) -> UnifiedDiff.Hunk {
        UnifiedDiff.Hunk(
            oldStart: oldStart, oldCount: oldCount,
            newStart: newStart, newCount: newCount,
            header: header,
            lines: lines.map { UnifiedDiff.Line(kind: $0.0, oldLineNo: $0.1, newLineNo: $0.2, content: $0.3) }
        )
    }

    // MARK: - .noNewline drop (§3.3)

    func test_mapLine_dropsNoNewline() {
        let nn = UnifiedDiff.Line(kind: .noNewline, oldLineNo: nil, newLineNo: nil, content: " No newline at end of file")
        XCTAssertNil(HunkContextCapture.mapLine(nn))
    }

    func test_mapLine_mapsTheThreeRealKinds() {
        let ctx = UnifiedDiff.Line(kind: .context, oldLineNo: 1, newLineNo: 1, content: "x")
        let add = UnifiedDiff.Line(kind: .added, oldLineNo: nil, newLineNo: 2, content: "y")
        let rem = UnifiedDiff.Line(kind: .removed, oldLineNo: 2, newLineNo: nil, content: "z")
        XCTAssertEqual(HunkContextCapture.mapLine(ctx)?.kind, .context)
        XCTAssertEqual(HunkContextCapture.mapLine(add)?.kind, .added)
        XCTAssertEqual(HunkContextCapture.mapLine(rem)?.kind, .removed)
    }

    func test_noNewlineInsideWindow_isDropped_neverOccupiesAContextSlot() {
        // Anchor on the new line 13. A `.noNewline` marker sits in the post
        // window — it must be skipped, and a real line beyond it pulled in.
        let h = hunk([
            (.context, 10, 10, "a"),
            (.context, 11, 11, "b"),
            (.context, 12, 12, "c"),
            (.added,   nil, 13, "TARGET"),
            (.noNewline, nil, nil, " No newline at end of file"),
            (.context, 14, 14, "d"),   // reachable only if the marker is dropped
        ])
        let ctx = HunkContextCapture.capture(hunk: h, side: .new, range: 13...13)!
        XCTAssertEqual(ctx.anchoredLines.map(\.content), ["TARGET"])
        // post = up to 3 real lines after; the marker is gone, "d" is the
        // first real post line.
        XCTAssertEqual(ctx.postLines.map(\.content), ["d"])
        // No DiffLine should ever carry the marker's content.
        let all = ctx.preLines + ctx.anchoredLines + ctx.postLines
        XCTAssertFalse(all.contains { $0.content.contains("No newline") })
    }

    // MARK: - boundary clipping (§9)

    func test_anchorAtHunkTop_hasFewerThan3PreLines_neverFabricated() {
        let h = hunk([
            (.added, nil, 10, "TARGET"),   // first line in hunk
            (.context, 11, 11, "b"),
            (.context, 12, 12, "c"),
            (.context, 13, 13, "d"),
            (.context, 14, 14, "e"),
        ])
        let ctx = HunkContextCapture.capture(hunk: h, side: .new, range: 10...10)!
        XCTAssertEqual(ctx.preLines.count, 0, "no lines exist before the hunk top")
        XCTAssertEqual(ctx.anchoredLines.map(\.content), ["TARGET"])
        XCTAssertEqual(ctx.postLines.map(\.content), ["b", "c", "d"]) // clipped to 3
    }

    func test_anchorAtHunkBottom_hasFewerThan3PostLines_neverFabricated() {
        let h = hunk([
            (.context, 10, 10, "a"),
            (.context, 11, 11, "b"),
            (.context, 12, 12, "c"),
            (.context, 13, 13, "d"),
            (.added, nil, 14, "TARGET"),   // last line in hunk
        ])
        let ctx = HunkContextCapture.capture(hunk: h, side: .new, range: 14...14)!
        XCTAssertEqual(ctx.preLines.map(\.content), ["b", "c", "d"]) // clipped to 3
        XCTAssertEqual(ctx.anchoredLines.map(\.content), ["TARGET"])
        XCTAssertEqual(ctx.postLines.count, 0, "no lines exist after the hunk bottom")
    }

    func test_anchorInMiddle_hasFull3PreAnd3Post() {
        let h = hunk([
            (.context, 10, 10, "p0"),
            (.context, 11, 11, "p1"),
            (.context, 12, 12, "p2"),
            (.context, 13, 13, "p3"),   // extra: should be clipped away from pre
            (.added,   nil, 14, "TARGET"),
            (.context, 15, 15, "q0"),
            (.context, 16, 16, "q1"),
            (.context, 17, 17, "q2"),
            (.context, 18, 18, "q3"),   // extra: should be clipped away from post
        ])
        let ctx = HunkContextCapture.capture(hunk: h, side: .new, range: 14...14)!
        XCTAssertEqual(ctx.preLines.map(\.content), ["p1", "p2", "p3"])
        XCTAssertEqual(ctx.anchoredLines.map(\.content), ["TARGET"])
        XCTAssertEqual(ctx.postLines.map(\.content), ["q0", "q1", "q2"])
    }

    // MARK: - multi-line anchor + correct line numbers

    func test_multiLineAnchor_capturesContiguousBlock_withCorrectNumbers() {
        let h = hunk([
            (.context, 10, 10, "a"),
            (.context, 11, 11, "b"),
            (.added,   nil, 12, "L12"),
            (.added,   nil, 13, "L13"),
            (.added,   nil, 14, "L14"),
            (.context, 15, 15, "c"),
        ])
        let ctx = HunkContextCapture.capture(hunk: h, side: .new, range: 12...14)!
        XCTAssertEqual(ctx.anchoredLines.map(\.content), ["L12", "L13", "L14"])
        XCTAssertEqual(ctx.anchoredLines.map(\.newLineNo), [12, 13, 14])
        XCTAssertEqual(ctx.preLines.map(\.content), ["a", "b"])
        XCTAssertEqual(ctx.postLines.map(\.content), ["c"])
    }

    func test_oldSideAnchor_usesOldLineNumbers() {
        let h = hunk([
            (.context, 10, 10, "a"),
            (.removed, 11, nil, "OLD11"),
            (.removed, 12, nil, "OLD12"),
            (.context, 13, 13, "b"),
        ])
        let ctx = HunkContextCapture.capture(hunk: h, side: .old, range: 11...12)!
        XCTAssertEqual(ctx.anchoredLines.map(\.content), ["OLD11", "OLD12"])
        XCTAssertEqual(ctx.anchoredLines.map(\.oldLineNo), [11, 12])
    }

    func test_interiorAddedLine_includedInContiguousAnchorBlock() {
        // Selecting old-side 10..11 spans a context line that, on the OLD
        // side, has number 10 and 11 — with an added line interleaved that
        // has no old number. The contiguous block must still include it so
        // the captured snippet is visually continuous.
        let h = hunk([
            (.context, 10, 20, "ctx10"),
            (.added,   nil, 21, "addedInterior"),
            (.context, 11, 22, "ctx11"),
        ])
        let ctx = HunkContextCapture.capture(hunk: h, side: .old, range: 10...11)!
        XCTAssertEqual(ctx.anchoredLines.map(\.content), ["ctx10", "addedInterior", "ctx11"])
    }

    // MARK: - anchor outside hunk → nil (no fabrication)

    func test_anchorOutsideHunk_returnsNil() {
        let h = hunk([
            (.context, 10, 10, "a"),
            (.context, 11, 11, "b"),
        ])
        XCTAssertNil(HunkContextCapture.capture(hunk: h, side: .new, range: 99...99))
    }

    func test_emptyHunk_returnsNil() {
        let h = hunk([])
        XCTAssertNil(HunkContextCapture.capture(hunk: h, side: .new, range: 1...1))
    }

    // MARK: - hunk header reconstruction

    func test_hunkHeaderString_rebuildsCanonicalForm() {
        let h = hunk(oldStart: 10, oldCount: 5, newStart: 12, newCount: 7, header: "func foo()", [
            (.context, 10, 12, "x"),
        ])
        XCTAssertEqual(
            HunkContextCapture.hunkHeaderString(h),
            "@@ -10,5 +12,7 @@ func foo()"
        )
    }

    func test_hunkHeaderString_omitsTailWhenEmpty() {
        let h = hunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 2, header: "", [
            (.context, 1, 1, "x"),
        ])
        XCTAssertEqual(HunkContextCapture.hunkHeaderString(h), "@@ -1,1 +1,2 @@")
    }
}
