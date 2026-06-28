import WebKit
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1270 — validates that the rendered-MD Find CLEAR removes ALL `<mark>`
/// highlights from the live DOM (the owner-reported bug: "highlights remain after
/// dismissing the Find bar"). The model side (dismiss → empty `renderedQuery`) is
/// covered host-only by `FindCoordinatorDraftTests` / `RenderedFindBarModelTests`;
/// THIS is the render half the host gate cannot run. It injects the SAME
/// `MarkdownRenderedView.Coordinator.findScript` the production view uses, marks a
/// query, then asserts both the explicit clear (`__mdvFindClear()` — the dismiss
/// path) AND the empty-query run leave ZERO mark elements — including the active
/// `mark.mdv-find-current` — and that the text survives the unwrap losslessly.
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1` — the VM/nightly WebView lane; listed in
/// `test-in-vm.sh` `run_webview_tests`). Demonstrates teeth: it goes RED if
/// `clearMarks` ever stops unwrapping the active match or drops/duplicates text.
@MainActor
final class RenderedFindClearWebViewTests: WebViewTestCase {

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

    // Completion-handler bridged (TSK-1047 — the async evaluateJavaScript
    // intermittently throws WKError-5 even for scalar results).
    private func evalBool(_ js: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            webView.evaluateJavaScript(js) { v, _ in
                cont.resume(returning: ((v as? NSNumber)?.boolValue) ?? (v as? Bool ?? false))
            }
        }
    }
    private func evalInt(_ js: String) async -> Int {
        await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            webView.evaluateJavaScript(js) { v, _ in
                cont.resume(returning: (v as? NSNumber)?.intValue ?? -1)
            }
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

    private func markCount() async -> Int {
        await evalInt("document.querySelectorAll('mark.mdv-find, mark.mdv-find-current').length")
    }

    /// search → explicit clear (the Esc / dismiss path) → no marks remain.
    func test_findClear_removesAllMarks_includingActive() async throws {
        try await loadBody("<p>alpha beta alpha gamma alpha</p>")
        await dispatch(MarkdownRenderedView.Coordinator.findScript)

        // Mark "alpha" (3 hits). __mdvFindRun makes the first the active match.
        await dispatch("window.__mdvFindRun('alpha', false, 1);")
        let marked = await markCount()
        XCTAssertEqual(marked, 3, "three 'alpha' hits wrapped in <mark>")
        let hasActive = await evalBool(
            "document.querySelectorAll('mark.mdv-find-current').length === 1")
        XCTAssertTrue(hasActive, "the active match is wrapped as mdv-find-current")

        // The dismiss path: __mdvFindClear must remove BOTH plain and active marks.
        await dispatch("window.__mdvFindClear();")
        let afterClear = await markCount()
        XCTAssertEqual(
            afterClear, 0,
            "TSK-1270: __mdvFindClear removes ALL marks incl. the active mdv-find-current")
        let textIntact = await evalBool(
            "document.body.textContent === 'alpha beta alpha gamma alpha'")
        XCTAssertTrue(textIntact, "clearMarks unwraps marks losslessly — no text lost or duplicated")
    }

    /// search → empty-query run (clearing the field, distinct from Esc) → no marks.
    func test_emptyQueryRun_alsoClears() async throws {
        try await loadBody("<p>one two one</p>")
        await dispatch(MarkdownRenderedView.Coordinator.findScript)
        await dispatch("window.__mdvFindRun('one', false, 1);")
        let marked = await markCount()
        XCTAssertEqual(marked, 2, "two 'one' hits marked")

        await dispatch("window.__mdvFindRun('', false, 1);")
        let afterEmpty = await markCount()
        XCTAssertEqual(afterEmpty, 0, "empty-query run clears marks (walkAndMark early-return)")
        let textIntact = await evalBool("document.body.textContent === 'one two one'")
        XCTAssertTrue(textIntact, "text intact after empty-query clear")
    }

    // MARK: - __mdvFindRun behavior (count / navigation / case / regex-escape)

    /// The reported total + the DOM mark count agree, and count is accurate.
    func test_findRun_countAccuracy() async throws {
        try await loadBody("<p>foo bar foo baz foo qux foo</p>")
        await dispatch(MarkdownRenderedView.Coordinator.findScript)
        let total = await evalInt("window.__mdvFindRun('foo', false, 1).total")
        XCTAssertEqual(total, 4, "four 'foo' occurrences counted")
        let marks = await markCount()
        XCTAssertEqual(marks, 4, "DOM mark count agrees with the reported total")
    }

    /// case-insensitive matches all cases; case-sensitive matches only exact case.
    func test_findRun_caseSensitivity() async throws {
        try await loadBody("<p>Foo foo FOO</p>")
        await dispatch(MarkdownRenderedView.Coordinator.findScript)
        let insensitive = await evalInt("window.__mdvFindRun('foo', false, 1).total")
        XCTAssertEqual(insensitive, 3, "case-insensitive matches all three")
        let sensitive = await evalInt("window.__mdvFindRun('foo', true, 1).total")
        XCTAssertEqual(sensitive, 1, "case-sensitive matches only the exact-case 'foo'")
    }

    /// next/prev steps the current match index and wraps at both ends (3 matches).
    func test_findRun_navigationCyclesAndWraps() async throws {
        try await loadBody("<p>x y x y x</p>")
        await dispatch(MarkdownRenderedView.Coordinator.findScript)
        let first = await evalInt("window.__mdvFindRun('x', false, 1).current")
        XCTAssertEqual(first, 0, "first run selects match 0")
        let next1 = await evalInt("window.__mdvFindRun('x', false, 1).current")
        XCTAssertEqual(next1, 1, "next → match 1")
        let next2 = await evalInt("window.__mdvFindRun('x', false, 1).current")
        XCTAssertEqual(next2, 2, "next → match 2")
        let wrapFwd = await evalInt("window.__mdvFindRun('x', false, 1).current")
        XCTAssertEqual(wrapFwd, 0, "next from the last wraps to 0 (3 matches)")
        let wrapBack = await evalInt("window.__mdvFindRun('x', false, -1).current")
        XCTAssertEqual(wrapBack, 2, "prev from 0 wraps to the last (2)")
    }

    /// Regex metacharacters in the query are escaped → matched LITERALLY, not as a pattern.
    func test_findRun_regexMetacharsAreLiteral() async throws {
        try await loadBody("<p>a.b axb a.b</p>")
        await dispatch(MarkdownRenderedView.Coordinator.findScript)
        // Literal "a.b" matches the two "a.b" (2). An UNescaped regex /a.b/ would
        // also match "axb" → 3. findScript escapes metachars, so the result is 2.
        let total = await evalInt("window.__mdvFindRun('a.b', false, 1).total")
        XCTAssertEqual(total, 2, "regex metachars escaped — 'a.b' matches literally, not 'axb'")
    }
}
