import Foundation

/// Pure, host-testable data model for the in-app Project Management feature
/// (TSK-345). This is the **foundation slice**: the work-item model, the
/// lifecycle state machine with per-edge ownership, the dependency edge sets,
/// the deterministic `work_next` queue, the autonomy gate, and the parent
/// roll-up projection — all derived from `docs/PROJECT_MANAGEMENT_DESIGN_v2.md`.
///
/// What is DELIBERATELY out of scope here (later slices, see the file footer
/// and the task `remaining`):
///   - The persistent store. The design mandates an embedded SQLite
///     event-log + materialized-projection store owned by the Rust core,
///     which needs the `rusqlite` crate — an *un-approved* new dependency.
///     This slice stays in-memory and dependency-free so it lands now; the
///     store is a separate, owner-gated slice.
///   - The MCP agent surface and the SwiftUI "control room" UI.
///   - The event log / hash-chain provenance and time-travel replay.
///
/// Everything here is value semantics, `Sendable`, and free of AppKit so it
/// can run off-main and be exhaustively unit-tested on the host. No render
/// path is involved, so this slice is fully host-validatable.
public enum WorkItemModel {

    // MARK: - Lifecycle state (§2.2)

    /// The lifecycle state machine. The states are derived from the only
    /// question that matters for an agent-driven SDLC: *who/what does the
    /// system block on, and what observable event ends the wait?*
    ///
    /// `parked` is a first-class superstate (constraint #2) carrying a typed
    /// ``ParkReason``. `claimedDone` (the agent's ceiling) is distinct from
    /// `verifiedDone` (an independent verifier passed) — that gap *is* the
    /// human review surface; collapsing it removes the place agent work is
    /// reviewed.
    public enum State: String, Equatable, Hashable, Sendable, CaseIterable, Codable {
        /// Exists, not yet admitted; scope/intent unconfirmed. Agents propose freely.
        case proposed
        /// Admitted, fully specified, preconditions met & acceptance present; dispatchable now.
        case ready
        /// An agent/human holds a lease and is doing the work.
        case active
        /// Durably suspended on a typed ``ParkReason`` — the first-class blocked state.
        case parked
        /// The doer asserts complete — the agent's ceiling.
        case claimedDone
        /// An independent verifier (tests/reviewer/human) passed.
        case verifiedDone
        /// Integrated/shipped. Terminal.
        case closed
        /// Declined at intake; never admitted. Terminal.
        case rejected
        /// Admitted but stopped without completion (budget exhausted, superseded,
        /// not-worth-it). Terminal, but carries the negative knowledge.
        case abandoned
        /// Was `verifiedDone`; an upstream `consumes[]` output changed (§1.7).
        /// Auto-entered, routes back to re-examination.
        case assumptionsInvalidated

        /// `true` while the item still demands attention or future work.
        public var isOpen: Bool {
            switch self {
            case .closed, .rejected, .abandoned: return false
            default: return true
            }
        }

        /// `true` for the three terminal states (no further transition expected).
        public var isTerminal: Bool {
            switch self {
            case .closed, .rejected, .abandoned: return true
            default: return false
            }
        }

        /// `true` if a `depends_on` upstream in this state counts as "satisfied"
        /// for the ordering gate (Closed counts; an Abandoned/Cut upstream also
        /// counts as resolved so a dependent isn't wedged forever).
        public var satisfiesOrdering: Bool {
            self == .closed || self == .abandoned
        }
    }

    // MARK: - Park reasons (§1.2)

    /// The typed reason an item is `parked`. All five share an identical
    /// lifecycle contract (durably suspended, holds a resume checkpoint, exits
    /// only when a specific event fires); they differ in **what event resumes
    /// them, who is authorized to fire it, the notification policy, and whether
    /// they auto-resume**. Modeling them as one superstate + a discriminated
    /// reason keeps the transition table small while preserving those four
    /// behavioural axes.
    public enum ParkReason: String, Equatable, Hashable, Sendable, CaseIterable, Codable {
        /// Agent hit a fork it isn't authorized/confident to take. Human only. Pings.
        case awaitingDecision
        /// Agent has a plan; needs yes/no/amend on a consequential action. Human only. Pings.
        case awaitingApproval
        /// Missing credential / spec / upstream artifact. Human or external. Pings.
        case awaitingInput
        /// Another work item must reach a state. System fires. Silent. Auto-resumes.
        case awaitingDependency
        /// Failing tests/CI/lint; retryable. System re-runs. Silent → escalates. Auto-resumes (capped).
        case awaitingGate

        /// `true` if a human (not the system) must supply the resuming value.
        /// Encodes the authorization boundary: an agent literally cannot resolve
        /// its own human-typed park.
        public var requiresHuman: Bool {
            switch self {
            case .awaitingDecision, .awaitingApproval, .awaitingInput: return true
            case .awaitingDependency, .awaitingGate: return false
            }
        }

        /// `true` if the system resumes this automatically when its signal fires
        /// (dependency reached state / gate re-ran), with no human in the loop.
        public var autoResumes: Bool {
            switch self {
            case .awaitingDependency, .awaitingGate: return true
            case .awaitingDecision, .awaitingApproval, .awaitingInput: return false
            }
        }

        /// `true` if entering this park must ping a human. Dependency waits are
        /// silent; decision/approval/input waits ping (a bare string reason would
        /// force you to either spam the human or drop the ping).
        public var pingsHuman: Bool {
            switch self {
            case .awaitingDecision, .awaitingApproval, .awaitingInput: return true
            case .awaitingDependency: return false
            // Gate waits are silent until retries are exhausted, then escalate
            // (a state edge — see WorkItemLifecycle.escalatedReason).
            case .awaitingGate: return false
            }
        }
    }

