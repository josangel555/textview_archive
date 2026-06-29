import Foundation

// Per-file view-mode lock (TSK-1110 SRP slice; TSK-811) — the ModeBar lock-icon
// state + toggle. The `viewModeLocks` store stays on DocumentModel. Behavior-
// preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// Whether the current file has a view-mode LOCK (the ModeBar lock-icon
    /// filled/unfilled state). `false` when no file is open.
    public var currentViewModeIsLocked: Bool {
        guard let url = currentURL else { return false }
        return viewModeLocks.isLocked(for: url)
    }

    /// Toggle the current file's view-mode lock (the lock-icon click): if
    /// already locked, clear it; otherwise lock the file to the tab's CURRENT
    /// mode so reopening re-applies it. Publishes so the icon updates at once.
    public func toggleCurrentViewModeLock() {
        guard let url = currentURL else { return }
        viewModeLocks.toggle(url, mode: currentViewMode)
        objectWillChange.send()
    }
}
