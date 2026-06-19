import XCTest
@testable import ViewerCore

/// Regression guard for the Swift 6.0 `count(where:)` adoption (TSK-793).
///
/// Several `ViewerCore` roll-up properties were converted from the
/// allocating `xs.filter { … }.count` idiom to the single-pass stdlib
/// `xs.count { … }` (`Sequence.count(where:)`, SE-0220, shipped Swift
/// 6.0 / our 6.3 toolchain). The two forms are behaviourally identical,
/// so this suite locks that equivalence at every converted call site —
/// including the boundary cases the conversion's correctness hinges on
/// (empty input, all-match, none-match). A logic regression here fails
/// the host headless gate.
///
/// Sites covered:
///  - `LSPDiagnosticsStore.{error,warning,information,hint}Count`
///  - `LSPProblemsViewModel.FileGroup.{error,warning}Count`
///  - `LSPProblemsViewModel.{live,dead}ServerCount`
///  - `ReviewStore` summary `unresolvedCount` (via `ReviewSummary`)
///  - `CrossFileReplace.Summary.filesChanged`
@MainActor
final class CountWhereAdoptionTests: XCTestCase {

    // MARK: - Fixtures

    private let urlA = URL(fileURLWithPath: "/tmp/a.swift")
    private let urlB = URL(fileURLWithPath: "/tmp/b.swift")

    private func diag(line: Int,
                      severity: LSPDiagnostic.Severity) -> LSPDiagnostic {
        LSPDiagnostic(
            range: .init(start: .init(line: line, character: 0),
                         end: .init(line: line, character: 4)),
            severity: severity, code: nil, source: nil, message: "msg")
    }

    // MARK: - LSPDiagnosticsStore severity roll-ups

    func test_diagnosticsStore_severityCounts_acrossFiles() {
        let store = LSPDiagnosticsStore()
        store.replace(url: urlA, with: [
            diag(line: 0, severity: .error),
            diag(line: 1, severity: .error),
            diag(line: 2, severity: .warning),
            diag(line: 3, severity: .information),
        ])
        store.replace(url: urlB, with: [
            diag(line: 0, severity: .error),
            diag(line: 1, severity: .hint),
            diag(line: 2, severity: .hint),
        ])

        XCTAssertEqual(store.errorCount, 3)
        XCTAssertEqual(store.warningCount, 1)
        XCTAssertEqual(store.informationCount, 1)
        XCTAssertEqual(store.hintCount, 2)
        // Sum of the four severities equals the total (no diagnostic is
        // double-counted or dropped by the single-pass predicate).
        XCTAssertEqual(
            store.errorCount + store.warningCount
                + store.informationCount + store.hintCount,
            store.totalCount)
    }

    func test_diagnosticsStore_severityCounts_emptyStore() {
        let store = LSPDiagnosticsStore()
        XCTAssertEqual(store.errorCount, 0)
        XCTAssertEqual(store.warningCount, 0)
        XCTAssertEqual(store.informationCount, 0)
        XCTAssertEqual(store.hintCount, 0)
    }

    func test_diagnosticsStore_severityCounts_allSameSeverity() {
        let store = LSPDiagnosticsStore()
        store.replace(url: urlA, with: [
            diag(line: 0, severity: .warning),
            diag(line: 1, severity: .warning),
        ])
        XCTAssertEqual(store.warningCount, 2)
        XCTAssertEqual(store.errorCount, 0)
    }

    // MARK: - LSPProblemsViewModel.FileGroup counts

    func test_fileGroup_errorWarningCounts() {
        let group = LSPProblemsViewModel.FileGroup(
            url: urlA,
            diagnostics: [
                diag(line: 0, severity: .error),
                diag(line: 1, severity: .warning),
                diag(line: 2, severity: .warning),
                diag(line: 3, severity: .hint),
            ])
        XCTAssertEqual(group.errorCount, 1)
        XCTAssertEqual(group.warningCount, 2)
    }

    func test_fileGroup_emptyDiagnostics() {
        let group = LSPProblemsViewModel.FileGroup(url: urlA, diagnostics: [])
        XCTAssertEqual(group.errorCount, 0)
        XCTAssertEqual(group.warningCount, 0)
    }

    // MARK: - LSPProblemsViewModel server-health counts

