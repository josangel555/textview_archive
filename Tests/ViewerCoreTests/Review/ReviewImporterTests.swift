import XCTest
@testable import ViewerCore

/// Round-trip tests for `ReviewImporter` (design §5.4 — the re-import half of
/// `ReviewExporter`). Pure `ViewerCore` logic, host-safe (T1).
///
/// The core scenario: export a review → an agent re-emits the JSON with
/// `resolved` flips + `response` fields → import merges them back. Plus the
/// guard cases (malformed / wrong-kind / schema-too-new / id-mismatch),
/// idempotency, partial replies, and the unmatched-comment signal.
final class ReviewImporterTests: XCTestCase {

    private let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let importDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeAuthor() -> ReviewAuthor {
        ReviewAuthor(name: "Jos", email: "jos@example.com")
    }

    private func ctx(_ line: Int, _ text: String) -> HunkContext {
        HunkContext(
            hunkHeader: "@@ -\(line),1 +\(line),1 @@",
            preLines: [],
            anchoredLines: [DiffLine(kind: .added, oldLineNo: nil, newLineNo: line, content: text)],
            postLines: []
        )
    }

    /// Two top-level comments on two files, both initially unresolved.
    private func makeReview() -> Review {
        let blocker = ReviewComment(
            id: "01HXY0000000000000000000B1",
            filePath: "src/a.swift",
            anchor: LineAnchor(side: .new, startLine: 10, endLine: 10, blobSha: "aa"),
            severity: .blocker,
            body: "Off-by-one here.",
            createdAt: pinnedDate, updatedAt: pinnedDate,
            hunkContext: ctx(10, "  for i in 0...n {")
        )
        let question = ReviewComment(
            id: "01HXY0000000000000000000Q1",
            filePath: "src/b.swift",
            anchor: LineAnchor(side: .new, startLine: 20, endLine: 22, blobSha: "bb"),
            severity: .question,
            body: "Why a force-unwrap?",
            createdAt: pinnedDate.addingTimeInterval(5), updatedAt: pinnedDate.addingTimeInterval(5),
            hunkContext: ctx(20, "  let x = dict[key]!")
        )
        return Review(
            id: "01HXY00000000000000000REVW",
            createdAt: pinnedDate, updatedAt: pinnedDate,
            title: "T", scope: .commit(sha: "abc"), repoRoot: "/tmp",
            baseSha: "abc~", headSha: "abc",
            state: .sent,
            comments: [blocker, question], author: makeAuthor()
        )
    }

