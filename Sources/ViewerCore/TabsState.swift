import Foundation
import ViewerKit

/// Ordered list of open tabs plus the selected index. Pure data; mutation
/// happens through value-type mutating methods so logic is easy to unit-test.
public struct TabsState: Equatable, Sendable {
    public private(set) var tabs: [Tab]
    public private(set) var selectedIndex: Int?

    public init(tabs: [Tab] = [], selectedIndex: Int? = nil) {
        self.tabs = tabs
        if let i = selectedIndex, tabs.indices.contains(i) {
            self.selectedIndex = i
        } else if !tabs.isEmpty {
            self.selectedIndex = 0
        } else {
            self.selectedIndex = nil
        }
    }

    public var selected: Tab? {
        guard let i = selectedIndex, tabs.indices.contains(i) else { return nil }
        return tabs[i]
    }

    public var isEmpty: Bool { tabs.isEmpty }

    // MARK: Mutation

    /// Appends a tab and selects it.
    public mutating func append(_ tab: Tab) {
        tabs.append(tab)
        selectedIndex = tabs.count - 1
    }

    /// Removes the tab at `index`. Adjusts `selectedIndex` so the same tab
    /// (or its neighbor) stays selected after the removal:
    /// - closing a tab *before* the selected one: index shifts down by 1
    /// - closing the selected tab itself: select the tab to the right, or
    ///   the new last tab if we were already at the end
    /// - closing a tab *after* the selected one: selection unchanged
    /// Out-of-bounds indices are a no-op.
    public mutating func close(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        guard let cur = selectedIndex else { return }
        if tabs.isEmpty {
            selectedIndex = nil
        } else if index < cur {
            selectedIndex = cur - 1
        } else if index == cur {
            selectedIndex = min(cur, tabs.count - 1)
        }
        // index > cur → selectedIndex unchanged
    }

    public mutating func select(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
    }

    public mutating func move(from: Int, to: Int) {
        guard tabs.indices.contains(from), to >= 0, to <= tabs.count else { return }
        let movingSelected = (selectedIndex == from)
        let tab = tabs.remove(at: from)
        let insertAt = (from < to) ? (to - 1) : to
        let bounded = min(max(insertAt, 0), tabs.count)
        tabs.insert(tab, at: bounded)
        if movingSelected {
            selectedIndex = bounded
        } else if let cur = selectedIndex {
            // Adjust if the move shifted around our selection.
            var newCur = cur
            if from < cur { newCur -= 1 }
            if bounded <= newCur { newCur += 1 }
            selectedIndex = min(max(newCur, 0), tabs.count - 1)
        }
    }

    public mutating func replace(at index: Int, with tab: Tab) {
        guard tabs.indices.contains(index) else { return }
        tabs[index] = tab
    }

    /// If a tab already displays `url`, switch to it and return its index.
    /// Otherwise: if the currently-selected tab is blank (no URL, .empty state)
    /// reuse it; else append a new tab. Returns the resulting index.
    @discardableResult
    public mutating func openOrReveal(
        url: URL,
        state: DocumentState,
        viewMode: ViewMode
    ) -> Int {
        if let existing = tabs.firstIndex(where: { $0.url == url }) {
            tabs[existing] = Tab(
                id: tabs[existing].id,
                url: url,
                state: state,
                viewMode: tabs[existing].viewMode
            )
            selectedIndex = existing
            return existing
        }
        if let cur = selectedIndex, tabs.indices.contains(cur), tabs[cur].isBlank {
            tabs[cur] = Tab(id: tabs[cur].id, url: url, state: state, viewMode: viewMode)
            return cur
        }
        let tab = Tab(url: url, state: state, viewMode: viewMode)
        tabs.append(tab)
        selectedIndex = tabs.count - 1
        return tabs.count - 1
    }
}
