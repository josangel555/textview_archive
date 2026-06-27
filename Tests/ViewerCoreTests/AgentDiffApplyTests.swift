import Testing
@testable import ViewerCore

/// TSK-941 — host coverage for the approve/reject (Model A revert-on-reject)
/// engine: reject-none is a no-op, reject-all reconstructs the base, and a
/// per-hunk reject reverts exactly that hunk (including pure insert/delete).
struct AgentDiffApplyTests {

    private func hunks(_ base: String, _ new: String) -> [LineDiff.DiffHunk] {
        LineDiff.hunks(from: base, to: new)
    }

    @Test func rejectNone_returnsNewUnchanged() {
        let base = "a\nb\nc\n", new = "a\nB\nc\n"
        #expect(AgentDiffApply.revertingRejectedHunks(in: new, hunks: hunks(base, new), rejected: []) == new)
    }

    @Test func rejectAll_reconstructsBase() {
        let base = "a\nb\nc\nd\n", new = "a\nB\nc\nD\n"
        #expect(AgentDiffApply.revertingAll(in: new, hunks: hunks(base, new)) == base)
    }

    @Test func rejectOneHunk_revertsThatHunkOnly() {
        // Two changes >2*context apart → two separate hunks (line 2 and line 10).
        let base = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"
        let new  = "l1\nX2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nX10\n"
        let h = hunks(base, new)
        #expect(h.count == 2, "expected two separated hunks, got \(h.count)")
        // Reject hunk 0 (the line-2 change) → l2 restored, X10 kept.
        let out = AgentDiffApply.revertingRejectedHunks(in: new, hunks: h, rejected: [0])
        #expect(out == "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nX10\n")
        // Reject hunk 1 instead → X2 kept, l10 restored.
        let out2 = AgentDiffApply.revertingRejectedHunks(in: new, hunks: h, rejected: [1])
        #expect(out2 == "l1\nX2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n")
    }

    @Test func rejectPureInsertion_removesIt() {
        let base = "a\nb\nc\n", new = "a\nINSERTED\nb\nc\n"
        #expect(AgentDiffApply.revertingAll(in: new, hunks: hunks(base, new)) == base)
    }

    @Test func rejectPureDeletion_restoresIt() {
        let base = "a\nb\nc\n", new = "a\nc\n"
        #expect(AgentDiffApply.revertingAll(in: new, hunks: hunks(base, new)) == base)
    }

    @Test func outOfRangeIndices_ignored() {
        let base = "a\nb\n", new = "a\nB\n"
        let h = hunks(base, new)
        #expect(AgentDiffApply.revertingRejectedHunks(in: new, hunks: h, rejected: [99]) == new)
    }

    // MARK: applyToFile — the guarded file-level apply (divergence safety)

    @Test func applyToFile_replacesUniqueEdit() {
        let file = "alpha\nNEW LINE\nomega"
        #expect(AgentDiffApply.applyToFile(fileContent: file, newString: "NEW LINE", resolvedNewSide: "OLD LINE")
                == "alpha\nOLD LINE\nomega", "the unique agent edit is reverted in place")
    }

    @Test func applyToFile_divergedFile_returnsNil() {
        let file = "alpha\nSOMETHING ELSE\nomega"   // the agent's new text is gone
        #expect(AgentDiffApply.applyToFile(fileContent: file, newString: "NEW LINE", resolvedNewSide: "OLD LINE")
                == nil, "absent edit (diverged file) → nil, never a corrupting write")
    }

    @Test func applyToFile_ambiguousOccurrences_returnsNil() {
        let file = "DUP\nmiddle\nDUP"
        #expect(AgentDiffApply.applyToFile(fileContent: file, newString: "DUP", resolvedNewSide: "X")
                == nil, "more than one occurrence → ambiguous → nil")
    }

    @Test func applyToFile_emptyNewString_returnsNil() {
        #expect(AgentDiffApply.applyToFile(fileContent: "x", newString: "", resolvedNewSide: "y") == nil)
    }
}
