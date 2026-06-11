import XCTest
import WebKit
@testable import ViewerUI

/// TSK-624 — the rendered-MD WKWebView coordinator must handle navigation
/// FAILURE outcomes, not just `didFinish`. Pre-fix, none of
/// `didFail` / `didFailProvisionalNavigation` /
/// `webViewWebContentProcessDidTerminate` were implemented, so a failed
/// load (or a renderer process death) left the `lastHTML` dedup baseline
/// claiming the page was current — `updateNSView` would never re-issue
/// the load and the user sat on a blank/spinner view forever ("retry
/// loads fast"). These tests drive the EXACT delegate methods WebKit
/// calls, against a windowless WKWebView (no load is started; host-safe).
@MainActor
final class RenderedLoadFailureRecoveryTests: XCTestCase {

    private func makeCoordinator() -> MarkdownRenderedView.Coordinator {
        MarkdownRenderedView.Coordinator()
    }

    private struct Stub: Error {}

    func test_didFailProvisional_clearsDedupBaseline() {
        let coord = makeCoordinator()
        let wv = WKWebView()
        coord.lastHTML = "<html>stale</html>"
        coord.webView(wv, didFailProvisionalNavigation: nil, withError: Stub())
        XCTAssertNil(coord.lastHTML,
            "a failed provisional load must drop the dedup baseline so the "
            + "next update re-issues the load (TSK-624)")
    }

    func test_didFail_clearsDedupBaseline() {
        let coord = makeCoordinator()
        let wv = WKWebView()
        coord.lastHTML = "<html>stale</html>"
        coord.webView(wv, didFail: nil, withError: Stub())
        XCTAssertNil(coord.lastHTML,
            "a mid-load failure must drop the dedup baseline (TSK-624)")
    }

    func test_processTermination_resetsReadyState_andBaseline() {
        let coord = makeCoordinator()
        let wv = WKWebView()
        coord.lastHTML = "<html>stale</html>"
        coord.documentReady = true
        coord.webViewWebContentProcessDidTerminate(wv)
        XCTAssertNil(coord.lastHTML,
            "renderer death must drop the dedup baseline — the blank view "
            + "never recovers on its own (TSK-624)")
        XCTAssertFalse(coord.documentReady,
            "a dead renderer has no ready document")
    }
}
