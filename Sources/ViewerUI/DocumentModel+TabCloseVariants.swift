import Foundation

// Tab close-variants (TSK-1110 SRP slice) — the menu/context close commands
// (close current, close others, close to the right). Each runs the dirty-prompt
// loop then delegates the actual removal to TabCoordinator + the shared
// confirmCloseIfDirty / settleSelectionAfterClose / purgeCaches helpers (which
// stay on DocumentModel — also used by the core closeTab path). Behavior-
// preserving move out of DocumentModel.swift.
extension DocumentModel {

    public func closeCurrentTab() {
        if let i = tabs.selectedIndex {
            closeTab(at: i)
        }
    }

    /// PANE-SCOPED (owner 2026-08-27): "Close Other Tabs" closes the other
    /// tabs OF THE KEPT TAB'S PANE — a split's other panes are untouched.
    /// Un-split, the single pane holds every tab, so the classic behavior
    /// is unchanged (no special case).
    public func closeOtherTabs(keeping index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        let keepID = tabs.tabs[index].id
        let paneIDs = tabCoordinator.paneAssignment.pane(containing: keepID)?.tabIDs
            ?? tabs.tabs.map(\.id)
        closeTabs(withIDs: Set(paneIDs.filter { $0 != keepID }), keeping: keepID)
    }

    /// PANE-SCOPED (owner 2026-08-27): "to the right" means the kept tab's
    /// PANE-STRIP order — the flat store order interleaves panes in a split,
    /// which closed tabs the user couldn't even see to the right.
    public func closeTabsToRight(of index: Int) {
        // Bounds-check up front: a stale gesture (menu/script verb firing
        // after the tab vanished from another path) can hand us an
        // out-of-range index.
        guard tabs.tabs.indices.contains(index) else { return }
        let keepID = tabs.tabs[index].id
        let paneIDs = tabCoordinator.paneAssignment.pane(containing: keepID)?.tabIDs
            ?? tabs.tabs.map(\.id)
        guard let pos = paneIDs.firstIndex(of: keepID) else { return }
        closeTabs(withIDs: Set(paneIDs.suffix(from: pos + 1)), keeping: keepID)
    }

    /// Shared close pipeline over an arbitrary doomed-id set: dirty-prompt
    /// loop (cancel aborts the remainder), Recently-Closed recording, cache
    /// purge, coordinator batch close, selection settle. If the store's
    /// selected tab was among the doomed, selection lands on `keeping` via
    /// the full `selectTab` pipeline (FileNav/watcher/footer follow — the
    /// coordinator-select-is-not-a-selection lesson).
    private func closeTabs(withIDs doomedIDs: Set<UUID>, keeping keepID: UUID) {
        guard !doomedIDs.isEmpty else { return }
        // Prompt-then-act for every dirty doomed tab, descending store order
        // so a mid-batch Cancel leaves a sensible remainder.
        let doomedDirty = tabs.tabs.enumerated()
            .filter { doomedIDs.contains($0.element.id) && $0.element.isDirty }
            .map(\.offset)
            .sorted(by: >)
        for i in doomedDirty {
            switch confirmCloseIfDirty(at: i) {
            case .none: break
            case .discard: hexDirtyBytes.removeValue(forKey: tabs.tabs[i].id)
            case .save:
                if isHexDirtyTab(at: i) {
                    if !saveHexEdits(forTabID: tabs.tabs[i].id) { return }
                } else if !saveEditor(forTabID: tabs.tabs[i].id) { return }
            case .cancel:
                return
            }
        }
        // Snapshot doomed URLs *before* the coordinator mutates `tabs`, so
        // the non-coordinator cache purge has the right URLs.
        let doomedURLsByID: [UUID: URL?] = Dictionary(
            uniqueKeysWithValues: tabs.tabs
                .filter { doomedIDs.contains($0.id) }
                .map { ($0.id, $0.url) }
        )
        let selectionWasDoomed = tabs.selected.map { doomedIDs.contains($0.id) } ?? false
        // Recently Closed (⇧⌘T) — record BEFORE the mutation, oldest-first
        // so ⇧⌘T walks back right-to-left, matching browsers.
        for i in tabs.tabs.indices where doomedIDs.contains(tabs.tabs[i].id) {
            noteTabClosed(at: i)
        }
        let closedIDs = tabCoordinator.closeTabs(ids: doomedIDs)
        for id in closedIDs {
            purgeCaches(forURL: doomedURLsByID[id] ?? nil, tabID: id)
        }
        settleSelectionAfterClose()
        if selectionWasDoomed,
           let keepIndex = tabs.tabs.firstIndex(where: { $0.id == keepID }) {
            selectTab(at: keepIndex)
        }
        updateDerived()
        startWatchingCurrentFile()
    }
}
