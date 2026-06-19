import XCTest
@testable import ViewerCore

/// TSK-318 — CR Q&A context-assembly slice.
///
/// Pins the contract for `ReviewQAContext.build`:
///   • each comment's hunk text + anchor + severity + file path is included,
///   • ordering is deterministic (file → start line → id),
///   • the payload is byte-bounded, and truncation drops LOWEST-priority
///     comments first (blocker kept longest, praise dropped first),
///   • the question and review identity are always retained.
final class ReviewQAContextTests: XCTestCase {

    // MARK: - Fixtures

    private let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func author() -> ReviewAuthor {
        ReviewAuthor(name: "Jos", email: "jos@example.com")
    }

    /// A hunk with a distinctive marker line so we can assert the hunk text
    /// surfaces in the assembled context.
    private func hunk(marker: String, line: Int) -> HunkContext {
        HunkContext(
            hunkHeader: "@@ -\(line),3 +\(line),4 @@ context-for-\(marker)",
            preLines: [
                DiffLine(kind: .context, oldLineNo: line - 1, newLineNo: line - 1,
                         content: "before-\(marker)")
            ],
            anchoredLines: [
                DiffLine(kind: .added, oldLineNo: nil, newLineNo: line,
                         content: "ANCHORED-\(marker)")
            ],
            postLines: [
                DiffLine(kind: .context, oldLineNo: line, newLineNo: line + 1,
                         content: "after-\(marker)")
            ]
        )
    }

    private func comment(
        id: String,
        file: String,
        startLine: Int,
        severity: ReviewComment.Severity,
        body: String,
        marker: String,
        resolved: Bool = false,
        createdAtOffset: TimeInterval = 0
    ) -> ReviewComment {
        ReviewComment(
            id: id,
            filePath: file,
            anchor: LineAnchor(side: .new, startLine: startLine, endLine: startLine, blobSha: "bb"),
            severity: severity,
            body: body,
            createdAt: pinnedDate.addingTimeInterval(createdAtOffset),
            updatedAt: pinnedDate.addingTimeInterval(createdAtOffset),
            resolved: resolved,
            hunkContext: hunk(marker: marker, line: startLine)
        )
    }

    private func review(comments: [ReviewComment]) -> Review {
        Review(
            id: "01HXY7M8K2QZ7C5E4N0V9JZRWA",
            createdAt: pinnedDate,
            updatedAt: pinnedDate,
            title: "Review of feat/x",
            description: "desc",
            scope: .branch(branch: "feat/x", base: "main"),
            repoRoot: "/repo",
            baseSha: "base000",
            headSha: "head000",
            state: .inReview,
            comments: comments,
            author: author()
        )
    }

    // MARK: - Inclusion: every comment's hunk + anchor + severity + path

    func testIncludesEachCommentsHunkAnchorSeverityAndPath() {
        let r = review(comments: [
            comment(id: "A", file: "a/one.swift", startLine: 10, severity: .blocker,
                    body: "blocker body", marker: "ONE"),
            comment(id: "B", file: "b/two.swift", startLine: 20, severity: .suggestion,
                    body: "suggestion body", marker: "TWO"),
        ])

        let ctx = ReviewQAContext.build(review: r, question: "What does this do?")

        XCTAssertEqual(ctx.comments.count, 2)
        XCTAssertEqual(ctx.droppedCommentCount, 0)
        XCTAssertEqual(ctx.question, "What does this do?")
        XCTAssertEqual(ctx.reviewID, r.id)
        XCTAssertEqual(ctx.reviewTitle, "Review of feat/x")
        XCTAssertEqual(ctx.scopeSummary, "branch feat/x vs main")

        let one = ctx.comments[0]
        XCTAssertEqual(one.filePath, "a/one.swift")
        XCTAssertEqual(one.severity, .blocker)
        XCTAssertEqual(one.anchor.startLine, 10)
        XCTAssertEqual(one.body, "blocker body")
        // Hunk text carries the anchored line + surrounding context, with diff
        // markers.
        XCTAssertTrue(one.hunkText.contains("+ANCHORED-ONE"), one.hunkText)
        XCTAssertTrue(one.hunkText.contains(" before-ONE"), one.hunkText)
        XCTAssertTrue(one.hunkText.contains(" after-ONE"), one.hunkText)
        XCTAssertEqual(one.hunkHeader, "@@ -10,3 +10,4 @@ context-for-ONE")

        let two = ctx.comments[1]
        XCTAssertEqual(two.filePath, "b/two.swift")
        XCTAssertEqual(two.severity, .suggestion)
        XCTAssertTrue(two.hunkText.contains("+ANCHORED-TWO"))
    }

