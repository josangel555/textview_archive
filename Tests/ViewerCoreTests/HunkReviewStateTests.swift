import Testing
@testable import ViewerCore

/// TSK-941 — host coverage for the per-hunk approve/reject selection seam (the
/// data-safety model the render review view binds). Count-agnostic: asserts the
/// resolve contract against AgentDiffApply rather than a fixed hunk count.
@Suite struct HunkReviewStateTests {
    /// base→new with two well-separated changes (mirrors AgentDiffApplyTests).
    private func multiHunkState() -> HunkReviewState {
        let base = (1...12).map { "line \($0)" }.joined(separator: "\n")
        var newLines = (1...12).map { "line \($0)" }
        newLines[1] = "CHANGED 2"
        newLines[9] = "CHANGED 10"
        let new = newLines.joined(separator: "\n")
        return HunkReviewState(newText: new, hunks: LineDiff.hunks(from: base, to: new))
    }

    @Test func approveAll_yieldsNewText() {
        var s = multiHunkState()
        #expect(s.hunkCount >= 1, "fixture has changes → at least one hunk")
        s.approveAll()
        #expect(s.rejected.isEmpty)
        #expect(s.resolvedText == s.newText, "approve-all keeps the agent's new text")
    }

    @Test func rejectAll_fullRevert() {
        var s = multiHunkState()
        s.rejectAll()
        #expect(s.rejected.count == s.hunkCount)
        #expect(s.resolvedText == AgentDiffApply.revertingAll(in: s.newText, hunks: s.hunks),
                "reject-all = full revert to base")
    }

    @Test func togglingEveryHunk_equalsRejectAll() {
        var s = multiHunkState()
        for i in 0..<s.hunkCount { s.toggle(i) }
        #expect(s.resolvedText == AgentDiffApply.revertingAll(in: s.newText, hunks: s.hunks),
                "toggling every hunk = reject-all")
    }

    @Test func toggleOne_rejectsOnlyThatHunk_andBack() {
        var s = multiHunkState()
        s.toggle(0)
        #expect(s.isRejected(0))
        #expect(s.resolvedText == AgentDiffApply.revertingRejectedHunks(
                    in: s.newText, hunks: s.hunks, rejected: [0]),
                "rejecting hunk 0 reverts only hunk 0")
        s.toggle(0)
        #expect(!s.isRejected(0))
        #expect(s.resolvedText == s.newText, "approving it back = new text")
    }

    @Test func toggle_outOfRange_isNoOp() {
        var s = multiHunkState()
        s.toggle(99)
        #expect(s.rejected.isEmpty, "out-of-range toggle changes nothing")
    }
}
