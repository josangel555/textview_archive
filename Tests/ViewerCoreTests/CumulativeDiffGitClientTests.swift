import XCTest
@testable import ViewerCore
import TestSupport

/// End-to-end teeth for the cumulative-diff feature (TSK-522 slice 2): the pure
/// `CumulativeDiffSelection` resolver feeding `GitClient.cumulativeDiff(base:tip:)`
/// against a REAL temp repo. The load-bearing property is that the result is the
/// CUMULATIVE (net) diff across the selection — intermediate commit states are
/// collapsed, NOT shown per-commit.
final class CumulativeDiffGitClientTests: XCTestCase {

    // MARK: - fixture helpers (mirror GitClientPanelTests)
    // TSK-850: shared batched fixture (one shell vs 4 git Processes); per-test
    // commits still use the local `git` below.
    private func makeRepo() throws -> URL {
        try GitTestRepo.makeRepo(prefix: "CumDiffTests")
    }
    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    private func commit(_ value: String, in dir: URL) throws {
        try "\(value)\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "a.txt"], in: dir)
        try git(["commit", "-q", "-m", "set \(value)"], in: dir)
    }
    /// Content of added/removed body lines (excludes the +++/--- file headers and
    /// the @@ hunk headers, so assertions can't be fooled by "-1" in a hunk header).
    private func changes(_ diff: String) -> (added: [String], removed: [String]) {
        var added: [String] = [], removed: [String] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { added.append(String(line.dropFirst())) }
            else if line.hasPrefix("-") { removed.append(String(line.dropFirst())) }
        }
        return (added, removed)
    }

    /// Build the resolver inputs from a real graphLog (index == topoIndex, newest=0).
    private func selection(_ log: [GitClient.GraphCommit], pick: (Int) -> Bool) -> [CumulativeDiffSelection.Commit] {
        log.enumerated().filter { pick($0.offset) }.map {
            CumulativeDiffSelection.Commit(sha: $0.element.sha, topoIndex: $0.offset, parents: $0.element.parents)
        }
    }

    func test_cumulativeAcrossTwoCommits_collapsesIntermediate() throws {
        let repo = try makeRepo()
        try commit("1", in: repo); try commit("2", in: repo); try commit("3", in: repo)
        let gc = GitClient(repoRoot: repo)
        let log = gc.graphLog()                       // [c3(0), c2(1), c1(2)]
        XCTAssertEqual(log.count, 3)

        // Select the two NEWEST (c3, c2) — base resolves to c1 (parent of oldest selected).
        let sel = selection(log) { $0 == 0 || $0 == 1 }
        let range = try XCTUnwrap(CumulativeDiffSelection.resolve(sel))
        XCTAssertEqual(range.tipRef, log[0].sha)      // c3
        XCTAssertEqual(range.baseRef, log[1].parents.first)  // c1 = parent of c2
        XCTAssertTrue(range.isContiguous)

        let ch = changes(gc.cumulativeDiff(baseRef: range.baseRef, tipRef: range.tipRef))
        // NET change c1→c3 is 1→3; the intermediate "2" must NOT appear.
        XCTAssertEqual(ch.added, ["3"])
        XCTAssertEqual(ch.removed, ["1"])
    }

    func test_singleCommit_isOnlyThatCommitsChange() throws {
        let repo = try makeRepo()
        try commit("1", in: repo); try commit("2", in: repo); try commit("3", in: repo)
        let gc = GitClient(repoRoot: repo)
        let log = gc.graphLog()
        let range = try XCTUnwrap(CumulativeDiffSelection.resolve(selection(log) { $0 == 0 }))  // c3 only
        let ch = changes(gc.cumulativeDiff(baseRef: range.baseRef, tipRef: range.tipRef))
        XCTAssertEqual(ch.added, ["3"])               // c2→c3
        XCTAssertEqual(ch.removed, ["2"])
    }

    func test_fullRangeIncludingRoot_usesEmptyTreeBase_showsFileAdd() throws {
        let repo = try makeRepo()
        try commit("1", in: repo); try commit("2", in: repo); try commit("3", in: repo)
        let gc = GitClient(repoRoot: repo)
        let log = gc.graphLog()
        let range = try XCTUnwrap(CumulativeDiffSelection.resolve(selection(log) { _ in true }))  // all 3
        XCTAssertEqual(range.baseRef, CumulativeDiffSelection.emptyTreeSHA)  // oldest is a root
        let diff = gc.cumulativeDiff(baseRef: range.baseRef, tipRef: range.tipRef)
        let ch = changes(diff)
        XCTAssertEqual(ch.added, ["3"])               // empty-tree → c3 = full add of final content
        XCTAssertTrue(ch.removed.isEmpty)
    }

    // TSK-523: single-commit diff (click a commit → its patch), root-safe.
    func test_commitDiff_isSingleCommitPatch_andRootSafe() throws {
        let repo = try makeRepo()
        try commit("1", in: repo); try commit("2", in: repo)
        let gc = GitClient(repoRoot: repo)
        let log = gc.graphLog()                       // [c2(0), c1(1, root)]
        let newest = changes(gc.commitDiff(sha: log[0].sha))   // c2: 1→2
        XCTAssertEqual(newest.added, ["2"]); XCTAssertEqual(newest.removed, ["1"])
        let root = changes(gc.commitDiff(sha: log[1].sha))     // c1: root, all-add
        XCTAssertEqual(root.added, ["1"]); XCTAssertTrue(root.removed.isEmpty)
    }

    // TSK-1003: cumulativeDiff/commitDiff must reject option-injecting refs (a
    // ref beginning with `-`) so a value like `--output=<file>` can't be read as
    // a git flag. TEETH: pre-guard, `git diff --no-color --output=<sink> <tip>`
    // WRITES the diff to <sink>; the guard returns "" and never invokes git, so
    // the file is never created.
    func test_diffMethods_rejectOptionInjectingRefs() throws {
        let repo = try makeRepo()
        try commit("1", in: repo); try commit("2", in: repo)
        let gc = GitClient(repoRoot: repo)
        let tip = gc.graphLog()[0].sha

        let sink = repo.appendingPathComponent("INJECTED.txt")
        let injecting = "--output=" + sink.path

        XCTAssertEqual(gc.cumulativeDiff(baseRef: injecting, tipRef: tip), "")
        XCTAssertEqual(gc.cumulativeDiff(baseRef: tip, tipRef: injecting), "")
        XCTAssertEqual(gc.commitDiff(sha: injecting), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.path),
                       "git --output option was injected — isSafeRevision guard failed")

        // Sanity: a safe revision still yields a real patch.
        XCTAssertFalse(gc.commitDiff(sha: tip).isEmpty)
    }
}
