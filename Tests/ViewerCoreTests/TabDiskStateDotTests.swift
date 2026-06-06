import XCTest
@testable import ViewerCore

/// Headless coverage for `Tab.DiskState`'s tab-dot UI helpers (TSK-371). The
/// TabBar reads these off the cheap `Tab` snapshot to decide whether to draw the
/// red disk-change dot and what to label it; pinning the mapping here keeps the
/// view a thin reader and catches a state→label drift without a live run.
final class TabDiskStateDotTests: XCTestCase {

    func test_fresh_showsNoDot_andHasNoLabels() {
        let s = Tab.DiskState.fresh
        XCTAssertFalse(s.showsTabDot)
        XCTAssertNil(s.tabDotHelpTitle)
        XCTAssertNil(s.tabDotHelpDescription)
    }

    func test_changeStates_showDot_withDistinctLabels() {
        for s in [Tab.DiskState.staleVsDisk, .deleted] {
            XCTAssertTrue(s.showsTabDot, "\(s) must surface the dot")
            XCTAssertNotNil(s.tabDotHelpTitle, "\(s) needs a help title")
            XCTAssertNotNil(s.tabDotHelpDescription, "\(s) needs a help description")
            XCTAssertFalse(s.tabDotHelpTitle!.isEmpty)
        }
        XCTAssertNotEqual(Tab.DiskState.staleVsDisk.tabDotHelpTitle,
                          Tab.DiskState.deleted.tabDotHelpTitle,
                          "changed-vs-deleted must read differently")
    }

    /// The dot is the only display-affecting addition; it must move in lockstep
    /// with the existing `isActiveTabStale` notion the status bar already uses
    /// (staleVsDisk + deleted are the two non-fresh states).
    func test_showsTabDot_isExactlyNonFresh() {
        XCTAssertEqual(Tab.DiskState.allNonFresh.allSatisfy { $0.showsTabDot }, true)
        XCTAssertFalse(Tab.DiskState.fresh.showsTabDot)
    }
}

private extension Tab.DiskState {
    /// Local test helper — the two states that mean "differs from disk".
    static var allNonFresh: [Tab.DiskState] { [.staleVsDisk, .deleted] }
}
