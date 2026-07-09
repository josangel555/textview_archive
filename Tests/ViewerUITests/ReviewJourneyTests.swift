import XCTest
import ViewerCore
import TestSupport
@testable import ViewerUI

/// TSK-1445 — the code-review journey driven as ONE end-to-end chain on a REAL
/// commit diff, not the per-method units (which use the no-git seam, anchors
/// `.unknown`). This is the "never driven as a whole" gap the ticket names:
/// open a commit review → comment on a real diff line → reply → resolve →
/// PERSIST → reopen from disk (survives) → export (carries the comment + hunk)
/// → MCP `get_review_context` parity. The interactive on-screen rungs (U1 diff
/// render, U3 scroll-to-anchor navigation) are the WebView/AX tier.
@MainActor
final class ReviewJourneyTests: XCTestCase {

    private var repo: URL!

    override func setUp() async throws {
        try await super.setUp()
        repo = try GitTestRepo.makeRepo(
            prefix: "ReviewJourneyTests", email: "rev@example.com", name: "Reviewer")
        // Two commits so HEAD has a real, non-empty diff to review.
        try commit("first", file: "a.txt", content: "one\n")
        try commit("second", file: "a.txt", content: "two\n")
    }

    override func tearDown() async throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        try await super.tearDown()
    }

    /// The whole journey in one flow. Each `XCTAssert` is a rung; a break
    /// anywhere in the chain fails here rather than passing a green per-unit
    /// suite that never proved the rungs connect.
    func test_reviewJourney_endToEnd_persistsExportsAndMCPParity() throws {
        let sha = try headSha()

        // U1 (model side of "open a commit diff"): the session loads a real diff.
        let model = GitPanelModel()
        model.setRepoRoot(repo)
        model.openCommitReview(sha: sha)
        let session = try XCTUnwrap(model.activeReviewSession, "openCommitReview must start a session")
        XCTAssertFalse(session.diffFiles.isEmpty, "the commit diff loaded with hunks")

        // U2: comment on a real reviewable diff line (anchors to file+line).
        let target = try XCTUnwrap(session.firstAddTarget, "a reviewable line exists in the diff")
        let commentID = try XCTUnwrap(
            session.addComment(at: target, severity: .suggestion, body: "consider renaming this"),
            "the comment anchors inside a hunk and is appended")

        // U4: reply threads under the parent.
        let replyID = try XCTUnwrap(
            session.addReply(to: commentID, body: "agreed, follow-up next commit"),
            "reply appends under the parent")

        // U5: resolve flips state.
        session.setResolved(id: commentID, true)
        XCTAssertTrue(session.review.comments.first(where: { $0.id == commentID })?.resolved == true)

        // Persist the debounced writes, then REOPEN from a fresh store off disk.
        session.flush()
        let reopened = try XCTUnwrap(
            ReviewStore.projectLocal(repoRoot: repo).load(id: session.review.id),
            "the review persists to the project-local store")

        // U2 persistence: comment + reply + resolved survive a reopen.
        let persisted = try XCTUnwrap(reopened.comments.first(where: { $0.id == commentID }))
        XCTAssertEqual(persisted.body, "consider renaming this")
        XCTAssertTrue(persisted.resolved, "resolved state persisted")
        XCTAssertTrue(reopened.comments.contains(where: { $0.id == replyID && $0.parentId == commentID }),
                      "the reply persisted, still threaded under the parent")

        // U6: export carries the comment body AND its hunk.
        let exported = try ReviewExporter.exportAsString(reopened)
        XCTAssertTrue(exported.contains("consider renaming this"), "export contains the comment")
        XCTAssertTrue(exported.contains("@@"), "export contains the diff hunk header")

        // U7: the MCP get_review_context builder returns this same review's
        // comment (agent-side parity — get_review_context wraps ReviewQAContext).
        // The QA context flattens replies into the parent's body (exporter
        // contract), so the top-level item's body CONTAINS the comment (and its
        // thread), rather than equalling it exactly.
        let ctx = ReviewQAContext.build(review: reopened, question: "what changed?")
        XCTAssertEqual(ctx.reviewID, reopened.id)
        let ctxItem = try XCTUnwrap(
            ctx.comments.first(where: { $0.commentID == commentID }),
            "the MCP context surfaces the journey's top-level comment")
        XCTAssertTrue(ctxItem.body.contains("consider renaming this"))
        XCTAssertTrue(ctxItem.resolved, "the resolved state carries into the MCP context")
    }

    /// A discard-of-work guard for the journey: deleting the parent comment
    /// removes its replies too (no orphaned thread persisted).
    func test_deleteParent_removesThread_persisted() throws {
        let model = GitPanelModel()
        model.setRepoRoot(repo)
        model.openCommitReview(sha: try headSha())
        let session = try XCTUnwrap(model.activeReviewSession)
        let target = try XCTUnwrap(session.firstAddTarget)
        let parent = try XCTUnwrap(session.addComment(at: target, severity: .issue, body: "bug here"))
        _ = session.addReply(to: parent, body: "confirmed")
        session.delete(id: parent)
        session.flush()
        let reopened = try XCTUnwrap(ReviewStore.projectLocal(repoRoot: repo).load(id: session.review.id))
        XCTAssertTrue(reopened.comments.isEmpty, "parent + reply both gone after delete")
    }

    // MARK: - helpers

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
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func commit(_ subject: String, file: String, content: String) throws {
        try content.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", subject])
    }

    private func headSha() throws -> String {
        try git(["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
