import XCTest
@testable import ViewerCore

/// Pure-logic tests for `SidebarSectionPlanner`.
///
/// Pins the contract used by `SidebarView`'s accordion: hidden
/// sections drop out entirely, and trailing dividers are emitted
/// only between two visible neighbours. This is the fix for the
/// "3-4 divider lines bunched up below GIT" bug — previously the
/// dividers were rendered unconditionally even when the panel they
/// separated was hidden.
final class SidebarSectionPlannerTests: XCTestCase {

    func test_emptyInput_returnsEmpty() {
        let plan = SidebarSectionPlanner.plan([])
        XCTAssertTrue(plan.isEmpty)
    }

    func test_allHidden_returnsEmpty() {
        let plan = SidebarSectionPlanner.plan([
            (.bookmarks, false),
            (.searchAnywhere, false),
            (.git, false),
        ])
        XCTAssertTrue(plan.isEmpty)
    }

    func test_singleVisible_hasNoTrailingDivider() {
        let plan = SidebarSectionPlanner.plan([
            (.bookmarks, true),
            (.searchAnywhere, false),
            (.git, false),
        ])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].panel, .bookmarks)
        XCTAssertFalse(plan[0].drawTrailingDivider)
    }

    func test_twoVisible_emitsOneDividerBetween() {
        let plan = SidebarSectionPlanner.plan([
            (.bookmarks, true),
            (.searchAnywhere, true),
        ])
        XCTAssertEqual(plan.count, 2)
        XCTAssertTrue(plan[0].drawTrailingDivider, "divider goes between visible neighbours")
        XCTAssertFalse(plan[1].drawTrailingDivider, "last entry never gets a trailing divider")
    }

    /// Reproduces the user-reported "bunched dividers below GIT": with
    /// git + claude + lspOutline all hidden but lspNavigation visible,
    /// the planner emits a single divider between `searchAnywhere` and
    /// `lspNavigation` — not 3 dividers stacked on top of each other.
    func test_runOfHiddenPanels_doesNotEmitMultipleDividers() {
        let plan = SidebarSectionPlanner.plan([
            (.bookmarks, true),
            (.searchAnywhere, true),
            (.git, false),
            (.claudeTimeline, false),
            (.lspOutline, false),
            (.lspNavigation, true),
            (.lspProblems, true),
        ])
        XCTAssertEqual(plan.map(\.panel),
                       [.bookmarks, .searchAnywhere, .lspNavigation, .lspProblems])
        XCTAssertEqual(plan.map(\.drawTrailingDivider),
                       [true, true, true, false])
    }

    /// Hidden trailing panels don't leave a phantom divider on the
    /// last visible one.
    func test_trailingHidden_dropsTrailingDivider() {
        let plan = SidebarSectionPlanner.plan([
            (.bookmarks, true),
            (.searchAnywhere, true),
            (.git, false),
        ])
        XCTAssertEqual(plan.map(\.panel), [.bookmarks, .searchAnywhere])
        XCTAssertEqual(plan.map(\.drawTrailingDivider), [true, false])
    }

    /// Leading hidden panels are dropped; the first visible panel
    /// becomes the head of the list.
    func test_leadingHidden_dropsCleanly() {
        let plan = SidebarSectionPlanner.plan([
            (.bookmarks, false),
            (.searchAnywhere, true),
            (.git, true),
        ])
        XCTAssertEqual(plan.map(\.panel), [.searchAnywhere, .git])
        XCTAssertEqual(plan.map(\.drawTrailingDivider), [true, false])
    }

    /// Order is preserved end-to-end — the planner is just a filter
    /// + divider tagger, never a sort.
    func test_orderIsPreserved() {
        let plan = SidebarSectionPlanner.plan([
            (.git, true),
            (.bookmarks, true),
            (.searchAnywhere, true),
        ])
        XCTAssertEqual(plan.map(\.panel), [.git, .bookmarks, .searchAnywhere])
    }
}
