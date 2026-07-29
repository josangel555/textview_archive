import AppKit
import Foundation
import ViewerCore

/// Preservation rules for disk-conflict resolution (owner directive,
/// 2026-07-28): *"don't delete anything — even the discarded version should be
/// in Local History … Never silently pick any version, or silently overwrite a
/// change that happened outside the app."*
///
/// Every conflict branch destroys one side of a divergence:
/// - **Keep Mine** re-baselines the buffer against disk, so the app forgets the
///   external write and the next ⌘S overwrites it — the DISK version is the
///   casualty, just deferred.
/// - **Take Disk** discards the unsaved buffer outright — MY version is the
///   casualty, immediately.
/// - **Merge** replaces the buffer with merged text — the pre-merge "mine" is
///   the casualty.
///
/// So each branch captures the side it is about to lose into Local History
/// FIRST. The capture is checked, not assumed: `LocalHistoryStore` legitimately
/// declines secrets, oversize, binary and disabled-history content, and a
/// caller that ignored that would destroy exactly the bytes the user was told
/// were safe. When preservation fails the user is asked, with the reason,
/// instead of the app quietly proceeding.
extension DocumentModel {

    /// Which side of a conflict a capture refers to — used in the copy the user
    /// sees, so a failure names the thing that would be lost.
    public enum ConflictSide: String, Sendable {
        case mine
        case disk

        public var label: String {
            switch self {
            case .mine: return "your unsaved edits"
            case .disk: return "the version on disk"
            }
        }
    }

    public enum UnpreservedDiscardChoice: String, Sendable, Equatable {
        case cancel
        case proceedAnyway
    }

    /// Capture one side of a conflict into Local History before it is lost.
    @discardableResult
    public func preserveConflictSide(
        _ side: ConflictSide, text: String, path: String, at date: Date = Date()
    ) -> LocalHistoryStore.CaptureOutcome {
        _ = side  // side is for the prompt copy; the store keys on path only
        return localHistoryStore.capture(path: path, content: text, at: date)
    }

    /// Gate a destructive branch on its capture. Returns true when it is safe
    /// to proceed — either the content is recoverable, or the user explicitly
    /// accepted losing it.
    ///
    /// NEVER returns true silently on a failed capture: that is the whole point
    /// of the directive.
    public func confirmDiscardIsPreserved(
        _ outcome: LocalHistoryStore.CaptureOutcome,
        side: ConflictSide,
        fileName: String
    ) -> Bool {
        if outcome.isPreserved { return true }
        let reason = outcome.refusal?.explanation ?? "it could not be saved"
        let choice = unpreservedDiscardPromptOverride?(fileName, side, reason)
            ?? runUnpreservedDiscardAlert(fileName: fileName, side: side, reason: reason)
        return choice == .proceedAnyway
    }

    /// The modal shown when Local History could not keep the copy. Cancel is the
    /// default button — the safe answer when the app cannot promise recovery.
    /// Never runs under the headless gate (tests install the override).
    private func runUnpreservedDiscardAlert(
        fileName: String, side: ConflictSide, reason: String
    ) -> UnpreservedDiscardChoice {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Can't keep a copy of \(side.label)"
        alert.informativeText =
            "\(fileName): Local History can't store this version because \(reason). "
            + "If you continue, \(side.label) will be lost permanently."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Anyway")
        return alert.runModal() == .alertFirstButtonReturn ? .cancel : .proceedAnyway
    }

    /// Current on-disk text for a conflicted tab, read with the buffer's own
    /// encoding so the captured copy round-trips.
    func diskText(forTabID id: UUID, url: URL) -> String? {
        let encoding = editor.editorBuffers[id]?.encoding ?? .utf8
        return try? String(contentsOf: url, encoding: encoding)
    }
}
