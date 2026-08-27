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

    // MARK: pane reorder (owner audit 2026-08-27)

    /// UN-split, the store owns the order — a pane-side reorder must drive
    /// the store, or `mirrorSinglePane` silently REVERTS it on the next
    /// coordinator mutation (the strip drag looked applied, then a tab
    /// click snapped the order back).
    func test_reorderPaneTab_unsplit_persistsThroughSubsequentSelect() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b"), x = makeTab("c")
        c.append(a); c.append(b); c.append(x)

        // Move `a` (position 0) to the end: gap 3 in TabsState.move coords.
        c.reorderPaneTab(id: a.id, to: 3)
        XCTAssertEqual(c.paneAssignment.panes[0].tabIDs, [b.id, x.id, a.id])
        XCTAssertEqual(openIDs(c), [b.id, x.id, a.id], "the STORE order moved too")

        // The clobber trigger: any store mutation re-mirrors the pane.
        c.select(at: 0)
        XCTAssertEqual(c.paneAssignment.panes[0].tabIDs, [b.id, x.id, a.id],
            "the reorder must survive the next sync — not snap back")
    }

    /// Split: reorder stays inside the tab's pane; the flat store and the
    /// other pane are untouched.
    func test_reorderPaneTab_split_reordersWithinPaneOnly() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b"), x = makeTab("c")
        c.append(a); c.append(b); c.append(x)   // x selected
        c.splitFocusedPane(movingSelected: true) // pane1=[a,b], pane2=[x]
        c.select(at: 1)                          // select b (pane1)
        let storeBefore = openIDs(c)

        // Move b (position 1 in pane1) to the front: gap 0.
        c.reorderPaneTab(id: b.id, to: 0)
        XCTAssertEqual(c.paneAssignment.panes[0].tabIDs, [b.id, a.id])
        XCTAssertEqual(c.paneAssignment.panes[1].tabIDs, [x.id], "other pane untouched")
        XCTAssertEqual(openIDs(c), storeBefore,
            "while split the flat store order is deliberately untouched")
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

    // MARK: S4c — strip-drag reorder + focus cycling

    func test_reorderPaneTab_reordersTheOverlayOnly_storeOrderUntouched() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b"), x = makeTab("c")
        c.append(a); c.append(b); c.append(x)
        c.splitFocusedPane(movingSelected: true)   // pane0 [a, b] · pane1 [c]
        let storeOrder = openIDs(c)

        c.reorderPaneTab(id: b.id, to: 0)          // pane0 → [b, a]

        XCTAssertEqual(c.paneAssignment.panes[0].tabIDs, [b.id, a.id])
        XCTAssertEqual(openIDs(c), storeOrder,
                       "while split, each pane owns its order — the flat store keeps its own")
        XCTAssertEqual(c.selected?.id, x.id, "selection unaffected by a strip reorder")
        XCTAssertTrue(c.paneAssignment.isConsistent(against: openIDs(c)))
    }

    func test_focusNextPane_cyclesAndWraps_drivingTheAppSelection() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b")
        c.append(a); c.append(b)
        c.splitFocusedPane(movingSelected: true)   // focus pane1 (b)
        let p0 = c.paneAssignment.panes[0].id
        let p1 = c.paneAssignment.panes[1].id

        c.focusNextPane()
        XCTAssertEqual(c.paneAssignment.focusedPaneID, p0, "wraps past the end")
        XCTAssertEqual(c.selected?.id, a.id, "the pane's remembered tab becomes current")

        c.focusNextPane()
        XCTAssertEqual(c.paneAssignment.focusedPaneID, p1)
        XCTAssertEqual(c.selected?.id, b.id)
    }

    // Owner 2026-08-22: ⌃Tab/⌘] cycling must stay INSIDE the focused pane
    // while split (it walked the flat store order and hopped panes).
    func test_tabCycling_staysInsideTheFocusedPane_whileSplit() {
        let model = DocumentModel()
        let mk = { (n: String) in Tab(url: URL(fileURLWithPath: "/tmp/cyc/\(n)"),
                                      state: .empty, viewMode: .source) }
        let a = mk("a"), b = mk("b"), x = mk("c"), d = mk("d")
        model.tabCoordinator.append(a); model.tabCoordinator.append(b)
        model.tabCoordinator.append(x); model.tabCoordinator.append(d)
        // Tear d (selected) right → pane0 [a,b,c], pane1 [d] focused.
        model.tabCoordinator.splitFocusedPane(movingSelected: true)
        // Focus the LEFT pane on tab a.
        model.focusPane(id: model.tabCoordinator.paneAssignment.panes[0].id)
        XCTAssertEqual(model.tabs.selected?.id, a.id)

        model.selectNextTab()
        XCTAssertEqual(model.tabs.selected?.id, b.id)
        model.selectNextTab()
        XCTAssertEqual(model.tabs.selected?.id, x.id)
        model.selectNextTab()
        XCTAssertEqual(model.tabs.selected?.id, a.id,
                       "cycling WRAPS within the pane — it never hops to d in the other pane")
        model.selectPreviousTab()
        XCTAssertEqual(model.tabs.selected?.id, x.id)
        XCTAssertEqual(model.tabCoordinator.paneAssignment.focusedPane.id,
                       model.tabCoordinator.paneAssignment.panes[0].id,
                       "focus never leaves the pane during cycling")
    }

    func test_tabCycling_unsplit_keepsClassicStoreOrder() {
        let model = DocumentModel()
        let mk = { (n: String) in Tab(url: URL(fileURLWithPath: "/tmp/cyc2/\(n)"),
                                      state: .empty, viewMode: .source) }
        let a = mk("a"), b = mk("b")
        model.tabCoordinator.append(a); model.tabCoordinator.append(b)
        model.selectTab(at: 0)
        model.selectNextTab()
        XCTAssertEqual(model.tabs.selected?.id, b.id)
        model.selectNextTab()
        XCTAssertEqual(model.tabs.selected?.id, a.id, "wraps over the store order")
    }

    func test_focusNextPane_isANoOpWhileUnsplit() {
        let c = TabCoordinator()
        c.append(makeTab("solo.md"))
        let before = c.paneAssignment
        c.focusNextPane()
        XCTAssertEqual(c.paneAssignment, before)
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

    func test_paneLayout_persistsWeights_andLegacyStateRestoresEqualShares() {
        // CAPTURE: a resized split (left pane dragged wider).
        let c1 = TabCoordinator()
        c1.append(makeTab("a.md")); c1.append(makeTab("b.md"))
        c1.splitFocusedPane(movingSelected: true)
        c1.setPaneWeights([3, 1])
        guard let state = c1.paneLayoutSnapshot() else {
            return XCTFail("a split layout must capture")
        }
        XCTAssertEqual(state.weights, [3, 1])

        // RESTORE onto fresh ids: the sizes come back.
        let c2 = TabCoordinator()
        c2.append(makeTab("a.md")); c2.append(makeTab("b.md"))
        c2.applyPaneLayout(state)
        XCTAssertEqual(c2.paneAssignment.panes.map(\.weight), [3, 1])

        // A pre-S4d snapshot (weights nil) restores equal shares.
        let legacy = SessionSnapshot.PaneLayoutState(
            panes: state.panes, selected: state.selected,
            focusedIndex: state.focusedIndex, orientation: state.orientation)
        let c3 = TabCoordinator()
        c3.append(makeTab("a.md")); c3.append(makeTab("b.md"))
        c3.applyPaneLayout(legacy)
        XCTAssertEqual(c3.paneAssignment.panes.map(\.weight), [1, 1])
    }

    func test_paneLayoutSnapshot_isNilWhileUnsplit() {
        let c = TabCoordinator()
        c.append(makeTab("solo.md"))
        XCTAssertNil(c.paneLayoutSnapshot(),
                     "un-split persists nothing (byte-compatible snapshots)")
    }

    /// Owner bug 2026-08-26 — the session-switch façade-leak guard: a split
    /// coordinator collapses to ONE pane mirroring the store (order +
    /// selection) when the incoming session has no persisted pane layout.
    func test_resetPaneLayout_collapsesToSingleStorePane() {
        let c = TabCoordinator()
        let a = makeTab("a"), b = makeTab("b"), x = makeTab("c")
        c.append(a); c.append(b); c.append(x)
        c.splitFocusedPane(movingSelected: true)
        XCTAssertTrue(c.paneAssignment.isSplit)

        c.select(at: 1)
        c.resetPaneLayout()
        let pa = c.paneAssignment
        XCTAssertFalse(pa.isSplit)
        XCTAssertEqual(pa.panes.count, 1)
        XCTAssertEqual(pa.panes[0].tabIDs, openIDs(c),
                       "the single pane mirrors the store order")
        XCTAssertEqual(pa.focusedSelectedTabID, b.id,
                       "the store's selection survives the collapse")
        XCTAssertTrue(pa.isConsistent(against: openIDs(c)))
    }

    /// A degenerate persisted single-pane layout means "un-split" — applying
    /// it over a live split must collapse, exactly like the nil case.
    func test_applyPaneLayout_singlePaneState_collapsesALiveSplit() {
        let c = TabCoordinator()
        c.append(makeTab("a")); c.append(makeTab("b"))
        c.splitFocusedPane(movingSelected: true)
        XCTAssertTrue(c.paneAssignment.isSplit)

        let degenerate = SessionSnapshot.PaneLayoutState(
            panes: [["/tmp/panes/a"]], selected: ["/tmp/panes/a"],
            focusedIndex: 0, orientation: "horizontal")
        c.applyPaneLayout(degenerate)
        XCTAssertFalse(c.paneAssignment.isSplit,
                       "a 1-pane persisted layout must not leave the live split standing")
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
