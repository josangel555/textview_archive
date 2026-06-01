import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// Stage 2 (CODE_REVIEW_V2_DESIGN_2026-06-01.md §7): the `@MainActor`
/// `ReviewSession` runtime. Headless / window-free — pure model exercise
/// against an injected temp-dir `ReviewStore`. Asserts:
///   • mutations mutate `review` and enqueue a debounced save (verified by
///     loading the store back after `flush()`).
///   • `setState` enforces `canTransition` (illegal transition is a no-op,
///     not a crash).
///   • capture produces a frozen `HunkContext` with the right line numbers.
///   • staleness map recomputes (degrades to `.unknown` without git).
///   • debounce: a burst of edits collapses but lands the FINAL value.
@MainActor
final class ReviewSessionTests: HeadlessUITestCase {

    private var tmp: URL!
    private var store: ReviewStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-revsession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = ReviewStore(directory: tmp)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeReview(state: ReviewState = .draft) -> Review {
        Review(
            id: ReviewID.generate(), createdAt: t0, updatedAt: t0, title: "S2",
            scope: .commit(sha: "abc123"), repoRoot: tmp.path,
            baseSha: "abc122", headSha: "abc123", state: state, comments: [],
            author: ReviewAuthor(name: "Jos", email: "jos@x")
        )
    }

    private func frozenContext() -> HunkContext {
        HunkContext(
            hunkHeader: "@@ -1,1 +1,2 @@",
            preLines: [],
            anchoredLines: [DiffLine(kind: .added, oldLineNo: nil, newLineNo: 1, content: "x")],
            postLines: []
        )
    }

    private func makeSession(_ review: Review) -> ReviewSession {
        let clock = t0   // hoist out so the @Sendable closure doesn't capture self
        return ReviewSession(review: review, store: store, git: nil, now: { clock })
    }

    // MARK: - addComment

    func test_addComment_appends_promotesDraftToInReview_andSaves() {
        let session = makeSession(makeReview(state: .draft))
        let id = session.addComment(
            filePath: "a.swift",
            anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .issue, body: "bug", hunkContext: frozenContext()
        )
        XCTAssertEqual(session.review.comments.count, 1)
        XCTAssertEqual(session.review.state, .inReview, "first comment auto-promotes draft")

        session.flush()
        let loaded = store.load(id: session.review.id)
        XCTAssertEqual(loaded?.comments.count, 1)
        XCTAssertEqual(loaded?.comments.first?.id, id)
        XCTAssertEqual(loaded?.state, .inReview)
    }

    func test_addComment_withoutGit_marksAnchorUnknown() {
        let session = makeSession(makeReview())
        let id = session.addComment(
            filePath: "a.swift",
            anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .info, body: "x", hunkContext: frozenContext()
        )
        // No git → no live blob → unknown (also captured blobSha is nil here).
        XCTAssertEqual(session.anchorStates[id], .unknown)
    }

    // MARK: - reply / edit / resolve / delete

    func test_addReply_threadsUnderParent() {
        let session = makeSession(makeReview())
        let parent = session.addComment(
            filePath: "a.swift",
            anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .question, body: "why?", hunkContext: frozenContext()
        )
        let reply = session.addReply(to: parent, body: "because")
        XCTAssertNotNil(reply)
        let r = session.review.comments.first { $0.id == reply }
        XCTAssertEqual(r?.parentId, parent)
        XCTAssertEqual(r?.filePath, "a.swift")
    }

    func test_addReply_unknownParent_isNoOp() {
        let session = makeSession(makeReview())
        XCTAssertNil(session.addReply(to: "nope", body: "x"))
        XCTAssertTrue(session.review.comments.isEmpty)
    }

    func test_updateComment_changesBodyAndSeverity() {
        let session = makeSession(makeReview())
        let id = session.addComment(
            filePath: "a.swift", anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .info, body: "old", hunkContext: frozenContext()
        )
        session.updateComment(id: id, body: "new", severity: .blocker)
        let c = session.review.comments.first { $0.id == id }
        XCTAssertEqual(c?.body, "new")
        XCTAssertEqual(c?.severity, .blocker)
    }

    func test_setResolved_flipsAndIsIdempotent() {
        let session = makeSession(makeReview())
        let id = session.addComment(
            filePath: "a.swift", anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .info, body: "x", hunkContext: frozenContext()
        )
        session.setResolved(id: id, true)
        XCTAssertEqual(session.review.comments.first { $0.id == id }?.resolved, true)
        // Idempotent: setting the same value doesn't crash / mutate further.
        session.setResolved(id: id, true)
        XCTAssertEqual(session.review.comments.first { $0.id == id }?.resolved, true)
    }

