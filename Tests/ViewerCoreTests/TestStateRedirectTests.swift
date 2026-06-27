import XCTest
@testable import ViewerCore

/// TSK-1288 — under XCTest, the on-disk-state default-dir helpers MUST redirect to
/// a per-process temp dir so HOST tests never read/write the developer's REAL
/// `~/Library/Application Support/MarkdownViewer` state (tests had polluted the real
/// history.json + bloated the real LocalHistory to ~132 MB).
final class TestStateRedirectTests: XCTestCase {

    func test_appSupportBase_redirectsUnderXCTest() throws {
        let base = try XCTUnwrap(TestStateRedirect.appSupportBase(), "redirect must be active under XCTest")
        XCTAssertTrue(base.path.contains("MDVTestState-"),
                      "expected a per-process temp base, got \(base.path)")
        XCTAssertFalse(base.path.contains("Library/Application Support/MarkdownViewer"),
                       "must NOT point at the real app-support dir")
    }

    // TEETH: if the redirect regresses, these return the real ~/Library path.
    func test_storageDefaults_doNotPointAtRealState() {
        let lh = LocalHistoryStore.defaultDirectory().path
        let hs = HistoryStore.defaultStoreURL().path
        XCTAssertTrue(lh.contains("MDVTestState-"),
                      "LocalHistory default must redirect under XCTest, got \(lh)")
        XCTAssertTrue(hs.contains("MDVTestState-"),
                      "history.json default must redirect under XCTest, got \(hs)")
        XCTAssertTrue(lh.hasSuffix("MarkdownViewer/LocalHistory"), "subpath preserved, got \(lh)")
        XCTAssertTrue(hs.hasSuffix("MarkdownViewer/history.json"), "subpath preserved, got \(hs)")
    }

    // Slice 2: the other confirmed-polluted stores also redirect under XCTest.
    func test_slice2_stores_redirectUnderXCTest() {
        XCTAssertTrue(ScrollMemoryStore.defaultStoreURL().path.contains("MDVTestState-"),
                      "scroll-memory must redirect, got \(ScrollMemoryStore.defaultStoreURL().path)")
        XCTAssertTrue(BookmarksStore.defaultStoreURL().path.contains("MDVTestState-"),
                      "bookmarks must redirect, got \(BookmarksStore.defaultStoreURL().path)")
        XCTAssertTrue(GoToPathHistoryStore.defaultStoreURL().path.contains("MDVTestState-"),
                      "recent-paths must redirect, got \(GoToPathHistoryStore.defaultStoreURL().path)")
        XCTAssertTrue(AuditLog().logURL.path.contains("MDVTestState-"),
                      "audit.jsonl must redirect, got \(AuditLog().logURL.path)")
        XCTAssertTrue(ViewModeLockStore.defaultStoreURL().path.contains("MDVTestState-"),
                      "view-mode-locks must redirect, got \(ViewModeLockStore.defaultStoreURL().path)")
        XCTAssertTrue(LSPTrustStore.defaultStoreURL().path.contains("MDVTestState-"),
                      "lsp-trust must redirect, got \(LSPTrustStore.defaultStoreURL().path)")
        XCTAssertTrue(TerminalFavoritesStore.defaultURL().path.contains("MDVTestState-"),
                      "terminal-favorites must redirect, got \(TerminalFavoritesStore.defaultURL().path)")
    }
}
