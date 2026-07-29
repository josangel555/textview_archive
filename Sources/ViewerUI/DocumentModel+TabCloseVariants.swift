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

    public func closeOtherTabs(keeping index: Int) {
        let keepID = tabs.tabs.indices.contains(index) ? tabs.tabs[index].id : nil
        // Prompt-then-act for every dirty tab that's about to vanish.
        // We process indices in descending order so the user can cancel
        // mid-batch and what's left of the close still makes sense.
        let doomed = tabs.tabs.enumerated()
            .filter { $0.element.id != keepID && $0.element.isDirty }
            .map { $0.offset }
            .sorted(by: >)
        for i in doomed {
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
        // Snapshot doomed tabs' URLs *before* the coordinator mutates
        // `tabs`, so the non-coordinator cache purge has the right
        // URLs to pass.
        let doomedURLsByID: [UUID: URL?] = Dictionary(
            uniqueKeysWithValues: tabs.tabs
                .filter { $0.id != keepID }
                .map { ($0.id, $0.url) }
        )
        // Recently Closed (⇧⌘T) — record BEFORE the coordinator mutates
        // `tabs`. Oldest-first so the leftmost tab ends up deepest in the
        // stack and ⇧⌘T walks back right-to-left, matching browsers.
        for i in tabs.tabs.indices where tabs.tabs[i].id != keepID {
            noteTabClosed(at: i)
        }
        let closedIDs = tabCoordinator.closeOtherTabs(keeping: index)
        for id in closedIDs {
            purgeCaches(forURL: doomedURLsByID[id] ?? nil, tabID: id)
        }
        settleSelectionAfterClose()
        updateDerived()
        startWatchingCurrentFile()
    }

    public func closeTabsToRight(of index: Int) {
        // Same dirty-prompt loop as closeOtherTabs. Process the
        // doomed tabs from right-to-left so a Cancel partway through
        // leaves a contiguous tail intact (rather than holes).
        // Bounds-check up front: a stale gesture (menu/script verb
        // firing after the tab vanished from another path) can hand
        // us an out-of-range index, and the `(index+1)..<count`
        // range construction below would trap before the coordinator
        // ever runs.
        guard index >= 0, index < tabs.tabs.count else { return }
        let toClose = (index + 1)..<tabs.tabs.count
        let doomedDirty = toClose.reversed().filter { tabs.tabs[$0].isDirty }
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
        let doomedURLsByID: [UUID: URL?] = Dictionary(
            uniqueKeysWithValues: tabs.tabs
                .suffix(from: index + 1)
                .map { ($0.id, $0.url) }
        )
        // Recently Closed (⇧⌘T) — record BEFORE the mutation, left-to-right
        // so ⇧⌘T brings them back right-to-left.
        for i in (index + 1)..<tabs.tabs.count {
            noteTabClosed(at: i)
        }
        let closedIDs = tabCoordinator.closeTabsToRight(of: index)
        for id in closedIDs {
            purgeCaches(forURL: doomedURLsByID[id] ?? nil, tabID: id)
        }
        settleSelectionAfterClose()
        updateDerived()
        startWatchingCurrentFile()
    }
}
