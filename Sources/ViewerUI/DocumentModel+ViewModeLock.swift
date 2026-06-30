import Foundation
import ViewerKit

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

    // TSK-1152: the per-FILENAME "Lock View As" affordance in the file-nav —
    // lock/unlock an ARBITRARY file (by URL, open or not), distinct from the
    // current-file ModeBar lock above. Reopening the file re-applies the locked
    // mode (subject to availability, via ViewModeLockStore.resolvedMode). All
    // three publish so a file-nav lock indicator + the menu state update at once.

    /// Lock `url` to `mode` (the file-nav "Lock View As → <mode>" choice).
    public func lockViewMode(_ url: URL, to mode: ViewMode) {
        viewModeLocks.lock(url, to: mode)
        objectWillChange.send()
    }

    /// Clear any view-mode lock on `url` (the file-nav "Unlock View As").
    public func unlockViewMode(_ url: URL) {
        viewModeLocks.clear(for: url)
        objectWillChange.send()
    }

    /// Whether `url` (any file) carries a view-mode lock — drives the file-nav
    /// lock indicator + the Lock/Unlock menu state.
    public func viewModeIsLocked(_ url: URL) -> Bool {
        viewModeLocks.isLocked(for: url)
    }
}
