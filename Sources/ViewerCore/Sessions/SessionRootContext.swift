import Combine
import Foundation

/// The session-backed `RootContextProviding` implementation (TSK-264).
///
/// A thin adapter over the existing `SessionsCoordinator`: `currentRoot`
/// is the active session's sidebar root, `openFolder` routes through
/// `SessionsCoordinator.openFolder` (the reveal-or-create + persistence
/// pipeline), and `rootDidChange` rides the coordinator's published
/// session list / active pointer. This is the provider the app builds
/// when `sessionsEnabled == true`, so the existing multi-session behavior
/// (index, snapshots, trash, LRU) is entirely unchanged — it's just now
/// reached through the `RootContextProviding` seam.
///
/// `@MainActor` to match the protocol and the wrapped coordinator.
@MainActor
public final class SessionRootContext: RootContextProviding {

    private let coordinator: SessionsCoordinator

    public init(coordinator: SessionsCoordinator) {
        self.coordinator = coordinator
    }

    public var currentRoot: URL? {
        guard let path = coordinator.active?.sidebarRootPath, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// The session-backed provider DOES expose the session tab strip.
    public nonisolated var exposesSessionUI: Bool { true }

    public func openFolder(_ url: URL) {
        coordinator.openFolder(url)
    }

    /// Fires whenever the session list or active pointer changes (which
    /// is the only way the active root can change). We don't try to
    /// filter to root-only edits — a session rename / reorder republish
    /// is cheap and the view layer's own equality already de-dupes.
    public var rootDidChange: AnyPublisher<Void, Never> {
        coordinator.objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }
}
