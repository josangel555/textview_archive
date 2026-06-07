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

    /// Swap the tab at `index` with its left neighbor. No-op at index 0.
    public mutating func swapWithPrevious(at index: Int) {
        guard tabs.indices.contains(index), index > 0 else { return }
        move(from: index, to: index - 1)
    }

    /// Swap the tab at `index` with its right neighbor. No-op at last index.
    /// (Internally, "move right by one" requires `to = index + 2` because
    /// `move` interprets `to` as the destination index in the post-removal
    /// list. Callers express intent here so they don't have to know that.)
    public mutating func swapWithNext(at index: Int) {
        guard tabs.indices.contains(index), index < tabs.count - 1 else { return }
        move(from: index, to: index + 2)
    }

    /// Keeps only the tab at `index`; everything else is removed.
    public mutating func closeAll(except index: Int) {
        guard tabs.indices.contains(index) else { return }
        let keep = tabs[index]
        tabs = [keep]
        selectedIndex = 0
    }

    /// Removes every tab whose index is greater than `index`.
    public mutating func closeAllToRight(of index: Int) {
        guard tabs.indices.contains(index) else { return }
        if tabs.count <= index + 1 { return }
        tabs = Array(tabs.prefix(index + 1))
        if let cur = selectedIndex, cur >= tabs.count {
            selectedIndex = tabs.count - 1
        }
    }

    /// Normalize a file URL for tab-dedup comparison: standardize and resolve
    /// symlinks so the macOS `/var`→`/private/var` symlink (and trailing-slash /
    /// percent-encoding differences) don't defeat the dedup and spawn a second
    /// tab for the same on-disk file. This matches the session-level dedup
    /// policy (`SessionsCoordinator.openFolder` resolves symlinks) and the
    /// resolved path `appendLazyTab` stores on restored tabs — closing the
    /// asymmetry that produced "close with 1 tab → reopen shows 2 tabs".
    ///
    /// `public` so the UI-layer restore path (`DocumentModel.appendLazyTab`)
    /// and the snapshot writer can apply the SAME normalized-key dedup the
    /// eager `openOrReveal` path uses. Restore previously appended every
    /// persisted tab unconditionally, so a duplicated persisted entry — or a
    /// snapshot that had already accumulated dupes across launches — spawned a
    /// fresh tab each time, and `makeSnapshot()` faithfully re-persisted the
    /// bloat: a one-way ratchet that grew an active session to ~2000 tabs of
    /// ~35 unique files and ballooned launch footprint to ~1 GB. See
    /// `TabsState.dedupedRestoreTabs(_:)`.
    public static func dedupKey(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Defensive ceiling on how many tabs a single session may restore.
    /// Even after the dedup fix below makes duplicate-accumulation
    /// impossible, a legitimately enormous (or maliciously crafted)
    /// persisted snapshot must not be able to allocate unbounded per-tab
    /// state at launch. 200 distinct open files is already far past any
    /// realistic working set; beyond it we keep the most-recent entries
    /// (the tail of the persisted list, nearest the user's last focus).
    public static let maxRestoredTabs = 200

    /// Pure restore-time dedup + cap. Given the persisted `(path, viewMode)`
    /// pairs in on-disk order, returns the surviving pairs with:
    ///   1. duplicates collapsed by normalized `dedupKey` (FIRST occurrence
    ///      wins, preserving on-disk order), and
    ///   2. the result clamped to the last `maxRestoredTabs` entries.
    ///
    /// Lives here (pure value logic, no FileManager / no `@MainActor`) so it
    /// is unit-testable in `ViewerCoreTests` without launching the app. The
    /// caller still applies its own `fileExists` filter — this only fixes the
    /// duplicate-ratchet and the unbounded-count blow-up.
    public static func dedupedRestoreTabs(
        _ tabs: [(path: String, viewMode: String)]
    ) -> [(path: String, viewMode: String)] {
        var seen = Set<String>()
        var out: [(path: String, viewMode: String)] = []
        out.reserveCapacity(min(tabs.count, maxRestoredTabs))
        for t in tabs {
            let key = dedupKey(URL(fileURLWithPath: t.path)).path
            if seen.insert(key).inserted {
                out.append(t)
            }
        }
        if out.count > maxRestoredTabs {
            out = Array(out.suffix(maxRestoredTabs))
        }
        return out
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
        let key = TabsState.dedupKey(url)
        if let existing = tabs.firstIndex(where: { $0.url.map(TabsState.dedupKey) == key }) {
            // For an already-materialized tab (state != .empty) we
            // preserve the user's current viewMode — they may have
            // switched it deliberately (e.g. Source for an .md file).
            // For a lazy/unmaterialized tab (state == .empty, typically
            // workspace-restored), the carried viewMode is stale: it
            // was the mode at last close, not a current preference.
            // Use the new computed mode so e.g. a restored markdown
            // tab opens in .rendered, not stale .source.
            let isLazy: Bool
            if case .empty = tabs[existing].state { isLazy = true } else { isLazy = false }
            let modeToUse = isLazy ? viewMode : tabs[existing].viewMode
            // Preserve the dirty flag: rebuilding the Tab here must not
            // silently discard unsaved-editor state. Dropping it made the
            // tab look clean, so a later close skipped the
            // unsaved-changes prompt → data loss (CORR-1).
            tabs[existing] = Tab(
                id: tabs[existing].id,
                url: url,
                state: state,
                viewMode: modeToUse,
                isDirty: tabs[existing].isDirty,
                // UX-K (#231): preserve the persisted per-file scroll on a
                // reveal so e.g. clicking a restored lazy tab in the sidebar
                // (which routes through here) doesn't drop the scroll line
                // before `restoreScroll` can re-apply it.
                scrollTopLine: tabs[existing].scrollTopLine
            )
            selectedIndex = existing
            return existing
        }
        if let cur = selectedIndex, tabs.indices.contains(cur), tabs[cur].isBlank {
            // A blank tab is by definition never dirty (it has no buffer),
            // but carry the flag through explicitly so the invariant is
            // local to this call site rather than an implicit default.
            tabs[cur] = Tab(
                id: tabs[cur].id,
                url: url,
                state: state,
                viewMode: viewMode,
                isDirty: tabs[cur].isDirty
            )
            return cur
        }
        let tab = Tab(url: url, state: state, viewMode: viewMode)
        tabs.append(tab)
        selectedIndex = tabs.count - 1
        return tabs.count - 1
    }

    // MARK: Preview tab (TSK-306 / TSK-272 — see docs/PREVIEW_TAB_DESIGN.md)

    /// id of the single ephemeral preview tab, if one exists.
    public var previewTabID: UUID? { tabs.first(where: { $0.isPreview })?.id }

    /// Open `url` in the ONE ephemeral preview slot (VSCode-style):
    /// - If `url` is already open in ANY tab → reveal it via `openOrReveal`
    ///   (never preview a file that already has a real tab).
    /// - Else if a preview tab already exists → replace its content in place
    ///   (same tab id), keeping it flagged preview.
    /// - Else reuse a blank selected tab, or append a fresh preview tab.
    ///
    /// Invariant: at most one tab is ever `isPreview`. Selecting/returning
    /// the resulting index mirrors `openOrReveal`.
    @discardableResult
    public mutating func openPreview(
        url: URL,
        state: DocumentState,
        viewMode: ViewMode
    ) -> Int {
        let key = TabsState.dedupKey(url)
        if tabs.contains(where: { $0.url.map(TabsState.dedupKey) == key }) {
            // Already open somewhere — reveal it (and re-materialize a lazy
            // tab) through the shared path; don't create a preview.
            return openOrReveal(url: url, state: state, viewMode: viewMode)
        }
        if let p = tabs.firstIndex(where: { $0.isPreview }) {
            tabs[p] = Tab(
                id: tabs[p].id,
                url: url,
                state: state,
                viewMode: viewMode,
                isPreview: true
            )
            selectedIndex = p
            return p
        }
        if let cur = selectedIndex, tabs.indices.contains(cur), tabs[cur].isBlank {
            tabs[cur] = Tab(
                id: tabs[cur].id,
                url: url,
                state: state,
                viewMode: viewMode,
                isPreview: true
            )
            selectedIndex = cur
            return cur
        }
        tabs.append(Tab(url: url, state: state, viewMode: viewMode, isPreview: true))
        selectedIndex = tabs.count - 1
        return tabs.count - 1
    }

    /// Promote the tab with `id` from preview → permanent ("pin"). No-op if
    /// `id` isn't a tab or isn't a preview. Idempotent.
    public mutating func promoteTab(id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].isPreview else { return }
        tabs[i].isPreview = false
    }
}
