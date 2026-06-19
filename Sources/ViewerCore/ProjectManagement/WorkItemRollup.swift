import Foundation

/// The parent roll-up projection (§2.1 of
/// `docs/PROJECT_MANAGEMENT_DESIGN_v2.md`). A parent's state is a **pure
/// projection over its children, computed bottom-up, never persisted as source
/// of truth.** The precedence — *worst / most-attention-needing wins* — is the
/// agent-specific bit: a deeply-nested human-decision wait must bubble to the
/// top so the whole epic shows "needs you", carrying the *notification
/// semantics*, not just the fact of blockage.
public enum WorkItemRollup {

    public typealias Item = WorkItemModel.Item
    public typealias State = WorkItemModel.State

    /// The rolled-up status of a parent, distinct from a leaf ``WorkItemModel/State``
    /// because the roll-up has flavors a leaf doesn't (human- vs auto-blocked,
    /// needs-attention partial).
    public enum RolledUp: Equatable, Hashable, Sendable {
        /// ANY child parked on a human-typed reason → bubbles to top, PINGS.
        case blockedHuman
        /// ANY child active/in-progress.
        case active
        /// ANY child parked on an auto reason (dependency/gate) → silent.
        case blockedAuto
        /// ANY child ready (none active/blocked).
        case ready
        /// All children verified-done/closed/abandoned (Cut counts as satisfied)
        /// → parent is eligible for its OWN review, never auto-closed.
        case settled
        /// All children closed.
        case closed
        /// Mixed terminal — some abandoned/rejected alongside done.
        case needsAttention
        /// No children at all (a leaf, or an empty parent).
        case empty
    }

    /// Compute the rolled-up status of `parentID` from its *direct* children in
    /// `items`. Precedence is strict and ordered (first match wins), matching
    /// the design's worst-wins table.
    public static func rollup(of parentID: String, in items: [Item]) -> RolledUp {
        let children = items.filter { $0.parent == parentID }
        guard !children.isEmpty else { return .empty }

        // 1. ANY child parked on a human-typed reason → BLOCKED(human). Bubbles, pings.
        if children.contains(where: { isHumanParked($0) }) {
            return .blockedHuman
        }
        // 2. ANY child active.
        if children.contains(where: { $0.state == .active }) {
            return .active
        }
        // 3. ANY child parked on an auto reason → BLOCKED(auto). Silent.
        if children.contains(where: { isAutoParked($0) }) {
            return .blockedAuto
        }
        // 4. ANY child ready (none active/blocked above).
        if children.contains(where: { $0.state == .ready }) {
            return .ready
        }
        // 5. ALL children closed → parent CLOSED.
        if children.allSatisfy({ $0.state == .closed }) {
            return .closed
        }
        // 6. ALL children resolved-as-done (verifiedDone/closed/abandoned count as
        //    satisfied), with at least one verifiedDone → eligible for own review.
        if children.allSatisfy({ isResolved($0) }) {
            // Distinguish a clean "all done" (settled) from a mixed terminal that
            // includes a rejection/abandonment without any positive completion.
            let anyPositive = children.contains { $0.state == .verifiedDone || $0.state == .closed }
            let anyNegativeTerminal = children.contains { $0.state == .abandoned || $0.state == .rejected }
            if anyNegativeTerminal && !anyPositive {
                return .needsAttention
            }
            if anyNegativeTerminal {
                return .needsAttention // partial — some cut, some done
            }
            return .settled
        }
        // 7. Anything else (e.g. proposed/claimedDone/assumptionsInvalidated mix)
        //    needs a human's eye.
        return .needsAttention
    }

    /// `true` if a notification (a "needs you" ping) should fire for this
    /// rolled-up status. Only the human-blocked roll-up pings; auto-blocked is
    /// silent — the parent inherits the child's notification semantics.
    public static func shouldPing(_ rolled: RolledUp) -> Bool {
        rolled == .blockedHuman
    }

    // MARK: - Helpers

    private static func isHumanParked(_ item: Item) -> Bool {
        item.state == .parked && (item.parkReason?.requiresHuman ?? false)
    }

    private static func isAutoParked(_ item: Item) -> Bool {
        item.state == .parked && (item.parkReason?.autoResumes ?? false)
    }

    private static func isResolved(_ item: Item) -> Bool {
        switch item.state {
        case .verifiedDone, .closed, .abandoned, .rejected: return true
        default: return false
        }
    }
}
