import XCTest
@testable import ViewerUI
@testable import ViewerCore
@testable import ViewerKit

/// Tests for `DocumentModel.showGitPanel(tab:)` — the View-menu wiring
/// added in commit c3200e8. It must bump `gitPanelFocusRequest` (so
/// SwiftUI's value-blind publish doesn't swallow repeat asks) and
/// publish `gitPanelDesiredTab`. Model-only — the actual panel
/// expansion happens inside `GitPanelSection` which observes both.
@MainActor
final class DocumentModelGitPanelTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() async throws {
        // No super.setUp — @MainActor strict-concurrency.
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelGitPanelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
    }

    func test_showGitPanel_bumpsFocusRequest() {
        let m = DocumentModel()
        let before = m.gitPanelFocusRequest
        m.showGitPanel(tab: .status)
        XCTAssertEqual(m.gitPanelFocusRequest, before &+ 1)
    }

    func test_showGitPanel_setsDesiredTab() {
        let m = DocumentModel()
        m.showGitPanel(tab: .log)
        XCTAssertEqual(m.gitPanelDesiredTab, .log)
        m.showGitPanel(tab: .remotes)
        XCTAssertEqual(m.gitPanelDesiredTab, .remotes)
    }

    func test_showGitPanel_defaultsToStatus() {
        let m = DocumentModel()
        // The default-argument variant — exercised by the "Show Git
        // Panel" menu item which doesn't specify a tab.
        m.showGitPanel()
        XCTAssertEqual(m.gitPanelDesiredTab, .status)
    }

    func test_showGitPanel_repeatedSameTab_stillBumpsNonce() {
        // SwiftUI dedupes value publishes. The nonce must bump on
        // every call so two clicks of "Show Repository History" both
        // scroll the panel into view, not just the first.
        let m = DocumentModel()
        m.showGitPanel(tab: .log)
        let after1 = m.gitPanelFocusRequest
        m.showGitPanel(tab: .log)
        XCTAssertEqual(m.gitPanelFocusRequest, after1 &+ 1)
    }
}
