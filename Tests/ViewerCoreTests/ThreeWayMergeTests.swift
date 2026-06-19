import XCTest
@testable import ViewerCore

/// Host coverage for the diff3 three-way merge foundation (TSK-712). Classic
/// diff3 fixtures: non-overlapping edits auto-merge cleanly; overlapping edits
/// produce a conflict carrying the correct base/ours/theirs slices; identical
/// edits on both sides DON'T conflict.
final class ThreeWayMergeTests: XCTestCase {

    // MARK: - No divergence

    func test_allIdentical_singleUnchangedRegion_noConflict() {
        let lines = ["a", "b", "c"]
        let r = ThreeWayMerge.merge(base: lines, ours: lines, theirs: lines)
        XCTAssertFalse(r.hasConflicts)
        XCTAssertEqual(r.regions, [.unchanged(["a", "b", "c"])])
        XCTAssertEqual(r.autoMerged, lines)
    }

    func test_empty_inputs() {
        let r = ThreeWayMerge.merge(base: [], ours: [], theirs: [])
        XCTAssertFalse(r.hasConflicts)
        XCTAssertEqual(r.regions, [])
        XCTAssertEqual(r.autoMerged, [])
    }

    // MARK: - One-sided edits (clean)

    func test_oursOnlyEdit_takesOurs_cleanMerge() {
        let base = ["a", "b", "c"]
        let ours = ["a", "B-EDIT", "c"]
        let theirs = ["a", "b", "c"]   // unchanged
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertFalse(r.hasConflicts)
        XCTAssertEqual(r.autoMerged, ["a", "B-EDIT", "c"])
        // The middle region must be classified oursOnly.
        XCTAssertTrue(r.regions.contains(.oursOnly(lines: ["B-EDIT"])))
    }

    func test_theirsOnlyEdit_takesTheirs_cleanMerge() {
        let base = ["a", "b", "c"]
        let ours = ["a", "b", "c"]     // unchanged
        let theirs = ["a", "b", "C-EDIT"]
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertFalse(r.hasConflicts)
        XCTAssertEqual(r.autoMerged, ["a", "b", "C-EDIT"])
        XCTAssertTrue(r.regions.contains(.theirsOnly(lines: ["C-EDIT"])))
    }

    // MARK: - Non-overlapping edits auto-merge

    func test_nonOverlappingEdits_autoMergeCleanly() {
        // ours edits the top, theirs edits the bottom — disjoint spans.
        let base = ["one", "two", "three", "four", "five"]
        let ours = ["ONE", "two", "three", "four", "five"]
        let theirs = ["one", "two", "three", "four", "FIVE"]
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertFalse(r.hasConflicts, "disjoint edits must not conflict")
        XCTAssertEqual(r.autoMerged, ["ONE", "two", "three", "four", "FIVE"])
    }

    func test_nonOverlappingInsertions_autoMerge() {
        // ours inserts after line1, theirs inserts after line3 — disjoint.
        let base = ["l1", "l2", "l3"]
        let ours = ["l1", "ins-ours", "l2", "l3"]
        let theirs = ["l1", "l2", "l3", "ins-theirs"]
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertFalse(r.hasConflicts)
        XCTAssertEqual(r.autoMerged, ["l1", "ins-ours", "l2", "l3", "ins-theirs"])
    }

    // MARK: - Identical edits on both sides don't conflict

    func test_identicalEditBothSides_noConflict_bothSame() {
        let base = ["a", "b", "c"]
        let ours = ["a", "SAME-EDIT", "c"]
        let theirs = ["a", "SAME-EDIT", "c"]
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertFalse(r.hasConflicts, "identical edits on both sides must not conflict")
        XCTAssertEqual(r.autoMerged, ["a", "SAME-EDIT", "c"])
        XCTAssertTrue(r.regions.contains(.bothSame(lines: ["SAME-EDIT"])))
    }

    func test_identicalMultiLineEditBothSides_noConflict() {
        let base = ["x", "y", "z"]
        let edit = ["x", "p", "q", "r", "z"]
        let r = ThreeWayMerge.merge(base: base, ours: edit, theirs: edit)
        XCTAssertFalse(r.hasConflicts)
        XCTAssertEqual(r.autoMerged, edit)
    }

    // MARK: - Overlapping edits conflict with correct slices

    func test_overlappingEdits_produceConflict_withCorrectSlices() {
        let base = ["a", "b", "c"]
        let ours = ["a", "OURS-B", "c"]
        let theirs = ["a", "THEIRS-B", "c"]
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertTrue(r.hasConflicts)
        XCTAssertEqual(r.conflictCount, 1)
        XCTAssertNil(r.autoMerged, "a conflicting merge has no clean auto-result")

        // The conflict region must carry the exact divergent slices.
        let conflict = r.regions.first { $0.isConflict }
        XCTAssertEqual(conflict, .conflict(base: ["b"], ours: ["OURS-B"], theirs: ["THEIRS-B"]))

        // Surrounding context stays unchanged.
        XCTAssertEqual(r.regions.first, .unchanged(["a"]))
        XCTAssertEqual(r.regions.last, .unchanged(["c"]))
    }

