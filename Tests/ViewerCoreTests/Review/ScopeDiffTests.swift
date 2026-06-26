import XCTest
@testable import ViewerCore
import TestSupport

/// Stage 1 (§7): the scope→diff resolver + blob-sha helpers on `GitClient`,
/// exercised against a REAL temp repo created under `temporaryDirectory`.
/// Asserts each `ReviewScope` case produces a parseable diff for the right
/// content, that the branch merge-base is resolved, and that the blob-sha
/// helpers (committed + working-tree) behave.
final class ScopeDiffTests: XCTestCase {

    private var repo: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("/usr/bin/git not available")
        }
        // TSK-850: shared batched fixture (one shell vs 4 git Processes).
        repo = try GitTestRepo.makeRepo(prefix: "mdv-scopediff")
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = repo
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func headSha() throws -> String {
        try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - .commit scope

    func test_commitScope_producesFullCommitDiff() throws {
        try write("a.txt", "one\ntwo\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "c1"])
        try write("a.txt", "one\ntwo\nthree\n")
        try git(["commit", "-q", "-am", "c2"])
        let sha = try headSha()

        let client = GitClient(repoRoot: repo)
        let diff = client.diff(scope: .commit(sha: sha), path: "a.txt")
        XCTAssertFalse(diff.isEmpty)
        let files = RustDiffAdapter.parse(diff)
        XCTAssertTrue(files.contains { $0.newPath == "a.txt" })
        // The added line must be in the parsed diff.
        let added = files.flatMap { $0.hunks }.flatMap { $0.lines }
            .filter { $0.kind == .added }.map(\.content)
        XCTAssertTrue(added.contains("three"))
    }

    // MARK: - .workingTree scope

    func test_workingTreeScope_diffsAgainstBase_includesUncommittedEdit() throws {
        try write("a.txt", "one\ntwo\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "c1"])
        // Uncommitted working-tree edit.
        try write("a.txt", "one\ntwo\nWORKTREE\n")

        let client = GitClient(repoRoot: repo)
        let diff = client.diff(scope: .workingTree(base: "HEAD"), path: "a.txt")
        XCTAssertFalse(diff.isEmpty)
        let added = RustDiffAdapter.parse(diff).flatMap { $0.hunks }.flatMap { $0.lines }
            .filter { $0.kind == .added }.map(\.content)
        XCTAssertTrue(added.contains("WORKTREE"))
    }

    // MARK: - .range scope

    func test_rangeScope_diffsBetweenTwoCommits() throws {
        try write("a.txt", "one\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "c1"])
        let from = try headSha()
        try write("a.txt", "one\nRANGE\n")
        try git(["commit", "-q", "-am", "c2"])
        let to = try headSha()

        let client = GitClient(repoRoot: repo)
        let diff = client.diff(scope: .range(from: from, to: to), path: "a.txt")
        XCTAssertFalse(diff.isEmpty)
        let added = RustDiffAdapter.parse(diff).flatMap { $0.hunks }.flatMap { $0.lines }
            .filter { $0.kind == .added }.map(\.content)
        XCTAssertTrue(added.contains("RANGE"))
    }

    // MARK: - .branch scope (merge-base frozen)

    func test_branchScope_resolvesMergeBase_andDiffsBranchTip() throws {
        // main: c1
        try write("a.txt", "base\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "c1"])
        let mergeBaseExpected = try headSha()

        // feature branch off c1, adds a line.
        try git(["checkout", "-q", "-b", "feature"])
        try write("a.txt", "base\nFEATURE\n")
        try git(["commit", "-q", "-am", "feat"])

        // main advances independently AFTER the branch point — the diff must
        // still be against the FROZEN merge-base, not the advanced main tip.
        try git(["checkout", "-q", "main"])
        try write("b.txt", "unrelated\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "main advance"])

        let client = GitClient(repoRoot: repo)
        let mb = client.mergeBase("main", "feature")
        XCTAssertEqual(mb, mergeBaseExpected)

        let diff = client.diff(scope: .branch(branch: "feature", base: "main"), path: "a.txt")
        XCTAssertFalse(diff.isEmpty)
        let added = RustDiffAdapter.parse(diff).flatMap { $0.hunks }.flatMap { $0.lines }
            .filter { $0.kind == .added }.map(\.content)
        XCTAssertTrue(added.contains("FEATURE"))
    }

    // MARK: - unsafe revision rejection (option-injection guard)

    func test_unsafeRevision_returnsEmpty_notAnInjectedFlag() {
        let client = GitClient(repoRoot: repo)
        XCTAssertEqual(client.diff(scope: .commit(sha: "--upload-pack=evil"), path: "a.txt"), "")
        XCTAssertEqual(client.diff(scope: .workingTree(base: "--foo"), path: "a.txt"), "")
        XCTAssertNil(client.blobSha(rev: "--evil", path: "a.txt"))
        XCTAssertNil(client.mergeBase("--evil", "main"))
        XCTAssertNil(client.revParse("--evil"))
    }

    // MARK: - blob SHA helpers (§3.1)

    func test_blobSha_committed_matchesGitLsTree() throws {
        try write("a.txt", "content\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "c1"])
        let sha = try headSha()

        let client = GitClient(repoRoot: repo)
        let blob = client.blobSha(rev: sha, path: "a.txt")
        XCTAssertNotNil(blob)

        // Cross-check against `git rev-parse <sha>:a.txt`.
        let expected = try git(["rev-parse", "\(sha):a.txt"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(blob, expected)
    }

    func test_blobSha_committed_nilForAbsentPath() throws {
        try write("a.txt", "content\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "c1"])
        let sha = try headSha()
        let client = GitClient(repoRoot: repo)
        XCTAssertNil(client.blobSha(rev: sha, path: "does-not-exist.txt"))
    }

    func test_blobShaForWorktree_matchesGitHashObject_andTracksEdits() throws {
        try write("a.txt", "v1\n")
        let client = GitClient(repoRoot: repo)

        let h1 = client.blobShaForWorktree(path: "a.txt")
        XCTAssertNotNil(h1)
        let expected1 = try git(["hash-object", "--", "a.txt"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(h1, expected1)

        // Edit the working-tree bytes → hash changes (staleness signal).
        try write("a.txt", "v2 changed\n")
        let h2 = client.blobShaForWorktree(path: "a.txt")
        XCTAssertNotNil(h2)
        XCTAssertNotEqual(h1, h2)
    }

    func test_blobShaForWorktree_nilForMissingFile() {
        let client = GitClient(repoRoot: repo)
        XCTAssertNil(client.blobShaForWorktree(path: "ghost.txt"))
    }

    // MARK: - end-to-end staleness via the AnchorState evaluator

    func test_endToEnd_anchorStateGoesStale_afterWorktreeEdit() throws {
        try write("a.txt", "alpha\nbeta\n")
        let client = GitClient(repoRoot: repo)

        // Capture blob at "creation".
        let captured = client.blobShaForWorktree(path: "a.txt")
        let anchor = LineAnchor(side: .new, startLine: 1, endLine: 1, blobSha: captured)

        // Same content on reload → current.
        XCTAssertEqual(
            AnchorState.evaluate(anchor: anchor, liveBlobSha: client.blobShaForWorktree(path: "a.txt")),
            .current
        )

        // Edit underneath → stale.
        try write("a.txt", "alpha CHANGED\nbeta\n")
        XCTAssertEqual(
            AnchorState.evaluate(anchor: anchor, liveBlobSha: client.blobShaForWorktree(path: "a.txt")),
            .stale
        )
    }
}
