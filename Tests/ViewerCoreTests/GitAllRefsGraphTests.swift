import XCTest
import TestSupport
@testable import ViewerCore

/// TSK-1602 — the ALL-REFS graph against a REAL repo with a REAL second
/// worktree. Owner problem: "hard to navigate back and forth between each
/// worktree and figure out where the branching/divergence happened."
///
/// Worktrees share one object DB, so `git log --all HEAD` from the main
/// worktree must show the sibling worktree's branch tip AND the common
/// ancestor — the divergence point — in one topo-ordered graph.
final class GitAllRefsGraphTests: XCTestCase {

    private var repo: URL!
    private var sibling: URL!

    override func setUp() async throws {
        repo = try GitTestRepo.makeRepo(prefix: "GitAllRefsGraphTests")
        sibling = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-wt2")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: sibling)
    }

    @discardableResult
    private func git(_ cmd: String, in dir: URL? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.currentDirectoryURL = dir ?? repo
        p.arguments = ["-c", "git \(cmd)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ name: String, _ body: String, in dir: URL? = nil) {
        try? body.write(to: (dir ?? repo).appendingPathComponent(name),
                        atomically: true, encoding: .utf8)
        git("add -A", in: dir)
        git("commit -q -m 'c \(name)'", in: dir)
    }

    /// base → (main: m2) and (sibling worktree branch: s1)
    private func makeDivergedWorktrees() -> (base: String, mainTip: String, siblingTip: String) {
        commit("base.txt", "base\n")
        let base = git("rev-parse --short HEAD")
        git("worktree add -q -b side '\(sibling.path)'")
        commit("side.txt", "side\n", in: sibling)
        let siblingTip = git("rev-parse --short HEAD", in: sibling)
        commit("main.txt", "main\n")
        let mainTip = git("rev-parse --short HEAD")
        return (base, mainTip, siblingTip)
    }

    func test_allRefs_showsSiblingWorktreeTipAndDivergencePoint() throws {
        let (base, mainTip, siblingTip) = makeDivergedWorktrees()
        let client = GitClient(repoRoot: repo)

        // DEFAULT (current worktree only): the sibling's tip is NOT there.
        let currentOnly = client.graphLog(maxEntries: 50, skip: 0, allRefs: false)
        let currentShas = currentOnly.map(\.sha)
        XCTAssertTrue(currentShas.contains(mainTip))
        XCTAssertFalse(currentShas.contains(siblingTip),
                       "the default graph is the current worktree's history only")

        // ALL REFS: both tips AND the shared ancestor (the divergence point).
        let all = client.graphLog(maxEntries: 50, skip: 0, allRefs: true)
        let allShas = all.map(\.sha)
        XCTAssertTrue(allShas.contains(mainTip), "main tip present")
        XCTAssertTrue(allShas.contains(siblingTip),
                      "the SIBLING WORKTREE's branch tip appears without checking it out")
        XCTAssertTrue(allShas.contains(base),
                      "the common ancestor — where the branches diverged — is in the graph")
    }

    func test_allRefs_decorationsIdentifyTheSiblingWorktreeBranch() throws {
        let (_, _, siblingTip) = makeDivergedWorktrees()
        let client = GitClient(repoRoot: repo)
        let all = client.graphLog(maxEntries: 50, skip: 0, allRefs: true)
        let sideRow = try XCTUnwrap(all.first { $0.sha == siblingTip })
        XCTAssertTrue(sideRow.refs.contains { $0.contains("side") },
                      "the sibling branch decoration rides along: \(sideRow.refs)")

        // The worktree map turns that decoration into the distinct chip kind.
        let map = Dictionary(uniqueKeysWithValues: client.worktreeList()
            .filter { $0.state != .current }
            .compactMap { wt in wt.branch.map { ($0, wt.path.lastPathComponent) } })
        XCTAssertEqual(map["side"], sibling.lastPathComponent,
                       "worktreeList maps the branch to its worktree dir")
        let refs = GitRefKind.classifyAll(sideRow.refs, worktreeBranches: map)
        XCTAssertTrue(refs.contains { $0.kind == .worktreeBranch && $0.name == "side" },
                      "the sibling worktree's branch is classified distinctly: \(refs)")
    }

    func test_worktreeSearch_findsTheSiblingTipByWorktreeName() throws {
        let (_, _, siblingTip) = makeDivergedWorktrees()
        let client = GitClient(repoRoot: repo)
        let all = client.graphLog(maxEntries: 50, skip: 0, allRefs: true)
        let wts = client.worktreeList().map {
            GitLogSearchQuery.Worktree(
                name: $0.path.lastPathComponent, branch: $0.branch, head: $0.head)
        }
        // Typing the worktree's directory-name prefix finds its head commit.
        let hits = GitLogSearchQuery.filter(
            commits: all, worktrees: wts, refsFor: { $0.refs },
            rawQuery: String(sibling.lastPathComponent.prefix(8)))
        XCTAssertTrue(hits.contains { $0.sha == siblingTip },
                      "a worktree-name query surfaces that worktree's head commit")
    }
}