    /// Build an agent reply JSON by exporting the review then patching specific
    /// comments' `resolved` / `response` via JSONSerialization (simulates what a
    /// coding agent re-emits). Keyed by file path + start line.
    private func agentReply(
        from review: Review,
        edits: [String: (resolved: Bool?, response: String?)]   // key = "path:startLine"
    ) throws -> Data {
        let exported = try ReviewExporter.export(review)
        var obj = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        var files = obj["files"] as! [[String: Any]]
        for fi in files.indices {
            let path = files[fi]["path"] as! String
            var comments = files[fi]["comments"] as! [[String: Any]]
            for ci in comments.indices {
                let anchor = comments[ci]["anchor"] as! [String: Any]
                let start = anchor["startLine"] as! Int
                if let edit = edits["\(path):\(start)"] {
                    if let r = edit.resolved { comments[ci]["resolved"] = r }
                    if let resp = edit.response { comments[ci]["response"] = resp }
                }
            }
            files[fi]["comments"] = comments
        }
        obj["files"] = files
        return try JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - Happy path

    func testMergeAppliesResolvedFlipAndResponse() throws {
        let review = makeReview()
        let reply = try agentReply(from: review, edits: [
            "src/a.swift:10": (resolved: true,  response: "Fixed: changed to ..<n."),
            "src/b.swift:20": (resolved: false, response: "Force-unwrap is safe — key is a compile-time constant."),
        ])

        var seq = 0
        let result = try ReviewImporter.merge(
            reply, into: review, now: importDate,
            replyIDFactory: { seq += 1; return String(format: "01HXY000000000000000000R%02d", seq) }
        )

        XCTAssertEqual(result.matched, 2)
        XCTAssertEqual(result.unmatched, 0)
        XCTAssertEqual(result.resolvedChanged, 1)   // only a.swift flipped (b stayed false)
        XCTAssertEqual(result.repliesAdded, 2)
        XCTAssertFalse(result.isNoOp)

        let merged = result.review
        // Blocker is now resolved.
        let blocker = merged.comments.first { $0.id == "01HXY0000000000000000000B1" }
        XCTAssertEqual(blocker?.resolved, true)
        XCTAssertEqual(blocker?.updatedAt, importDate)
        // Question stays unresolved.
        let question = merged.comments.first { $0.id == "01HXY0000000000000000000Q1" }
        XCTAssertEqual(question?.resolved, false)

        // Two agent replies appended, parented correctly, dated to importDate.
        let replies = merged.comments.filter { $0.parentId != nil }
        XCTAssertEqual(replies.count, 2)
        let blockerReply = replies.first { $0.parentId == "01HXY0000000000000000000B1" }
        XCTAssertEqual(blockerReply?.body, "Fixed: changed to ..<n.")
        XCTAssertEqual(blockerReply?.severity, .info)
        XCTAssertEqual(blockerReply?.createdAt, importDate)
        XCTAssertEqual(blockerReply?.filePath, "src/a.swift")

        // Review updatedAt bumped.
        XCTAssertEqual(merged.updatedAt, importDate)
    }

    func testResolvedFlipWithoutResponse() throws {
        let review = makeReview()
        let reply = try agentReply(from: review, edits: [
            "src/a.swift:10": (resolved: true, response: nil),
        ])
        let result = try ReviewImporter.merge(reply, into: review, now: importDate)
        XCTAssertEqual(result.resolvedChanged, 1)
        XCTAssertEqual(result.repliesAdded, 0)
        XCTAssertEqual(result.matched, 2)   // both echoed (export carries both)
        XCTAssertTrue(result.review.comments.filter { $0.parentId != nil }.isEmpty)
    }

    func testResponseWithoutResolvedChange() throws {
        let review = makeReview()
        // Default export resolved=false; reply keeps false but adds a response.
        let reply = try agentReply(from: review, edits: [
            "src/b.swift:20": (resolved: nil, response: "Answered inline."),
        ])
        let result = try ReviewImporter.merge(reply, into: review, now: importDate)
        XCTAssertEqual(result.resolvedChanged, 0)
        XCTAssertEqual(result.repliesAdded, 1)
        XCTAssertFalse(result.isNoOp)
    }

    // MARK: - Idempotency

    func testReimportIsIdempotent() throws {
        let review = makeReview()
        let reply = try agentReply(from: review, edits: [
            "src/a.swift:10": (resolved: true, response: "Fixed."),
        ])
        var seq = 0
        let factory = { seq += 1; return String(format: "01HXY000000000000000000R%02d", seq) }

        let first = try ReviewImporter.merge(reply, into: review, now: importDate, replyIDFactory: factory)
        XCTAssertEqual(first.repliesAdded, 1)
        XCTAssertEqual(first.resolvedChanged, 1)

        // Re-import the SAME reply into the already-merged review: no dup reply,
        // no further resolved change → no-op.
        let second = try ReviewImporter.merge(reply, into: first.review, now: importDate, replyIDFactory: factory)
        XCTAssertEqual(second.repliesAdded, 0)
        XCTAssertEqual(second.resolvedChanged, 0)
        XCTAssertTrue(second.isNoOp)
        // updatedAt is NOT bumped on a no-op merge.
        XCTAssertEqual(second.review.updatedAt, first.review.updatedAt)
        // Reply count stays at 1.
        XCTAssertEqual(second.review.comments.filter { $0.parentId != nil }.count, 1)
    }

    // MARK: - Whitespace / blank response

    func testBlankResponseIsIgnored() throws {
        let review = makeReview()
        let reply = try agentReply(from: review, edits: [
            "src/a.swift:10": (resolved: nil, response: "   \n  "),
        ])
        let result = try ReviewImporter.merge(reply, into: review, now: importDate)
        XCTAssertEqual(result.repliesAdded, 0)
    }

    func testResponseIsTrimmed() throws {
        let review = makeReview()
        let reply = try agentReply(from: review, edits: [
            "src/a.swift:10": (resolved: nil, response: "  trimmed me  \n"),
        ])
        let result = try ReviewImporter.merge(reply, into: review, now: importDate)
        let appended = result.review.comments.first { $0.parentId != nil }
        XCTAssertEqual(appended?.body, "trimmed me")
    }

    // MARK: - Unmatched comments surfaced

    func testUnmatchedCommentSurfacedNotDropped() throws {
        let review = makeReview()
        var obj = try JSONSerialization.jsonObject(with: try ReviewExporter.export(review)) as! [String: Any]
        var files = obj["files"] as! [[String: Any]]
        // Inject a comment the model doesn't have (agent invented a finding on
        // a line we never anchored).
        files.append([
            "path": "src/c.swift",
            "stats": ["added": 0, "removed": 0],
            "comments": [[
                "severity": "issue",
                "resolved": false,
                "anchor": ["side": "new", "startLine": 99, "endLine": 99],
                "body": "agent-invented finding",
            ]],
        ])
        obj["files"] = files
        let data = try JSONSerialization.data(withJSONObject: obj)

        let result = try ReviewImporter.merge(data, into: review, now: importDate)
        XCTAssertEqual(result.unmatched, 1)
        XCTAssertEqual(result.matched, 2)
        // The invented comment is NOT injected into the model.
        XCTAssertEqual(result.review.comments.filter { $0.parentId == nil }.count, 2)
    }

    func testPartialReplyOnlyTouchesMentionedComments() throws {
        let review = makeReview()
        // Agent reply echoing ONLY a.swift (drop b.swift's file entirely).
        var obj = try JSONSerialization.jsonObject(with: try ReviewExporter.export(review)) as! [String: Any]
        var files = obj["files"] as! [[String: Any]]
        files.removeAll { ($0["path"] as! String) == "src/b.swift" }
        // Resolve the surviving a.swift comment.
        var comments = files[0]["comments"] as! [[String: Any]]
        comments[0]["resolved"] = true
        files[0]["comments"] = comments
        obj["files"] = files
        let data = try JSONSerialization.data(withJSONObject: obj)

        let result = try ReviewImporter.merge(data, into: review, now: importDate)
        XCTAssertEqual(result.matched, 1)
        XCTAssertEqual(result.unmatched, 0)
        XCTAssertEqual(result.resolvedChanged, 1)
        // b.swift's question is untouched (still unresolved).
        XCTAssertEqual(
            result.review.comments.first { $0.id == "01HXY0000000000000000000Q1" }?.resolved,
            false
        )
    }

    // MARK: - Guards

    func testMalformedJSONRejected() {
        let review = makeReview()
        XCTAssertThrowsError(try ReviewImporter.merge("not json {{{", into: review)) { err in
            guard case ReviewImporter.ImportError.malformed = err else {
                return XCTFail("expected .malformed, got \(err)")
            }
        }
    }

    func testWrongKindRejected() throws {
        let review = makeReview()
        var obj = try JSONSerialization.jsonObject(with: try ReviewExporter.export(review)) as! [String: Any]
        obj["kind"] = "something.else"
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertThrowsError(try ReviewImporter.merge(data, into: review)) { err in
            guard case ReviewImporter.ImportError.wrongKind(let k) = err else {
                return XCTFail("expected .wrongKind, got \(err)")
            }
            XCTAssertEqual(k, "something.else")
        }
    }

    func testSchemaTooNewRejected() throws {
        let review = makeReview()
        var obj = try JSONSerialization.jsonObject(with: try ReviewExporter.export(review)) as! [String: Any]
        obj["schemaVersion"] = Review.currentSchema + 5
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertThrowsError(try ReviewImporter.merge(data, into: review)) { err in
            guard case ReviewImporter.ImportError.schemaTooNew(let found, let supported) = err else {
                return XCTFail("expected .schemaTooNew, got \(err)")
            }
            XCTAssertEqual(found, Review.currentSchema + 5)
            XCTAssertEqual(supported, Review.currentSchema)
        }
    }

    func testReviewIDMismatchRejected() throws {
        let review = makeReview()
        var obj = try JSONSerialization.jsonObject(with: try ReviewExporter.export(review)) as! [String: Any]
        var rev = obj["review"] as! [String: Any]
        rev["id"] = "01HXY00000000000000000WRONG"
        obj["review"] = rev
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertThrowsError(try ReviewImporter.merge(data, into: review)) { err in
            guard case ReviewImporter.ImportError.reviewIDMismatch(let expected, let found) = err else {
                return XCTFail("expected .reviewIDMismatch, got \(err)")
            }
            XCTAssertEqual(expected, review.id)
            XCTAssertEqual(found, "01HXY00000000000000000WRONG")
        }
    }

    func testOversizePayloadRejected() throws {
        let review = makeReview()
        // A blob over the cap — doesn't even need to be valid JSON.
        let big = Data(count: ReviewImporter.maxImportBytes + 1)
        XCTAssertThrowsError(try ReviewImporter.merge(big, into: review)) { err in
            guard case ReviewImporter.ImportError.malformed = err else {
                return XCTFail("expected .malformed (oversize), got \(err)")
            }
        }
    }

    // MARK: - Reply preserves anchor + commitSha

    func testReplyInheritsParentAnchorAndCommitSha() throws {
        // A comment anchored to a specific commit (the commit-diff flow).
        let commitComment = ReviewComment(
            id: "01HXY0000000000000000000C1",
            parentId: nil,
            filePath: "x.swift",
            commitSha: "deadbeef",
            anchor: LineAnchor(side: .old, startLine: 3, endLine: 3, blobSha: "zz"),
            severity: .issue, body: "stale call",
            createdAt: pinnedDate, updatedAt: pinnedDate,
            hunkContext: ctx(3, "  legacy()")
        )
        let review = Review(
            id: "01HXY00000000000000000REVW",
            createdAt: pinnedDate, updatedAt: pinnedDate,
            title: "T", scope: .commit(sha: "deadbeef"), repoRoot: "/tmp",
            baseSha: "deadbeef~", headSha: "deadbeef",
            comments: [commitComment], author: makeAuthor()
        )
        let reply = try agentReply(from: review, edits: [
            "x.swift:3": (resolved: true, response: "removed the legacy call"),
        ])
        let result = try ReviewImporter.merge(reply, into: review, now: importDate,
                                              replyIDFactory: { "01HXY000000000000000000R01" })
        let appended = result.review.comments.first { $0.parentId != nil }
        XCTAssertEqual(appended?.commitSha, "deadbeef")
        XCTAssertEqual(appended?.anchor.side, .old)
        XCTAssertEqual(appended?.anchor.startLine, 3)
    }
}
