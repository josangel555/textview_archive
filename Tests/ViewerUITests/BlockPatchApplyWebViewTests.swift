import WebKit
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1183 — validates the DOM-patch JS apply path (`BlockPatchJS.applyFunction`)
/// END-TO-END against a live WKWebView: `RenderedBlockDiff.diff(old,new)` →
/// `jsPayload` → `mdvApplyBlockPatch` → the patched DOM must equal the NEW block
/// list. This proves the JS replays `RenderedBlockDiff.apply`'s index semantics on
/// a real DOM (the host side — diff/apply/jsPayload — is RenderedBlockDiffTests;
/// THIS is the live half that the host gate cannot run). It exercises the SAME
/// `BlockPatchJS.applyFunction` string the live `updateNSView` rewiring (slice B)
/// will inject, so test and production share one source of truth.
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1` — the VM/nightly WebView lane; listed in
/// `test-in-vm.sh` `run_webview_tests`).
@MainActor
final class BlockPatchApplyWebViewTests: WebViewTestCase {

    private var webView: WKWebView!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    private func loadBody(_ bodyHTML: String) async throws {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.loadHTMLString(
            "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(bodyHTML)</body></html>",
            baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        _ = await evalUntil("document.readyState === 'complete'", deadline: 5)
    }

    // Completion-handler bridged (TSK-1047 — NOT the async evaluateJavaScript, which
    // intermittently throws WKError-5 even for Bool/Number/String results).
    private func evalBool(_ js: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            webView.evaluateJavaScript(js) { v, _ in
                cont.resume(returning: ((v as? NSNumber)?.boolValue) ?? (v as? Bool ?? false))
            }
        }
    }
    private func evalStr(_ js: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(js) { v, _ in cont.resume(returning: (v as? String) ?? "") }
        }
    }
    @discardableResult
    private func evalUntil(_ expr: String, deadline seconds: TimeInterval) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if await evalBool("Boolean(\(expr))") { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
    private func dispatch(_ js: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(js) { _, _ in cont.resume() }
        }
    }

    /// "tag:text|tag:text|…" of the body's element children — a whitespace-robust
    /// snapshot of the block list.
    private func bodySummary() async -> String {
        await evalStr("""
        Array.from(document.body.children)
          .map(function (c) { return c.tagName.toLowerCase() + ':' + c.textContent; })
          .join('|')
        """)
    }

    private func block(_ tag: String, _ html: String) -> RenderedBlockDiff.Block {
        RenderedBlockDiff.Block(tag: tag, html: html)
    }

    /// Drive the full pipeline and assert the live DOM equals `expectedSummary`.
    private func assertPatch(
        load oldHTML: String,
        old: [RenderedBlockDiff.Block],
        new: [RenderedBlockDiff.Block],
        expect expectedSummary: String,
        _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let ops = RenderedBlockDiff.diff(old: old, new: new)
        let payload = RenderedBlockDiff.jsPayload(ops)
        try await loadBody(oldHTML)
        await dispatch(BlockPatchJS.applyFunction)
        let ok = await evalBool("window.mdvApplyBlockPatch('body', JSON.stringify(\(payload)))")
        XCTAssertTrue(ok, "mdvApplyBlockPatch returned false (\(message))", file: file, line: line)
        let summary = await bodySummary()
        XCTAssertEqual(summary, expectedSummary, "\(message) — got: \(summary)", file: file, line: line)
    }

    func test_applyBlockPatch_replaceMiddle_andTagChange() async throws {
        try await assertPatch(
            load: "<p>Alpha</p>\n<p>Beta</p>\n<p>Gamma</p>\n",
            old: [block("p", "<p>Alpha</p>\n"), block("p", "<p>Beta</p>\n"), block("p", "<p>Gamma</p>\n")],
            new: [block("p", "<p>Alpha</p>\n"), block("p", "<p>Beta EDITED</p>\n"), block("h2", "<h2>Delta</h2>\n")],
            expect: "p:Alpha|p:Beta EDITED|h2:Delta",
            "replace middle paragraph + change last block's tag")
    }

    func test_applyBlockPatch_insertAtHead_removeTail() async throws {
        try await assertPatch(
            load: "<p>One</p>\n<p>Two</p>\n",
            old: [block("p", "<p>One</p>\n"), block("p", "<p>Two</p>\n")],
            new: [block("p", "<p>Zero</p>\n"), block("p", "<p>One</p>\n")],
            expect: "p:Zero|p:One",
            "insert a new head block + remove the tail (One is LCS-matched, not rebuilt)")
    }

    func test_applyBlockPatch_unchanged_isNoOp() async throws {
        // An identical doc yields no ops → the DOM is untouched.
        try await assertPatch(
            load: "<p>Same</p>\n<p>Body</p>\n",
            old: [block("p", "<p>Same</p>\n"), block("p", "<p>Body</p>\n")],
            new: [block("p", "<p>Same</p>\n"), block("p", "<p>Body</p>\n")],
            expect: "p:Same|p:Body",
            "no-op patch leaves the DOM intact")
    }

    // MARK: - The production helper (MarkdownRenderedView.tryApplyDOMPatch) on a live WebView

    func test_tryApplyDOMPatch_smallDiff_patchesLiveBody() async throws {
        let oldHTML = "<p>Alpha</p>\n<p>Beta</p>\n<p>Gamma</p>\n"
        try await loadBody(oldHTML)
        let newHTML = "<p>Alpha</p>\n<p>Beta EDITED</p>\n<p>Gamma</p>\n"
        // The EXACT production helper the gated updateNSView same-file path calls.
        let patched = MarkdownRenderedView.tryApplyDOMPatch(
            oldHTML: oldHTML, newHTML: newHTML, webView: webView)
        XCTAssertTrue(patched, "a small same-file diff should patch in place")
        // tryApplyDOMPatch's evaluateJavaScript is async — poll until it lands.
        var summary = ""
        for _ in 0..<60 {
            summary = await bodySummary()
            if summary == "p:Alpha|p:Beta EDITED|p:Gamma" { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(summary, "p:Alpha|p:Beta EDITED|p:Gamma",
            "the live body must reflect the patched block; got: \(summary)")
    }

    func test_tryApplyDOMPatch_largeDiff_returnsFalseForFallback() async throws {
        let oldHTML = (0..<10).map { "<p>old \($0)</p>\n" }.joined()
        try await loadBody(oldHTML)
        let newHTML = (0..<10).map { "<p>new \($0)</p>\n" }.joined()  // all 10 blocks differ
        // A large rewrite (10/10 blocks) exceeds the eligibility threshold, so the
        // helper declines (false) and the caller falls back to loadHTMLString.
        let patched = MarkdownRenderedView.tryApplyDOMPatch(
            oldHTML: oldHTML, newHTML: newHTML, webView: webView)
        XCTAssertFalse(patched,
            "a large diff should NOT patch — caller falls back to a full loadHTMLString reload")
    }
}
