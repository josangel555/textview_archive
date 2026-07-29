import Foundation

/// TSK-1602 — Git Log view preferences.
///
/// `showAllRefs`: load the ALL-REFS graph (`git log --all HEAD`) instead of
/// only the current worktree's history, so every worktree's branch tip and
/// the divergence points between them are visible in ONE graph. Ships OFF —
/// it widens the graph for single-worktree repos, where the current-branch
/// view is what the user wants; the Log tab's "All refs" toggle turns it on
/// (and the panel offers it prominently once >1 worktree exists).
public enum GitLogPrefs {
    public static let showAllRefsKey = "mdv.gitLog.showAllRefs"
    public static let showAllRefsDefault = false

    /// Read the persisted value, falling back to the shipped default when the
    /// key was never written (a bare `bool(forKey:)` can't tell those apart).
    public static func resolveShowAllRefs(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: showAllRefsKey) as? Bool ?? showAllRefsDefault
    }
}
