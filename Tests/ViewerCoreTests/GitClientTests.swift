import XCTest
@testable import ViewerCore

/// Tests against a freshly created temp git repo. Skipped if
/// /usr/bin/git isn't available.
final class GitClientTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        // Skip cleanly if no git.
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("/usr/bin/git not available")
        }
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-git-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // git init + identity for clean commits
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.email", "test@example.com"])
        _ = try git(["config", "user.name", "Test"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testDiscoverRootInsideRepo() {
        let nested = tmp.appendingPathComponent("a/b/c")
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let root = GitClient.discoverRoot(from: nested)
        // Path comparison via standardized — temp dirs go through /var/folders or /private/var/folders.
        // Compare paths, not URLs — URLs differ in trailing-slash even
        // after standardization.
        XCTAssertEqual(root?.standardizedFileURL.resolvingSymlinksInPath().path,
                       tmp.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testDiscoverRootOutsideRepo() {
        let outside = URL(fileURLWithPath: "/")
        XCTAssertNil(GitClient.discoverRoot(from: outside))
    }

    func testStatusReflectsNewFile() throws {
        try "hello".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let client = GitClient(repoRoot: tmp)
        let entries = client.status()
        XCTAssertTrue(entries.contains(where: { $0.path == "a.txt" && $0.isUntracked }))
    }

    func testStatusReflectsModifiedFile() throws {
        let f = tmp.appendingPathComponent("a.txt")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        _ = try git(["add", "a.txt"])
        _ = try git(["commit", "-q", "-m", "init"])
        try "v2".write(to: f, atomically: true, encoding: .utf8)
        let entries = GitClient(repoRoot: tmp).status()
        let mod = entries.first(where: { $0.path == "a.txt" })
        XCTAssertEqual(mod?.workingStatus, "M")
    }

    func testStatusEmptyOnCleanRepo() throws {
        let f = tmp.appendingPathComponent("a.txt")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        _ = try git(["add", "a.txt"])
        _ = try git(["commit", "-q", "-m", "init"])
        XCTAssertTrue(GitClient(repoRoot: tmp).status().isEmpty)
    }

    func testLogReturnsEntries() throws {
        try "x".write(to: tmp.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-q", "-m", "first commit"])
        try "y".write(to: tmp.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-q", "-m", "second commit"])
        let log = GitClient(repoRoot: tmp).log()
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log[0].subject, "second commit")
        XCTAssertEqual(log[1].subject, "first commit")
    }

    func testStatusEmptyOutsideRepo() {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-a-repo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        // GitClient.status() catches the error and returns [].
        XCTAssertTrue(GitClient(repoRoot: outside).status().isEmpty)
    }

    // MARK: - diff (Batch C, commit db57c6a)

    func test_diff_returns_unified_diff_for_modified_file() throws {
        // Stage a tracked file at HEAD, modify it, ask for diff.
        let file = tmp.appendingPathComponent("notes.md")
        try "v1\nline two\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try git(["add", "notes.md"])
        _ = try git(["commit", "-q", "-m", "init"])
        try "v1\nline two CHANGED\nline three\n".write(to: file, atomically: true, encoding: .utf8)

        let diff = GitClient(repoRoot: tmp).diff(forPath: "notes.md")
        XCTAssertTrue(diff.contains("--- a/notes.md"),
                      "expected unified-diff header, got:\n\(diff)")
        XCTAssertTrue(diff.contains("+++ b/notes.md"),
                      "expected unified-diff header (b), got:\n\(diff)")
        XCTAssertTrue(diff.contains("+line two CHANGED"),
                      "expected the new line in the patch, got:\n\(diff)")
        XCTAssertTrue(diff.contains("-line two"),
                      "expected the deleted line in the patch, got:\n\(diff)")
        XCTAssertFalse(diff.contains("\u{1B}["),
                       "diff should be color-stripped (--no-color); ANSI escapes leaked")
    }

    func test_diff_is_empty_for_unmodified_file() throws {
        let file = tmp.appendingPathComponent("clean.txt")
        try "static\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try git(["add", "clean.txt"])
        _ = try git(["commit", "-q", "-m", "init"])

        let diff = GitClient(repoRoot: tmp).diff(forPath: "clean.txt")
        XCTAssertTrue(diff.isEmpty || diff.allSatisfy(\.isWhitespace),
                      "expected empty diff for unmodified file, got:\n\(diff)")
    }

    func test_diff_returns_empty_when_path_missing() {
        // Path that doesn't exist in the tree → git returns nothing
        // (no warning since the file isn't tracked); we surface "".
        let diff = GitClient(repoRoot: tmp).diff(forPath: "no/such/file.md")
        XCTAssertEqual(diff, "")
    }

    func test_diff_handles_path_with_spaces() throws {
        let file = tmp.appendingPathComponent("a file.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try git(["add", "a file.txt"])
        _ = try git(["commit", "-q", "-m", "init"])
        try "before\nafter\n".write(to: file, atomically: true, encoding: .utf8)
        let diff = GitClient(repoRoot: tmp).diff(forPath: "a file.txt")
        XCTAssertTrue(diff.contains("+after"),
                      "diff must work with spaces in path, got:\n\(diff)")
    }

    // MARK: - SEC-005: env scrub (GIT_* control vars never inherited)

    func test_status_ignoresHostileGitDirFromParentEnv() throws {
        // A stray/hostile GIT_DIR in the app's environment must NOT
        // redirect where GitClient reads the repo. The scrubbed env in
        // `run` only sets the four hardening vars + PATH/HOME, so
        // GIT_DIR is dropped and git resolves the repo from
        // currentDirectoryURL (repoRoot) as intended.
        try "hello".write(
            to: tmp.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8)
        setenv("GIT_DIR", "/definitely/not/a/real/git/dir", 1)
        defer { unsetenv("GIT_DIR") }
        let entries = GitClient(repoRoot: tmp).status()
        XCTAssertTrue(
            entries.contains(where: { $0.path == "a.txt" && $0.isUntracked }),
            "GIT_DIR from parent env leaked through and broke repo resolution")
    }

    func test_log_ignoresHostileGitConfigGlobalFromParentEnv() throws {
        try "x".write(
            to: tmp.appendingPathComponent("x.txt"),
            atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-q", "-m", "first commit"])
        // GIT_CONFIG_GLOBAL pointing at a bogus path would, if
        // inherited, change which global config git reads. We just
        // confirm the operation is unaffected (the var is scrubbed).
        setenv("GIT_CONFIG_GLOBAL", "/definitely/not/a/real/gitconfig", 1)
        defer { unsetenv("GIT_CONFIG_GLOBAL") }
        let log = GitClient(repoRoot: tmp).log()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].subject, "first commit")
    }

    func test_gitClient_resolvesBinary_andRunsBasicCommand() throws {
        // MAGIC-004: probe-list resolution. On a host with git on the
        // standard path, a basic op must succeed (proves the resolved
        // binary is invoked, not a hard-coded path that might be wrong).
        try "v1".write(
            to: tmp.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8)
        XCTAssertFalse(GitClient(repoRoot: tmp).status().isEmpty)
    }

    // MARK: - worktree create/remove (TSK-349)

    func testWorktreeAddCreatesBranchThenRemove() throws {
        // `git worktree add` needs a commit (HEAD must resolve).
        try "hi".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "a.txt"])
        _ = try git(["commit", "-q", "-m", "init"])
        let client = GitClient(repoRoot: tmp)

        // A worktree must live OUTSIDE the main worktree → sibling temp dir.
        let wt = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: wt) }

        func same(_ a: URL, _ b: URL) -> Bool {
            a.standardizedFileURL.resolvingSymlinksInPath().path
                == b.standardizedFileURL.resolvingSymlinksInPath().path
        }

        XCTAssertTrue(client.worktreeAdd(path: wt, branch: "feature", createBranch: true),
                      "worktree add -b feature should succeed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path),
                      "worktree directory created on disk")
        let afterAdd = client.worktreeList()
        XCTAssertTrue(afterAdd.contains { same($0.path, wt) },
                      "worktreeList reflects the new worktree — got \(afterAdd.map { $0.path.lastPathComponent })")
        XCTAssertTrue(afterAdd.contains { same($0.path, wt) && $0.branch == "feature" },
                      "the new worktree is on branch 'feature'")

        XCTAssertTrue(client.worktreeRemove(path: wt),
                      "worktree remove should succeed on a clean worktree")
        XCTAssertFalse(client.worktreeList().contains { same($0.path, wt) },
                       "worktreeList no longer shows the removed worktree")
    }

    func testWorktreeRemoveFailsGracefullyOnNonWorktree() throws {
        // Removing a path that was never registered as a worktree makes git
        // error ("is not a working tree"); the method must return false
        // (non-throwing), never crash. Teeth for the `(try? run(...)) != nil`
        // error contract — and side-effect-free (no worktree is created).
        try "hi".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "a.txt"])
        _ = try git(["commit", "-q", "-m", "init"])
        let client = GitClient(repoRoot: tmp)
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-not-a-worktree-\(UUID().uuidString)")
        XCTAssertFalse(client.worktreeRemove(path: bogus),
                       "removing a non-worktree path returns false, doesn't throw")
    }

    private func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = tmp
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
