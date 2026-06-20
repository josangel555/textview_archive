import Foundation

/// The pre-write decision for a ⌘S / Save: given the buffer's load/last-sync
/// fingerprint baseline, the file's CURRENT on-disk fingerprint, and whether the
/// buffer is dirty, decide whether a save may write straight through, must stop
/// and ask the user to resolve a conflict, or should just reload the (clean)
/// buffer from disk.
///
/// This closes the data-loss class where ⌘S blind-overwrites a change another
/// process made to the file AFTER the buffer was loaded/last-synced (the
/// 2026-06-20 incident: a background process rewrote `OwnerWishlist.md` under a
/// dirty buffer, and ⌘S clobbered it with no warning and no recovery). The
/// existing external-edit detection (`EditorCoordinator.presentExternalEditConflict`
/// / `reconcileLostWatcherEvent`) only fires from a watcher tick the app
/// actually observed, or from the post-write recheck of the brief pause window —
/// a write the watcher never reported (FSEvents debounce/coalescing, a different
/// watched URL, the watcher not running) sails straight through. This guard is
/// the WRITE-TIME backstop: it re-stats the file immediately before writing and
/// refuses to clobber a dirty buffer over an unproven-clean disk.
///
/// Pure — no I/O. The owning `EditorCoordinator` reads the buffer fingerprint
/// and the fresh disk stat and hands both in. Mirrors `DiskConflictResolver.classify`
/// (the same `dirty × hasExternalEdit × hasUnknownDiskState` table) so the
/// write-time guard and the watcher-time classifier can't drift.
public enum SaveConflictDecision: Sendable, Equatable {
    /// The save may write straight through:
    ///   - the buffer is clean and there is nothing to lose, OR
    ///   - the file on disk is PROVABLY unchanged since the buffer's baseline.
    case proceed

    /// The buffer is dirty AND the on-disk file changed (or we cannot prove it
    /// is unchanged) since the buffer's baseline. Writing would clobber the
    /// external change with no recovery — STOP and surface a resolution. The
    /// associated `actions` are the offered resolutions, most-conservative first.
    case conflict(actions: [SaveConflictAction])

    /// The buffer is CLEAN but the on-disk file changed. There is nothing to
    /// save and nothing to lose — the right move is to reload the buffer from
    /// disk (the normal external-update path), NOT to prompt. Returned so a
    /// caller that routed a "save" here can short-circuit to a reload.
    case reloadSilently
}

/// A resolution the user can pick when a save hits a conflict. The order in
/// `SaveConflictDecision.conflict(actions:)` is the offered order: the
/// non-destructive choices come first so the default / least-surprising option
/// never silently loses data.
public enum SaveConflictAction: String, Sendable, Equatable, CaseIterable {
    /// Show the difference between the buffer ("mine") and the on-disk bytes
    /// before deciding. Non-destructive; listed first because "look before you
    /// leap" is the safest response to a surprise conflict.
    case viewDiff
    /// Write the buffer to a NEW file, leaving both the on-disk change and the
    /// buffer's edits intact. Non-destructive.
    case saveAsCopy
    /// Discard the buffer's edits and take the on-disk contents. Destructive to
    /// the buffer's unsaved edits (but the disk change survives).
    case reload
    /// Overwrite the on-disk file with the buffer ("keep mine"). Destructive to
    /// the external change — listed LAST so it is never the accidental default.
    case overwrite
}

public extension SaveConflictDecision {
    /// The actions offered for a genuine save conflict, most-conservative first.
    /// Centralised so the decision function, the prompt UI, and the tests agree
    /// on the exact set + order.
    static let conflictActions: [SaveConflictAction] = [
        .viewDiff, .saveAsCopy, .reload, .overwrite,
    ]

    /// Decide a save from the raw signals. Pure; mirrors
    /// `DiskConflictResolver.classify`'s table:
    ///
    ///     dirty?  hasExternalEdit  hasUnknownDiskState  →  decision
    ///     -----   ---------------  -------------------     ----------------------
    ///     no      false            *                       proceed (proven clean / nothing to lose)
    ///     no      true             *                       reloadSilently (clean buffer, disk moved)
    ///     yes     false            false                   proceed (PROVEN unchanged)
    ///     yes     true             *                       conflict (both moved)
    ///     yes     false            true                    conflict (can't prove unchanged — be safe)
    ///
    /// The asymmetry is the whole point: a *dirty* buffer over an unprovable
    /// disk state escalates to a conflict (we refuse to clobber what we can't
    /// confirm), whereas a *clean* buffer just reloads (no edits to lose).
    static func decide(
        dirty: Bool,
        hasExternalEdit: Bool,
        hasUnknownDiskState: Bool
    ) -> SaveConflictDecision {
        if dirty {
            if hasExternalEdit || hasUnknownDiskState {
                return .conflict(actions: conflictActions)
            }
            return .proceed
        } else {
            // Clean buffer: nothing to lose. If disk moved, reload; else proceed
            // (a clean save is effectively a no-op write, but callers may still
            // want the write to happen, so don't divert it to reload spuriously).
            return hasExternalEdit ? .reloadSilently : .proceed
        }
    }

    /// Convenience: decide directly against a live `EditorBuffer` and the
    /// freshly-stat'd current on-disk fingerprint. The caller does the stat
    /// (this stays I/O-free) and hands the `(mtime, size)` in.
    static func decide(
        buffer: EditorBuffer,
        currentMTime: Date?,
        currentSize: Int?
    ) -> SaveConflictDecision {
        decide(
            dirty: buffer.isDirty,
            hasExternalEdit: buffer.hasExternalEdit(
                currentMTime: currentMTime, currentSize: currentSize),
            hasUnknownDiskState: buffer.hasUnknownDiskState(
                currentMTime: currentMTime, currentSize: currentSize)
        )
    }
}
