import Foundation

/// EDITOR PANES (owner 2026-08-11): "split the window into panes and have a
/// different set of tabs open in each" — the editor-group model (VS Code
/// groups / IntelliJ splitters).
///
/// ARCHITECTURE — an overlay, not an ownership migration: the app keeps ONE
/// flat tab store (`TabsState` on `TabCoordinator`; buffers, dirty state,
/// hot-exit and session persistence all key by tab id and stay exactly where
/// they are). A pane is purely "which tab ids render in MY strip, in what
/// order, and which of them is selected HERE"; one pane is focused and the
/// app-wide "current tab" is the focused pane's selection. This keeps the
/// blast radius small: every existing tab mutation path may keep mutating
/// the flat store, and `normalized(against:)` reconciles the overlay after
/// the fact (unknown ids drop, unassigned ids join the focused pane, the
/// ≥1-pane and valid-selection invariants re-establish).
///
/// Pure, Equatable, host-tested (`PaneAssignmentTests`). Codable so a
/// session snapshot can persist the layout additively.
public struct PaneAssignment: Equatable, Sendable, Codable {

    public struct Pane: Equatable, Sendable, Codable, Identifiable {
        public let id: UUID
        /// Strip order for this pane.
        public var tabIDs: [UUID]
        /// This pane's own selection (each pane remembers what it shows).
        public var selectedTabID: UUID?

        public init(id: UUID = UUID(), tabIDs: [UUID] = [], selectedTabID: UUID? = nil) {
            self.id = id
            self.tabIDs = tabIDs
            self.selectedTabID = tabIDs.contains(where: { $0 == selectedTabID })
                ? selectedTabID : tabIDs.first
        }
    }

    /// Which way the pane run stacks (owner 2026-08-11: "split bottom"):
    /// `.horizontal` = side-by-side columns (split right), `.vertical` =
    /// stacked rows (split down). SINGLE-AXIS v1 — the first split picks
    /// the axis, later splits join the same run; mixed grids are the
    /// future split-tree work. Resets to horizontal when the run closes
    /// back to one pane.
    public enum SplitOrientation: String, Equatable, Sendable, Codable {
        case horizontal, vertical
    }

    /// Panes, leading → trailing along `orientation`. Never empty.
    public private(set) var panes: [Pane]
    /// The pane keyboard/commands act on. Always a live pane id.
    public private(set) var focusedPaneID: UUID
    /// The run's axis (meaningful only when split).
    public private(set) var orientation: SplitOrientation = .horizontal

    // MARK: - Construction

    /// The single-pane world every session starts in (and the exact
    /// pre-panes behavior when never split).
    public init(tabIDs: [UUID] = [], selectedTabID: UUID? = nil) {
        let pane = Pane(tabIDs: tabIDs, selectedTabID: selectedTabID)
        self.panes = [pane]
        self.focusedPaneID = pane.id
    }

    init(panes: [Pane], focusedPaneID: UUID) {
        precondition(!panes.isEmpty)
        self.panes = panes
        self.focusedPaneID = panes.contains(where: { $0.id == focusedPaneID })
            ? focusedPaneID : panes[0].id
    }

    /// I-21 S4b — rebuild a PERSISTED layout (session restore). The caller
    /// resolves persisted paths → live tab ids and then normalizes against
    /// the store; an empty input degrades to the single-pane world.
    public init(
        restoring panes: [Pane], focusedIndex: Int,
        orientation: SplitOrientation
    ) {
        let safe = panes.isEmpty ? [Pane()] : panes
        self.panes = safe
        self.focusedPaneID = safe.indices.contains(focusedIndex)
            ? safe[focusedIndex].id : safe[0].id
        self.orientation = orientation
    }

    // MARK: - Reads

    public var focusedPane: Pane {
        panes.first { $0.id == focusedPaneID } ?? panes[0]
    }

    /// The app-wide "current tab": the focused pane's selection.
    public var focusedSelectedTabID: UUID? { focusedPane.selectedTabID }

    public func pane(containing tabID: UUID) -> Pane? {
        panes.first { $0.tabIDs.contains(tabID) }
    }

    public var isSplit: Bool { panes.count > 1 }

    // MARK: - Pane operations

