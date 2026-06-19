import Combine
import Foundation

/// The no-session `RootContextProviding` implementation (TSK-264).
///
/// Holds EXACTLY ONE root folder and nothing else: no session index, no
/// per-session snapshots, no trash. `openFolder` rebinds the single root
/// in place. Critically, it touches NO `Sessions/` directory at all — it
/// never constructs or drives a `SessionStore`, so a user who turns
/// sessions off stops accruing `index.json` / `<uuid>.json` / `trash/`
/// writes entirely (asserted by `SingleRootContextTests`).
///
/// The last root is remembered through the SAME `PreferencesStore.lastFolder`
/// preference the session-disabled launch path already reads, so a relaunch
/// re-binds where the user left off without any session machinery. Persisting
/// is delegated to the caller via the `onRootChange` hook (the app wires it to
/// `PreferencesStore.lastFolderURL = …`); keeping the write out of this type
/// lets `ViewerCore` stay free of a concrete preferences dependency and keeps
/// the unit tests pure (no UserDefaults side effects).
///
/// `@MainActor` to match the protocol and the file-tree wiring it feeds.
@MainActor
public final class SingleRootContext: RootContextProviding, ObservableObject {

    @Published public private(set) var currentRoot: URL?

    /// `SingleRootContext` is the no-session provider, so it never exposes
    /// the session tab strip.
    public nonisolated var exposesSessionUI: Bool { false }

    /// Invoked AFTER `currentRoot` is rebound (including the initial bind
    /// in `init`). The app wires this to persist the root
    /// (`PreferencesStore.lastFolderURL`). `nil` = no persistence (tests).
    private let onRootChange: ((URL?) -> Void)?

    /// Normalize a root the same way `SessionsCoordinator.openFolder` does
    /// (`standardizedFileURL` + `resolvingSymlinksInPath`) so the single-
    /// root and session-backed providers agree on what "the same folder"
    /// is — e.g. `/x/proj` and `/x/proj/` and a symlink to it all collapse
    /// to one canonical path. This also stops a re-open of the same folder
    /// from emitting a spurious `rootDidChange`.
    private static func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public init(initialRoot: URL? = nil,
                onRootChange: ((URL?) -> Void)? = nil) {
        self.onRootChange = onRootChange
        if let initialRoot {
            self.currentRoot = Self.normalize(initialRoot)
        }
        // Surface the initial bind so the caller can persist it.
        onRootChange?(self.currentRoot)
    }

    /// Rebind the one root in place. A no-op (no publish, no callback) when
    /// the normalized URL equals the current root, so re-opening the same
    /// folder doesn't churn the change stream.
    public func openFolder(_ url: URL) {
        let resolved = Self.normalize(url)
        guard resolved != currentRoot else { return }
        currentRoot = resolved
        onRootChange?(resolved)
    }

    public var rootDidChange: AnyPublisher<Void, Never> {
        $currentRoot.map { _ in () }.eraseToAnyPublisher()
    }
}
