import Foundation

/// TSK-941 — pure per-hunk approve/reject SELECTION state for the agent-diff review
/// UI (Model A: revert-on-reject). Holds the agent's new text + the base→new hunks
/// + the set of REJECTED hunk indices; toggling drives `resolvedText` via the
/// host-tested `AgentDiffApply`. This is the host-testable seam the render review
/// view binds — its contract (the right text for any approve/reject selection) is
/// the data-safety guard for a feature that ultimately WRITES the file.
public struct HunkReviewState {
    /// The agent's already-applied new text (the document's current content).
    public let newText: String
    /// The base→new hunks (from `LineDiff.hunks(from:to:)`).
    public let hunks: [LineDiff.DiffHunk]
    /// 0-based indices of the hunks the user has REJECTED (to be reverted).
    public private(set) var rejected: Set<Int>

    public init(newText: String, hunks: [LineDiff.DiffHunk], rejected: Set<Int> = []) {
        self.newText = newText
        self.hunks = hunks
        self.rejected = rejected
    }

    public var hunkCount: Int { hunks.count }
    public func isRejected(_ index: Int) -> Bool { rejected.contains(index) }

    /// Toggle a hunk between rejected/approved (out-of-range is a no-op).
    public mutating func toggle(_ index: Int) {
        guard hunks.indices.contains(index) else { return }
        if rejected.contains(index) { rejected.remove(index) } else { rejected.insert(index) }
    }

    /// Reject every hunk (full revert to base).
    public mutating func rejectAll() { rejected = Set(hunks.indices) }
    /// Approve every hunk (keep the agent's new text).
    public mutating func approveAll() { rejected.removeAll() }

    /// The document text after the current approve/reject decision is applied.
    /// Empty `rejected` ⇒ `newText` (approve-all); all rejected ⇒ the base text.
    public var resolvedText: String {
        AgentDiffApply.revertingRejectedHunks(in: newText, hunks: hunks, rejected: rejected)
    }
}
