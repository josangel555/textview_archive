import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-595: the Log tab highlights the commit row whose diff is shown.
/// The highlight derives from `GitPanelModel.selectedLogSHA`; these pin
/// the selection state machine headlessly (set on select, replaced on
/// re-select, reset on repo switch so a stale SHA never matches a row in
/// an unrelated repo). The accent-fill rendering itself is VM-lane.
@MainActor
final class GitLogSelectionTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-gitlog-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_selectLogCommit_setsAndReplacesSelection() {
        let panel = GitPanelModel()
        XCTAssertNil(panel.selectedLogSHA, "no selection before any click")

        panel.selectLogCommit(sha: "abc1234")
        XCTAssertEqual(panel.selectedLogSHA, "abc1234")

        panel.selectLogCommit(sha: "def5678")
        XCTAssertEqual(panel.selectedLogSHA, "def5678",
                       "selecting another commit replaces the selection")
    }

    func test_setRepoRoot_clearsSelection() {
        let panel = GitPanelModel()
        panel.selectLogCommit(sha: "abc1234")

        panel.setRepoRoot(tmp.appendingPathComponent("other-repo"))
        XCTAssertNil(panel.selectedLogSHA,
                     "a repo switch must drop the stale SHA — it could "
                     + "coincidentally match a row in the new repo's log")
    }

    func test_setRepoRoot_sameRoot_keepsSelection() {
        // The no-op guard in setRepoRoot means re-asserting the SAME root
        // (e.g. re-picking it in the header picker) must not wipe state.
        let panel = GitPanelModel()
        let root = tmp.appendingPathComponent("repo")
        panel.setRepoRoot(root)
        panel.selectLogCommit(sha: "abc1234")

        panel.setRepoRoot(root)
        XCTAssertEqual(panel.selectedLogSHA, "abc1234",
                       "same-root setRepoRoot is a no-op and keeps the selection")
    }
}
