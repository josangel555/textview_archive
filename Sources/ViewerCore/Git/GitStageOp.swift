import Foundation

/// The interactive Status-tab index actions (TSK-1443), and — crucially — the
/// PURE decision of which of them are DESTRUCTIVE and must be confirmed before
/// they run. Keeping the confirm-gate here (not inline in the view) makes the
/// "never silent data loss" invariant host-testable: a regression that lets a
/// discard run without confirmation fails a unit test, not just a VM pass.
public enum GitStageOp: Equatable, Sendable, CaseIterable {
    /// `git add` — stage a modified/untracked file. Reversible (`unstage`).
    case stage
    /// `git reset HEAD` (or `rm --cached` on an unborn HEAD) — reversible.
    case unstage
    /// `git commit` the staged index. Reversible (amend / reset) and gated by
    /// a non-empty message, so no confirm.
    case commit
    /// `git checkout -- <path>` — reverts working-tree changes to HEAD/index.
    /// DESTRUCTIVE: uncommitted edits are lost with no git-side undo.
    case discard

    /// True for ops that silently and irreversibly lose the user's work if run
    /// by accident — the UI must present a confirmation first. Stage / unstage /
    /// commit are all reversible, so they run immediately.
    public var requiresConfirm: Bool {
        switch self {
        case .discard:                    return true
        case .stage, .unstage, .commit:   return false
        }
    }

    /// Lower-case verb for toast/error copy ("Git stage failed").
    public var verb: String {
        switch self {
        case .stage:   return "stage"
        case .unstage: return "unstage"
        case .commit:  return "commit"
        case .discard: return "discard"
        }
    }

    /// Confirmation copy for a destructive op on `path` (title · message ·
    /// destructive-button verb), or `nil` for a non-confirming op. The verb is
    /// separated so the view can style the confirm button `.destructive`.
    public func confirmation(path: String) -> (title: String, message: String, verb: String)? {
        switch self {
        case .discard:
            return (
                title: "Discard changes to “\(path)”?",
                message: "This reverts the file to its last committed state. "
                    + "Any uncommitted changes to it are lost and can’t be recovered.",
                verb: "Discard Changes")
        case .stage, .unstage, .commit:
            return nil
        }
    }
}
