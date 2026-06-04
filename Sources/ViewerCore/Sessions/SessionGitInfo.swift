import Foundation

/// Lightweight, **subprocess-free** git facts for a session's folder, cheap
/// enough to call from a SwiftUI row body.
///
/// The session-tab strip (`SessionTabBar`) renders one cell per open session
/// and wants two cheap signals: *is this folder a git repo root* and *what
/// branch is checked out*. Spawning `git` (as `GitClient.headInfo()` does —
/// two `git` invocations) per cell per body pass is a non-starter on the main
/// actor. Both facts are available from plain filesystem reads:
///
///   - **Repo root**: a `.git` entry directly inside the folder. A normal
///     checkout has a `.git` *directory*; a linked worktree / submodule has a
///     `.git` *file* whose contents are `gitdir: <path>`. We accept either —
///     matching `GitClient.discoverRoot`'s `fileExists` test, but anchored to
///     the folder itself (we want "is this folder a root", not "is it inside a
///     repo"), so a child folder of a repo does NOT read as a root.
///
///   - **Branch**: `.git/HEAD` is a tiny text file: `ref: refs/heads/<branch>`
///     on a normal branch, or a bare 40-char SHA when detached. For a linked
///     worktree the `.git` file points at the real gitdir; we resolve one hop
///     and read its `HEAD`. No index parse, no subprocess.
///
/// All reads are bounded (HEAD is a few dozen bytes) and best-effort: any I/O
/// failure degrades to "not a repo" / "no branch", never throws. Pure value
/// logic split out so it is host-safe and unit-testable (T1m) without a live
/// git binary.
public enum SessionGitInfo {

    /// What the strip needs to render the badge: whether the folder is a repo
    /// root, and (if resolvable) the current branch. `branch == nil` with
    /// `isRepoRoot == true` means a detached HEAD (or an unreadable ref) — the
    /// caller still shows the git glyph, just without a branch label.
    public struct Badge: Equatable, Sendable {
        public let isRepoRoot: Bool
        public let branch: String?

        public init(isRepoRoot: Bool, branch: String? = nil) {
            self.isRepoRoot = isRepoRoot
            self.branch = branch
        }

        /// The "no git here" result — the common case for a non-repo folder.
        public static let none = Badge(isRepoRoot: false, branch: nil)
    }

    /// Resolve the badge for `rootPath` (a session's `sidebarRootPath`).
    /// `nil` / empty path → `.none`.
    public static func badge(forRootPath rootPath: String?) -> Badge {
        guard let rootPath, !rootPath.isEmpty else { return .none }
        return badge(for: URL(fileURLWithPath: rootPath, isDirectory: true))
    }

    /// Resolve the badge for a folder URL.
    public static func badge(for folder: URL) -> Badge {
        let fm = FileManager.default
        let dotGit = folder.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) else {
            return .none
        }
        let gitDir = resolveGitDir(dotGit: dotGit, isDirectory: isDir.boolValue)
        let branch = gitDir.flatMap { readBranch(gitDir: $0) }
        return Badge(isRepoRoot: true, branch: branch)
    }

    // MARK: - footer chip formatting (UX-C, #225)

    /// Format the footer git chip label as `repo · branch` (or just `repo`
    /// when HEAD is detached / unreadable). Returns `nil` when `folder`
    /// isn't a repo root — the caller hides the chip entirely.
    ///
    /// `folder` is the current file's discovered repo root; its last path
    /// component is the repo-folder name. Pure over the resolved badge so
    /// it's T1m-testable without touching the filesystem twice — pass an
    /// explicit `badge` to test the formatting in isolation.
    public static func footerLabel(
        for folder: URL,
        badge resolved: Badge? = nil
    ) -> String? {
        let badge = resolved ?? badge(for: folder)
        guard badge.isRepoRoot else { return nil }
        return footerLabel(repoName: folder.lastPathComponent, branch: badge.branch)
    }

    /// Pure label composer: `repo · branch`, or just `repo` when `branch`
    /// is nil/empty (detached HEAD). Split out so the exact `·` separator
    /// and detached-HEAD fallback are pinned by unit tests independent of
    /// any `.git` fixture.
    public static func footerLabel(repoName: String, branch: String?) -> String {
        let name = repoName.isEmpty ? "(repo)" : repoName
        if let branch, !branch.isEmpty {
            return "\(name) · \(branch)"
        }
        return name
    }

    // MARK: - private

    /// Resolve the real `.git` directory. For a normal checkout `.git` IS the
    /// directory. For a linked worktree / submodule, `.git` is a FILE whose
    /// single line is `gitdir: <path>` (absolute, or relative to the folder).
    private static func resolveGitDir(dotGit: URL, isDirectory: Bool) -> URL? {
        if isDirectory { return dotGit }
        // `.git` is a file: read the `gitdir:` pointer (one short line).
        guard let raw = try? String(contentsOf: dotGit, encoding: .utf8) else {
            return nil
        }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir:"
        guard line.hasPrefix(prefix) else { return nil }
        let target = line.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if target.hasPrefix("/") {
            return URL(fileURLWithPath: target, isDirectory: true)
        }
        // Relative to the folder containing the `.git` file.
        return dotGit.deletingLastPathComponent()
            .appendingPathComponent(target)
            .standardizedFileURL
    }

    /// Parse `<gitDir>/HEAD`. `ref: refs/heads/<branch>` → the branch leaf;
    /// a bare SHA (detached HEAD) or any unparseable content → `nil`.
    private static func readBranch(gitDir: URL) -> String? {
        let head = gitDir.appendingPathComponent("HEAD")
        guard let raw = try? String(contentsOf: head, encoding: .utf8) else {
            return nil
        }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref:"
        guard line.hasPrefix(refPrefix) else {
            // Detached HEAD (bare SHA) — no symbolic branch.
            return nil
        }
        let ref = line.dropFirst(refPrefix.count)
            .trimmingCharacters(in: .whitespaces)
        // `refs/heads/feature/x` → `feature/x` (keep slashes after the
        // `refs/heads/` prefix so nested branch names survive).
        let headsPrefix = "refs/heads/"
        if ref.hasPrefix(headsPrefix) {
            let branch = String(ref.dropFirst(headsPrefix.count))
            return branch.isEmpty ? nil : branch
        }
        // Some other ref namespace (rare for a checkout) — surface the leaf.
        let leaf = ref.split(separator: "/").last.map(String.init)
        return (leaf?.isEmpty == false) ? leaf : nil
    }
}
