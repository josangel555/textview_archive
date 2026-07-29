import XCTest
@testable import ViewerCore

/// TSK-1600/1601/1602 — the pure engines behind the Git Log upgrades:
/// multi-field search (commit-id / branch / worktree prefixes + subject),
/// decoration classification (per-kind chip colors), and the all-refs pref.
final class GitLogSearchAndRefsTests: XCTestCase {

    private func commit(
        _ sha: String, subject: String = "s", refs: [String] = []
    ) -> GitClient.GraphCommit {
        GitClient.GraphCommit(
            sha: sha, parents: [], author: "t", timestamp: 0,
            subject: subject, refs: refs,
            filesChanged: 0, insertions: 0, deletions: 0)
    }

    // MARK: - TSK-1600 multi-field search

    func test_search_matchesCommitIDPrefix_caseInsensitive() {
        let c = commit("3f2a9b1", subject: "unrelated")
        XCTAssertEqual(
            GitLogSearchQuery.matchingFields(
                commit: c, refs: [], worktrees: [], rawQuery: "3f2"),
            [.commitID])
        XCTAssertEqual(
            GitLogSearchQuery.matchingFields(
                commit: c, refs: [], worktrees: [], rawQuery: "3F2A"),
            [.commitID], "sha matching is case-insensitive")
        XCTAssertTrue(
            GitLogSearchQuery.matchingFields(
                commit: c, refs: [], worktrees: [], rawQuery: "f2a").isEmpty,
            "PREFIX only — a mid-sha substring is not a hit")
    }

    func test_search_matchesBranchPrefix_andPathComponent() {
        let c = commit("aaa1111", refs: ["feature/b6-grooming", "origin/main"])
        for q in ["feature", "b6", "origin", "main"] {
            XCTAssertTrue(
                GitLogSearchQuery.matchingFields(
                    commit: c, refs: c.refs, worktrees: [], rawQuery: q).contains(.ref),
                "\(q) must match a ref name or one of its path components")
        }
        XCTAssertFalse(
            GitLogSearchQuery.matchingFields(
                commit: c, refs: c.refs, worktrees: [], rawQuery: "zzz").contains(.ref))
    }

    func test_search_matchesWorktreePrefix_viaItsHead() {
        let head = commit("bbb2222")
        let other = commit("ccc3333")
        let wts = [GitLogSearchQuery.Worktree(
            name: "b6-grooming", branch: "feature/b6", head: "bbb2222")]
        XCTAssertTrue(
            GitLogSearchQuery.matchingFields(
                commit: head, refs: [], worktrees: wts, rawQuery: "b6").contains(.worktree),
            "a worktree query surfaces the commit its HEAD points at")
        XCTAssertTrue(
            GitLogSearchQuery.matchingFields(
                commit: other, refs: [], worktrees: wts, rawQuery: "b6").isEmpty,
            "unrelated commits are not dragged in by a worktree query")
    }

    func test_search_matchesSubjectSubstring() {
        let c = commit("ddd4444", subject: "fix: the lifecycle authority")
        XCTAssertTrue(
            GitLogSearchQuery.matchingFields(
                commit: c, refs: [], worktrees: [], rawQuery: "LIFECYCLE").contains(.subject),
            "subject matching is a case-insensitive SUBSTRING")
    }

    func test_search_filterAndMerge_dedupePreservingLocalOrder() {
        let a = commit("aaa1111", subject: "alpha")
        let b = commit("bbb2222", subject: "beta")
        let bodyOnly = commit("ccc3333", subject: "gamma")
        let local = GitLogSearchQuery.filter(
            commits: [a, b, bodyOnly], worktrees: [],
            refsFor: { $0.refs }, rawQuery: "alp")
        XCTAssertEqual(local.map(\.sha), ["aaa1111"])
        // The --grep pass re-finds `a` (body hit) and adds `bodyOnly`.
        let merged = GitLogSearchQuery.merge(local: local, body: [a, bodyOnly])
        XCTAssertEqual(merged.map(\.sha), ["aaa1111", "ccc3333"],
                       "local order first, body-only hits appended, deduped by sha")
    }

    func test_search_emptyQuery_matchesNothing() {
        XCTAssertTrue(GitLogSearchQuery.filter(
            commits: [commit("aaa1111")], worktrees: [],
            refsFor: { $0.refs }, rawQuery: "   ").isEmpty)
    }

    // MARK: - TSK-1601 decoration classification

    func test_classify_everyDecorationKind() {
        XCTAssertEqual(GitRefKind.classify("tag: v1.2").kind, .tag)
        XCTAssertEqual(GitRefKind.classify("tag: v1.2").name, "v1.2",
                       "the tag: prefix is stripped for display")
        XCTAssertEqual(GitRefKind.classify("HEAD").kind, .head)
        let headArrow = GitRefKind.classify("HEAD -> main")
        XCTAssertEqual(headArrow.kind, .head)
        XCTAssertEqual(headArrow.name, "main", "the arrow form shows the branch name")
        XCTAssertEqual(GitRefKind.classify("origin/main").kind, .remoteBranch)
        XCTAssertEqual(GitRefKind.classify("main").kind, .localBranch)
        XCTAssertEqual(GitRefKind.classify("grafted").kind, .other)
    }

    func test_classify_worktreeBranchGetsItsOwnKindAndName() {
        let ref = GitRefKind.classify(
            "b5a4-lifecycle", worktreeBranches: ["b5a4-lifecycle": "b5a4-worktree"])
        XCTAssertEqual(ref.kind, .worktreeBranch,
                       "a branch checked out in ANOTHER worktree is visually distinct")
        XCTAssertEqual(ref.worktreeName, "b5a4-worktree")
        // The same name with no sibling worktree is just a local branch.
        XCTAssertEqual(GitRefKind.classify("b5a4-lifecycle").kind, .localBranch)
    }

    func test_classify_customRemoteName() {
        XCTAssertEqual(
            GitRefKind.classify("fork/topic", remoteNames: ["fork"]).kind, .remoteBranch)
        XCTAssertEqual(
            GitRefKind.classify("fork/topic", remoteNames: ["origin"]).kind, .localBranch,
            "a slash alone doesn't imply a remote — the prefix must be a known remote")
    }

    func test_classifyAll_preservesOrderAndDropsEmpties() {
        let refs = GitRefKind.classifyAll(["HEAD -> main", "origin/main", "tag: v1", "  "])
        XCTAssertEqual(refs.map(\.kind), [.head, .remoteBranch, .tag])
        XCTAssertEqual(refs.map(\.name), ["main", "origin/main", "v1"])
    }

    // MARK: - TSK-1602 all-refs pref

    func test_allRefsPref_defaultsOffAndRoundTrips() {
        let suite = "GitLogPrefsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertFalse(GitLogPrefs.resolveShowAllRefs(d), "ships OFF")
        d.set(true, forKey: GitLogPrefs.showAllRefsKey)
        XCTAssertTrue(GitLogPrefs.resolveShowAllRefs(d))
    }
}
