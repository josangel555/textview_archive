import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore

/// Stage 3 (§7): structural T1m for the comment-card views. Mounts each card
/// headlessly (window-free `NSHostingView` + layout) across all 6 severities
/// and the `.stale` badge, asserting they realize without throwing. Also
/// pins the severity→presentation + anchor-state→badge mappings (pure logic
/// that drives the cards). Real interaction is VM-owed.
@MainActor
final class CommentCardStructureTests: HeadlessUITestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tmpDir: URL!

    override func setUp() async throws {
        suiteName = "CommentCardStructureTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
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

    private func comment(_ sev: ReviewComment.Severity, resolved: Bool = false) -> ReviewComment {
        ReviewComment(
            id: ReviewID.generate(),
            filePath: "a.swift",
            anchor: LineAnchor(side: .new, startLine: 3, endLine: 3),
            severity: sev, body: "card body for \(sev.rawValue)",
            createdAt: t0, updatedAt: t0, resolved: resolved,
            hunkContext: HunkContext(hunkHeader: "@@ -3,1 +3,1 @@", preLines: [], anchoredLines: [], postLines: [])
        )
    }

    @discardableResult
    private func mount<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        host.layoutSubtreeIfNeeded()
        return host
    }

    // MARK: - severity / badge mapping (pure)

    func test_allSeverities_haveDistinctLabels() {
        let labels = ReviewComment.Severity.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, ReviewComment.Severity.allCases.count)
    }

    func test_anchorState_badge_currentHasNone_staleAndUnknownDo() {
        XCTAssertNil(AnchorState.current.badge)
        XCTAssertNotNil(AnchorState.stale.badge)
        XCTAssertNotNil(AnchorState.unknown.badge)
    }

    // MARK: - CommentThreadView mounts across all severities + states

    func test_threadCard_mounts_forEverySeverity() {
        let doc = makeDoc()
        for sev in ReviewComment.Severity.allCases {
            let view = CommentThreadView(
                doc: doc, parent: comment(sev), replies: [],
                anchorState: .current,
                onResolveToggle: {}, onReply: {}, onEdit: {}, onDelete: {}
            )
            let host = mount(view)
            XCTAssertFalse(host.subviews.isEmpty, "thread card must realize for \(sev.rawValue)")
        }
    }

    func test_threadCard_mounts_withStaleBadge() {
        let doc = makeDoc()
        let view = CommentThreadView(
            doc: doc, parent: comment(.issue), replies: [],
            anchorState: .stale,
            onResolveToggle: {}, onReply: {}, onEdit: {}, onDelete: {}
        )
        let host = mount(view)
        XCTAssertFalse(host.subviews.isEmpty)
    }

    func test_threadCard_mounts_withReplies() {
        let doc = makeDoc()
        let parent = comment(.question)
        let reply = ReviewComment(
            id: ReviewID.generate(), parentId: parent.id, filePath: "a.swift",
            anchor: parent.anchor, severity: .info, body: "a reply",
            createdAt: t0, updatedAt: t0, hunkContext: parent.hunkContext
        )
        let view = CommentThreadView(
            doc: doc, parent: parent, replies: [reply],
            anchorState: .unknown,
            onResolveToggle: {}, onReply: {}, onEdit: {}, onDelete: {}
        )
        let host = mount(view)
        XCTAssertFalse(host.subviews.isEmpty)
    }

    // MARK: - CommentEditorView mounts

    func test_editorCard_mounts() {
        let doc = makeDoc()
        let view = CommentEditorView(doc: doc, onCommit: { _, _ in }, onCancel: {})
        let host = mount(view)
        XCTAssertFalse(host.subviews.isEmpty)
    }

    // MARK: - CommentSidebar mounts empty + populated

    func test_sidebar_mounts_empty() {
        let doc = makeDoc()
        let view = CommentSidebar(doc: doc, comments: [], onSelect: { _ in })
        let host = mount(view)
        // Empty sidebar is a bare Text (no child NSViews); the real "it laid
        // out without throwing" signal is a realized, non-empty frame.
        XCTAssertGreaterThan(host.frame.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func test_sidebar_mounts_populated() {
        let doc = makeDoc()
        let view = CommentSidebar(
            doc: doc,
            comments: ReviewComment.Severity.allCases.map { comment($0) },
            onSelect: { _ in }
        )
        let host = mount(view)
        XCTAssertFalse(host.subviews.isEmpty)
    }
}