    func test_serverCounts_liveAndDead() {
        let keyA = LSPPool.Key(language: .swift,
                               workspaceRoot: URL(fileURLWithPath: "/ws/a"))
        let keyB = LSPPool.Key(language: .swift,
                               workspaceRoot: URL(fileURLWithPath: "/ws/b"))
        let keyC = LSPPool.Key(language: .swift,
                               workspaceRoot: URL(fileURLWithPath: "/ws/c"))
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [],
            serverStatuses: [
                LSPPool.StatusSnapshot(key: keyA, isLive: true, isDead: false,
                                       status: LSPPool.LSPServerStatus()),
                LSPPool.StatusSnapshot(key: keyB, isLive: false, isDead: true,
                                       status: LSPPool.LSPServerStatus()),
                LSPPool.StatusSnapshot(key: keyC, isLive: true, isDead: false,
                                       status: LSPPool.LSPServerStatus()),
            ])
        XCTAssertEqual(vm.liveServerCount, 2)
        XCTAssertEqual(vm.deadServerCount, 1)
    }

    func test_serverCounts_noServers() {
        let vm = LSPProblemsViewModel(diagnosticsByFile: [], serverStatuses: [])
        XCTAssertEqual(vm.liveServerCount, 0)
        XCTAssertEqual(vm.deadServerCount, 0)
    }

    // MARK: - ReviewSummary.unresolvedCount

    func test_reviewSummary_unresolvedCount() {
        let summary = ReviewSummary(makeReview(comments: [
            makeComment(id: "01HXY7M8K2QZ7C5E4N0V9JZRW1", resolved: false),
            makeComment(id: "01HXY7M8K2QZ7C5E4N0V9JZRW2", resolved: true),
            makeComment(id: "01HXY7M8K2QZ7C5E4N0V9JZRW3", resolved: false),
            makeComment(id: "01HXY7M8K2QZ7C5E4N0V9JZRW4", resolved: false),
        ]))
        XCTAssertEqual(summary.commentCount, 4)
        XCTAssertEqual(summary.unresolvedCount, 3)
    }

    func test_reviewSummary_allResolved() {
        let summary = ReviewSummary(makeReview(comments: [
            makeComment(id: "01HXY7M8K2QZ7C5E4N0V9JZRW1", resolved: true),
            makeComment(id: "01HXY7M8K2QZ7C5E4N0V9JZRW2", resolved: true),
        ]))
        XCTAssertEqual(summary.unresolvedCount, 0)
    }

    func test_reviewSummary_noComments() {
        XCTAssertEqual(ReviewSummary(makeReview(comments: [])).unresolvedCount, 0)
    }

    private func makeReview(comments: [ReviewComment]) -> Review {
        Review(
            id: "01HXY7M8K2QZ7C5E4N0V9JZRWA",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            title: "Test Review",
            scope: .branch(branch: "feat/x", base: "main"),
            repoRoot: "/tmp/repo",
            baseSha: "a3f1c20",
            headSha: "4e1a8c2",
            state: .inReview,
            comments: comments,
            author: ReviewAuthor(name: "Jos", email: "jos@example.com"))
    }

    private func makeComment(id: String, resolved: Bool) -> ReviewComment {
        ReviewComment(
            id: id,
            filePath: "src/foo.swift",
            anchor: LineAnchor(side: .new, startLine: 10, endLine: 10, blobSha: "abc"),
            severity: .blocker,
            body: "comment body",
            createdAt: Date(timeIntervalSince1970: 1_700_000_050),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_050),
            resolved: resolved,
            hunkContext: HunkContext(
                hunkHeader: "@@ -10,3 +10,3 @@",
                preLines: [],
                anchoredLines: [
                    DiffLine(kind: .added, oldLineNo: nil, newLineNo: 10, content: "code")
                ],
                postLines: []))
    }

    // MARK: - CrossFileReplace.Summary.filesChanged

    func test_crossFileReplace_filesChanged() {
        // `succeeded` is derived: error == nil. So a nil-error outcome with
        // >0 replacements is the only kind that counts as "changed".
        let outcomes: [CrossFileReplace.FileOutcome] = [
            .init(url: urlA, replacements: 3, error: nil),
            // Succeeded but zero replacements ⇒ NOT counted as changed.
            .init(url: urlB, replacements: 0, error: nil),
            // Failed (error set) ⇒ NOT counted as changed.
            .init(url: URL(fileURLWithPath: "/tmp/c"), replacements: 0, error: "boom"),
            .init(url: URL(fileURLWithPath: "/tmp/d"), replacements: 1, error: nil),
        ]
        let summary = CrossFileReplace.Summary(outcomes: outcomes)
        XCTAssertEqual(summary.filesChanged, 2)
    }

    func test_crossFileReplace_filesChanged_noneChanged() {
        let outcomes: [CrossFileReplace.FileOutcome] = [
            .init(url: urlA, replacements: 0, error: nil),
            .init(url: urlB, replacements: 0, error: "x"),
        ]
        XCTAssertEqual(CrossFileReplace.Summary(outcomes: outcomes).filesChanged, 0)
    }
}
