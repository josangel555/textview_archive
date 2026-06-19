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

    // MARK: - add-comment affordance closure (TSK-912)
    //
    // These pin the exact closures the diff gutter / review toolbar invoke, so
    // a logic regression of the visible add-comment path fails on the host gate
    // (the pixel visibility itself is VM-owed).

    private func sampleFile() -> UnifiedDiff.File {
        let hunk = UnifiedDiff.Hunk(
            oldStart: 10, oldCount: 3, newStart: 10, newCount: 4, header: "f()",
            lines: [
                UnifiedDiff.Line(kind: .context, oldLineNo: 10, newLineNo: 10, content: "a"),
                UnifiedDiff.Line(kind: .added, oldLineNo: nil, newLineNo: 11, content: "TARGET"),
                UnifiedDiff.Line(kind: .context, oldLineNo: 11, newLineNo: 12, content: "b"),
            ]
        )
        return UnifiedDiff.File(oldPath: "a.swift", newPath: "a.swift", hunks: [hunk])
    }

    func test_addCommentFromHunk_capturesAndAppends() {
        // The gutter "Add comment" closure: capture(file,hunk,side,range) +
        // addComment in one call. Severity + body land in the session's
        // comments for that path/range with the frozen context.
        let session = makeSession(makeReview())
        let file = sampleFile()
        let id = session.addComment(
            file: file, hunk: file.hunks[0], side: .new, lineRange: 11...11,
            severity: .blocker, body: "fix this"
        )
        XCTAssertNotNil(id)
        XCTAssertEqual(session.review.comments.count, 1)
        let c = session.review.comments.first
        XCTAssertEqual(c?.filePath, "a.swift")
        XCTAssertEqual(c?.anchor.startLine, 11)
        XCTAssertEqual(c?.anchor.side, .new)
        XCTAssertEqual(c?.severity, .blocker)
        XCTAssertEqual(c?.body, "fix this")
        XCTAssertEqual(c?.hunkContext.anchoredLines.map(\.content), ["TARGET"])
    }

    func test_addCommentFromHunk_rangeOutsideHunk_returnsNil_appendsNothing() {
        let session = makeSession(makeReview())
        let file = sampleFile()
        let id = session.addComment(
            file: file, hunk: file.hunks[0], side: .new, lineRange: 99...99,
            severity: .issue, body: "x"
        )
        XCTAssertNil(id, "a range outside the hunk freezes no bogus snapshot")
        XCTAssertTrue(session.review.comments.isEmpty)
    }

    func test_firstAddTarget_picksFirstReviewableLine_topDown() {
        // Pure picker over a parsed diff: top-down, the FIRST reviewable line
        // wins (here the leading context line at 10), mapped to its side. This
        // drives the toolbar default — it lands at the top of the diff.
        let file = sampleFile()
        let target = ReviewSession.firstAddTarget(in: [file])
        XCTAssertEqual(target, ReviewSession.AddTarget(
            fileIndex: 0, hunkIndex: 0, side: .context, lineNo: 10))
    }

    func test_firstAddTarget_mapsAddedLineToNewSide() {
        // An added-first hunk maps to `.new` on the added line's new number.
        let hunk = UnifiedDiff.Hunk(
            oldStart: 5, oldCount: 0, newStart: 5, newCount: 1, header: "",
            lines: [UnifiedDiff.Line(kind: .added, oldLineNo: nil, newLineNo: 5, content: "new")]
        )
        let file = UnifiedDiff.File(oldPath: "n", newPath: "n", isNew: true, hunks: [hunk])
        XCTAssertEqual(ReviewSession.firstAddTarget(in: [file]),
                       ReviewSession.AddTarget(fileIndex: 0, hunkIndex: 0, side: .new, lineNo: 5))
    }

    func test_firstAddTarget_mapsRemovedLineToOldSide() {
        let hunk = UnifiedDiff.Hunk(
            oldStart: 8, oldCount: 1, newStart: 8, newCount: 0, header: "",
            lines: [UnifiedDiff.Line(kind: .removed, oldLineNo: 8, newLineNo: nil, content: "gone")]
        )
        let file = UnifiedDiff.File(oldPath: "d", newPath: "d", isDeleted: true, hunks: [hunk])
        XCTAssertEqual(ReviewSession.firstAddTarget(in: [file]),
                       ReviewSession.AddTarget(fileIndex: 0, hunkIndex: 0, side: .old, lineNo: 8))
    }

    func test_firstAddTarget_fallsBackToContext_whenNoAddedOrRemoved() {
        let hunk = UnifiedDiff.Hunk(
            oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, header: "",
            lines: [
                UnifiedDiff.Line(kind: .context, oldLineNo: 1, newLineNo: 1, content: "x"),
                UnifiedDiff.Line(kind: .context, oldLineNo: 2, newLineNo: 2, content: "y"),
            ]
        )
        let file = UnifiedDiff.File(oldPath: "c", newPath: "c", hunks: [hunk])
        let target = ReviewSession.firstAddTarget(in: [file])
        XCTAssertEqual(target, ReviewSession.AddTarget(
            fileIndex: 0, hunkIndex: 0, side: .context, lineNo: 1))
    }

    func test_firstAddTarget_emptyDiff_isNil() {
        XCTAssertNil(ReviewSession.firstAddTarget(in: []))
        let binary = UnifiedDiff.File(oldPath: "b", newPath: "b", isBinary: true, hunks: [])
        XCTAssertNil(ReviewSession.firstAddTarget(in: [binary]),
                     "a binary file has no anchorable line")
    }

    func test_addCommentAtTarget_resolvesAgainstLoadedDiff_andAppends() {
        // The toolbar closure: addComment(at: firstAddTarget). Seed diffFiles
        // via the test seam (reload() needs a live git repo).
        let session = makeSession(makeReview())
        session.setDiffFilesForTesting([sampleFile()])
        let target = try? XCTUnwrap(session.firstAddTarget)
        let id = session.addComment(at: target!, severity: .suggestion, body: "consider X")
        XCTAssertNotNil(id)
        XCTAssertEqual(session.review.comments.count, 1)
        let c = session.review.comments.first
        // firstAddTarget is the top-down first reviewable line (context @ 10).
        XCTAssertEqual(c?.anchor.startLine, 10)
        XCTAssertEqual(c?.anchor.side, .context)
        XCTAssertEqual(c?.severity, .suggestion)
        XCTAssertEqual(c?.body, "consider X")
    }

    func test_addCommentAtTarget_outOfRangeIndices_returnsNil() {
        let session = makeSession(makeReview())
        session.setDiffFilesForTesting([sampleFile()])
        // fileIndex past the end → nil, no append.
        let bad = ReviewSession.AddTarget(fileIndex: 9, hunkIndex: 0, side: .new, lineNo: 11)
        XCTAssertNil(session.addComment(at: bad, severity: .info, body: "x"))
        XCTAssertTrue(session.review.comments.isEmpty)
    }

    func test_listBinding_reflectsAddEditResolveFromAffordanceClosure() {
        // The comments list (sidebar/threads bind to review.comments) updates
        // across the affordance closure's add → edit → resolve lifecycle.
        let session = makeSession(makeReview())
        let file = sampleFile()
        let id = try? XCTUnwrap(session.addComment(
            file: file, hunk: file.hunks[0], side: .new, lineRange: 11...11,
            severity: .issue, body: "first"))
        XCTAssertEqual(session.review.comments.filter { $0.parentId == nil }.count, 1)

        session.updateComment(id: id!, body: "edited", severity: .blocker)
        XCTAssertEqual(session.review.comments.first?.body, "edited")
        XCTAssertEqual(session.review.comments.first?.severity, .blocker)

        session.setResolved(id: id!, true)
        XCTAssertEqual(session.review.comments.first?.resolved, true)
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