    // MARK: - Deterministic ordering

    func testDeterministicOrderingByFileThenLineThenID() {
        // Intentionally shuffle the input; assert a stable file→line→id order.
        let r = review(comments: [
            comment(id: "Z", file: "z.swift", startLine: 5, severity: .info, body: "z", marker: "Z"),
            comment(id: "A2", file: "a.swift", startLine: 40, severity: .info, body: "a40", marker: "A40"),
            comment(id: "A1", file: "a.swift", startLine: 10, severity: .info, body: "a10", marker: "A10"),
            // Same file + same start line → id breaks the tie (A_dup < A_zzz).
            comment(id: "A_zzz", file: "a.swift", startLine: 10, severity: .info, body: "dupZ", marker: "DUPZ"),
            comment(id: "A_dup", file: "a.swift", startLine: 10, severity: .info, body: "dupA", marker: "DUPA"),
        ])

        let ctx = ReviewQAContext.build(review: r, question: "q")
        let order = ctx.comments.map(\.commentID)
        XCTAssertEqual(order, ["A1", "A_dup", "A_zzz", "A2", "Z"])

        // Byte-for-byte reproducible across builds.
        let again = ReviewQAContext.build(review: r, question: "q")
        XCTAssertEqual(ctx.serialized(), again.serialized())
    }

    // MARK: - Replies flatten onto their parent

    func testRepliesFlattenIntoParentBody() {
        let parent = comment(id: "P", file: "a.swift", startLine: 1, severity: .question,
                             body: "why?", marker: "P")
        let reply = ReviewComment(
            id: "R", parentId: "P", filePath: "a.swift",
            anchor: parent.anchor, severity: .info, body: "because reasons",
            createdAt: pinnedDate.addingTimeInterval(5),
            updatedAt: pinnedDate.addingTimeInterval(5),
            hunkContext: parent.hunkContext
        )
        let ctx = ReviewQAContext.build(review: review(comments: [parent, reply]), question: "q")
        XCTAssertEqual(ctx.comments.count, 1)   // reply folded, not a separate item
        XCTAssertTrue(ctx.comments[0].body.contains("why?"))
        XCTAssertTrue(ctx.comments[0].body.contains("Thread:"))
        XCTAssertTrue(ctx.comments[0].body.contains("because reasons"))
    }

    // MARK: - Byte budget + priority-aware truncation

    func testTruncationDropsLowestPriorityFirstAndStaysUnderBudget() {
        // Each comment carries a big body so a tight budget forces drops. Keep
        // bodies equal-sized so the drop decision is purely severity-driven.
        let big = String(repeating: "X", count: 2_000)
        let r = review(comments: [
            comment(id: "PR", file: "a.swift", startLine: 1, severity: .praise,     body: big, marker: "PR"),
            comment(id: "IN", file: "a.swift", startLine: 2, severity: .info,       body: big, marker: "IN"),
            comment(id: "QU", file: "a.swift", startLine: 3, severity: .question,   body: big, marker: "QU"),
            comment(id: "SU", file: "a.swift", startLine: 4, severity: .suggestion, body: big, marker: "SU"),
            comment(id: "IS", file: "a.swift", startLine: 5, severity: .issue,      body: big, marker: "IS"),
            comment(id: "BL", file: "a.swift", startLine: 6, severity: .blocker,    body: big, marker: "BL"),
        ])

        // Budget that fits roughly 2 of the 6 comments.
        let budget = 6_000
        let ctx = ReviewQAContext.build(review: r, question: "q", byteBudget: budget)

        XCTAssertLessThanOrEqual(ctx.byteSize, budget, "payload must fit the budget")
        XCTAssertEqual(ctx.byteSize, ctx.serialized().count, "byteSize must match serialized payload")
        XCTAssertGreaterThan(ctx.droppedCommentCount, 0, "expected drops under a tight budget")
        XCTAssertEqual(ctx.comments.count + ctx.droppedCommentCount, 6)

        // Whatever survived must be the HIGHEST-priority comments. The minimum
        // priority among kept comments must be >= the maximum priority among
        // dropped ones.
        let keptIDs = Set(ctx.comments.map(\.commentID))
        let keptSeverities = ctx.comments.map(\.severity)
        let minKept = keptSeverities.map(ReviewQAContext.priority(of:)).min() ?? 0

        // The dropped set is the complement.
        let allBySeverity: [String: ReviewComment.Severity] = [
            "PR": .praise, "IN": .info, "QU": .question,
            "SU": .suggestion, "IS": .issue, "BL": .blocker,
        ]
        let droppedSeverities = allBySeverity
            .filter { !keptIDs.contains($0.key) }
            .map(\.value)
        let maxDropped = droppedSeverities.map(ReviewQAContext.priority(of:)).max() ?? -1

        XCTAssertGreaterThanOrEqual(minKept, maxDropped,
            "a kept comment must never be lower-priority than a dropped one")
        // Blocker must always survive a partial truncation.
        XCTAssertTrue(keptIDs.contains("BL"), "blocker should be the last to go")
        XCTAssertFalse(keptIDs.contains("PR"), "praise should be the first to go")

        // Surviving comments stay in DISPLAY order (file→line), not drop order.
        let lines = ctx.comments.map(\.anchor.startLine)
        XCTAssertEqual(lines, lines.sorted(), "kept comments must stay in display order")
    }

