import Foundation

/// The deterministic, explainable `work_next` queue and the autonomy gate
/// (§2.4 / §2.5 of `docs/PROJECT_MANAGEMENT_DESIGN_v2.md`).
///
/// The queue is a pure **filter-then-rank** function with a stable final
/// tiebreak so a human and an agent never disagree on "the next task". It is
/// explainable: ``candidacy(of:in:)`` returns *why* an item is or isn't a
/// candidate, which the UI/MCP surfaces instead of an opaque "no work".
public enum WorkItemQueue {

    public typealias Item = WorkItemModel.Item

    /// The reasons an item is excluded from the dispatchable set. An empty set
    /// means the item is a candidate.
    public enum Exclusion: String, Equatable, Hashable, Sendable, CaseIterable {
        /// Not a leaf — parents are containers, never directly dispatched.
        case notLeaf
        /// State isn't `ready`/`active`.
        case notDispatchableState
        /// Gate is `supervised`, or a human-typed park is open on it.
        case autonomyGate
        /// A `dependsOn` upstream isn't satisfied (closed/abandoned).
        case unsatisfiedDependency
        /// A `consumes` upstream is in `assumptionsInvalidated` (stale input, §1.7).
        case staleUpstream
        /// `touches` intersects an item that is currently active (contention).
        case contention
        /// No budget remains for the next step (§1.9).
        case budgetExhausted
        /// Acceptance is missing — definition-of-ready fails (§2.4).
        case noAcceptance
        /// A `context_ref` is stale (hash mismatch / TTL expired, §1.1).
        case staleContext
    }

    /// Compute the full exclusion set for one item against the whole set. Empty
    /// ⇒ candidate. Deterministic and side-effect-free.
    public static func candidacy(of item: Item, in items: [Item]) -> Set<Exclusion> {
        var reasons: Set<Exclusion> = []
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        // 1. Leaf only.
        if items.contains(where: { $0.parent == item.id }) {
            reasons.insert(.notLeaf)
        }
        // 2. Dispatchable state.
        if item.state != .ready && item.state != .active {
            reasons.insert(.notDispatchableState)
        }
        // 3. Autonomy gate: supervised never auto-runs; an open human-typed park blocks.
        if item.gate == .supervised {
            reasons.insert(.autonomyGate)
        }
        if item.state == .parked, let r = item.parkReason, r.requiresHuman {
            reasons.insert(.autonomyGate)
        }
        // 4. Hard ordering — every dependsOn must be satisfied.
        for upstreamID in item.dependsOn {
            guard let up = byId[upstreamID] else { continue }
            if !up.state.satisfiesOrdering {
                reasons.insert(.unsatisfiedDependency)
                break
            }
        }
        // 5. Freshness — no consumed upstream may be invalidated.
        for upstreamID in item.consumes {
            if byId[upstreamID]?.state == .assumptionsInvalidated {
                reasons.insert(.staleUpstream)
                break
            }
        }
        // 6. Soft contention — touches must not intersect any active item.
        let activeIDs = Set(items.filter { $0.state == .active && $0.id != item.id }.map(\.id))
        if !Set(item.touches).isDisjoint(with: activeIDs) {
            reasons.insert(.contention)
        }
        // 7. Economic gate.
        if !item.budgetRemaining {
            reasons.insert(.budgetExhausted)
        }
        // 8. Definition-of-ready: acceptance present.
        if !item.hasAcceptance {
            reasons.insert(.noAcceptance)
        }
        // 9. Staleness pre-flight.
        if !item.contextFresh {
            reasons.insert(.staleContext)
        }
        return reasons
    }

    /// `true` if the item is dispatchable right now (no exclusions).
    public static func isCandidate(_ item: Item, in items: [Item]) -> Bool {
        candidacy(of: item, in: items).isEmpty
    }

    /// Count of *other* items whose only unsatisfied `dependsOn` is `id` — a
    /// cheap critical-path proxy ("unblocks the most"). Higher ranks earlier.
    private static func unblockWeight(of id: String, in items: [Item]) -> Int {
        items.reduce(0) { acc, item in
            item.dependsOn.contains(id) ? acc + 1 : acc
        }
    }

    /// The ranked dispatch queue: filter to candidates, then rank descending by
    /// `tier` (lower tier first), then critical-path unblock weight (higher
    /// first), then age (`sequence`, lower/older first), then a stable `id`
    /// tiebreak so the ordering is fully deterministic.
    public static func workNext(_ items: [Item]) -> [Item] {
        items
            .filter { isCandidate($0, in: items) }
            .sorted { a, b in
                if a.tier != b.tier { return a.tier < b.tier }
                let wa = unblockWeight(of: a.id, in: items)
                let wb = unblockWeight(of: b.id, in: items)
                if wa != wb { return wa > wb }
                if a.sequence != b.sequence { return a.sequence < b.sequence }
                return a.id < b.id
            }
    }

    /// The single next item to dispatch, or `nil` if nothing is dispatchable.
    public static func next(_ items: [Item]) -> Item? {
        workNext(items).first
    }

    // MARK: - Autonomy gate evaluation (§2.5)

    /// `true` if the item may be run unattended right now: explicitly `auto`,
    /// dispatchable, and contention-free — the three affirmative conditions of
    /// the default-STOP asymmetry. (`gated`/`supervised` always need a human.)
    public static func isAutoRunnable(_ item: Item, in items: [Item]) -> Bool {
        item.gate == .auto && isCandidate(item, in: items)
    }

    /// `true` if confidence has fallen below the escalation threshold, which
    /// should auto-emit an `awaitingDecision` park (§2.5 — the autonomy gate and
    /// the blocked state are two ends of one mechanism).
    public static func shouldEscalateOnConfidence(_ item: Item) -> Bool {
        item.confidence < item.escalationThreshold
    }
}
