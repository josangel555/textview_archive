import XCTest
@testable import ViewerCore
import TestSupport

/// Tests covering the new GitClient surfaces added for the multi-tab
/// Git panel: graphLog, stashList, worktreeList, remoteList, headInfo.
/// Each test owns a temp directory, initializes a real repo, drives
/// just enough state, and asserts the parser output.
final class GitClientPanelTests: XCTestCase {

    // MARK: - Setup helpers

    // TSK-850: shared batched fixture (one shell vs 4 git Processes); per-test
    // commits still use the local `run`/`writeFile` below.
    private func makeRepo() throws -> URL {
        try GitTestRepo.makeRepo(prefix: "GitClientPanelTests")
    }

    @discardableResult
    private func run(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func writeFile(_ name: String, _ contents: String, in dir: URL) throws {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - graphLog

    func test_graphLog_returns_empty_for_empty_repo() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = GitClient(repoRoot: repo)
        XCTAssertEqual(client.graphLog(maxEntries: 10), [])
    }

    func test_graphLog_returns_commits_with_stats() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "first line\nsecond line\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "add a"], in: repo)
        try writeFile("a.txt", "first line\nsecond line\nthird\n", in: repo)
        try run(["commit", "-q", "-am", "extend a"], in: repo)

        let client = GitClient(repoRoot: repo)
        let log = client.graphLog(maxEntries: 10)
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log[0].subject, "extend a")
        XCTAssertEqual(log[1].subject, "add a")
        XCTAssertGreaterThan(log[0].insertions, 0)
        XCTAssertFalse(log[0].sha.isEmpty)
        // Parents: head has 1 parent, root has none.
        XCTAssertEqual(log[0].parents.count, 1)
        XCTAssertEqual(log[1].parents.count, 0)
    }

    func test_graphLog_records_merge_parents() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "base\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "base"], in: repo)
        try run(["checkout", "-q", "-b", "side"], in: repo)
        try writeFile("b.txt", "side\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "side change"], in: repo)
        try run(["checkout", "-q", "main"], in: repo)
        try writeFile("c.txt", "main\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "main change"], in: repo)
        try run(["merge", "-q", "--no-ff", "side", "-m", "merge side"], in: repo)

        let client = GitClient(repoRoot: repo)
        let log = client.graphLog(maxEntries: 10)
        let merge = log.first { $0.isMerge }
        XCTAssertNotNil(merge, "expected a merge commit in log")
        XCTAssertEqual(merge?.parents.count, 2)
    }

    // MARK: - stashList

    func test_stashList_returns_entries() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "hello\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "initial"], in: repo)
        try writeFile("a.txt", "hello\nworld\n", in: repo)
        try run(["stash", "push", "-m", "wip extension"], in: repo)

        let client = GitClient(repoRoot: repo)
        let stashes = client.stashList()
        XCTAssertEqual(stashes.count, 1)
        XCTAssertTrue(stashes[0].ref.hasPrefix("stash@{"))
        XCTAssertTrue(stashes[0].subject.contains("wip extension"))
    }

    func test_stashList_empty_when_no_stashes() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "x", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "init"], in: repo)
        XCTAssertEqual(GitClient(repoRoot: repo).stashList(), [])
    }

    // MARK: - worktreeList

    func test_worktreeList_returns_current_only_by_default() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "x", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "init"], in: repo)

        let trees = GitClient(repoRoot: repo).worktreeList()
        XCTAssertEqual(trees.count, 1)
        XCTAssertEqual(trees[0].state, .current)
        XCTAssertEqual(trees[0].branch, "main")
    }

    func test_worktreeList_lists_additional_trees() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "x", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "init"], in: repo)
        let extraPath = repo.appendingPathComponent("../extra-wt")
            .standardizedFileURL
        try run(["worktree", "add", "-q", "-b", "side", extraPath.path], in: repo)
        defer { try? FileManager.default.removeItem(at: extraPath) }

        let trees = GitClient(repoRoot: repo).worktreeList()
        XCTAssertEqual(trees.count, 2)
        XCTAssertEqual(trees.filter { $0.state == .current }.count, 1)
        let side = trees.first { $0.branch == "side" }
        XCTAssertNotNil(side)
    }

    // MARK: - remoteList

    func test_remoteList_empty_with_no_remote() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        XCTAssertEqual(GitClient(repoRoot: repo).remoteList(), [])
    }

    func test_remoteList_parses_remote_url() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try run(["remote", "add", "origin", "git@github.com:foo/bar.git"], in: repo)
        let remotes = GitClient(repoRoot: repo).remoteList()
        XCTAssertEqual(remotes.count, 1)
        XCTAssertEqual(remotes[0].name, "origin")
        XCTAssertEqual(remotes[0].url, "git@github.com:foo/bar.git")
    }

    func test_remoteList_dedupes_fetch_push() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try run(["remote", "add", "origin", "git@github.com:foo/bar.git"], in: repo)
        try run(["remote", "add", "upstream", "https://github.com/foo/up.git"], in: repo)
        let remotes = GitClient(repoRoot: repo).remoteList()
        XCTAssertEqual(remotes.count, 2)
        XCTAssertEqual(Set(remotes.map(\.name)), Set(["origin", "upstream"]))
    }

    // MARK: - headInfo

    func test_headInfo_reports_branch_and_sha() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "x", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "init"], in: repo)

        let info = GitClient(repoRoot: repo).headInfo()
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.branch, "main")
        XCTAssertFalse(info?.sha.isEmpty ?? true)
        XCTAssertEqual(info?.ahead, 0)
        XCTAssertEqual(info?.behind, 0)
    }

    func test_headInfo_detached() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "x", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "init"], in: repo)
        try writeFile("a.txt", "y", in: repo)
        try run(["commit", "-q", "-am", "second"], in: repo)
        // Detach HEAD onto first commit.
        let firstSha = (try run(["rev-list", "--max-parents=0", "HEAD"], in: repo))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try run(["checkout", "-q", firstSha], in: repo)

        let info = GitClient(repoRoot: repo).headInfo()
        XCTAssertNotNil(info)
        XCTAssertNil(info?.branch)
    }
}