    // MARK: - Autonomy gate (§2.5)

    /// Authorization axis — "may an agent do this alone?" Keyed on
    /// reversibility / blast-radius / cost, **not importance**. Default-STOP:
    /// an item is auto-runnable only if explicitly `auto`.
    public enum AutonomyGate: String, Equatable, Hashable, Sendable, CaseIterable, Codable {
        /// Agent may run unattended (reversible, low blast radius).
        case auto
        /// Agent may plan but needs a human yes before the consequential action.
        case gated
        /// A human must be in the loop throughout; never agent-dispatchable.
        case supervised
    }

    // MARK: - Actor classes (transition ownership, §2.2)

    /// Who is attempting a transition. The lifecycle guard keys off this to
    /// enforce the safety boundary as *data*, so an autonomous loop cannot skip
    /// a human gate even when instructed to.
    public enum Actor: String, Equatable, Hashable, Sendable, CaseIterable, Codable {
        case agent
        case human
        case system
    }

    // MARK: - Dependency edge kinds (§2.4)

    /// The four edge kinds among items. They are *different edge sets with
    /// different algorithms* — the single most repo-specific insight in the
    /// design. Only `dependsOn` and `parent` are acyclic DAGs the queue walks;
    /// `consumes` is the reverse-ripple data edge; `touches` is an undirected
    /// contention relation.
    public enum EdgeKind: String, Equatable, Hashable, Sendable, CaseIterable, Codable {
        /// ORDERING — A must finish before B starts (DAG, acyclic). Does NOT ripple.
        case dependsOn
        /// DATA — B consumed A's output; A changes ⇒ B invalidated (§1.7). RIPPLES.
        case consumes
        /// CONCURRENCY — A and B must not RUN at once (undirected contention).
        case touches
        /// CONTAINMENT — B is part of A (strict tree, drives roll-up).
        case parent
    }

    // MARK: - The work item (§2.1)

    /// One recursive work item. Value type; the parent's *state* is a derived
    /// projection (see ``WorkItemRollup``) and is NOT stored here as authored
    /// truth.
    public struct Item: Equatable, Hashable, Sendable, Identifiable, Codable {
        public let id: String
        public var title: String
        /// Immutable once set — the drift reference (§1.10). Empty until anchored.
        public let intentAnchor: String
        /// Open vocabulary (Feature|Bug|Chore|Spike|Decision|…) — not a fixed enum.
        public var kind: String
        public var state: State
        /// Present iff `state == .parked`.
        public var parkReason: ParkReason?
        public var gate: AutonomyGate
        /// Calibrated confidence in scope/approach, 0...1 (§1.8).
        public var confidence: Double
        /// Below this, low confidence auto-emits an AwaitingDecision park (§2.5).
        public var escalationThreshold: Double
        /// HARD ordering upstreams (must be satisfied before this can run).
        public var dependsOn: [String]
        /// DATA upstreams whose output this consumed (reverse-ripple, §1.7).
        public var consumes: [String]
        /// Contention set — items that must not RUN concurrently with this.
        public var touches: [String]
        /// Containment parent id, or nil for a root.
        public var parent: String?
        /// Whether a crisp, machine-checkable acceptance check exists
        /// (definition-of-ready, §2.4: no acceptance ⇒ not ready).
        public var hasAcceptance: Bool
        /// Whether an active lease is held (a proxy for "an agent is on it").
        public var hasLease: Bool
        /// Whether budget remains for at least one more step (§1.9 economic gate).
        public var budgetRemaining: Bool
        /// Whether every context_ref is fresh (hash matches / within TTL, §1.1).
        public var contextFresh: Bool
        /// Tie-break tier (lower runs first; e.g. priority band).
        public var tier: Int
        /// Monotonic creation order used as the age tiebreak (lower = older).
        public var sequence: Int

        public init(
            id: String,
            title: String = "",
            intentAnchor: String = "",
            kind: String = "Feature",
            state: State = .proposed,
            parkReason: ParkReason? = nil,
            gate: AutonomyGate = .gated,
            confidence: Double = 1.0,
            escalationThreshold: Double = 0.0,
            dependsOn: [String] = [],
            consumes: [String] = [],
            touches: [String] = [],
            parent: String? = nil,
            hasAcceptance: Bool = true,
            hasLease: Bool = false,
            budgetRemaining: Bool = true,
            contextFresh: Bool = true,
            tier: Int = 0,
            sequence: Int = 0
        ) {
            self.id = id
            self.title = title
            self.intentAnchor = intentAnchor
            self.kind = kind
            self.state = state
            self.parkReason = parkReason
            self.gate = gate
            self.confidence = confidence
            self.escalationThreshold = escalationThreshold
            self.dependsOn = dependsOn
            self.consumes = consumes
            self.touches = touches
            self.parent = parent
            self.hasAcceptance = hasAcceptance
            self.hasLease = hasLease
            self.budgetRemaining = budgetRemaining
            self.contextFresh = contextFresh
            self.tier = tier
            self.sequence = sequence
        }

        /// A leaf has no children (parents are containers and are never
        /// directly dispatched — only their leaves run).
        public func isLeaf(amongChildrenOf children: [Item]) -> Bool {
            !children.contains { $0.parent == id }
        }
    }
}