    func test_overlappingMultiLineEdits_conflictSlicesSpanFullDivergence() {
        let base = ["h1", "x", "y", "h2"]
        let ours = ["h1", "OX", "OY", "h2"]
        let theirs = ["h1", "TX", "TY", "TZ", "h2"]
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertTrue(r.hasConflicts)
        let conflict = r.regions.first { $0.isConflict }
        XCTAssertEqual(
            conflict,
            .conflict(base: ["x", "y"], ours: ["OX", "OY"], theirs: ["TX", "TY", "TZ"]))
    }

    // MARK: - Mixed: one clean + one conflict in the same document

    func test_oneCleanRegion_oneConflictRegion() {
        let base = ["top", "mid", "bottom"]
        // ours: clean edit of "top"; conflicting edit of "bottom".
        let ours = ["TOP", "mid", "OURS-BOTTOM"]
        // theirs: "top" unchanged; conflicting edit of "bottom".
        let theirs = ["top", "mid", "THEIRS-BOTTOM"]
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertTrue(r.hasConflicts)
        XCTAssertEqual(r.conflictCount, 1)
        // The clean top edit is preserved as oursOnly even though a conflict exists below.
        XCTAssertTrue(r.regions.contains(.oursOnly(lines: ["TOP"])))
        XCTAssertTrue(r.regions.contains(
            .conflict(base: ["bottom"], ours: ["OURS-BOTTOM"], theirs: ["THEIRS-BOTTOM"])))
    }

    // MARK: - Deletions

    func test_oursDeletesLine_theirsUnchanged_cleanDelete() {
        let base = ["a", "b", "c"]
        let ours = ["a", "c"]          // deleted "b"
        let theirs = ["a", "b", "c"]
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertFalse(r.hasConflicts)
        XCTAssertEqual(r.autoMerged, ["a", "c"])
    }

    func test_bothDeleteSameLine_noConflict() {
        let base = ["a", "b", "c"]
        let del = ["a", "c"]
        let r = ThreeWayMerge.merge(base: base, ours: del, theirs: del)
        XCTAssertFalse(r.hasConflicts)
        XCTAssertEqual(r.autoMerged, ["a", "c"])
    }

    func test_oursDeletes_theirsEditsSameLine_conflict() {
        let base = ["a", "b", "c"]
        let ours = ["a", "c"]              // deleted "b"
        let theirs = ["a", "B-EDIT", "c"]  // edited "b"
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertTrue(r.hasConflicts)
        let conflict = r.regions.first { $0.isConflict }
        XCTAssertEqual(conflict, .conflict(base: ["b"], ours: [], theirs: ["B-EDIT"]))
    }

    // MARK: - Conflict text rendering (git-compatible markers)

    func test_conflictText_emitsGitMarkers() {
        let base = ["a", "b", "c"]
        let ours = ["a", "OURS", "c"]
        let theirs = ["a", "THEIRS", "c"]
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        let text = r.text(oursLabel: "HEAD", theirsLabel: "branch")
        XCTAssertEqual(text, """
        a
        <<<<<<< HEAD
        OURS
        =======
        THEIRS
        >>>>>>> branch
        c
        """)
    }

    func test_conflictText_diff3StyleIncludesBase() {
        let base = ["a", "b", "c"]
        let ours = ["a", "OURS", "c"]
        let theirs = ["a", "THEIRS", "c"]
        let r = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        let text = r.text(includeBaseInConflict: true)
        XCTAssertEqual(text, """
        a
        <<<<<<< ours
        OURS
        ||||||| base
        b
        =======
        THEIRS
        >>>>>>> theirs
        c
        """)
    }

    // MARK: - String convenience overload

    func test_stringOverload_splitsAndMerges() {
        let r = ThreeWayMerge.merge(
            base: "a\nb\nc",
            ours: "a\nB-EDIT\nc",
            theirs: "a\nb\nc")
        XCTAssertFalse(r.hasConflicts)
        XCTAssertEqual(r.autoMerged, ["a", "B-EDIT", "c"])
    }

    // MARK: - Pure-add scenarios (no common base lines)

    func test_emptyBase_bothAddDifferent_conflict() {
        let r = ThreeWayMerge.merge(base: [], ours: ["x"], theirs: ["y"])
        XCTAssertTrue(r.hasConflicts)
        XCTAssertEqual(r.regions.first { $0.isConflict },
                       .conflict(base: [], ours: ["x"], theirs: ["y"]))
    }

    func test_emptyBase_onlyOneSideAdds_clean() {
        let r = ThreeWayMerge.merge(base: [], ours: ["x", "y"], theirs: [])
        XCTAssertFalse(r.hasConflicts)
        XCTAssertEqual(r.autoMerged, ["x", "y"])
    }
}
