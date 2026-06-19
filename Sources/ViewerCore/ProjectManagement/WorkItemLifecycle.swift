import Foundation

/// The lifecycle state machine for ``WorkItemModel`` — legal transitions, the
/// per-edge ownership/guard table, and the escalation edge — encoded as data
/// so an autonomous loop *cannot* skip a human gate even when instructed to
/// (§2.2 of `docs/PROJECT_MANAGEMENT_DESIGN_v2.md`).
///
/// Principle: agents own the *doing*, *self-parking*, and *proposing* done +
/// objective checks; humans own *admission*, *acceptance*, *abandonment*, and
/// resolving human-typed parks; the **system** owns leasing, requeue-on-crash,
/// firing auto-resume signals, escalation, and rehydration.
public enum WorkItemLifecycle {

    public typealias State = WorkItemModel.State
    public typealias Actor = WorkItemModel.Actor
    public typealias ParkReason = WorkItemModel.ParkReason

    /// Why a transition was rejected — surfaced to callers so the UI/MCP can
    /// explain *why* a move is illegal rather than silently no-op.
    public enum TransitionError: Error, Equatable, Sendable {
        /// No edge exists between these two states.
        case noSuchEdge(from: State, to: State)
        /// The edge exists but this actor class isn't authorized to fire it.
        /// (The structural realization of "an agent can never self-certify".)
        case actorNotAuthorized(from: State, to: State, actor: Actor)
        /// Entering `parked` requires a `ParkReason`; leaving it forbids one.
        case parkReasonMismatch
    }

    /// One legal edge with its authorized actor classes.
    private struct Edge: Hashable {
        let from: State
        let to: State
        let owners: Set<Actor>
    }

    /// The full transition table (§2.2). Each edge names the actor classes
    /// permitted to fire it. The crucial safety edges:
    ///   - `active → claimedDone` is **agent-only** (proposing done — its ceiling).
    ///   - `claimedDone → verifiedDone` is **system/verifier-only**, NEVER the
    ///     agent — that gap is the human review surface.
    ///   - `proposed → ready` / `proposed → rejected` / `* → abandoned` are
    ///     **human-only** (admission/abandonment).
    private static let edges: [Edge] = [
        // Intake
        .init(from: .proposed, to: .ready, owners: [.human]),
        .init(from: .proposed, to: .rejected, owners: [.human]),
        // Dispatch (atomic claim happens here)
        .init(from: .ready, to: .active, owners: [.agent, .system]),
        // Self-park + auto-resume
        .init(from: .active, to: .parked, owners: [.agent, .system]),
        .init(from: .parked, to: .ready, owners: [.system]),
        .init(from: .parked, to: .active, owners: [.system]),
        .init(from: .parked, to: .abandoned, owners: [.human]),
        // Proposing done (agent ceiling) + verifier gate
        .init(from: .active, to: .claimedDone, owners: [.agent]),
        .init(from: .claimedDone, to: .verifiedDone, owners: [.system]),
        .init(from: .claimedDone, to: .active, owners: [.agent, .human]), // kickback
        // Requeue on crash/lease-expiry (idempotent)
        .init(from: .active, to: .ready, owners: [.system]),
        // Integration
        .init(from: .verifiedDone, to: .closed, owners: [.human, .system]),
        // Reverse-ripple invalidation (§1.7)
        .init(from: .verifiedDone, to: .assumptionsInvalidated, owners: [.system]),
        .init(from: .assumptionsInvalidated, to: .active, owners: [.agent, .system]),
        .init(from: .assumptionsInvalidated, to: .ready, owners: [.system]),
        // Kill in-flight work (human-only) from any non-terminal state
        .init(from: .ready, to: .abandoned, owners: [.human]),
        .init(from: .active, to: .abandoned, owners: [.human]),
        .init(from: .claimedDone, to: .abandoned, owners: [.human]),
    ]

    private static let edgeIndex: [StatePair: Set<Actor>] = {
        var index: [StatePair: Set<Actor>] = [:]
        for edge in edges {
            index[StatePair(from: edge.from, to: edge.to)] = edge.owners
        }
        return index
    }()

    private struct StatePair: Hashable {
        let from: State
        let to: State
    }

    /// `true` if any actor may move `from → to` (ignores authorization).
    public static func isLegalEdge(from: State, to: State) -> Bool {
        edgeIndex[StatePair(from: from, to: to)] != nil
    }

    /// The set of actor classes authorized to fire `from → to`, or `nil` if no
    /// such edge exists.
    public static func authorizedActors(from: State, to: State) -> Set<Actor>? {
        edgeIndex[StatePair(from: from, to: to)]
    }

    /// Validate a proposed transition. Pure — does not mutate. Returns `nil` if
    /// the transition is permitted, or the ``TransitionError`` explaining why
    /// it is rejected.
    ///
    /// - Parameters:
    ///   - from/to: the requested edge.
    ///   - actor: the actor class attempting it.
    ///   - parkReason: the reason supplied (required iff `to == .parked`).
    public static func validate(
        from: State,
        to: State,
        actor: Actor,
        parkReason: ParkReason?
    ) -> TransitionError? {
        guard let owners = authorizedActors(from: from, to: to) else {
            return .noSuchEdge(from: from, to: to)
        }
        guard owners.contains(actor) else {
            return .actorNotAuthorized(from: from, to: to, actor: actor)
        }
        // Entering parked needs a reason; any other target forbids one.
        if to == .parked && parkReason == nil { return .parkReasonMismatch }
        if to != .parked && parkReason != nil { return .parkReasonMismatch }
        return nil
    }

    /// Apply a validated transition to a copy of the item, returning the new
    /// item or the rejection reason. The single mutation point so the state +
    /// `parkReason` invariant stay coupled.
    public static func apply(
        _ item: WorkItemModel.Item,
        to: State,
        actor: Actor,
        parkReason: ParkReason? = nil
    ) -> Result<WorkItemModel.Item, TransitionError> {
        if let error = validate(from: item.state, to: to, actor: actor, parkReason: parkReason) {
            return .failure(error)
        }
        var next = item
        next.state = to
        next.parkReason = (to == .parked) ? parkReason : nil
        return .success(next)
    }

    /// Escalation as a *state edge*, not a new state (§1.2): an `awaitingGate`
    /// park whose retry cap is exhausted re-parks as `awaitingDecision` — the
    /// retryable mechanical wait converts into a human-ping. Returns the reason
    /// the item should carry after escalation, or `nil` if it doesn't escalate.
    public static func escalatedReason(
        for reason: ParkReason,
        retriesRemaining: Int
    ) -> ParkReason? {
        guard reason == .awaitingGate, retriesRemaining <= 0 else { return nil }
        return .awaitingDecision
    }
}
