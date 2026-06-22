import XCTest
import Foundation

/// TSK-1231 (TSK-1133 follow-up) — guards CI-workflow invariants the docs + the
/// tier discipline depend on, so a CI refactor can't silently break them.
///
/// The MDV_RUN_WEBVIEW_TESTS lane is LOAD-BEARING: the in-process live-WKWebView
/// suites (ComponentVisualTests, ContentViewHostingTests, MermaidHostingTests,
/// RenderedFindBarTests, …) `#192`-gate themselves on that env var and therefore
/// run ONLY in `nightly-vm.yml`'s WebView lane. Two ways that silently breaks:
///   - the nightly lane is dropped in a CI refactor → those suites run NOWHERE,
///     coverage vanishes with no other signal;
///   - the lane leaks into `pr.yml` (the merge gate) → the gate would realize
///     real WKWebViews on the runner (against CLAUDE.md "not the merge gate").
/// This pins both directions. Pure file read — host-safe, no module dependency.
final class CIWorkflowTruthTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func read(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(rel), encoding: .utf8)
    }

    func test_webViewLane_isInNightly_notInMergeGate() throws {
        let nightly = try read(".github/workflows/nightly-vm.yml")
        let pr = try read(".github/workflows/pr.yml")

        XCTAssertTrue(nightly.contains("MDV_RUN_WEBVIEW_TESTS"),
            "nightly-vm.yml must run the WebView lane (MDV_RUN_WEBVIEW_TESTS) — the in-process "
            + "live-WKWebView suites run NOWHERE else; dropping it silently loses their coverage")
        XCTAssertFalse(pr.contains("MDV_RUN_WEBVIEW_TESTS"),
            "pr.yml (the merge gate) must NOT set MDV_RUN_WEBVIEW_TESTS — it would realize real "
            + "WKWebViews on the CI runner; the WebView lane is nightly-only (CLAUDE.md: 'not the merge gate')")
    }
}
