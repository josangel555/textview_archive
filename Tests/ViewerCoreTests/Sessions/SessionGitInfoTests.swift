import XCTest
@testable import ViewerCore

/// Host-safe (T1m) tests for `SessionGitInfo` — the subprocess-free git-root +
/// branch reader the session-tab strip (B1) uses for its per-row badge.
///
/// We never spawn `git`: every fixture is a hand-built `.git` directory / file
/// in temp scratch (`FileManager.temporaryDirectory`, per CLAUDE.md — never
/// `~/Documents`). That keeps the suite host-green and fast, and pins the exact
/// `.git/HEAD` / worktree-pointer parsing the live badge depends on.
final class SessionGitInfoTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-gitinfo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// Build a folder with a `.git` DIRECTORY containing a `HEAD` file with
    /// the given contents; returns the folder URL.
    private func makeRepo(headContents: String, named name: String = "repo") throws -> URL {
        let folder = scratch.appendingPathComponent(name, isDirectory: true)
        let gitDir = folder.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try headContents.data(using: .utf8)!
            .write(to: gitDir.appendingPathComponent("HEAD"))
        return folder
    }

    // MARK: - not a repo

    func test_nonRepoFolder_returnsNone() throws {
        let plain = scratch.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertEqual(SessionGitInfo.badge(for: plain), .none)
    }

    func test_nilAndEmptyPath_returnNone() {
        XCTAssertEqual(SessionGitInfo.badge(forRootPath: nil), .none)
        XCTAssertEqual(SessionGitInfo.badge(forRootPath: ""), .none)
    }

    /// A *child* of a repo is not itself a root: the badge anchors to the
    /// folder, not "anywhere up the tree" (unlike `GitClient.discoverRoot`).
    func test_childOfRepo_isNotRoot() throws {
        let repo = try makeRepo(headContents: "ref: refs/heads/main\n")
        let child = repo.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertEqual(SessionGitInfo.badge(for: child), .none)
    }

    // MARK: - branch parsing

    func test_repoRoot_readsBranch() throws {
        let repo = try makeRepo(headContents: "ref: refs/heads/main\n")
        let badge = SessionGitInfo.badge(for: repo)
        XCTAssertTrue(badge.isRepoRoot)
        XCTAssertEqual(badge.branch, "main")
    }

    func test_nestedBranchName_keepsSlashes() throws {
        let repo = try makeRepo(headContents: "ref: refs/heads/feature/login-v2\n")
        XCTAssertEqual(SessionGitInfo.badge(for: repo).branch, "feature/login-v2")
    }

    func test_detachedHead_isRootButNoBranch() throws {
        // A detached HEAD is a bare 40-char SHA, no `ref:` prefix.
        let repo = try makeRepo(headContents: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\n")
        let badge = SessionGitInfo.badge(for: repo)
        XCTAssertTrue(badge.isRepoRoot, "detached HEAD is still a repo root")
        XCTAssertNil(badge.branch, "detached HEAD has no symbolic branch")
    }

    func test_headWithoutTrailingNewline_parses() throws {
        let repo = try makeRepo(headContents: "ref: refs/heads/dev")
        XCTAssertEqual(SessionGitInfo.badge(for: repo).branch, "dev")
    }

    // MARK: - linked worktree (`.git` is a FILE)

    func test_linkedWorktree_resolvesGitdirPointer_andReadsBranch() throws {
        // The real gitdir lives elsewhere; the worktree's `.git` is a FILE
        // with a `gitdir:` pointer. We resolve one hop and read its HEAD.
        let realGitDir = scratch.appendingPathComponent("real-gitdir", isDirectory: true)
        try FileManager.default.createDirectory(at: realGitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/wt-branch\n".data(using: .utf8)!
            .write(to: realGitDir.appendingPathComponent("HEAD"))

        let worktree = scratch.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(realGitDir.path)\n".data(using: .utf8)!
            .write(to: worktree.appendingPathComponent(".git"))

        let badge = SessionGitInfo.badge(for: worktree)
        XCTAssertTrue(badge.isRepoRoot, "a `.git` FILE still marks a worktree root")
        XCTAssertEqual(badge.branch, "wt-branch")
    }

    func test_gitFileWithGarbage_isRootButNoBranch() throws {
        // A `.git` file that isn't a valid `gitdir:` pointer: still treat the
        // folder as a repo root (the `.git` entry exists), but no branch.
        let folder = scratch.appendingPathComponent("oddrepo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "not a gitdir pointer\n".data(using: .utf8)!
            .write(to: folder.appendingPathComponent(".git"))
        let badge = SessionGitInfo.badge(for: folder)
        XCTAssertTrue(badge.isRepoRoot)
        XCTAssertNil(badge.branch)
    }

    // MARK: - path-string entry point

    func test_forRootPath_matchesURLEntryPoint() throws {
        let repo = try makeRepo(headContents: "ref: refs/heads/main\n")
        XCTAssertEqual(SessionGitInfo.badge(forRootPath: repo.path),
                       SessionGitInfo.badge(for: repo))
    }
}
