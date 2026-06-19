import XCTest
@testable import ViewerCore

/// Host tests for the worktree-manager UX logic (TSK-716). All pure-logic /
/// model-layer — no `git` is spawned; a recording stub stands in for the
/// `WorktreeGitOps` surface so we can assert the exact arguments dispatched.
final class WorktreeManagerModelTests: XCTestCase {

    // MARK: - stub git layer

    /// Records every mutation call + returns canned `worktreeList()` output.
    private final class StubGit: WorktreeGitOps {
        let repoRoot: URL
        var listToReturn: [GitClient.WorktreeEntry]
        var addReturns = true
        var removeReturns = true
        var pruneReturns = true

        // recorded calls
        private(set) var addCalls: [(path: URL, branch: String?, createBranch: Bool)] = []
        private(set) var removeCalls: [(path: URL, force: Bool)] = []
        private(set) var pruneCallCount = 0
        private(set) var listCallCount = 0

        init(repoRoot: URL, list: [GitClient.WorktreeEntry] = []) {
            self.repoRoot = repoRoot
            self.listToReturn = list
        }

        func worktreeList() -> [GitClient.WorktreeEntry] {
            listCallCount += 1
            return listToReturn
        }
        func worktreeAdd(path: URL, branch: String?, createBranch: Bool) -> Bool {
            addCalls.append((path, branch, createBranch))
            return addReturns
        }
        func worktreeRemove(path: URL, force: Bool) -> Bool {
            removeCalls.append((path, force))
            return removeReturns
        }
        func worktreePrune() -> Bool {
            pruneCallCount += 1
            return pruneReturns
        }
    }

    private func entry(
        _ path: String,
        branch: String? = nil,
        head: String = "abc1234",
        state: GitClient.WorktreeEntry.State = .normal
    ) -> GitClient.WorktreeEntry {
        GitClient.WorktreeEntry(
            path: URL(fileURLWithPath: path),
            branch: branch, head: head, state: state
        )
    }

    /// Probe that treats `existing` paths as present, every other path as
    /// absent, and reports parents as writable directories unless listed in
    /// `nonWritable`.
    private func probe(
        existing: Set<String> = [],
        directories: Set<String>,
        nonWritable: Set<String> = []
    ) -> WorktreePlanner.FileProbe {
        WorktreePlanner.FileProbe(
            exists: { existing.contains($0.standardizedFileURL.path) },
            isDirectory: { directories.contains($0.standardizedFileURL.path) },
            isWritable: { !nonWritable.contains($0.standardizedFileURL.path) }
        )
    }

    // MARK: - directory leaf derivation

    func testDirectoryLeafStripsRefsHeadsAndSlash() {
        XCTAssertEqual(WorktreePlanner.directoryLeaf(forBranch: "feature/login"), "feature-login")
        XCTAssertEqual(WorktreePlanner.directoryLeaf(forBranch: "refs/heads/feature/login"), "feature-login")
    }

    func testDirectoryLeafCoalescesAndTrimsDashes() {
        XCTAssertEqual(WorktreePlanner.directoryLeaf(forBranch: "wip//double"), "wip-double")
        XCTAssertEqual(WorktreePlanner.directoryLeaf(forBranch: "  spaced name  "), "spaced-name")
        XCTAssertEqual(WorktreePlanner.directoryLeaf(forBranch: "-leading-trailing-"), "leading-trailing")
    }

    func testDirectoryLeafEmptyFallsBack() {
        XCTAssertEqual(WorktreePlanner.directoryLeaf(forBranch: ""), "worktree")
        XCTAssertEqual(WorktreePlanner.directoryLeaf(forBranch: "///"), "worktree")
    }

    func testDirectoryLeafKeepsDotsUnderscores() {
        XCTAssertEqual(WorktreePlanner.directoryLeaf(forBranch: "v1.2_rc"), "v1.2_rc")
    }

    // MARK: - default path derivation

