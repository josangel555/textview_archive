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
}