    /// Split: a new pane AFTER the focused one (right in a horizontal run,
    /// below in a vertical one), focused. `direction` picks the run's axis
    /// on the FIRST split (an already-split run keeps its axis — single-
    /// axis v1). When `moving` names a tab in the focused pane, it MOVES
    /// there (the "tear this tab into a new pane" gesture); nil = an empty
    /// pane (the empty-state surface renders until a tab opens there).
    public mutating func splitFocusedPane(
        moving tabID: UUID? = nil,
        direction: SplitOrientation = .horizontal
    ) {
        guard let idx = panes.firstIndex(where: { $0.id == focusedPaneID }) else { return }
        if panes.count == 1 { orientation = direction }
        var newPane = Pane()
        if let tabID, let from = panes.firstIndex(where: { $0.tabIDs.contains(tabID) }) {
            panes[from].tabIDs.removeAll { $0 == tabID }
            if panes[from].selectedTabID == tabID {
                panes[from].selectedTabID = panes[from].tabIDs.first
            }
            newPane.tabIDs = [tabID]
            newPane.selectedTabID = tabID
        }
        panes.insert(newPane, at: idx + 1)
        focusedPaneID = newPane.id
    }

    /// Close a pane: its tabs APPEND to the left neighbor (or the right
    /// one for the leftmost pane) — closing a pane never closes tabs. The
    /// last pane can't close. Focus moves to the absorbing pane.
    public mutating func closePane(id: UUID) {
        guard panes.count > 1,
              let idx = panes.firstIndex(where: { $0.id == id }) else { return }
        let closing = panes[idx]
        let absorbIdx = idx > 0 ? idx - 1 : 1
        panes[absorbIdx].tabIDs.append(contentsOf: closing.tabIDs)
        if panes[absorbIdx].selectedTabID == nil {
            panes[absorbIdx].selectedTabID = closing.selectedTabID
        }
        let absorbID = panes[absorbIdx].id
        panes.remove(at: idx)
        if focusedPaneID == id { focusedPaneID = absorbID }
        // Back to a single pane: the next split picks its axis fresh.
        if panes.count == 1 { orientation = .horizontal }
    }

    public mutating func focusPane(id: UUID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        focusedPaneID = id
    }

    // MARK: - Tab operations

    /// Select `tabID` wherever it lives: focuses its pane AND selects it
    /// there (a click in any strip does both).
    public mutating func selectTab(id tabID: UUID) {
        guard let idx = panes.firstIndex(where: { $0.tabIDs.contains(tabID) }) else { return }
        panes[idx].selectedTabID = tabID
        focusedPaneID = panes[idx].id
    }

    /// Move a tab to `paneID` at `index` (clamped; nil = append). The
    /// source pane keeps running with its next tab selected; the moved tab
    /// becomes the destination's selection. A tab moved onto its own pane
    /// is a reorder.
    public mutating func moveTab(
        id tabID: UUID, toPane paneID: UUID, at index: Int? = nil
    ) {
        guard let to = panes.firstIndex(where: { $0.id == paneID }),
              let from = panes.firstIndex(where: { $0.tabIDs.contains(tabID) })
        else { return }
        panes[from].tabIDs.removeAll { $0 == tabID }
        if panes[from].selectedTabID == tabID {
            panes[from].selectedTabID = panes[from].tabIDs.first
        }
        let clamped = min(max(index ?? panes[to].tabIDs.count, 0), panes[to].tabIDs.count)
        panes[to].tabIDs.insert(tabID, at: clamped)
        panes[to].selectedTabID = tabID
    }

    /// Reorder `tabID` WITHIN its own pane (the strip drag). `gap` is in
    /// `TabsState.move(from:to:)` coordinates against the pane's ORIGINAL
    /// order — an insertion point `0...count`. Selections are untouched
    /// (they track ids, not positions). Cross-pane moves are
    /// `moveTab(id:toPane:at:)`.
    public mutating func reorderTab(id tabID: UUID, to gap: Int) {
        guard let p = panes.firstIndex(where: { $0.tabIDs.contains(tabID) }),
              let from = panes[p].tabIDs.firstIndex(of: tabID),
              gap >= 0, gap <= panes[p].tabIDs.count else { return }
        let moved = panes[p].tabIDs.remove(at: from)
        let insertAt = (from < gap) ? (gap - 1) : gap
        panes[p].tabIDs.insert(
            moved, at: min(max(insertAt, 0), panes[p].tabIDs.count))
    }

