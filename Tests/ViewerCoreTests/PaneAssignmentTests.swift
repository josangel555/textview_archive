import Foundation
import Testing
import ViewerCore

/// Editor panes S1 (owner 2026-08-11) — the pure overlay model: panes are
/// order+selection over the single flat tab store; every operation keeps
/// the invariants (each open tab in exactly one pane, ≥1 pane, focused
/// valid, selections valid) that `isConsistent(against:)` checks.
@Suite struct PaneAssignmentTests {

    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func single() -> PaneAssignment {
        PaneAssignment(tabIDs: [a, b, c], selectedTabID: b)
    }

    @Test func singlePane_isThePrePanesWorld() {
        let p = single()
        #expect(!p.isSplit)
        #expect(p.focusedSelectedTabID == b)
        #expect(p.isConsistent(against: [a, b, c]))
    }

    @Test func splitMovingATab_tearsItIntoTheNewFocusedPane() {
        var p = single()
        p.splitFocusedPane(moving: b)
        #expect(p.isSplit)
        #expect(p.panes.count == 2)
        #expect(p.panes[0].tabIDs == [a, c])
        #expect(p.panes[0].selectedTabID == a, "the source pane settles its selection")
        #expect(p.panes[1].tabIDs == [b])
        #expect(p.focusedPaneID == p.panes[1].id, "the new pane takes focus")
        #expect(p.focusedSelectedTabID == b)
        #expect(p.isConsistent(against: [a, b, c]))
    }

    @Test func splitEmpty_makesAFocusedEmptyPane() {
        var p = single()
        p.splitFocusedPane()
        #expect(p.panes[1].tabIDs.isEmpty)
        #expect(p.focusedPane.id == p.panes[1].id)
        #expect(p.focusedSelectedTabID == nil)
        #expect(p.isConsistent(against: [a, b, c]))
    }

    @Test func closePane_absorbsTabsIntoTheNeighbor_neverClosesTabs() {
        var p = single()
        p.splitFocusedPane(moving: b)
        let newPaneID = p.panes[1].id
        p.closePane(id: newPaneID)
        #expect(p.panes.count == 1)
        #expect(Set(p.panes[0].tabIDs) == Set([a, b, c]), "the tab came back, not closed")
        #expect(p.focusedPaneID == p.panes[0].id)
        #expect(p.isConsistent(against: [a, b, c]))
    }

    @Test func closeTheLastPane_isRefused() {
        var p = single()
        let id = p.panes[0].id
        p.closePane(id: id)
        #expect(p.panes.count == 1, "the last pane can never close")
    }

    @Test func selectTab_focusesItsPane() {
        var p = single()
        p.splitFocusedPane(moving: b)      // focus on the new pane
        p.selectTab(id: a)                 // a lives in pane 0
        #expect(p.focusedPaneID == p.panes[0].id, "selecting focuses the tab's pane")
        #expect(p.focusedSelectedTabID == a)
    }

    @Test func moveTab_betweenPanes_selectsAtTheDestination() {
        var p = single()
        p.splitFocusedPane(moving: b)
        let dest = p.panes[1].id
        p.moveTab(id: a, toPane: dest, at: 0)
        #expect(p.panes[0].tabIDs == [c])
        #expect(p.panes[1].tabIDs == [a, b])
        #expect(p.panes[1].selectedTabID == a, "a moved tab shows at its destination")
        #expect(p.isConsistent(against: [a, b, c]))
    }

    @Test func didOpen_joinsTheFocusedPane_andSelects() {
        var p = single()
        p.splitFocusedPane()               // focused empty pane
        p.didOpenTab(id: d)
        #expect(p.focusedPane.tabIDs == [d])
        #expect(p.focusedSelectedTabID == d)
        #expect(p.isConsistent(against: [a, b, c, d]))
    }

    @Test func didClose_dropsEverywhere_andSettlesSelectionToNeighbor() {
        var p = single()                   // selection b (index 1)
        p.didCloseTab(id: b)
        #expect(p.panes[0].tabIDs == [a, c])
        #expect(p.panes[0].selectedTabID == c,
                "the neighbor at the closed slot takes over (TabsState.remove parity)")
        #expect(p.isConsistent(against: [a, c]))
    }

    @Test func emptyPaneSurvivesItsLastTabClosing() {
        var p = single()
        p.splitFocusedPane(moving: b)
        p.didCloseTab(id: b)
        #expect(p.panes.count == 2, "panes close explicitly, not by emptying")
        #expect(p.panes[1].tabIDs.isEmpty)
        #expect(p.isConsistent(against: [a, c]))
    }

    // MARK: normalization — the safety net

    @Test func normalized_dropsUnknown_adoptsUnseen_repairsSelection() {
        var p = single()
        p.splitFocusedPane(moving: b)
        // The store closed `c` behind the overlay's back and opened `d`.
        let fixed = p.normalized(against: [a, b, d])
        #expect(fixed.isConsistent(against: [a, b, d]))
        #expect(fixed.pane(containing: c) == nil)
        #expect(fixed.pane(containing: d)?.id == fixed.focusedPaneID,
                "an unseen (just-opened) tab joins the focused pane")
    }

    @Test func normalized_neverEndsUpPaneless() {
        let p = PaneAssignment(tabIDs: [a])
        let fixed = p.normalized(against: [])
        #expect(fixed.panes.count >= 1)
        #expect(fixed.isConsistent(against: []))
    }

    @Test func orientation_firstSplitPicksAxis_laterSplitsKeepIt_resetOnUnsplit() {
        var p = single()
        p.splitFocusedPane(moving: b, direction: .vertical)
        #expect(p.orientation == .vertical, "the first split picks the axis")
        p.splitFocusedPane(direction: .horizontal)
        #expect(p.orientation == .vertical,
                "an already-split run keeps its axis (single-axis v1)")
        // Close back down to one pane: the axis resets for a fresh choice.
        while p.panes.count > 1 { p.closePane(id: p.panes[1].id) }
        #expect(p.orientation == .horizontal)
        #expect(p.isConsistent(against: [a, b, c]))
    }

    @Test func manySplits_haveNoModelCap() {
        var p = single()
        for _ in 0..<7 { p.splitFocusedPane() }
        #expect(p.panes.count == 8, "splits are unbounded in the model")
        #expect(p.isConsistent(against: [a, b, c]))
    }

    @Test func codableRoundTrip() throws {
        var p = single()
        p.splitFocusedPane(moving: b)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(PaneAssignment.self, from: data)
        #expect(back == p, "the session snapshot can persist the layout verbatim")
    }
}
