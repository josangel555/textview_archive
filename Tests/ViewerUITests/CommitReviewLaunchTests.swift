import XCTest
@testable import ViewerCore
import TestSupport
@testable import ViewerUI

/// TSK-523 slice 3 (host core) — "Review Commit…" from the Git Log. The
/// Log row's context-menu item calls exactly `openCommitReview(sha:)`, the
/// index row calls exactly `openReview(id:)`, and the back button calls
/// exactly `closeActiveReview()` (exact-closure rule) — pinning these pins
/// the launch behavior. ReviewTabView's pixels are the VM lane.
@MainActor
final class CommitReviewLaunchTests: XCTestCase {

    private var repo: URL!

    override func setUp() async throws {
        try await super.setUp()
        repo = try GitTestRepo.makeRepo(
            prefix: "CommitReviewLaunchTests", email: "rev@example.com", name: "Reviewer")
        try commit("first", file: "a.txt", content: "one\n")
        try commit("second", file: "a.txt", content: "two\n")
    }

    override func tearDown() async throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        try await super.tearDown()
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
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8) ?? ""
    }

    private func commit(_ subject: String, file: String, content: String) throws {
        try content.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", subject])
    }

    private func headSha() throws -> String {
        try git(["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeModel() -> GitPanelModel {
        let m = GitPanelModel()
        m.setRepoRoot(repo)
        return m
    }

    // MARK: launch ------------------------------------------------------

    func test_openCommitReview_createsPersistedCommitReview_andSelectsReviewTab() throws {
        let m = makeModel()
        let sha = try headSha()

        m.openCommitReview(sha: sha)

        let session = try XCTUnwrap(m.activeReviewSession)
        XCTAssertEqual(session.review.scope, .commit(sha: sha))
        XCTAssertEqual(session.review.author.name, "Reviewer",
                       "author captured from git config at creation")
        XCTAssertEqual(m.selectedTab, .review, "launch lands the user ON the review")
        XCTAssertFalse(session.diffFiles.isEmpty,
                       "the commit's structured diff is loaded (git show → DiffParser)")
        // Persisted in the project-local store.
        let store = ReviewStore.projectLocal(repoRoot: repo)
        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(store.load(id: session.review.id)?.scope, .commit(sha: sha))
    }

    func test_openCommitReview_isIdempotentPerSha() throws {
        let m = makeModel()
        let sha = try headSha()

        m.openCommitReview(sha: sha)
        let firstId = m.activeReviewSession?.review.id
        m.openCommitReview(sha: sha)

        XCTAssertEqual(m.activeReviewSession?.review.id, firstId,
                       "re-invoking reopens the SAME review — comments accumulate")
        XCTAssertEqual(ReviewStore.projectLocal(repoRoot: repo).list().count, 1,
                       "no duplicate review minted per (repo, sha)")
    }

    func test_openCommitReview_differentSha_isADifferentReview() throws {
        let m = makeModel()
        let head = try headSha()
        let parent = try git(["rev-parse", "--short", "HEAD^"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        m.openCommitReview(sha: head)
        let headReviewId = m.activeReviewSession?.review.id
        m.openCommitReview(sha: parent)

        XCTAssertNotEqual(m.activeReviewSession?.review.id, headReviewId)
        XCTAssertEqual(ReviewStore.projectLocal(repoRoot: repo).list().count, 2)
    }

    func test_openReview_byId_activatesExisting_andCloseClears() throws {
        let m = makeModel()
        let sha = try headSha()
        m.openCommitReview(sha: sha)
        let id = try XCTUnwrap(m.activeReviewSession?.review.id)

        m.closeActiveReview()
        XCTAssertNil(m.activeReviewSession, "back button clears the active session")

        m.selectTab(.log)
        m.openReview(id: id)
        XCTAssertEqual(m.activeReviewSession?.review.id, id, "index row click reopens by id")
        XCTAssertEqual(m.selectedTab, .review)
    }

    func test_setRepoRoot_clearsActiveReviewSession() throws {
        let m = makeModel()
        m.openCommitReview(sha: try headSha())
        XCTAssertNotNil(m.activeReviewSession)

        m.setRepoRoot(FileManager.default.temporaryDirectory
            .appendingPathComponent("elsewhere-\(UUID().uuidString)"))
        XCTAssertNil(m.activeReviewSession,
                     "a session's store/git are bound to the old root — must not leak")
    }

    // MARK: comment stamping (TSK-523 anchor model) ----------------------

    func test_addComment_onCommitScopedSession_stampsCommitSha() throws {
        let m = makeModel()
        let sha = try headSha()
        m.openCommitReview(sha: sha)
        let session = try XCTUnwrap(m.activeReviewSession)

        let id = session.addComment(
            filePath: "a.txt",
            anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .info,
            body: "looks wrong",
            hunkContext: HunkContext(
                hunkHeader: "@@ -1 +1 @@",
                preLines: [], anchoredLines: [
                    DiffLine(kind: .added, oldLineNo: nil, newLineNo: 1, content: "two")
                ], postLines: [])
        )

        let comment = session.review.comments.first { $0.id == id }
        XCTAssertEqual(comment?.commitSha, sha,
                       "commit-scoped comments carry the sha for CommitDiffAnchor partitioning")
        // The stamped comment round-trips through the store.
        session.flush()
        let reloaded = ReviewStore.projectLocal(repoRoot: repo).load(id: session.review.id)
        XCTAssertEqual(reloaded?.comments.first?.commitSha, sha)
    }

    func test_addComment_onWorkingTreeScopedSession_leavesCommitShaNil() {
        let store = ReviewStore.projectLocal(repoRoot: repo)
        let now = Date()
        let review = Review(
            id: ReviewID.generate(now: now), createdAt: now, updatedAt: now,
            title: "wt", scope: .workingTree(base: "HEAD"),
            repoRoot: repo.path, baseSha: nil, headSha: nil,
            author: ReviewAuthor(name: "t", email: ""))
        let session = ReviewSession(review: review, store: store)

        let id = session.addComment(
            filePath: "a.txt",
            anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .info,
            body: "wt comment",
            hunkContext: HunkContext(
                hunkHeader: "@@ -1 +1 @@",
                preLines: [], anchoredLines: [
                    DiffLine(kind: .context, oldLineNo: 1, newLineNo: 1, content: "one")
                ], postLines: [])
        )

        XCTAssertNil(session.review.comments.first { $0.id == id }?.commitSha,
                     "file/working-tree reviews are NOT commit-anchored")
    }
}
