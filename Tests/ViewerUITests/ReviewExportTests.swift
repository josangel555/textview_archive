import XCTest
import AppKit
@testable import ViewerUI
@testable import ViewerCore

/// Stage 3 (§6.5/§7): the export coordinator. The pure JSON build is already
/// covered by ViewerCore's ReviewExporterTests; here we pin the SIDE EFFECTS
/// — pasteboard write, file write, export-record append, and the guarded
/// state → .sent transition. Uses a non-general NSPasteboard so the test
/// doesn't clobber the user's clipboard.
@MainActor
final class ReviewExportTests: HeadlessUITestCase {

    private var tmp: URL!
    private var store: ReviewStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-revexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = ReviewStore(directory: tmp)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSession() -> ReviewSession {
        let comment = ReviewComment(
            id: ReviewID.generate(), filePath: "a.swift",
            anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .blocker, body: "fix this", createdAt: t0, updatedAt: t0,
            hunkContext: HunkContext(hunkHeader: "@@ -1,1 +1,1 @@", preLines: [], anchoredLines: [], postLines: [])
        )
        let review = Review(
            id: ReviewID.generate(), createdAt: t0, updatedAt: t0, title: "EXP",
            scope: .commit(sha: "abc"), repoRoot: tmp.path,
            baseSha: "abc~", headSha: "abc", state: .inReview, comments: [comment],
            author: ReviewAuthor(name: "Jos", email: "jos@x")
        )
        let clock = t0
        return ReviewSession(review: review, store: store, git: nil, now: { clock })
    }

