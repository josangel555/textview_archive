import XCTest
@testable import ViewerCore
@testable import ViewerUI

/// TSK-522 slice 3 — the Log tab's multi-select state machine and the
/// cumulative-diff range it feeds. The row Button routes Cmd/Shift
/// clicks to exactly `GitPanelModel.logRowClicked` and the selection
/// bar's View Diff button reads exactly `cumulativeLogSelectionRange`
/// (exact-closure rule), so pinning these pins the feature's behavior;
/// the bar's rendering + real modifier clicks are the VM lane.
@MainActor
final class GitLogMultiSelectTests: XCTestCase {

    private func commit(_ sha: String, parent: String?) -> GitClient.GraphCommit {
        GitClient.GraphCommit(
            sha: sha, parents: parent.map { [$0] } ?? [],
            author: "t", timestamp: 0, subject: "s\(sha)",
            refs: [], filesChanged: 0, insertions: 0, deletions: 0)
    }

    /// e (newest, idx 0) → d → c → b → a (root, idx 4) — a straight line.
    private func makeModel() -> GitPanelModel {
        let m = GitPanelModel()
        m.logEntries = [
            commit("e", parent: "d"),
            commit("d", parent: "c"),
            commit("c", parent: "b"),
            commit("b", parent: "a"),
            commit("a", parent: nil),
        ]
        return m
    }

    // MARK: click state machine ---------------------------------------

    func test_plainSelect_resetsMultiSelectionToSingle() {
        let m = makeModel()
        m.logRowClicked(sha: "c", command: true)
        m.logRowClicked(sha: "e", command: true)
        XCTAssertEqual(m.selectedLogSHAs, ["c", "e"])

        m.selectLogCommit(sha: "d")   // the plain-click path
        XCTAssertEqual(m.selectedLogSHAs, ["d"],
                       "a plain click collapses the multi-selection to the clicked commit")
        XCTAssertEqual(m.selectedLogSHA, "d")
    }

    func test_cmdClick_togglesMembership() {
        let m = makeModel()
        m.logRowClicked(sha: "b", command: true)
        m.logRowClicked(sha: "d", command: true)
        XCTAssertEqual(m.selectedLogSHAs, ["b", "d"])

        m.logRowClicked(sha: "b", command: true)
        XCTAssertEqual(m.selectedLogSHAs, ["d"], "Cmd-click on a selected row deselects it")
    }

    func test_shiftClick_selectsRunFromAnchor_bothDirections() {
        let m = makeModel()
        m.selectLogCommit(sha: "d")          // anchor at idx 1
        m.logRowClicked(sha: "b", shift: true)  // extend DOWN to idx 3
        XCTAssertEqual(m.selectedLogSHAs, ["d", "c", "b"],
                       "shift-click selects the unbroken run anchor→target")

        m.selectLogCommit(sha: "b")          // re-anchor at idx 3
        m.logRowClicked(sha: "e", shift: true)  // extend UP to idx 0
        XCTAssertEqual(m.selectedLogSHAs, ["e", "d", "c", "b"],
                       "shift works upward from the anchor too")
    }

    func test_shiftClick_withoutAnchor_fallsBackToSingleSelect() {
        let m = makeModel()
        m.logRowClicked(sha: "c", shift: true)
        XCTAssertEqual(m.selectedLogSHAs, ["c"])
        XCTAssertEqual(m.selectedLogSHA, "c")
    }

    func test_clearLogSelection_dropsEverything() {
        let m = makeModel()
        m.selectLogCommit(sha: "d")
        m.logRowClicked(sha: "b", command: true)

        m.clearLogSelection()
        XCTAssertTrue(m.selectedLogSHAs.isEmpty)
        XCTAssertNil(m.selectedLogSHA)
    }

    func test_setRepoRoot_clearsMultiSelection() {
        let m = makeModel()
        m.logRowClicked(sha: "c", command: true)
        m.logRowClicked(sha: "e", command: true)

        m.setRepoRoot(FileManager.default.temporaryDirectory
            .appendingPathComponent("other-repo-\(UUID().uuidString)"))
        XCTAssertTrue(m.selectedLogSHAs.isEmpty,
                      "stale SHAs must never highlight rows of an unrelated repo")
    }

    // MARK: cumulative range ------------------------------------------

    func test_range_nilUnderTwoSelected() {
        let m = makeModel()
        XCTAssertNil(m.cumulativeLogSelectionRange)
        m.selectLogCommit(sha: "c")
        XCTAssertNil(m.cumulativeLogSelectionRange,
                     "a single selection is the plain commit-diff path, not cumulative")
    }

    func test_range_contiguousPair_baseIsParentOfOldest() {
        let m = makeModel()
        m.selectLogCommit(sha: "d")
        m.logRowClicked(sha: "c", command: true)

        let r = m.cumulativeLogSelectionRange
        XCTAssertEqual(r?.baseRef, "b", "base = parent of the OLDEST selected (c→b)")
        XCTAssertEqual(r?.tipRef, "d", "tip = the NEWEST selected")
        XCTAssertEqual(r?.isContiguous, true)
        XCTAssertEqual(r?.spannedCount, 2)
    }

    func test_range_withGap_reportsNonContiguousAndSpan() {
        let m = makeModel()
        m.logRowClicked(sha: "e", command: true)
        m.logRowClicked(sha: "b", command: true)   // skips d, c

        let r = m.cumulativeLogSelectionRange
        XCTAssertEqual(r?.baseRef, "a")
        XCTAssertEqual(r?.tipRef, "e")
        XCTAssertEqual(r?.isContiguous, false,
                       "d and c sit unselected inside the range — the UI must warn")
        XCTAssertEqual(r?.spannedCount, 4)
        XCTAssertEqual(r?.selectedCount, 2)
    }

    func test_range_includingRoot_usesEmptyTreeBase() {
        let m = makeModel()
        m.selectLogCommit(sha: "b")
        m.logRowClicked(sha: "a", shift: true)   // a is the root commit

        let r = m.cumulativeLogSelectionRange
        XCTAssertEqual(r?.baseRef, CumulativeDiffSelection.emptyTreeSHA,
                       "a root commit has no parent — diff against the empty tree")
        XCTAssertEqual(r?.tipRef, "b")
    }
}
