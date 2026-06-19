import Foundation

/// Selects which `RootContextProviding` implementation to build at launch
/// based on the persisted `sessionsEnabled` flag (TSK-264).
///
///   - `sessionsEnabled == true`  → `SessionRootContext` wrapping the
///     supplied `SessionsCoordinator` (the full multi-session experience).
///   - `sessionsEnabled == false` → `SingleRootContext` seeded from
///     `PreferencesStore.lastFolderURL`, persisting its root back to the
///     same preference. NO `SessionsCoordinator` / `SessionStore` is
///     touched on this path, so no `Sessions/` writes occur.
///
/// Kept as a free function (not baked into `SessionsAppCoordinator.init`)
/// so the selection logic is host-testable in isolation — a test can pass
/// a `PreferencesStore` over a throwaway `UserDefaults(suiteName:)`, flip
/// the flag, and assert the concrete provider type without spinning up the
/// session machinery.
@MainActor
public enum RootContextFactory {

    /// Build the provider the flag selects.
    ///
    /// - Parameters:
    ///   - preferences: source of the `sessionsEnabled` flag and the
    ///     `lastFolderURL` seed/persist target.
    ///   - sessionCoordinator: the coordinator to wrap when sessions are
    ///     enabled. A non-`nil` value is REQUIRED on the enabled path; on
    ///     the disabled path it's ignored (and may be `nil`).
    /// - Returns: a `SessionRootContext` or a `SingleRootContext`.
    public static func make(
        preferences: PreferencesStore,
        sessionCoordinator: @autoclosure () -> SessionsCoordinator?
    ) -> any RootContextProviding {
        if preferences.sessionsEnabled {
            // The enabled path needs a coordinator; if the caller failed to
            // supply one, fall back to the single-root provider rather than
            // crash — losing the session UI is strictly better than a launch
            // abort. (In production the coordinator is always supplied.)
            if let coord = sessionCoordinator() {
                return SessionRootContext(coordinator: coord)
            }
        }
        // Disabled (or no coordinator): single root, no session machinery.
        // Persist the root back to the same `lastFolderURL` preference the
        // disabled-launch path reads, so a relaunch re-binds where the user
        // left off — without any `Sessions/` writes.
        return SingleRootContext(
            initialRoot: preferences.lastFolderURL,
            onRootChange: { url in preferences.lastFolderURL = url }
        )
    }
}
