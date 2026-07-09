import XCTest
@testable import ViewerCore

/// TSK-1443 — the index-mutation surface (stage / unstage / commit / discard)
/// against a real temp repo. These are the teeth that catch a regression in
/// the "standard git loop" the Status tab drives. Skipped if /usr/bin/git is
/// unavailable.
final class GitClientMutationTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("/usr/bin/git not available")
        }
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-git-mut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.email", "test@example.com"])
        _ = try git(["config", "user.name", "Test"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - safeRelativePath (pure)

    func test_safeRelativePath_rejectsOptionAndTraversal() {
        XCTAssertNil(GitClient.safeRelativePath("-rf"), "leading dash could be read as an option")
        XCTAssertNil(GitClient.safeRelativePath("/etc/passwd"), "absolute path escapes the repo")
        XCTAssertNil(GitClient.safeRelativePath("../outside"), "..-traversal escapes the repo")
        XCTAssertNil(GitClient.safeRelativePath("   "), "blank is invalid")
        XCTAssertEqual(GitClient.safeRelativePath("  src/a.swift  "), "src/a.swift", "trims + accepts")
    }

    // MARK: - stage / unstage

    func test_stage_movesUntrackedToIndex() throws {
        try "hello".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let client = GitClient(repoRoot: tmp)
        XCTAssertTrue(client.stage(path: "a.txt").ok)
        // git now reports it STAGED (index status 'A').
        let porcelain = try git(["status", "--porcelain"])
        XCTAssertTrue(porcelain.contains("A  a.txt"), "expected staged 'A  a.txt', got: \(porcelain)")
    }

    func test_unstage_reversesAStageOnUnbornHead() throws {
        // Fresh repo, no commits → unborn HEAD. Stage then unstage must return
        // the file to untracked (the rm --cached fallback path).
        try "hello".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let client = GitClient(repoRoot: tmp)
        XCTAssertTrue(client.stage(path: "a.txt").ok)
        XCTAssertTrue(client.unstage(path: "a.txt").ok)
        let porcelain = try git(["status", "--porcelain"])
        XCTAssertTrue(porcelain.contains("?? a.txt"), "expected untracked '?? a.txt', got: \(porcelain)")
    }

    func test_unstage_afterCommit_usesResetHead() throws {
        // With a real HEAD, staging a modification then unstaging leaves it as
        // an unstaged modification (' M'), not untracked.
        let f = tmp.appendingPathComponent("a.txt")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        _ = try git(["add", "a.txt"]); _ = try git(["commit", "-q", "-m", "init"])
        try "v2".write(to: f, atomically: true, encoding: .utf8)
        let client = GitClient(repoRoot: tmp)
        XCTAssertTrue(client.stage(path: "a.txt").ok)
        XCTAssertTrue(client.unstage(path: "a.txt").ok)
        let porcelain = try git(["status", "--porcelain"])
        XCTAssertTrue(porcelain.contains(" M a.txt"), "expected unstaged ' M a.txt', got: \(porcelain)")
    }

    // MARK: - commit

    func test_commit_createsRealCommit_andClearsStaged() throws {
        try "hello".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let client = GitClient(repoRoot: tmp)
        XCTAssertTrue(client.stage(path: "a.txt").ok)
        XCTAssertTrue(client.commit(message: "first commit").ok)
        // A real commit exists with that subject.
        let log = try git(["log", "--oneline"])
        XCTAssertTrue(log.contains("first commit"), "commit not in log: \(log)")
        // Index is clean (nothing staged) after the commit.
        let porcelain = try git(["status", "--porcelain"])
        XCTAssertTrue(porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "working tree should be clean after commit, got: \(porcelain)")
    }

    func test_commit_emptyMessage_isRefused() throws {
        try "hello".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let client = GitClient(repoRoot: tmp)
        _ = client.stage(path: "a.txt")
        let r = client.commit(message: "   ")
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.message.isEmpty, "a refusal must carry feedback")
        // No commit was created — the file is STILL staged (unborn HEAD, nothing
        // committed). git log on an unborn branch prints a fatal notice, so we
        // assert on the index state instead.
        let porcelain = try git(["status", "--porcelain"])
        XCTAssertTrue(porcelain.contains("A  a.txt"),
                      "file should remain staged, not committed: \(porcelain)")
    }

    // MARK: - discard (destructive)

    func test_discardChanges_revertsWorkingTreeToHead() throws {
        let f = tmp.appendingPathComponent("a.txt")
        try "committed".write(to: f, atomically: true, encoding: .utf8)
        _ = try git(["add", "a.txt"]); _ = try git(["commit", "-q", "-m", "init"])
        // Dirty the file, then discard.
        try "local edit".write(to: f, atomically: true, encoding: .utf8)
        let client = GitClient(repoRoot: tmp)
        XCTAssertTrue(client.discardChanges(path: "a.txt").ok)
        // File content is back to the committed version — the destructive op did
        // exactly what it says (and nothing was silently lost beyond the edit).
        let content = try String(contentsOf: f, encoding: .utf8)
        XCTAssertEqual(content, "committed")
    }

    func test_mutations_rejectUnsafePath() {
        let client = GitClient(repoRoot: tmp)
        XCTAssertFalse(client.stage(path: "-rf").ok)
        XCTAssertFalse(client.unstage(path: "/etc/passwd").ok)
        XCTAssertFalse(client.discardChanges(path: "../escape").ok)
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
