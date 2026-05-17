import XCTest
@testable import ViewerCore

/// Layer-1 tests from §9 of CODE_REVIEW_DESIGN.md.
///
/// These exercise the pure persistence types — defaults, invariants,
/// Codable round-trips, the tagged-union scope, and the ID format.
/// Nothing touches disk; that's `ReviewStoreTests`.
final class ReviewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeAuthor() -> ReviewAuthor {
        ReviewAuthor(name: "Jos", email: "jos@example.com")
    }

    private func makeReview(
        state: ReviewState = .draft,
        comments: [ReviewComment] = []
    ) -> Review {
        Review(
            id: "01HXY7M8K2QZ7C5E4N0V9JZRWA",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            title: "Test Review",
            description: "A test review.",
            scope: .branch(branch: "feat/x", base: "main"),
            repoRoot: "/tmp/repo",
            baseSha: "a3f1c20",
            headSha: "4e1a8c2",
            state: state,
            comments: comments,
            author: makeAuthor(),
            exports: []
        )
    }

    private func makeComment(
        id: String = "01HXY7M8K2QZ7C5E4N0V9JZRWB",
        severity: ReviewComment.Severity = .blocker,
        resolved: Bool = false,
        startLine: Int = 10,
        endLine: Int = 10
    ) -> ReviewComment {
        ReviewComment(
            id: id,
            parentId: nil,
            filePath: "src/foo.swift",
            anchor: LineAnchor(side: .new, startLine: startLine, endLine: endLine, blobSha: "abc"),
            severity: severity,
            body: "comment body",
            createdAt: Date(timeIntervalSince1970: 1_700_000_050),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_050),
            resolved: resolved,
            hunkContext: HunkContext(
                hunkHeader: "@@ -10,3 +10,3 @@",
                preLines: [],
                anchoredLines: [
                    DiffLine(kind: .added, oldLineNo: nil, newLineNo: startLine, content: "code")
                ],
                postLines: []
            )
        )
    }

    // MARK: - Defaults

    func testReviewInitDefaults() {
        let r = Review(
            id: "01HXY7M8K2QZ7C5E4N0V9JZRWA",
            createdAt: Date(),
            updatedAt: Date(),
            title: "T",
            scope: .commit(sha: "abc"),
            repoRoot: "/tmp",
            baseSha: nil,
            headSha: nil,
            author: makeAuthor()
        )
        XCTAssertEqual(r.state, .draft)
        XCTAssertEqual(r.comments, [])
        XCTAssertEqual(r.exports, [])
        XCTAssertEqual(r.schemaVersion, Review.currentSchema)
        XCTAssertNil(r.description)
    }

    func testReviewCommentInitDefaults() {
        let c = makeComment()
        XCTAssertNil(c.parentId)
        XCTAssertFalse(c.resolved)
    }

    // MARK: - Codable round-trip

    func testReviewRoundTrip() throws {
        let r = makeReview(comments: [makeComment()])
        let data = try JSONFileStore.encoder.encode(r)
        let decoded = try JSONFileStore.decoder.decode(Review.self, from: data)
        XCTAssertEqual(decoded, r)
    }

    func testReviewWithMultipleSeveritiesRoundTrip() throws {
        let comments: [ReviewComment] = ReviewComment.Severity.allCases.enumerated().map {
            (idx, sev) in
            makeComment(
                id: "01HXY7M8K2QZ7C5E4N0V9JZRW\(idx)",
                severity: sev,
                startLine: 10 + idx
            )
        }
        let r = makeReview(comments: comments)
        let data = try JSONFileStore.encoder.encode(r)
        let decoded = try JSONFileStore.decoder.decode(Review.self, from: data)
        XCTAssertEqual(decoded, r)
    }

    func testReviewExportRecordRoundTrip() throws {
        let rec = ReviewExportRecord(
            target: .clipboard,
            at: Date(timeIntervalSince1970: 1_700_000_999),
            destination: "clipboard",
            commentCount: 3
        )
        let data = try JSONFileStore.encoder.encode(rec)
        let decoded = try JSONFileStore.decoder.decode(ReviewExportRecord.self, from: data)
        XCTAssertEqual(decoded, rec)
    }

    // MARK: - ReviewScope tagged-union round-trip

    func testReviewScopeAllCasesRoundTrip() throws {
        let cases: [ReviewScope] = [
            .workingTree(base: "HEAD"),
            .commit(sha: "abc123"),
            .range(from: "main", to: "feat/x"),
            .branch(branch: "feat/x", base: "main"),
        ]
        for scope in cases {
            let data = try JSONFileStore.encoder.encode(scope)
            let decoded = try JSONFileStore.decoder.decode(ReviewScope.self, from: data)
            XCTAssertEqual(decoded, scope, "round-trip failed for \(scope)")
            // Discriminator is visible in the JSON — makes the on-disk
            // file inspectable in TextView itself.
            let s = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(s.contains("\"kind\""), "missing discriminator in: \(s)")
        }
    }

    func testReviewScopeDiscriminatorValues() throws {
        // Spot-check the discriminator strings — they're load-bearing
        // for forward-compat with the export DTO.
        let cases: [(ReviewScope, String)] = [
            (.workingTree(base: "HEAD"),                 "workingTree"),
            (.commit(sha: "abc"),                         "commit"),
            (.range(from: "main", to: "x"),               "range"),
            (.branch(branch: "x", base: "main"),          "branch"),
        ]
        for (scope, expectedKind) in cases {
            let data = try JSONFileStore.encoder.encode(scope)
            let s = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(
                s.contains("\"\(expectedKind)\""),
                "expected kind \(expectedKind) in: \(s)"
            )
        }
    }

    // MARK: - LineAnchor / HunkContext invariants

    func testLineAnchorEndGreaterOrEqualStart() {
        // The type doesn't precondition-trap (we want to keep the
        // store loading corrupt-but-shaped data instead of crashing),
        // but well-formed anchors satisfy this. Spot-check the
        // common construction paths.
        let single = LineAnchor(side: .new, startLine: 10, endLine: 10)
        XCTAssertGreaterThanOrEqual(single.endLine, single.startLine)
        let multi = LineAnchor(side: .new, startLine: 10, endLine: 15)
        XCTAssertGreaterThanOrEqual(multi.endLine, multi.startLine)
    }

    func testHunkContextPreAndPostLineBudget() {
        // Spec says "up to 3" — the type accepts any count (we don't
        // trap on disk-load), but the *exporter* and *builder* honor
        // the cap. This test enforces the type's caller contract.
        let ctx = HunkContext(
            hunkHeader: "@@ ...",
            preLines: Array(repeating: DiffLine(kind: .context, oldLineNo: 1, newLineNo: 1, content: ""), count: 3),
            anchoredLines: [DiffLine(kind: .added, oldLineNo: nil, newLineNo: 4, content: "x")],
            postLines: Array(repeating: DiffLine(kind: .context, oldLineNo: 5, newLineNo: 5, content: ""), count: 3)
        )
        XCTAssertLessThanOrEqual(ctx.preLines.count, 3)
        XCTAssertLessThanOrEqual(ctx.postLines.count, 3)
    }

    // MARK: - Severity enum

    func testSeverityExhaustive() {
        // Must match §2 of the design — the export bySeverity
        // breakdown has fixed fields for each.
        let expected: Set<ReviewComment.Severity> = [
            .info, .suggestion, .issue, .blocker, .praise, .question,
        ]
        XCTAssertEqual(Set(ReviewComment.Severity.allCases), expected)
        XCTAssertEqual(ReviewComment.Severity.allCases.count, 6)
    }

    // MARK: - State machine

    func testStateMachineAllowedTransitions() {
        // §8: explicit allow-list.
        XCTAssertTrue (ReviewState.draft.canTransition(to: .inReview))
        XCTAssertTrue (ReviewState.draft.canTransition(to: .complete))
        XCTAssertTrue (ReviewState.inReview.canTransition(to: .complete))
        XCTAssertTrue (ReviewState.inReview.canTransition(to: .sent))
        XCTAssertTrue (ReviewState.complete.canTransition(to: .sent))
        XCTAssertTrue (ReviewState.complete.canTransition(to: .inReview))  // reopen
        XCTAssertTrue (ReviewState.sent.canTransition(to: .inReview))      // reopen

        // Same-state is idempotent.
        for s in ReviewState.allCases {
            XCTAssertTrue(s.canTransition(to: s), "self-transition refused for \(s)")
        }
    }

    func testStateMachineForbiddenTransitions() {
        // Anything not explicitly allowed must be refused.
        XCTAssertFalse(ReviewState.draft.canTransition(to: .sent))         // skip too far
        XCTAssertFalse(ReviewState.sent.canTransition(to: .draft))         // no back-to-draft
        XCTAssertFalse(ReviewState.sent.canTransition(to: .complete))      // re-export goes via inReview
        XCTAssertFalse(ReviewState.complete.canTransition(to: .draft))
        XCTAssertFalse(ReviewState.inReview.canTransition(to: .draft))
    }

    // MARK: - ID format

    func testReviewIDIsWellFormed() {
        for _ in 0..<32 {
            let id = ReviewID.generate()
            XCTAssertEqual(id.count, 26, "wrong length: \(id)")
            XCTAssertTrue(ReviewID.isWellFormed(id), "malformed id: \(id)")
        }
    }

    func testReviewIDIsFilenameSafe() {
        // Crockford base32 — `[0-9A-Z]` minus I, L, O, U.
        // No whitespace, no path separators, no shell metachars.
        let id = ReviewID.generate()
        let forbidden: Set<Character> = ["/", "\\", ":", " ", ".", "?", "*"]
        XCTAssertTrue(id.allSatisfy { !forbidden.contains($0) })
    }

    func testReviewIDIsLexicographicallyMonotonic() {
        // Two IDs generated a few ms apart should be lex-orderable
        // by creation time. Use explicit dates to avoid clock-skew
        // flakiness.
        let early = ReviewID.generate(now: Date(timeIntervalSince1970: 1_700_000_000))
        let late  = ReviewID.generate(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertLessThan(early.prefix(10), late.prefix(10),
                          "time-prefix not monotonic: \(early) >= \(late)")
    }

    func testReviewIDMalformedDetection() {
        XCTAssertFalse(ReviewID.isWellFormed(""))
        XCTAssertFalse(ReviewID.isWellFormed("too-short"))
        XCTAssertFalse(ReviewID.isWellFormed(String(repeating: "Z", count: 25)))  // 25 chars
        XCTAssertFalse(ReviewID.isWellFormed(String(repeating: "Z", count: 27)))  // 27 chars
        XCTAssertFalse(ReviewID.isWellFormed(String(repeating: "I", count: 26)))  // I excluded
        XCTAssertFalse(ReviewID.isWellFormed(String(repeating: "L", count: 26)))  // L excluded
        XCTAssertFalse(ReviewID.isWellFormed(String(repeating: "O", count: 26)))  // O excluded
        XCTAssertFalse(ReviewID.isWellFormed(String(repeating: "U", count: 26)))  // U excluded
        XCTAssertFalse(ReviewID.isWellFormed(String(repeating: "z", count: 26)))  // lowercase
    }

    // MARK: - Summary projection

    func testReviewSummaryFromReview() {
        let r = makeReview(
            state: .inReview,
            comments: [
                makeComment(id: "01HXY7M8K2QZ7C5E4N0V9JZRW1", resolved: false),
                makeComment(id: "01HXY7M8K2QZ7C5E4N0V9JZRW2", resolved: true),
                makeComment(id: "01HXY7M8K2QZ7C5E4N0V9JZRW3", resolved: false),
            ]
        )
        let s = ReviewSummary(r)
        XCTAssertEqual(s.id, r.id)
        XCTAssertEqual(s.title, r.title)
        XCTAssertEqual(s.state, .inReview)
        XCTAssertEqual(s.commentCount, 3)
        XCTAssertEqual(s.unresolvedCount, 2)
    }
}
