import Combine
import Foundation

/// The root-folder abstraction the app's root / file-tree wiring consumes
/// INSTEAD of reaching into `SessionsCoordinator` directly (TSK-264,
/// foundation slice of the Sessions-optional epic).
///
/// Two implementations exist:
///
///   - `SessionRootContext` — the existing multi-session experience,
///     backed by a `SessionsCoordinator` (an index of sessions, per-
///     session snapshots, trash, LRU). This is what the app builds when
///     `sessionsEnabled == true`.
///   - `SingleRootContext` — a single root folder, NO session index, NO
///     per-session snapshots, NO trash. `openFolder` rebinds the one
///     root in place. This is what the app builds when
///     `sessionsEnabled == false`.
///
/// Why a protocol and not a flag-laden `SessionsCoordinator`: keeping the
/// session machinery intact behind a seam lets us turn it off cleanly
/// (no `Sessions/` writes, no index restore on launch) without ripping
/// it out — the no-session path is a *different provider*, not a degraded
/// session provider. The seam is also the natural place a future "remote
/// root" or "scratch root" provider would slot in.
///
/// `@MainActor` because the file-tree / sidebar wiring it drives is, and
/// because the session-backed implementation wraps a `@MainActor`
/// coordinator.
@MainActor
public protocol RootContextProviding: AnyObject {
    /// The currently-bound root folder, or `nil` when nothing is open
    /// (fresh launch with no remembered root). The file tree / sidebar
    /// roots itself here.
    var currentRoot: URL? { get }

    /// True when this provider exposes the multi-session UI surface
    /// (the session tab strip). The session-backed provider returns
    /// `true`; `SingleRootContext` returns `false`. The view layer reads
    /// this to hide/show `SessionTabBar` (TSK-264 UI skeleton — we only
    /// gate the strip's visibility; we do NOT rip sessions out).
    var exposesSessionUI: Bool { get }

    /// Rebind the root to `url`. For `SingleRootContext` this replaces
    /// the one root in place; for the session-backed provider it routes
    /// through `SessionsCoordinator.openFolder` (reveal-or-create).
    func openFolder(_ url: URL)

    /// A change signal the view layer can observe. Fires whenever
    /// `currentRoot` changes. Type-erased to keep this protocol free of
    /// the concrete publisher type each implementation uses.
    var rootDidChange: AnyPublisher<Void, Never> { get }
}
