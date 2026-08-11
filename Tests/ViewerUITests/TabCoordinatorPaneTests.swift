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

    // MARK: S4b — persistence round-trip (split, close, reopen ⇒ splits back)

    func test_paneLayout_capturesByPath_andRestoresOntoFreshTabIDs() {
        // CAPTURE: a split coordinator with real paths.
        let c1 = TabCoordinator()
        let a1 = makeTab("keep.md"), b1 = makeTab("torn.md")
        c1.append(a1); c1.append(b1)
        c1.splitFocusedPane(movingSelected: true, direction: .vertical)
        guard let state = c1.paneLayoutSnapshot() else {
            return XCTFail("a split layout must capture")
        }
        XCTAssertEqual(state.panes, [["/tmp/panes/keep.md"], ["/tmp/panes/torn.md"]])
        XCTAssertEqual(state.focusedIndex, 1)
        XCTAssertEqual(state.orientation, "vertical")

        // RESTORE: a FRESH coordinator (session reopen) — new tab UUIDs,
        // same paths, the layout comes back.
        let c2 = TabCoordinator()
        let a2 = makeTab("keep.md"), b2 = makeTab("torn.md")
        c2.append(a2); c2.append(b2)
        c2.applyPaneLayout(state)

        XCTAssertTrue(c2.paneAssignment.isSplit, "reopen ⇒ still split")
        XCTAssertEqual(c2.paneAssignment.orientation, .vertical)
        XCTAssertEqual(c2.paneAssignment.panes[0].tabIDs, [a2.id])
        XCTAssertEqual(c2.paneAssignment.panes[1].tabIDs, [b2.id])
        XCTAssertEqual(c2.paneAssignment.focusedPane.id, c2.paneAssignment.panes[1].id)
        XCTAssertEqual(c2.selected?.id, b2.id,
                       "the focused pane's remembered tab is current again")
        XCTAssertTrue(c2.paneAssignment.isConsistent(against: openIDs(c2)))
    }

    func test_applyPaneLayout_missingFilesDrop_extraTabsAdopt() {
        let c = TabCoordinator()
        let a = makeTab("keep.md"), extra = makeTab("new-since-capture.md")
        c.append(a); c.append(extra)
        // Persisted: keep.md in pane 0, a since-deleted file in pane 1.
        let state = SessionSnapshot.PaneLayoutState(
            panes: [["/tmp/panes/keep.md"], ["/tmp/panes/deleted.md"]],
            selected: ["/tmp/panes/keep.md", "/tmp/panes/deleted.md"],
            focusedIndex: 0, orientation: "horizontal")
        c.applyPaneLayout(state)
        XCTAssertTrue(c.paneAssignment.isConsistent(against: openIDs(c)),
                      "missing files drop; the unassigned tab adopts into the focused pane")
        XCTAssertEqual(c.paneAssignment.pane(containing: extra.id)?.id,
                       c.paneAssignment.focusedPaneID)
    }

    func test_paneLayoutSnapshot_isNilWhileUnsplit() {
        let c = TabCoordinator()
        c.append(makeTab("solo.md"))
        XCTAssertNil(c.paneLayoutSnapshot(),
                     "un-split persists nothing (byte-compatible snapshots)")
    }

    func test_paneLayoutState_codable_andLegacyDecode() throws {
        let state = SessionSnapshot.PaneLayoutState(
            panes: [["/a.md"], ["/b.md"]], selected: ["/a.md", "/b.md"],
            focusedIndex: 1, orientation: "vertical")
        let snap = SessionSnapshot(
            id: UUID(), displayName: "s", createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: nil, paneLayout: state)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(back.paneLayout, state)
        // A pre-panes snapshot (no key) decodes with nil — downgrade-safe.
        let legacy = try JSONDecoder().decode(SessionSnapshot.self, from: Data("""
            {"schemaVersion": 2, "savedAt": 0, "id": "\(UUID().uuidString)",
             "displayName": "old", "createdAt": 0, "lastActiveAt": 0,
             "openTabs": []}
            """.utf8))
        XCTAssertNil(legacy.paneLayout)
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
