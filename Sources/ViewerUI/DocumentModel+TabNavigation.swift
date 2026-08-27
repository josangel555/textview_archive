import Foundation

// Tab navigation (TSK-1110 SRP slice) — reorder the current/given tab and cycle
// selection next/previous. Thin forwarders to TabCoordinator + selectTab.
// Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    public func moveTab(from src: Int, to dst: Int) {
        tabCoordinator.move(from: src, to: dst)
        updateDerived()
    }

    /// PANE-SCOPED (owner audit 2026-08-27): Move Tab Left/Right walks the
    /// current tab's PANE-STRIP order — the flat-store swap was invisible
    /// (or cross-pane) while split, because each pane owns its strip order.
    /// Un-split, the single pane mirrors the store, so the gap coordinates
    /// are identical to the old swap — no special case.
    public func moveCurrentTabLeft() {
        guard let selID = tabs.selected?.id,
              let pane = tabCoordinator.paneAssignment.pane(containing: selID),
              let pos = pane.tabIDs.firstIndex(of: selID), pos > 0 else { return }
        tabCoordinator.reorderPaneTab(id: selID, to: pos - 1)
        updateDerived()
    }

    public func moveCurrentTabRight() {
        guard let selID = tabs.selected?.id,
              let pane = tabCoordinator.paneAssignment.pane(containing: selID),
              let pos = pane.tabIDs.firstIndex(of: selID),
              pos < pane.tabIDs.count - 1 else { return }
        tabCoordinator.reorderPaneTab(id: selID, to: pos + 2)
        updateDerived()
    }

    public func selectNextTab() { cycleTab(direction: 1) }

    public func selectPreviousTab() { cycleTab(direction: -1) }

    /// Owner 2026-08-22 ("tab switching in a split view … also includes
    /// tabs in the right pane"): ⌃Tab/⌘] used to walk the FLAT store
    /// order, which interleaves panes after cross-pane moves — cycling in
    /// the left pane hopped into the right pane's tabs (and yanked focus
    /// with it). While SPLIT, cycle within the FOCUSED PANE's own strip
    /// order — VS Code group semantics; un-split keeps the classic
    /// store-order cycle byte-for-byte.
    private func cycleTab(direction: Int) {
        guard !tabs.isEmpty else { return }
        let a = tabCoordinator.paneAssignment
        if a.isSplit {
            let pane = a.focusedPane
            let ids = pane.tabIDs
            guard !ids.isEmpty else { return }
            let cur = pane.selectedTabID.flatMap { ids.firstIndex(of: $0) } ?? 0
            let n = ids.count
            let nextID = ids[((cur + direction) % n + n) % n]
            if let idx = tabs.tabs.firstIndex(where: { $0.id == nextID }) {
                selectTab(at: idx)
            }
            return
        }
        guard let cur = tabs.selectedIndex else { return }
        let n = tabs.tabs.count
        selectTab(at: ((cur + direction) % n + n) % n)
    }
}