    func testFullReviewUnderBudgetDropsNothing() {
        let r = review(comments: [
            comment(id: "A", file: "a.swift", startLine: 1, severity: .blocker, body: "x", marker: "A"),
            comment(id: "B", file: "b.swift", startLine: 2, severity: .info, body: "y", marker: "B"),
        ])
        let ctx = ReviewQAContext.build(review: r, question: "q")  // default generous budget
        XCTAssertEqual(ctx.droppedCommentCount, 0)
        XCTAssertEqual(ctx.comments.count, 2)
        XCTAssertLessThanOrEqual(ctx.byteSize, ReviewQAContext.defaultByteBudget)
    }

    func testTinyBudgetDropsAllCommentsButKeepsQuestion() {
        let big = String(repeating: "Y", count: 5_000)
        let r = review(comments: [
            comment(id: "A", file: "a.swift", startLine: 1, severity: .blocker, body: big, marker: "A"),
        ])
        // A budget far below even one comment → all comments dropped, but the
        // question + review identity stay (we never truncate the question).
        let ctx = ReviewQAContext.build(review: r, question: "an important question", byteBudget: 200)
        XCTAssertEqual(ctx.comments.count, 0)
        XCTAssertEqual(ctx.droppedCommentCount, 1)
        XCTAssertEqual(ctx.question, "an important question")
        XCTAssertTrue(ctx.serializedString().contains("an important question"))
    }

    // MARK: - Priority ladder is a total, sane order

    func testPriorityLadder() {
        XCTAssertGreaterThan(ReviewQAContext.priority(of: .blocker),
                             ReviewQAContext.priority(of: .issue))
        XCTAssertGreaterThan(ReviewQAContext.priority(of: .issue),
                             ReviewQAContext.priority(of: .suggestion))
        XCTAssertGreaterThan(ReviewQAContext.priority(of: .suggestion),
                             ReviewQAContext.priority(of: .question))
        XCTAssertGreaterThan(ReviewQAContext.priority(of: .question),
                             ReviewQAContext.priority(of: .info))
        XCTAssertGreaterThan(ReviewQAContext.priority(of: .info),
                             ReviewQAContext.priority(of: .praise))
        // No two severities share a priority (a total order).
        let prios = ReviewComment.Severity.allCases.map(ReviewQAContext.priority(of:))
        XCTAssertEqual(Set(prios).count, ReviewComment.Severity.allCases.count)
    }

    // MARK: - Scope summaries

    func testScopeSummaries() {
        XCTAssertEqual(ReviewQAContext.scopeSummary(.workingTree(base: "HEAD")), "working tree vs HEAD")
        XCTAssertEqual(ReviewQAContext.scopeSummary(.commit(sha: "abc123")), "commit abc123")
        XCTAssertEqual(ReviewQAContext.scopeSummary(.range(from: "v1", to: "v2")), "range v1..v2")
        XCTAssertEqual(ReviewQAContext.scopeSummary(.branch(branch: "feat", base: "main")),
                       "branch feat vs main")
    }

    // MARK: - hunkText marker mapping

    func testHunkTextDiffMarkers() {
        let ctx = HunkContext(
            hunkHeader: "@@",
            preLines: [DiffLine(kind: .context, oldLineNo: 1, newLineNo: 1, content: "ctx")],
            anchoredLines: [
                DiffLine(kind: .added, oldLineNo: nil, newLineNo: 2, content: "add"),
                DiffLine(kind: .removed, oldLineNo: 2, newLineNo: nil, content: "rem"),
            ],
            postLines: []
        )
        let text = ReviewQAContext.hunkText(ctx)
        XCTAssertEqual(text, " ctx\n+add\n-rem")
    }
}
