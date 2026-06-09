import XCTest
@testable import ViewerCore

/// Teeth for TSK-523 slice 2: the commit-diff extension of the review-comment
/// anchor model. The load-bearing contracts:
///   • `ReviewComment.commitSha` round-trips and is ADDITIVE — a review JSON
///     written before the field existed still decodes (key absent → nil), so
///     existing on-disk reviews are not broken.
///   • `CommitDiffAnchor` partitions comments by commit, counts them, lists the
///     distinct commented commits, and resolves the blob rev per anchor side
///     (root commit → empty tree) so `AnchorStaleness` composes.
final class CommitDiffAnchorTests: XCTestCase {

    // MARK: - Fixtures

    private func comment(
        id: String,
        commitSha: String?,
        filePath: String = "src/foo.swift",
        side: LineAnchor.Side = .new,
        line: Int = 10
    ) -> ReviewComment {
        ReviewComment(
            id: id,
            parentId: nil,
            filePath: filePath,
            commitSha: commitSha,
            anchor: LineAnchor(side: side, startLine: line, endLine: line, blobSha: "blob-\(id)"),
            severity: .issue,
            body: "body \(id)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            resolved: false,
            hunkContext: HunkContext(
                hunkHeader: "@@ -10,1 +10,1 @@",
                preLines: [],
                anchoredLines: [DiffLine(kind: .added, oldLineNo: nil, newLineNo: line, content: "x")],
                postLines: []
            )
        )
    }

    // MARK: - Codable: additive + backward-compatible

    func test_commitSha_roundTrips() throws {
        let c = comment(id: "A", commitSha: "deadbeefcafe")
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(ReviewComment.self, from: data)
        XCTAssertEqual(back.commitSha, "deadbeefcafe")
        XCTAssertEqual(back, c)
    }

    /// nil commitSha must be OMITTED from the encoded JSON (synthesized
    /// `encodeIfPresent`) — so a freshly-written file-review comment is
    /// byte-identical to one written before the field existed.
    func test_nilCommitSha_isOmittedFromJSON() throws {
        let c = comment(id: "A", commitSha: nil)
        let data = try JSONEncoder().encode(c)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["commitSha"], "nil commitSha should not appear in the on-disk JSON")
    }

    /// THE backward-compat guard: a review JSON written by code that predates
    /// `commitSha` (key entirely absent) must still decode, with commitSha nil.
    /// Simulated by stripping the key from a valid encoding.
    func test_preCommitShaJSON_decodesWithNilCommitSha() throws {
        let c = comment(id: "A", commitSha: "shouldBeDropped")
        let data = try JSONEncoder().encode(c)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "commitSha")               // pretend it's an old file
        XCTAssertNil(obj["commitSha"])
        let oldData = try JSONSerialization.data(withJSONObject: obj)

        let decoded = try JSONDecoder().decode(ReviewComment.self, from: oldData)
        XCTAssertNil(decoded.commitSha)                    // absent → nil, no throw
        XCTAssertEqual(decoded.id, "A")                    // the rest still loads
        XCTAssertEqual(decoded.filePath, "src/foo.swift")
    }

    // MARK: - Partition / counts / distinct

    func test_commentsForCommit_filtersByShaAndExcludesNil() {
        let all = [
            comment(id: "A", commitSha: "c1"),
            comment(id: "B", commitSha: "c2"),
            comment(id: "C", commitSha: "c1"),
            comment(id: "D", commitSha: nil),     // scope-diff / file-review comment
        ]
        let c1 = CommitDiffAnchor.comments(all, forCommit: "c1")
        XCTAssertEqual(c1.map(\.id), ["A", "C"])  // order preserved, c2 + nil excluded
        XCTAssertEqual(CommitDiffAnchor.comments(all, forCommit: "c2").map(\.id), ["B"])
        XCTAssertTrue(CommitDiffAnchor.comments(all, forCommit: "nope").isEmpty)
    }

    func test_commentedCommits_distinctFirstSeenOrder() {
        let all = [
            comment(id: "A", commitSha: "c2"),
            comment(id: "B", commitSha: nil),
            comment(id: "C", commitSha: "c1"),
            comment(id: "D", commitSha: "c2"),    // dup — already seen
        ]
        XCTAssertEqual(CommitDiffAnchor.commentedCommits(all), ["c2", "c1"])
    }

    func test_commentCounts_perCommitExcludingNil() {
        let all = [
            comment(id: "A", commitSha: "c1"),
            comment(id: "B", commitSha: "c1"),
            comment(id: "C", commitSha: "c2"),
            comment(id: "D", commitSha: nil),
        ]
        XCTAssertEqual(CommitDiffAnchor.commentCounts(all), ["c1": 2, "c2": 1])
    }

    // MARK: - blobRev (staleness bridge)

    func test_blobRev_newAndContextSides_readTheCommitItself() {
        XCTAssertEqual(
            CommitDiffAnchor.blobRev(side: .new, commitSha: "c9", firstParent: "p8"), "c9")
        XCTAssertEqual(
            CommitDiffAnchor.blobRev(side: .context, commitSha: "c9", firstParent: "p8"), "c9")
    }

    func test_blobRev_oldSide_readsTheParent() {
        XCTAssertEqual(
            CommitDiffAnchor.blobRev(side: .old, commitSha: "c9", firstParent: "p8"), "p8")
    }

    func test_blobRev_oldSide_rootCommit_usesEmptyTree() {
        XCTAssertEqual(
            CommitDiffAnchor.blobRev(side: .old, commitSha: "root", firstParent: nil),
            CumulativeDiffSelection.emptyTreeSHA)
    }

    // MARK: - AnchorStaleness composition (documented semantic)

    /// A commit is immutable: the captured blob still resolves at the rev
    /// `blobRev` returns ⇒ `.current`. If the commit was rewritten/GC'd the rev
    /// is unresolvable (live nil) ⇒ `.unknown`. Never `.stale` for a live commit.
    func test_anchorStaleness_composesOverCommitImmutability() {
        let captured = "blobX"
        // commit still present → live blob equals captured.
        XCTAssertEqual(
            AnchorState.evaluate(capturedBlobSha: captured, liveBlobSha: captured), .current)
        // commit vanished (rev no longer resolves) → unknown, not stale.
        XCTAssertEqual(
            AnchorState.evaluate(capturedBlobSha: captured, liveBlobSha: nil), .unknown)
    }
}