    func test_renderJSON_producesTextviewCodeReviewPayload() {
        let session = makeSession()
        let json = ReviewExportCoordinator.renderJSON(session, instructions: nil)
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("\"textview.code-review\""))
        XCTAssertTrue(json!.contains("\"fix this\""))
    }

    func test_exportToClipboard_writesPasteboard_recordsExport_transitionsToSent() {
        let session = makeSession()
        // Private pasteboard — must NOT touch .general.
        let pb = NSPasteboard(name: .init("mdv-test-\(UUID().uuidString)"))

        let json = ReviewExportCoordinator.exportToClipboard(session, instructions: nil, pasteboard: pb)
        XCTAssertNotNil(json)
        XCTAssertEqual(pb.string(forType: .string), json)
        XCTAssertEqual(session.review.exports.count, 1)
        XCTAssertEqual(session.review.exports.first?.target, .clipboard)
        XCTAssertEqual(session.review.state, .sent, "export transitions inReview → sent")
    }

    func test_exportToFile_writesJSON_andRecordsExport() throws {
        let session = makeSession()
        let out = tmp.appendingPathComponent("export.json")
        XCTAssertTrue(ReviewExportCoordinator.exportToFile(session, instructions: nil, url: out))
        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(written.contains("\"textview.code-review\""))
        XCTAssertEqual(session.review.exports.first?.target, .file)
        XCTAssertEqual(session.review.exports.first?.destination, out.path)
    }

    // MARK: - Two export modes (TSK-530)

    func test_renderJSON_withCode_includesContextSnippet() throws {
        // A comment with a non-empty hunk context so the `context` block has
        // something to carry — otherwise both modes would look identical.
        let session = makeSessionWithSnippet()
        let json = try XCTUnwrap(
            ReviewExportCoordinator.renderJSON(session, instructions: nil, mode: .withCode)
        )
        XCTAssertTrue(json.contains("\"includesCode\" : true"),
                      "withCode flips the top-level flag on")
        XCTAssertTrue(json.contains("\"context\""),
                      "withCode keeps the per-comment snippet block")
        XCTAssertTrue(json.contains("let x = 1"),
                      "withCode carries the verbatim source line")
    }

    func test_renderJSON_withoutCode_omitsContextSnippet_keepsComment() throws {
        let session = makeSessionWithSnippet()
        let json = try XCTUnwrap(
            ReviewExportCoordinator.renderJSON(session, instructions: nil, mode: .withoutCode)
        )
        XCTAssertTrue(json.contains("\"includesCode\" : false"),
                      "withoutCode flips the top-level flag off")
        XCTAssertFalse(json.contains("\"context\""),
                       "withoutCode drops the per-comment snippet block")
        XCTAssertFalse(json.contains("let x = 1"),
                       "withoutCode must not leak the verbatim source line")
        // The comment + anchor themselves survive — only the code is gone.
        XCTAssertTrue(json.contains("\"fix the snippet\""),
                      "the feedback itself stays in withoutCode mode")
    }

    func test_renderJSON_defaultMode_isWithCode() throws {
        // The defaulted-mode overload must keep the legacy with-code shape so
        // existing callers (and the menu's primary action) stay unchanged.
        let session = makeSessionWithSnippet()
        let defaultJSON = try XCTUnwrap(
            ReviewExportCoordinator.renderJSON(session, instructions: nil)
        )
        let withCodeJSON = try XCTUnwrap(
            ReviewExportCoordinator.renderJSON(session, instructions: nil, mode: .withCode)
        )
        XCTAssertEqual(defaultJSON, withCodeJSON)
    }

    func test_exportToClipboard_withoutCode_writesLeanPayload_andRecords() {
        let session = makeSessionWithSnippet()
        let pb = NSPasteboard(name: .init("mdv-test-\(UUID().uuidString)"))
        let json = ReviewExportCoordinator.exportToClipboard(
            session, instructions: nil, mode: .withoutCode, pasteboard: pb
        )
        XCTAssertNotNil(json)
        XCTAssertEqual(pb.string(forType: .string), json)
        XCTAssertFalse(json!.contains("\"context\""),
                       "the clipboard payload honors the withoutCode mode")
        // The export is still recorded + the state still transitions — the mode
        // only changes the payload, not the bookkeeping.
        XCTAssertEqual(session.review.exports.count, 1)
        XCTAssertEqual(session.review.state, .sent)
    }

    func test_exportToFile_withoutCode_writesLeanPayload() throws {
        let session = makeSessionWithSnippet()
        let out = tmp.appendingPathComponent("export-nocode.json")
        XCTAssertTrue(
            ReviewExportCoordinator.exportToFile(
                session, instructions: nil, url: out, mode: .withoutCode
            )
        )
        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(written.contains("\"includesCode\" : false"))
        XCTAssertFalse(written.contains("let x = 1"),
                       "no source leaks to the file in withoutCode mode")
        XCTAssertEqual(session.review.exports.first?.target, .file)
    }

    /// A session whose single comment carries a real hunk snippet, so the
    /// with/without-code payloads actually differ.
    private func makeSessionWithSnippet() -> ReviewSession {
        let line = DiffLine(kind: .added, oldLineNo: nil, newLineNo: 1, content: "let x = 1")
        let comment = ReviewComment(
            id: ReviewID.generate(), filePath: "a.swift",
            anchor: LineAnchor(side: .new, startLine: 1, endLine: 1),
            severity: .issue, body: "fix the snippet", createdAt: t0, updatedAt: t0,
            hunkContext: HunkContext(
                hunkHeader: "@@ -0,0 +1,1 @@",
                preLines: [], anchoredLines: [line], postLines: []
            )
        )
        let review = Review(
            id: ReviewID.generate(), createdAt: t0, updatedAt: t0, title: "EXP",
            scope: .commit(sha: "abc"), repoRoot: tmp.path,
            baseSha: "abc~", headSha: "abc", state: .inReview, comments: [comment],
            author: ReviewAuthor(name: "Jos", email: "jos@x")
        )
        let clock = t0
        return ReviewSession(review: review, store: store, git: nil, now: { clock })
    }

    func test_export_persistsToStore_afterFlush() {
        let session = makeSession()
        let pb = NSPasteboard(name: .init("mdv-test-\(UUID().uuidString)"))
        ReviewExportCoordinator.exportToClipboard(session, instructions: nil, pasteboard: pb)
        session.flush()
        let loaded = store.load(id: session.review.id)
        XCTAssertEqual(loaded?.state, .sent)
        XCTAssertEqual(loaded?.exports.count, 1)
    }
}
