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

    // MARK: - fillTarget (owner 2026-08-09: tool windows fill the shoulder
    // regardless of how many are open, in what combination)

    /// The accordion panel kinds in on-screen order (FILES + plugins render
    /// outside the accordion).
    private static let accordionKinds: [SidebarPanelKind] = [
        .bookmarks, .searchAnywhere, .git, .claudeTimeline,
        .lspOutline, .markdownOutline, .lspNavigation, .lspProblems, .recentlyOpened,
    ]

    private func visibility(
        shown: Set<SidebarPanelKind>
    ) -> [(panel: SidebarPanelKind, isVisible: Bool)] {
        Self.accordionKinds.map { ($0, shown.contains($0)) }
    }

    /// EVERY panel kind, SOLO (files hidden): that panel is the fill target —
    /// it must occupy 100% of the shoulder.
    func test_fillTarget_everyPanelSolo_isTheFill() {
        for kind in Self.accordionKinds {
            XCTAssertEqual(
                SidebarSectionPlanner.fillTarget(
                    filesVisible: false, pluginsVisible: false,
                    accordion: visibility(shown: [kind])),
                kind,
                "\(kind) solo must flex-fill the shoulder")
        }
    }

    /// Combinations: the LAST visible panel (accordion order) fills; the ones
    /// above keep their fixed heights.
    func test_fillTarget_combinations_lastVisibleFills() {
        let combos: [(Set<SidebarPanelKind>, SidebarPanelKind)] = [
            ([.bookmarks, .git], .git),
            ([.git, .recentlyOpened], .recentlyOpened),
            ([.bookmarks, .searchAnywhere, .lspOutline], .lspOutline),
            ([.searchAnywhere, .claudeTimeline, .lspProblems, .recentlyOpened], .recentlyOpened),
            ([.bookmarks, .markdownOutline], .markdownOutline),
        ]
        for (shown, expected) in combos {
            XCTAssertEqual(
                SidebarSectionPlanner.fillTarget(
                    filesVisible: false, pluginsVisible: false,
                    accordion: visibility(shown: shown)),
                expected,
                "\(shown) → \(expected) fills")
        }
    }

    /// FILES visible → FILES is the designed fill; no accordion panel takes
    /// the role. Plugins below the accordion also disable it.
    func test_fillTarget_filesOrPlugins_disableAccordionFill() {
        XCTAssertNil(SidebarSectionPlanner.fillTarget(
            filesVisible: true, pluginsVisible: false,
            accordion: visibility(shown: [.git])))
        XCTAssertNil(SidebarSectionPlanner.fillTarget(
            filesVisible: false, pluginsVisible: true,
            accordion: visibility(shown: [.git, .bookmarks])))
    }

    /// No visible panels → nothing to fill.
    func test_fillTarget_emptyAccordion_isNil() {
        XCTAssertNil(SidebarSectionPlanner.fillTarget(
            filesVisible: false, pluginsVisible: false,
            accordion: visibility(shown: [])))
    }
}
