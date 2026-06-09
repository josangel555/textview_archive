import XCTest
@testable import ViewerCore

/// Teeth for the cumulative-diff range resolver (TSK-522 slice 1). The
/// load-bearing contracts: base = (first) parent of the OLDEST selected commit
/// (empty-tree for a root), tip = the NEWEST selected commit, and the
/// contiguous/spanned accounting that tells the UI when unselected commits are
/// swept into the range.
final class CumulativeDiffSelectionTests: XCTestCase {
    typealias Sel = CumulativeDiffSelection
    private func c(_ sha: String, _ topo: Int, _ parents: [String] = []) -> Sel.Commit {
        Sel.Commit(sha: sha, topoIndex: topo, parents: parents)
    }

    func test_emptySelection_returnsNil() {
        XCTAssertNil(Sel.resolve([]))
    }

    func test_singleCommit_isParentToSelf() {
        let r = Sel.resolve([c("bbb", 3, ["aaa"])])
        XCTAssertEqual(r?.baseRef, "aaa")          // parent
        XCTAssertEqual(r?.tipRef, "bbb")           // the commit
        XCTAssertEqual(r?.isContiguous, true)
        XCTAssertEqual(r?.selectedCount, 1)
        XCTAssertEqual(r?.spannedCount, 1)
    }

    func test_singleRootCommit_usesEmptyTreeBase() {
        let r = Sel.resolve([c("root", 9, [])])    // no parents
        XCTAssertEqual(r?.baseRef, Sel.emptyTreeSHA)
        XCTAssertEqual(r?.tipRef, "root")
    }

    func test_contiguousRange_baseIsOldestParent_tipIsNewest() {
        // topo: newest=2 (tip), oldest=4 (base from its parent "p5"); 3 selected.
        let r = Sel.resolve([c("c2", 2, ["c3"]), c("c3", 3, ["c4"]), c("c4", 4, ["p5"])])
        XCTAssertEqual(r?.baseRef, "p5")           // parent of the oldest selected
        XCTAssertEqual(r?.tipRef, "c2")            // newest selected
        XCTAssertEqual(r?.isContiguous, true)
        XCTAssertEqual(r?.selectedCount, 3)
        XCTAssertEqual(r?.spannedCount, 3)
    }

    func test_nonContiguousSelection_flagsGapAndSpannedCount() {
        // Select topo 2 and 4 but NOT 3 → range spans 2..4 (3 commits), so the
        // unselected commit 3 is swept in; isContiguous must be false.
        let r = Sel.resolve([c("c2", 2, ["c3"]), c("c4", 4, ["p5"])])
        XCTAssertEqual(r?.baseRef, "p5")
        XCTAssertEqual(r?.tipRef, "c2")
        XCTAssertEqual(r?.isContiguous, false)
        XCTAssertEqual(r?.selectedCount, 2)
        XCTAssertEqual(r?.spannedCount, 3)         // 4 - 2 + 1
    }

    func test_orderIndependent_andDeduped() {
        let scrambled = Sel.resolve([c("c4", 4, ["p5"]), c("c2", 2, ["c3"]),
                                     c("c2", 2, ["c3"]), c("c3", 3, ["c4"])])  // dup c2
        XCTAssertEqual(scrambled?.baseRef, "p5")
        XCTAssertEqual(scrambled?.tipRef, "c2")
        XCTAssertEqual(scrambled?.selectedCount, 3)   // dup collapsed
        XCTAssertEqual(scrambled?.spannedCount, 3)
        XCTAssertEqual(scrambled?.isContiguous, true)
    }

    func test_emptyTreeSHA_isGitCanonicalValue() {
        XCTAssertEqual(Sel.emptyTreeSHA, "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
    }
}
