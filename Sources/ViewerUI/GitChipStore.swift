import Foundation
import Combine
import ViewerCore

/// Off-main cache for the StatusBar git-chip menu data (local branches +
/// worktrees) so the `Menu` content builder NEVER spawns a `git` subprocess on
/// the SwiftUI body/layout path.
///
/// TSK-734 (crash): SwiftUI evaluates `Menu` content *during the layout/commit
/// pass* (it is NOT strictly click-deferred). The old `gitChipMenu` called
/// `GitClient.localBranches()` / `worktreeList()` synchronously there, and
/// `NSTask.waitUntilExit()` spins a nested `CFRunLoop` *inside*
/// `CA::Transaction::commit()` → AppKit detects the reentrancy and raises an
/// NSException → `+[NSApplication _crashOnException:]` → `SIGTRAP`. Moving the
/// enumeration off-main (here) and having the menu read only the published
/// cache removes the subprocess from every body/layout eval.
@MainActor
public final class GitChipStore: ObservableObject {
    @Published public private(set) var branches: [String] = []
    @Published public private(set) var worktrees: [GitClient.WorktreeEntry] = []
    /// The repo root the current cache belongs to (nil until the first load).
    public private(set) var loadedRoot: URL?

    public init() {}

    /// Runs the git enumeration for `root`. Injectable so tests can supply a
    /// counting fake (and so the production path is the only place that touches
    /// `GitClient`). The default hops off the main thread via `Task.detached` —
    /// that off-main hop is the whole point (a main-thread `git` subprocess is
    /// what crashed). `@Sendable` because it is invoked across the actor hop.
    public var enumerate: @Sendable (URL) async -> ([String], [GitClient.WorktreeEntry]) = { root in
        await Task.detached {
            let client = GitClient(repoRoot: root, statusTimeout: 5)
            return (client.localBranches(), client.worktreeList())
        }.value
    }

    /// Populate the cache for `root`. Call from a `.task(id: root)` on the chip
    /// so the data is ready by the time the user opens the menu; the menu reads
    /// only `branches` / `worktrees`, never `GitClient`.
    public func load(root: URL) async {
        let (b, w) = await enumerate(root)
        branches = b
        worktrees = w
        loadedRoot = root
    }
}
