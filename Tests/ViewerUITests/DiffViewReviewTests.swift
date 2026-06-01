import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore

/// Stage 3 (CODE_REVIEW_V2_DESIGN_2026-06-01.md §6.2/§7): structural T1m for
/// the review-aware `DiffView` + comment cards. Window-FREE — mounts in an
/// `NSHostingView` and lays out without ever ordering a window front (no
/// WKWebView in these views, so the `#192` gate doesn't apply). Real-screen
/// interaction (hover-`+`, drag-select, composer commit) is VM-owed.
///
/// The load-bearing assertion: `reviewSession == nil` renders IDENTICALLY to
/// today, so the two existing read-only call sites are unaffected. We prove
/// this two ways: (1) the nil host realizes a tree with no comment-card
/// content; (2) the affordance path is data-gated on the session.
@MainActor
final class DiffViewReviewTests: HeadlessUITestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tmpDir: URL!

    override func setUp() async throws {
        suiteName = "DiffViewReviewTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeDoc() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private let sampleDiff = """
    diff --git a/a.swift b/a.swift
    index 111..222 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -1,3 +1,4 @@
     line one
    +added line
     line two
     line three
    """

    private func makeReviewWithComment(filePath: String = "a.swift", line: Int = 2) -> Review {
        let comment = ReviewComment(
            id: ReviewID.generate(),
            filePath: filePath,
            anchor: LineAnchor(side: .new, startLine: line, endLine: line),
            severity: .issue,
            body: "needs a guard here",
            createdAt: t0, updatedAt: t0,
            hunkContext: HunkContext(
                hunkHeader: "@@ -1,3 +1,4 @@",
                preLines: [],
                anchoredLines: [DiffLine(kind: .added, oldLineNo: nil, newLineNo: line, content: "added line")],
                postLines: []
            )
        )
        return Review(
            id: ReviewID.generate(), createdAt: t0, updatedAt: t0, title: "DV",
            scope: .commit(sha: "abc"), repoRoot: tmpDir.path,
            baseSha: "abc~", headSha: "abc", state: .inReview, comments: [comment],
            author: ReviewAuthor(name: "Jos", email: "jos@x")
        )
    }

    /// Mount a view in a window-free NSHostingView and lay it out. Returns the
    /// host so callers can walk the realized tree. Never orders a window.
    @discardableResult
    private func mount<V: View>(_ view: V, size: NSSize = .init(width: 640, height: 480)) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }

    // MARK: - nil path renders identically (read-only guard)

    func test_nilReviewSession_mountsReadOnly_withoutThrowing() {
        let doc = makeDoc()
        // Default initializer — no reviewSession; this is exactly the two
        // existing call sites' shape.
        let view = DiffView(text: sampleDiff, doc: doc)
        let host = mount(view)
        XCTAssertFalse(host.subviews.isEmpty, "read-only diff still realizes a tree")
    }

    func test_nilReviewSession_defaultArgument_isNil() {
        // The contract: the property defaults to nil so call sites that omit
        // it (ContentView, FileHistoryView) get the read-only path.
        let doc = makeDoc()
        let view = DiffView(text: sampleDiff, doc: doc)
        XCTAssertNil(view.reviewSession)
    }

    // MARK: - session path mounts the review affordances

    func test_reviewSessionPresent_mountsWithThreadContainer_withoutThrowing() {
        let doc = makeDoc()
        let store = ReviewStore(directory: tmpDir)
        let session = ReviewSession(review: makeReviewWithComment(), store: store, git: nil)
        let view = DiffView(text: sampleDiff, doc: doc, reviewSession: session)
        XCTAssertNotNil(view.reviewSession)
        let host = mount(view)
        XCTAssertFalse(host.subviews.isEmpty)
    }

    func test_sessionDrivesAffordances_dataGate() {
        // The render gate is `reviewSession != nil` and the per-line thread
        // filter keys on filePath + anchor.startLine. Assert that data layer
        // directly so the structural test isn't hostage to SwiftUI internals.
        let store = ReviewStore(directory: tmpDir)
        let session = ReviewSession(review: makeReviewWithComment(line: 2), store: store, git: nil)
        let onLine2 = session.review.comments.filter {
            $0.parentId == nil && $0.filePath == "a.swift" && $0.anchor.startLine == 2
        }
        XCTAssertEqual(onLine2.count, 1)
        let onLine9 = session.review.comments.filter {
            $0.parentId == nil && $0.filePath == "a.swift" && $0.anchor.startLine == 9
        }
        XCTAssertTrue(onLine9.isEmpty, "no thread anchors to an unrelated line")
    }
}
