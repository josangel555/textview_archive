import Foundation

// Tab navigation (TSK-1110 SRP slice) — reorder the current/given tab and cycle
// selection next/previous. Thin forwarders to TabCoordinator + selectTab.
// Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    public func moveTab(from src: Int, to dst: Int) {
        tabCoordinator.move(from: src, to: dst)
        updateDerived()
    }

    public func moveCurrentTabLeft() {
        guard let i = tabs.selectedIndex else { return }
        tabCoordinator.swapWithPrevious(at: i)
        updateDerived()
    }

    public func moveCurrentTabRight() {
        guard let i = tabs.selectedIndex else { return }
        tabCoordinator.swapWithNext(at: i)
        updateDerived()
    }

    public func selectNextTab() {
        guard !tabs.isEmpty, let cur = tabs.selectedIndex else { return }
        let next = (cur + 1) % tabs.tabs.count
        selectTab(at: next)
    }

    public func selectPreviousTab() {
        guard !tabs.isEmpty, let cur = tabs.selectedIndex else { return }
        let prev = (cur - 1 + tabs.tabs.count) % tabs.tabs.count
        selectTab(at: prev)
    }
}
