import Foundation

/// The mounted-pane retention set for perf Fix#1 (instant tab switching —
/// design: `docs/research/perf-fix1-view-retention.md`). Pure value logic,
/// SwiftUI-free, so the eviction-ordering correctness — the part most likely to
/// be wrong — is unit-tested headlessly before any view wiring.
///
/// The view layer renders a `ZStack` of one pane per id in `ids`; only the
/// most-recently-activated (index 0) is visible. Keeping inactive ids in the
/// set keeps their `WKWebView` mounted (no reload on switch-back). An id leaving
/// the set is the ONE place a pane unmounts (`dismantleNSView`), so eviction
/// must be deterministic:
///   • the active tab is always retained (it was just activated → front);
///   • the set is MRU-ordered; overflow evicts the least-recently-active tail;
///   • re-activating a mounted id never duplicates and never evicts;
///   • a closed tab is removed (its pane unmounts);
///   • `trim(to:)` handles the memory-pressure "collapse to 1" path.
public struct MountedPanesLRU: Equatable, Sendable {

    /// Steady-state cap on retained panes (clamped to ≥ 1). LRU(~4) per the design.
    public let capacity: Int

    /// MRU-first. Index 0 is the active pane.
    private var order: [UUID]

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.order = []
    }

    public var ids: [UUID] { order }
    public var count: Int { order.count }
    public var isEmpty: Bool { order.isEmpty }
    public func contains(_ id: UUID) -> Bool { order.contains(id) }

    /// Mark `id` the active pane: move it to the front, then evict the
    /// least-recently-active tail beyond `capacity`. Returns the evicted ids
    /// (whose panes should now tear down). Re-activating a mounted id moves it
    /// to the front without duplicating or evicting.
    @discardableResult
    public mutating func activate(_ id: UUID) -> [UUID] {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        return evictBeyond(capacity)
    }

    /// Remove a closed tab so its pane unmounts. Returns true if it was present.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        let before = order.count
        order.removeAll { $0 == id }
        return order.count != before
    }

    /// Prune to ids that are still open (after a bulk close / session switch),
    /// preserving the MRU order of survivors. Returns the dropped ids.
    @discardableResult
    public mutating func retainOnly(_ open: Set<UUID>) -> [UUID] {
        let dropped = order.filter { !open.contains($0) }
        order.removeAll { !open.contains($0) }
        return dropped
    }

    /// Transiently shrink to at most `n` panes (memory-pressure → collapse to
    /// 1), evicting the LRU tail. `n` is clamped to `1...`. Future `activate`
    /// calls grow the set back up to `capacity` — this only trims the current
    /// occupancy, it does not change `capacity`. Returns the evicted ids.
    @discardableResult
    public mutating func trim(to n: Int) -> [UUID] {
        evictBeyond(max(1, n))
    }

    // MARK: -

    /// Drop everything past index `keep-1`; return the dropped tail.
    private mutating func evictBeyond(_ keep: Int) -> [UUID] {
        guard order.count > keep else { return [] }
        let evicted = Array(order[keep...])
        order.removeLast(order.count - keep)
        return evicted
    }
}
