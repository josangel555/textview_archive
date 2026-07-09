import Testing
@testable import ViewerCore

/// TSK-1443 — the pure confirm-gate for the Status-tab index actions. This is
/// the host-side teeth on "destructive actions never run silently": if a future
/// change flips `discard.requiresConfirm` to false, this fails.
struct GitStageOpTests {

    @Test func onlyDiscardRequiresConfirmation() {
        #expect(GitStageOp.discard.requiresConfirm == true)
        #expect(GitStageOp.stage.requiresConfirm == false)
        #expect(GitStageOp.unstage.requiresConfirm == false)
        #expect(GitStageOp.commit.requiresConfirm == false)
    }

    @Test func discardCarriesConfirmationCopy() {
        let copy = GitStageOp.discard.confirmation(path: "src/a.swift")
        #expect(copy != nil)
        #expect(copy?.title.contains("src/a.swift") == true)
        #expect(copy?.verb == "Discard Changes")
        #expect(copy?.message.isEmpty == false)
    }

    @Test(arguments: [GitStageOp.stage, .unstage, .commit])
    func nonDestructiveOpsHaveNoConfirmationCopy(op: GitStageOp) {
        #expect(op.confirmation(path: "x") == nil)
    }

    @Test func verbsAreDistinctAndLowercase() {
        let verbs = GitStageOp.allCases.map(\.verb)
        #expect(Set(verbs).count == verbs.count)
        #expect(verbs.allSatisfy { $0 == $0.lowercased() })
    }
}