    func testDefaultPathIsSiblingOfRepoRoot() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let p = WorktreePlanner.defaultPath(forBranch: "feature/x", mainRepoRoot: root)
        XCTAssertEqual(p.path, "/work/myrepo-feature-x")
    }

    func testDefaultPathDisambiguatesAgainstExisting() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let existing = [URL(fileURLWithPath: "/work/myrepo-feature-x")]
        let p = WorktreePlanner.defaultPath(forBranch: "feature/x", mainRepoRoot: root, existing: existing)
        XCTAssertEqual(p.path, "/work/myrepo-feature-x-2")
    }

    func testDefaultPathDisambiguatesPastSecond() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let existing = [
            URL(fileURLWithPath: "/work/myrepo-feature-x"),
            URL(fileURLWithPath: "/work/myrepo-feature-x-2"),
        ]
        let p = WorktreePlanner.defaultPath(forBranch: "feature/x", mainRepoRoot: root, existing: existing)
        XCTAssertEqual(p.path, "/work/myrepo-feature-x-3")
    }

    // MARK: - path validation

    func testValidatePathRejectsEmpty() {
        let v = WorktreePlanner.validatePath(
            rawPath: "",
            existingWorktrees: [],
            probe: probe(directories: [])
        )
        XCTAssertEqual(v, .empty)
        XCTAssertFalse(v.isValid)
    }

    func testValidatePathRejectsWhitespaceOnly() {
        let v = WorktreePlanner.validatePath(
            rawPath: "   ",
            existingWorktrees: [],
            probe: probe(directories: [])
        )
        XCTAssertEqual(v, .empty)
    }

    func testValidatePathRejectsDuplicateWorktree() {
        let dup = "/work/myrepo-feature"
        let v = WorktreePlanner.validatePath(
            URL(fileURLWithPath: dup),
            existingWorktrees: [entry(dup, branch: "feature")],
            probe: probe(directories: ["/work"])
        )
        XCTAssertEqual(v, .alreadyWorktree)
    }

    func testValidatePathRejectsExistingFileOrDir() {
        let target = "/work/already-here"
        let v = WorktreePlanner.validatePath(
            URL(fileURLWithPath: target),
            existingWorktrees: [],
            probe: probe(existing: [target], directories: ["/work"])
        )
        XCTAssertEqual(v, .alreadyExists)
    }

    func testValidatePathRejectsMissingParent() {
        let target = "/work/nope/child"
        let v = WorktreePlanner.validatePath(
            URL(fileURLWithPath: target),
            existingWorktrees: [],
            // parent "/work/nope" neither exists nor is a directory
            probe: probe(directories: ["/work"])
        )
        XCTAssertEqual(v, .parentMissing)
    }

    func testValidatePathRejectsNonWritableParent() {
        let target = "/work/locked/child"
        let parent = "/work/locked"
        let v = WorktreePlanner.validatePath(
            URL(fileURLWithPath: target),
            existingWorktrees: [],
            probe: probe(
                existing: [parent],
                directories: [parent],
                nonWritable: [parent]
            )
        )
        XCTAssertEqual(v, .parentNotWritable)
    }

    func testValidatePathAcceptsGoodPath() {
        let target = "/work/myrepo-new"
        let v = WorktreePlanner.validatePath(
            URL(fileURLWithPath: target),
            existingWorktrees: [entry("/work/myrepo", branch: "main", state: .current)],
            probe: probe(existing: ["/work"], directories: ["/work"])
        )
        XCTAssertEqual(v, .ok)
        XCTAssertTrue(v.isValid)
    }

    // MARK: - classification

    func testClassifyMarksMainWorktreeCurrentAndNotRemovable() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let rows = WorktreePlanner.classify(
            [
                entry("/work/myrepo", branch: "main", state: .current),
                entry("/work/myrepo-feature", branch: "feature", state: .normal),
            ],
            mainRepoRoot: root
        )
        XCTAssertEqual(rows[0].kind, .current)
        XCTAssertFalse(rows[0].isRemovable)
        XCTAssertEqual(rows[1].kind, .normal)
        XCTAssertTrue(rows[1].isRemovable)
        XCTAssertFalse(rows[1].requiresForceToRemove)
    }

    func testClassifyLockedAndPrunableRequireForce() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let rows = WorktreePlanner.classify(
            [
                entry("/work/myrepo", state: .current),
                entry("/work/locked-wt", state: .locked),
                entry("/work/gone-wt", state: .prunable),
            ],
            mainRepoRoot: root
        )
        XCTAssertEqual(rows[1].kind, .locked)
        XCTAssertTrue(rows[1].isRemovable)
        XCTAssertTrue(rows[1].requiresForceToRemove)
        XCTAssertEqual(rows[2].kind, .prunable)
        XCTAssertTrue(rows[2].requiresForceToRemove)
    }

    func testPruneCandidatesPicksOnlyPrunable() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let rows = WorktreePlanner.classify(
            [
                entry("/work/myrepo", state: .current),
                entry("/work/normal-wt", state: .normal),
                entry("/work/gone-1", state: .prunable),
                entry("/work/gone-2", state: .prunable),
            ],
            mainRepoRoot: root
        )
        let candidates = WorktreePlanner.pruneCandidates(rows)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(Set(candidates.map { $0.path.lastPathComponent }), ["gone-1", "gone-2"])
    }

    // MARK: - model: add dispatch

    func testAddRefusesInvalidPathWithoutCallingGit() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [entry("/work/myrepo", state: .current)])
        let model = WorktreeManagerModel(
            git: stub,
            probe: probe(existing: ["/work/exists"], directories: ["/work"])
        )
        model.refresh()
        let r = model.addWorktree(path: URL(fileURLWithPath: "/work/exists"))
        XCTAssertEqual(r, .invalid(.alreadyExists))
        XCTAssertTrue(stub.addCalls.isEmpty, "git must not run on a rejected path")
    }

    func testAddCallsThroughWithRightArgs() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [entry("/work/myrepo", state: .current)])
        let model = WorktreeManagerModel(
            git: stub,
            probe: probe(existing: ["/work"], directories: ["/work"])
        )
        model.refresh()
        let target = URL(fileURLWithPath: "/work/myrepo-new")
        let r = model.addWorktree(path: target, branch: "newbranch", createBranch: true)
        XCTAssertEqual(r, .added)
        XCTAssertEqual(stub.addCalls.count, 1)
        XCTAssertEqual(stub.addCalls[0].path.path, "/work/myrepo-new")
        XCTAssertEqual(stub.addCalls[0].branch, "newbranch")
        XCTAssertTrue(stub.addCalls[0].createBranch)
        // refresh ran after a successful add (one list at refresh(), one post-add)
        XCTAssertEqual(stub.listCallCount, 2)
    }

    func testAddRawPathRejectsEmptyWithoutCallingGit() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [entry("/work/myrepo", state: .current)])
        let model = WorktreeManagerModel(git: stub, probe: probe(directories: ["/work"]))
        model.refresh()
        let r = model.addWorktree(rawPath: "   ")
        XCTAssertEqual(r, .invalid(.empty))
        XCTAssertTrue(stub.addCalls.isEmpty)
    }

    func testAddRawPathCallsThrough() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [entry("/work/myrepo", state: .current)])
        let model = WorktreeManagerModel(
            git: stub,
            probe: probe(existing: ["/work"], directories: ["/work"])
        )
        model.refresh()
        let r = model.addWorktree(rawPath: "/work/myrepo-new", branch: "b", createBranch: false)
        XCTAssertEqual(r, .added)
        XCTAssertEqual(stub.addCalls.count, 1)
        XCTAssertEqual(stub.addCalls[0].path.path, "/work/myrepo-new")
        XCTAssertEqual(stub.addCalls[0].branch, "b")
        XCTAssertFalse(stub.addCalls[0].createBranch)
    }

    func testAddSurfacesGitFailure() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [entry("/work/myrepo", state: .current)])
        stub.addReturns = false
        let model = WorktreeManagerModel(
            git: stub,
            probe: probe(existing: ["/work"], directories: ["/work"])
        )
        model.refresh()
        let r = model.addWorktree(path: URL(fileURLWithPath: "/work/myrepo-new"))
        XCTAssertEqual(r, .gitFailed)
        XCTAssertEqual(stub.addCalls.count, 1)
    }

    // MARK: - model: remove dispatch (safe vs force)

    func testRemoveCurrentRefuses() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [entry("/work/myrepo", state: .current)])
        let model = WorktreeManagerModel(git: stub, probe: probe(directories: []))
        let rows = model.refresh()
        let r = model.removeRow(rows[0])
        XCTAssertEqual(r, .notRemovable)
        XCTAssertTrue(stub.removeCalls.isEmpty)
    }

    func testRemoveNormalIsSafeNoForce() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [
            entry("/work/myrepo", state: .current),
            entry("/work/feature-wt", branch: "feature", state: .normal),
        ])
        let model = WorktreeManagerModel(git: stub, probe: probe(directories: []))
        let rows = model.refresh()
        let r = model.removeRow(rows[1])
        XCTAssertEqual(r, .removed)
        XCTAssertEqual(stub.removeCalls.count, 1)
        XCTAssertEqual(stub.removeCalls[0].path.path, "/work/feature-wt")
        XCTAssertFalse(stub.removeCalls[0].force, "a clean worktree removes without --force")
    }

    func testRemoveLockedForcesAutomatically() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [
            entry("/work/myrepo", state: .current),
            entry("/work/locked-wt", state: .locked),
        ])
        let model = WorktreeManagerModel(git: stub, probe: probe(directories: []))
        let rows = model.refresh()
        let r = model.removeRow(rows[1])
        XCTAssertEqual(r, .removed)
        XCTAssertEqual(stub.removeCalls.count, 1)
        XCTAssertTrue(stub.removeCalls[0].force, "a locked worktree needs --force")
    }

    func testRemoveNormalCanBeForcedExplicitly() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [
            entry("/work/myrepo", state: .current),
            entry("/work/feature-wt", branch: "feature", state: .normal),
        ])
        let model = WorktreeManagerModel(git: stub, probe: probe(directories: []))
        let rows = model.refresh()
        let r = model.removeRow(rows[1], force: true)
        XCTAssertEqual(r, .removed)
        XCTAssertTrue(stub.removeCalls[0].force, "explicit force overrides safe classification")
    }

    func testRemoveSurfacesGitFailure() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [
            entry("/work/myrepo", state: .current),
            entry("/work/feature-wt", branch: "feature", state: .normal),
        ])
        stub.removeReturns = false
        let model = WorktreeManagerModel(git: stub, probe: probe(directories: []))
        let rows = model.refresh()
        let r = model.removeRow(rows[1])
        XCTAssertEqual(r, .gitFailed)
    }

    // MARK: - model: prune

    func testCanPruneReflectsCandidates() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [
            entry("/work/myrepo", state: .current),
            entry("/work/gone-wt", state: .prunable),
        ])
        let model = WorktreeManagerModel(git: stub, probe: probe(directories: []))
        model.refresh()
        XCTAssertTrue(model.canPrune)
        XCTAssertEqual(model.pruneCandidates.count, 1)
    }

    func testCanPruneFalseWhenNoPrunable() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [
            entry("/work/myrepo", state: .current),
            entry("/work/feature-wt", branch: "feature", state: .normal),
        ])
        let model = WorktreeManagerModel(git: stub, probe: probe(directories: []))
        model.refresh()
        XCTAssertFalse(model.canPrune)
    }

    func testPruneCallsThroughAndRefreshes() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [
            entry("/work/myrepo", state: .current),
            entry("/work/gone-wt", state: .prunable),
        ])
        let model = WorktreeManagerModel(git: stub, probe: probe(directories: []))
        model.refresh()
        XCTAssertTrue(model.prune())
        XCTAssertEqual(stub.pruneCallCount, 1)
        XCTAssertEqual(stub.listCallCount, 2) // refresh() + post-prune refresh
    }

    func testPruneSurfacesGitFailure() {
        let root = URL(fileURLWithPath: "/work/myrepo")
        let stub = StubGit(repoRoot: root, list: [entry("/work/myrepo", state: .current)])
        stub.pruneReturns = false
        let model = WorktreeManagerModel(git: stub, probe: probe(directories: []))
        model.refresh()
        XCTAssertFalse(model.prune())
        XCTAssertEqual(stub.pruneCallCount, 1)
        XCTAssertEqual(stub.listCallCount, 1) // no post-prune refresh on failure
    }
}
