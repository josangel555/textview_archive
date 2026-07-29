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
    /// The TSK-838 verified-apply contract: `mdvApplyBlockPatch` returns the
    /// post-apply `children.length` (or -1 on container/parse failure).
    private func evalInt(_ js: String) async -> Int {
        await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            webView.evaluateJavaScript(js) { v, _ in
                cont.resume(returning: (v as? NSNumber)?.intValue ?? Int.min)
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
        let landed = await evalInt("window.mdvApplyBlockPatch('body', JSON.stringify(\(payload)))")
        XCTAssertEqual(landed, new.count,
            "mdvApplyBlockPatch must return the post-apply children.length (\(message))",
            file: file, line: line)
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

    // MARK: - The production plan (MarkdownRenderedView.domPatchPlan) on a live WebView

    func test_domPatchPlan_smallDiff_patchesLiveBody_andCountVerifies() async throws {
        let oldHTML = "<p>Alpha</p>\n<p>Beta</p>\n<p>Gamma</p>\n"
        try await loadBody(oldHTML)
        let newHTML = "<p>Alpha</p>\n<p>Beta EDITED</p>\n<p>Gamma</p>\n"
        // The EXACT production plan the gated updateNSView same-file path evaluates.
        guard let plan = MarkdownRenderedView.domPatchPlan(oldHTML: oldHTML, newHTML: newHTML) else {
            return XCTFail("a small same-file diff should produce a patch plan")
        }
        XCTAssertEqual(plan.expectedBlockCount, 3)
        let landed = await evalInt(plan.js)
        XCTAssertEqual(landed, plan.expectedBlockCount,
            "a clean apply must land on the expected block count (the verify contract)")
        let summary = await bodySummary()
        XCTAssertEqual(summary, "p:Alpha|p:Beta EDITED|p:Gamma",
            "the live body must reflect the patched block; got: \(summary)")
    }

    /// TSK-838 external-change staleness fix — the DETECTION teeth: when the live
    /// body has drifted from the splitBlocks grain (the silent-no-op class that left
    /// externally-changed markdown stale), the returned count MISMATCHES the plan's
    /// expectation, which is exactly the signal `updateNSView` uses to fall back to
    /// a full reload. Before the fix this scenario "succeeded" fire-and-forget.
    func test_domPatchPlan_misalignedLiveBody_countMismatchSignalsFallback() async throws {
        let oldHTML = "<p>Alpha</p>\n<p>Beta</p>\n<p>Gamma</p>\n"
        let newHTML = "<p>Alpha</p>\n<p>Beta EDITED</p>\n<p>Gamma</p>\n"
        // Live body has ONE EXTRA block vs the splitBlocks grain of oldHTML —
        // the mermaid/math post-processing drift class.
        try await loadBody(oldHTML + "<div>injected-by-postprocessing</div>\n")
        guard let plan = MarkdownRenderedView.domPatchPlan(oldHTML: oldHTML, newHTML: newHTML) else {
            return XCTFail("plan expected for a small diff")
        }
        let landed = await evalInt(plan.js)
        XCTAssertNotEqual(landed, plan.expectedBlockCount,
            "a drifted body must NOT count-verify — this mismatch is the fallback trigger")
        XCTAssertEqual(landed, plan.expectedBlockCount + 1,
            "returned value is the real post-apply children.length")
    }

    func test_domPatchPlan_largeDiff_isNilForFallback() async throws {
        let oldHTML = (0..<10).map { "<p>old \($0)</p>\n" }.joined()
        let newHTML = (0..<10).map { "<p>new \($0)</p>\n" }.joined()  // all 10 blocks differ
        // A large rewrite (10/10 blocks) exceeds the eligibility threshold, so the
        // plan declines (nil) and the caller falls back to loadHTMLString.
        XCTAssertNil(MarkdownRenderedView.domPatchPlan(oldHTML: oldHTML, newHTML: newHTML),
            "a large diff should NOT patch — caller falls back to a full loadHTMLString reload")
    }
}
