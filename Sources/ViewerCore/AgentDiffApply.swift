import Foundation

/// TSK-941 — apply an approve/reject DECISION over an agent's diff.
///
/// **Model A (revert-on-reject)** — the only feasible model without intercepting
/// the agent's writes: the agent's change is ALREADY applied (the document holds
/// the NEW text), so "approve" is a no-op and "reject" reverts the unwanted
/// hunks' new-side lines back to their old-side lines. Pure + host-tested; the
/// hunk-selection review UI (per-hunk approve/reject affordances) is the render
/// slice that drives this.
public enum AgentDiffApply {

    /// Revert the hunks at `rejected` (0-based indices into `hunks`, the base→new
    /// hunks from `LineDiff.hunks`) within `newText`, returning the resulting
    /// text. Rejections are applied BOTTOM-TO-TOP so an earlier revert never
    /// shifts a later hunk's line range. Out-of-range indices are ignored; an
    /// empty `rejected` returns `newText` unchanged (approve-all).
    public static func revertingRejectedHunks(
        in newText: String,
        hunks: [LineDiff.DiffHunk],
        rejected: Set<Int>
    ) -> String {
        guard !rejected.isEmpty else { return newText }
        var lines = LineDiff.lines(of: newText)
        let rejectedHunks = rejected
            .compactMap { hunks.indices.contains($0) ? hunks[$0] : nil }
            .sorted { $0.newStart > $1.newStart }   // bottom-to-top
        for hunk in rejectedHunks {
            let lo = hunk.newStart - 1
            let hi = lo + hunk.newCount
            guard lo >= 0, hi <= lines.count, lo <= hi else { continue }
            // The OLD side = context + removed lines (everything that isn't an
            // added-only line), in old order — what the rejected new-side region
            // reverts to. Context lines are identical on both sides, so this is a
            // no-op for them and a true revert for the added/removed lines.
            let oldSide = hunk.lines.filter { $0.kind != .added }.map(\.content)
            lines.replaceSubrange(lo..<hi, with: oldSide)
        }
        return lines.joined(separator: "\n")
    }

    /// Reject EVERY hunk (full reject) → reconstructs the base text. A convenience
    /// over `revertingRejectedHunks` with all indices; also the round-trip check
    /// (revert-all of `hunks(from: base, to: new)` applied to `new` == `base`).
    public static func revertingAll(in newText: String, hunks: [LineDiff.DiffHunk]) -> String {
        revertingRejectedHunks(in: newText, hunks: hunks, rejected: Set(hunks.indices))
    }
}