    /// A tab OPENED in the flat store: joins `paneID` (default: the
    /// focused pane) and becomes its selection — matching today's
    /// open-selects behavior, per pane.
    public mutating func didOpenTab(id tabID: UUID, inPane paneID: UUID? = nil) {
        guard pane(containing: tabID) == nil else { return }
        let target = paneID ?? focusedPaneID
        guard let idx = panes.firstIndex(where: { $0.id == target })
        else { return }
        panes[idx].tabIDs.append(tabID)
        panes[idx].selectedTabID = tabID
    }

    /// A tab CLOSED in the flat store: drop it everywhere; a pane that
    /// loses its selection falls to the nearest remaining neighbor
    /// (matching `TabsState.remove`'s settle behavior). Panes are NOT
    /// auto-closed when emptied (explicit `closePane` — an empty pane
    /// shows the empty-state surface).
    public mutating func didCloseTab(id tabID: UUID) {
        for i in panes.indices {
            guard let pos = panes[i].tabIDs.firstIndex(of: tabID) else { continue }
            panes[i].tabIDs.remove(at: pos)
            if panes[i].selectedTabID == tabID {
                let ids = panes[i].tabIDs
                panes[i].selectedTabID =
                    ids.indices.contains(pos) ? ids[pos] : ids.last
            }
        }
    }

    // MARK: - Reconciliation

    /// Reconcile the overlay against the flat store's truth: ids the store
    /// no longer has are dropped; ids the overlay has never seen join the
    /// FOCUSED pane (and become its selection — they were just opened);
    /// every pane's selection re-validates; the ≥1-pane invariant holds.
    /// This is the safety net that lets every existing tab mutation path
    /// keep working untouched.
    public func normalized(against openTabIDs: [UUID]) -> PaneAssignment {
        let open = Set(openTabIDs)
        var next = panes
        for i in next.indices {
            next[i].tabIDs.removeAll { !open.contains($0) }
            if let sel = next[i].selectedTabID, !next[i].tabIDs.contains(sel) {
                next[i].selectedTabID = next[i].tabIDs.first
            } else if next[i].selectedTabID == nil {
                next[i].selectedTabID = next[i].tabIDs.first
            }
        }
        if next.isEmpty { next = [Pane()] }
        var out = PaneAssignment(
            panes: next,
            focusedPaneID: focusedPaneID)
        // The rebuild goes through the internal init — carry the run's
        // axis (dropping it silently reset every split to horizontal on
        // the first post-split store mutation).
        out.orientation = orientation
        let assigned = Set(next.flatMap(\.tabIDs))
        // Preserve the STORE's order for never-seen ids so a bulk restore
        // lands in reading order.
        for id in openTabIDs where !assigned.contains(id) {
            out.didOpenTab(id: id)
        }
        return out
    }

    /// Single-pane lockstep (S2): while the window is UN-split, the one
    /// pane's strip must be byte-identical to the flat store's strip —
    /// same order, same selection — so the pre-panes world renders and
    /// behaves exactly as before. A no-op when split (each pane owns its
    /// own order/selection then). Preserves the pane's identity.
    public mutating func mirrorSinglePane(order: [UUID], selected: UUID?) {
        guard panes.count == 1 else { return }
        panes[0].tabIDs = order
        panes[0].selectedTabID = order.contains(where: { $0 == selected })
            ? selected : order.first
    }

    /// Invariant check (tests + debug asserts): every open id in exactly
    /// one pane, focused pane exists, selections valid.
    public func isConsistent(against openTabIDs: [UUID]) -> Bool {
        let open = Set(openTabIDs)
        var seen = Set<UUID>()
        for p in panes {
            for id in p.tabIDs {
                guard open.contains(id), !seen.contains(id) else { return false }
                seen.insert(id)
            }
            if let sel = p.selectedTabID, !p.tabIDs.contains(sel) { return false }
            if p.selectedTabID == nil, !p.tabIDs.isEmpty { return false }
        }
        guard seen == open else { return false }
        return panes.contains { $0.id == focusedPaneID }
    }
}
