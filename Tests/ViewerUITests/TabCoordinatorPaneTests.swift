import XCTest
import ViewerCore
@testable import ViewerUI

/// Editor panes S2 (I-21) — the coordinator wiring: `paneAssignment` stays
/// reconciled with the flat tab store through every mutation primitive, the
/// single-pane world mirrors the store byte-for-byte (pre-panes behavior
/// unchanged), and the pane verbs drive the app-wide selection through the
/// focused pane.
@MainActor
final class TabCoordinatorPaneTests: XCTestCase {

    private func makeTab(_ name: String) -> Tab {
        Tab(url: URL(fileURLWithPath: "/tmp/panes/\(name)"),
            state: .empty, viewMode: .source)
    }

    private func openIDs(_ c: TabCoordinator) -> [UUID] { c.tabs.tabs.map(\.id) }

    // MARK: single-pane lockstep (the pre-panes world)

    func test_singlePane_mirrorsStore_throughOpenSelectCloseAndReorder() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b"), x = makeTab("c")
        c.append(a); c.append(b); c.append(x)
        XCTAssertEqual(c.paneAssignment.panes.count, 1)
        XCTAssertEqual(c.paneAssignment.panes[0].tabIDs, openIDs(c))
        XCTAssertEqual(c.paneAssignment.focusedSelectedTabID, x.id, "append selects")

        c.select(at: 0)
        XCTAssertEqual(c.paneAssignment.focusedSelectedTabID, a.id)

        c.move(from: 0, to: 2)
        XCTAssertEqual(c.paneAssignment.panes[0].tabIDs, openIDs(c),
                       "un-split, the pane order IS the store order")

        _ = c.closeTab(at: 0)
        XCTAssertEqual(c.paneAssignment.panes[0].tabIDs, openIDs(c))
        XCTAssertTrue(c.paneAssignment.isConsistent(against: openIDs(c)))
    }

    // MARK: split + focus semantics

    func test_splitMovingSelected_tearsTheCurrentTabRight_selectionIntact() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b")
        c.append(a); c.append(b)          // b selected

        c.splitFocusedPane(movingSelected: true)

        XCTAssertTrue(c.paneAssignment.isSplit)
        XCTAssertEqual(c.paneAssignment.panes[1].tabIDs, [b.id])
        XCTAssertEqual(c.paneAssignment.focusedPane.id, c.paneAssignment.panes[1].id)
        XCTAssertEqual(c.selected?.id, b.id, "the same tab stays current")
        XCTAssertTrue(c.paneAssignment.isConsistent(against: openIDs(c)))
    }

    func test_focusPane_switchesTheAppWideSelection_toThatPanesMemory() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b")
        c.append(a); c.append(b)
        c.splitFocusedPane(movingSelected: true)   // b in pane 1 (focused)
        let left = c.paneAssignment.panes[0].id

        c.focusPane(id: left)

        XCTAssertEqual(c.paneAssignment.focusedPane.id, left)
        XCTAssertEqual(c.selected?.id, a.id,
                       "focusing a pane makes ITS remembered tab current")
    }

    func test_openWhileSplit_joinsTheFocusedPane() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b")
        c.append(a); c.append(b)
        c.splitFocusedPane(movingSelected: true)   // focus = right pane
        let x = makeTab("c")
        c.append(x)
        XCTAssertEqual(c.paneAssignment.pane(containing: x.id)?.id,
                       c.paneAssignment.panes[1].id,
                       "a new tab opens in the focused pane")
        XCTAssertEqual(c.selected?.id, x.id)
        XCTAssertTrue(c.paneAssignment.isConsistent(against: openIDs(c)))
    }

    func test_selectingAnotherPanesTab_focusesItsPane() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b")
        c.append(a); c.append(b)
        c.splitFocusedPane(movingSelected: true)   // focus right (b)
        // The store selects a (e.g. openOrReveal of an already-open file).
        c.select(at: 0)
        XCTAssertEqual(c.paneAssignment.focusedPane.id, c.paneAssignment.panes[0].id,
                       "revealing a tab focuses the pane that hosts it")
    }

    func test_movePaneTab_landsFocusedAndSelectedAtTheDestination() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b")
        c.append(a); c.append(b)
        c.splitFocusedPane(movingSelected: true)
        let left = c.paneAssignment.panes[0].id

        c.movePaneTab(id: b.id, toPane: left)

        XCTAssertEqual(c.paneAssignment.pane(containing: b.id)?.id, left)
        XCTAssertEqual(c.paneAssignment.focusedPane.id, left)
        XCTAssertEqual(c.selected?.id, b.id)
        XCTAssertTrue(c.paneAssignment.isConsistent(against: openIDs(c)))
    }

    func test_closePane_absorbsAndReselects() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b")
        c.append(a); c.append(b)
        c.splitFocusedPane(movingSelected: true)
        let right = c.paneAssignment.panes[1].id

        c.closePane(id: right)

        XCTAssertFalse(c.paneAssignment.isSplit)
        XCTAssertEqual(Set(c.paneAssignment.panes[0].tabIDs), Set(openIDs(c)),
                       "the pane's tabs were absorbed, not closed")
        XCTAssertNotNil(c.selected)
        XCTAssertTrue(c.paneAssignment.isConsistent(against: openIDs(c)))
    }

    func test_closingTheFocusedPanesLastTab_keepsTheOverlayConsistent() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b")
        c.append(a); c.append(b)
        c.splitFocusedPane(movingSelected: true)   // right pane = [b], focused
        if let idx = c.tabs.tabs.firstIndex(where: { $0.id == b.id }) {
            _ = c.closeTab(at: idx)
        }
        XCTAssertNil(c.paneAssignment.pane(containing: b.id))
        XCTAssertTrue(c.paneAssignment.isConsistent(against: openIDs(c)))
    }

    // MARK: bulk paths (session drain shape)

    func test_closeOthersThenAppends_staysConsistent() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b"), x = makeTab("c")
        c.append(a); c.append(b); c.append(x)
        c.splitFocusedPane(movingSelected: true)
        _ = c.closeOtherTabs(keeping: 0)
        let d = makeTab("d")
        c.append(d)
        XCTAssertTrue(c.paneAssignment.isConsistent(against: openIDs(c)))
    }
}
