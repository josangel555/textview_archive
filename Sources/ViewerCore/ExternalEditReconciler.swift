import Foundation

/// Non-blocking reconciliation when a file changes ON DISK while the editor
/// holds UNSAVED local edits (TSK-764). Instead of forcing a blunt
/// keep-mine / reload-theirs choice, this composes the diff3 three-way merge
/// ([`ThreeWayMerge`], TSK-712) over (base = last-saved, ours = local unsaved,
/// theirs = current disk) so non-overlapping external edits auto-merge and only
/// genuine overlaps surface as a conflict.
///
/// Pure logic — host-testable. The editor wiring (detect the disk change via the
/// saved mtime/size baseline, then present the outcome) is the render tail.
public enum ExternalEditReconciler {

    public enum Outcome: Equatable, Sendable {
        /// Disk matches the last-saved baseline — no external change; keep local.
        case noExternalChange
        /// No local edits (local == base) — safe to take the disk version wholesale.
        case cleanReload(String)
        /// Disk and local diverged in NON-overlapping regions — auto-merged cleanly.
        case autoMerged(String)
        /// Overlapping edits — `merged` carries git-style conflict markers for the
        /// user to resolve; `conflictCount` regions need attention.
        case conflict(merged: String, conflictCount: Int)
    }

    /// Reconcile `local` (in-editor, possibly unsaved) against `disk` (current
    /// file content) relative to `base` (the content at last save).
    public static func reconcile(
        base: String,
        local: String,
        disk: String,
        oursLabel: String = "your edits",
        theirsLabel: String = "on disk"
    ) -> Outcome {
        if disk == base { return .noExternalChange }      // no external edit
        if local == base { return .cleanReload(disk) }    // no local edits → take disk
        let result = ThreeWayMerge.merge(base: base, ours: local, theirs: disk)
        if let merged = result.autoMerged {
            return .autoMerged(merged.joined(separator: "\n"))
        }
        return .conflict(
            merged: result.text(oursLabel: oursLabel, theirsLabel: theirsLabel),
            conflictCount: result.conflictCount
        )
    }
}
