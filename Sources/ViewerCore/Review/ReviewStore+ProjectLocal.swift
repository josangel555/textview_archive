import Foundation

// MARK: - ReviewStore + project-local resolution
//
// v2 (CODE_REVIEW_V2_DESIGN_2026-06-01.md §1, §5.1): relocate the review
// store from the global Application Support dir into a project-local
// `<repoRoot>/.textview/reviews/` sidecar so reviews live alongside the repo
// (git-ignored by default — opt in per-repo via config.json — and handed to
// Claude alongside the code when shared).
//
// This is an ADDITIVE extension only. `ReviewStore.init(directory:)` is
// already injectable, so no change to `ReviewStore` proper is required —
// the on-disk format, CRUD, index, size-guard and schema-gate are all
// reused verbatim. The only thing that changes is *where* the directory is.

extension ReviewStore {

    /// Name of the project-local sidecar directory. A dotfile so it stays
    /// out of the way in file listings; the user-facing "TextView sidecar".
    public static let sidecarDirName = ".textview"

    /// The `reviews/` tenant inside the sidecar. Laid out so a future
    /// Sessions feature can add sibling tenants (`sessions/`, `workspaces/`)
    /// without disturbing this one.
    public static let reviewsTenantName = "reviews"

    /// Environment override (§1.5): relocate the whole sidecar elsewhere
    /// (e.g. to a non-dotted, cloud-syncable path). When set, the reviews
    /// store lives at `$MDV_TEXTVIEW_DIR/reviews/`.
    public static let sidecarDirEnvVar = "MDV_TEXTVIEW_DIR"

    /// Resolve the project-local sidecar root for a repo.
    ///
    /// Resolution order (§1.5):
    ///   1. `$MDV_TEXTVIEW_DIR` (env override) — used verbatim.
    ///   2. `<repoRoot>/.textview` (the default).
    ///
    /// `environment` is injectable so tests can exercise the override
    /// without mutating the process environment.
    public static func sidecarRoot(
        repoRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[sidecarDirEnvVar],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return repoRoot.appendingPathComponent(sidecarDirName, isDirectory: true)
    }

    /// The reviews directory inside the resolved sidecar root.
    public static func projectLocalDirectory(
        repoRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        sidecarRoot(repoRoot: repoRoot, environment: environment)
            .appendingPathComponent(reviewsTenantName, isDirectory: true)
    }

    /// A store whose directory is `<repoRoot>/.textview/reviews/` (or the
    /// `$MDV_TEXTVIEW_DIR` override). Creates the directory eagerly so the
    /// first save / index write doesn't race the parent-dir creation.
    ///
    /// Pass `repoRoot` as the absolute working-tree root, typically from
    /// `GitClient.discoverRoot(from:)`.
    public static func projectLocal(
        repoRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ReviewStore {
        let dir = projectLocalDirectory(repoRoot: repoRoot, environment: environment)
        // Best-effort: `JSONFileStore.write` also creates intermediate dirs,
        // but eager creation keeps `list()` on a fresh repo from racing.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return ReviewStore(directory: dir)
    }
}