    func test_delete_removesCommentAndItsReplies() {
        let session = makeSession(makeReview())
        let parent = session.addComment(
            filePath: "a.swift", anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .info, body: "p", hunkContext: frozenContext()
        )
        _ = session.addReply(to: parent, body: "r1")
        _ = session.addReply(to: parent, body: "r2")
        XCTAssertEqual(session.review.comments.count, 3)
        session.delete(id: parent)
        XCTAssertTrue(session.review.comments.isEmpty, "thread deleted as a unit")
        XCTAssertNil(session.anchorStates[parent])
    }

    // MARK: - setState / canTransition

    func test_setState_legalTransition_succeeds() {
        let session = makeSession(makeReview(state: .inReview))
        XCTAssertTrue(session.setState(.complete))
        XCTAssertEqual(session.review.state, .complete)
    }

    func test_setState_illegalTransition_isNoOp_notCrash() {
        // draft → sent is NOT allowed (must go via inReview/complete).
        let session = makeSession(makeReview(state: .draft))
        XCTAssertFalse(session.setState(.sent))
        XCTAssertEqual(session.review.state, .draft, "illegal transition left state untouched")
    }

    func test_recordExport_appendsRecord_andTransitionsToSent() {
        let session = makeSession(makeReview(state: .inReview))
        let rec = session.recordExport(target: .clipboard, destination: "clipboard")
        XCTAssertEqual(rec.target, .clipboard)
        XCTAssertEqual(session.review.exports.count, 1)
        XCTAssertEqual(session.review.state, .sent)
    }

    // MARK: - capture (§3.1)

    func test_capture_producesFrozenContext_withCorrectAnchor() {
        let session = makeSession(makeReview())
        let hunk = UnifiedDiff.Hunk(
            oldStart: 10, oldCount: 3, newStart: 10, newCount: 4, header: "f()",
            lines: [
                UnifiedDiff.Line(kind: .context, oldLineNo: 10, newLineNo: 10, content: "a"),
                UnifiedDiff.Line(kind: .added, oldLineNo: nil, newLineNo: 11, content: "TARGET"),
                UnifiedDiff.Line(kind: .context, oldLineNo: 11, newLineNo: 12, content: "b"),
            ]
        )
        let file = UnifiedDiff.File(oldPath: "a.swift", newPath: "a.swift", hunks: [hunk])
        let captured = session.capture(file: file, hunk: hunk, side: .new, range: 11...11)
        XCTAssertNotNil(captured)
        XCTAssertEqual(captured?.anchor.startLine, 11)
        XCTAssertEqual(captured?.anchor.endLine, 11)
        XCTAssertEqual(captured?.context.anchoredLines.map(\.content), ["TARGET"])
        XCTAssertEqual(captured?.context.preLines.map(\.content), ["a"])
        XCTAssertEqual(captured?.context.postLines.map(\.content), ["b"])
        // No git injected → blobSha frozen as nil.
        XCTAssertNil(captured?.anchor.blobSha)
    }

    func test_capture_anchorOutsideHunk_returnsNil() {
        let session = makeSession(makeReview())
        let hunk = UnifiedDiff.Hunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, header: "",
            lines: [UnifiedDiff.Line(kind: .context, oldLineNo: 1, newLineNo: 1, content: "x")]
        )
        let file = UnifiedDiff.File(oldPath: "a", newPath: "a", hunks: [hunk])
        XCTAssertNil(session.capture(file: file, hunk: hunk, side: .new, range: 99...99))
    }

    // MARK: - debounced persistence (republish/storm guard)

    func test_burstOfEdits_coalesces_butLandsTheFinalValueOnDisk() {
        let session = makeSession(makeReview())
        let id = session.addComment(
            filePath: "a.swift", anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .info, body: "v0", hunkContext: frozenContext()
        )
        // Hammer the body — simulates a typing storm. Each call enqueues a
        // save; the coalescing map collapses them.
        for i in 1...50 {
            session.updateComment(id: id, body: "v\(i)")
        }
        session.flush()

        let loaded = store.load(id: session.review.id)
        XCTAssertEqual(loaded?.comments.first?.body, "v50", "the final value must win on disk")
    }

    func test_savePersists_acrossAFreshSessionLoad() {
        let r = makeReview()
        let session = makeSession(r)
        _ = session.addComment(
            filePath: "a.swift", anchor: LineAnchor(side: .new, startLine: 2, endLine: 2),
            severity: .suggestion, body: "tighten", hunkContext: frozenContext()
        )
        session.flush()

        // A brand-new session over the same store id sees the persisted state.
        guard let reloaded = store.load(id: r.id) else { return XCTFail("not persisted") }
        let session2 = makeSession(reloaded)
        XCTAssertEqual(session2.review.comments.count, 1)
        XCTAssertEqual(session2.review.comments.first?.body, "tighten")
    }
}
