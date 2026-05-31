import XCTest
import WebKit
@testable import ViewerUI

@MainActor
final class MarkdownRenderedViewTests: XCTestCase {

    private func decide(
        _ url: String?,
        navigationType: WKNavigationType = .linkActivated,
        currentDocumentURL: URL? = nil
    ) -> MarkdownRenderedView.LinkDecision {
        MarkdownRenderedView.Coordinator.decide(
            url: url.flatMap(URL.init(string:)),
            navigationType: navigationType,
            currentDocumentURL: currentDocumentURL
        )
    }

    // MARK: Scheme allowlist (CRIT-1 / S4)

    func test_decide_http_linkActivated_opensExternally() {
        let result = decide("https://example.com")
        guard case .openExternally(let u) = result else {
            return XCTFail("expected .openExternally, got \(result)")
        }
        XCTAssertEqual(u.host, "example.com")
    }

    func test_decide_mailto_opensExternally() {
        guard case .openExternally = decide("mailto:user@example.com") else {
            return XCTFail("expected .openExternally")
        }
    }

    func test_decide_javascript_isCancelled() {
        XCTAssertEqual(decide("javascript:alert(1)"), .cancel)
    }

    func test_decide_data_isCancelled() {
        XCTAssertEqual(decide("data:text/html,%3Cscript%3Ealert(1)%3C/script%3E"), .cancel)
    }

    func test_decide_file_isCancelled() {
        XCTAssertEqual(decide("file:///etc/passwd"), .cancel)
    }

    func test_decide_customAppScheme_isCancelled() {
        XCTAssertEqual(decide("myapp://something/?evil=1"), .cancel)
    }

    func test_decide_nonLinkActivated_isAllowed() {
        // The initial loadHTMLString navigation is `.other`; must always allow
        // or the page never renders.
        XCTAssertEqual(decide("about:blank", navigationType: .other), .allow)
        XCTAssertEqual(decide("file:///tmp/page.html", navigationType: .other), .allow)
    }

    // MARK: WV-4 — post-initial-load .other file:/data: is a script escape

    func test_decide_other_fileScheme_beforeLoad_isAllowed() {
        // Bootstrap loadFileURL / loadHTMLString surfaces as `.other`
        // before didFinish — must be allowed or the page never renders.
        let result = MarkdownRenderedView.Coordinator.decide(
            url: URL(string: "file:///tmp/page.html"),
            navigationType: .other,
            currentDocumentURL: nil,
            initialLoadComplete: false
        )
        XCTAssertEqual(result, .allow)
    }

    func test_decide_other_fileScheme_afterLoad_isCancelled() {
        // `window.location = 'file:///etc/passwd'` from in-page script
        // arrives as a top-level `.other` AFTER the initial load — cancel.
        let result = MarkdownRenderedView.Coordinator.decide(
            url: URL(string: "file:///etc/passwd"),
            navigationType: .other,
            currentDocumentURL: URL(string: "file:///tmp/page.html"),
            initialLoadComplete: true
        )
        XCTAssertEqual(result, .cancel)
    }

    func test_decide_other_dataScheme_afterLoad_isCancelled() {
        // `location.replace('data:text/html,…')` style escape.
        let result = MarkdownRenderedView.Coordinator.decide(
            url: URL(string: "data:text/html,%3Cscript%3E1%3C/script%3E"),
            navigationType: .other,
            currentDocumentURL: URL(string: "file:///tmp/page.html"),
            initialLoadComplete: true
        )
        XCTAssertEqual(result, .cancel)
    }

    func test_decide_other_dataScheme_beforeLoad_isAllowed() {
        // `loadHTMLString(baseURL: nil)` can surface as a data: `.other`
        // during bootstrap — must be permitted until first load completes.
        let result = MarkdownRenderedView.Coordinator.decide(
            url: URL(string: "data:text/html,%3Ch1%3Ehi%3C/h1%3E"),
            navigationType: .other,
            currentDocumentURL: nil,
            initialLoadComplete: false
        )
        XCTAssertEqual(result, .allow)
    }

    func test_decide_other_httpScheme_afterLoad_isAllowed() {
        // The post-load guard is scoped to file:/data: only — a legit
        // http(s) sub-frame / programmatic nav is unaffected.
        let result = MarkdownRenderedView.Coordinator.decide(
            url: URL(string: "https://example.com/page"),
            navigationType: .other,
            currentDocumentURL: URL(string: "file:///tmp/page.html"),
            initialLoadComplete: true
        )
        XCTAssertEqual(result, .allow)
    }

    func test_decide_other_javascript_afterLoad_isCancelled() {
        // javascript: stays unconditionally blocked regardless of the flag.
        let result = MarkdownRenderedView.Coordinator.decide(
            url: URL(string: "javascript:alert(1)"),
            navigationType: .other,
            currentDocumentURL: URL(string: "file:///tmp/page.html"),
            initialLoadComplete: true
        )
        XCTAssertEqual(result, .cancel)
    }

    func test_coordinator_didFinishFirstLoad_startsFalse() {
        // Bootstrap-permissive default: a fresh coordinator has NOT
        // finished its first load, so the very first `.other` file:/data:
        // bootstrap is allowed.
        let coordinator = MarkdownRenderedView.Coordinator()
        XCTAssertFalse(coordinator.didFinishFirstLoad)
    }

    // MARK: Fragment navigation (CRIT-8 — anchor clicks work)

    func test_decide_sameDocFragment_isAllowed() {
        // Use a realistic `file://` URL — newer Foundation (macOS 15.6.1+)
        // no longer parses `about:blank#heading` as having a fragment,
        // so an `about:` test gives a misleading nil-fragment path. In
        // production WKWebView always passes the loaded page's real URL
        // (typically file:// for our bundled markdown render), not
        // about:blank.
        let current = URL(string: "file:///docs/page.html")!
        let target = URL(string: "file:///docs/page.html#heading")!
        let result = MarkdownRenderedView.Coordinator.decide(
            url: target, navigationType: .linkActivated, currentDocumentURL: current
        )
        XCTAssertEqual(result, .allow)
    }

    func test_decide_fragmentOnDifferentDocument_isCancelled() {
        let current = URL(string: "file:///a.html")!
        let target = URL(string: "file:///b.html#heading")!
        let result = MarkdownRenderedView.Coordinator.decide(
            url: target, navigationType: .linkActivated, currentDocumentURL: current
        )
        XCTAssertEqual(result, .cancel)
    }

    // MARK: T1 — Coordinator.lastHTML guards against redundant loads

    func test_coordinator_lastHTML_startsNil() {
        let coordinator = MarkdownRenderedView.Coordinator()
        XCTAssertNil(coordinator.lastHTML)
    }

    func test_coordinator_lastHTML_isUpdatedOnSet() {
        let coordinator = MarkdownRenderedView.Coordinator()
        coordinator.lastHTML = "v1"
        XCTAssertEqual(coordinator.lastHTML, "v1")
        coordinator.lastHTML = "v2"
        XCTAssertEqual(coordinator.lastHTML, "v2")
    }

    // MARK: Mermaid injection state machine (2026-05-29 security fix)
    //
    // Pin: the `mermaidInjected` flag must transition with the active
    // document, NOT stay latched once true. Otherwise a markdown file
    // with one mermaid block followed by a non-mermaid file in the same
    // tab keeps the 2.5 MB runtime + shim attached, extending JS attack
    // surface (`addUserScript` bypasses CSP) to docs that shouldn't have
    // any script-src.
    //
    // The contract is enforced by `nextMermaidInjectionState(...)` — a
    // pure function so we can pin it without a `WKWebView`. The
    // host-safe coverage here exercises the state machine; the live
    // `WKWebView` path (`updateNSView` → `removeAllUserScripts()` /
    // `addUserScript`) is exercised in VM-only `MermaidHostingTests`.

    func test_htmlNeedsMermaid_detectsHostElement() {
        XCTAssertTrue(MarkdownRenderedView.htmlNeedsMermaid(
            "<div class=\"mdv-mermaid\">graph LR;A-->B</div>"
        ))
    }

    func test_htmlNeedsMermaid_emptyOrPlain_returnsFalse() {
        XCTAssertFalse(MarkdownRenderedView.htmlNeedsMermaid(""))
        XCTAssertFalse(MarkdownRenderedView.htmlNeedsMermaid(
            "<h1>Hello</h1><p>No diagrams here.</p>"
        ))
        // Substring match must be tight to the class token. We intentionally
        // accept slight false-positives (e.g. text containing the literal
        // "mdv-mermaid") because the cost of installing the runtime on a
        // doc that just *mentions* the string is negligible — but a doc
        // that doesn't mention it at all must register as not-needing.
        XCTAssertFalse(MarkdownRenderedView.htmlNeedsMermaid(
            "<div class=\"mdv-other\">unrelated</div>"
        ))
    }

    func test_nextMermaidInjectionState_freshNonMermaidDoc_noChange() {
        XCTAssertEqual(
            MarkdownRenderedView.nextMermaidInjectionState(
                currentlyInjected: false, documentWantsMermaid: false
            ),
            .noChange
        )
    }

    func test_nextMermaidInjectionState_freshMermaidDoc_installs() {
        XCTAssertEqual(
            MarkdownRenderedView.nextMermaidInjectionState(
                currentlyInjected: false, documentWantsMermaid: true
            ),
            .install
        )
    }

    func test_nextMermaidInjectionState_mermaidToMermaid_isIdempotent() {
        // Subsequent mermaid render in the same WebView must NOT
        // re-add user scripts (would double-attach the 2.5 MB runtime).
        XCTAssertEqual(
            MarkdownRenderedView.nextMermaidInjectionState(
                currentlyInjected: true, documentWantsMermaid: true
            ),
            .noChange
        )
    }

    func test_nextMermaidInjectionState_mermaidToNonMermaid_evicts() {
        // The regression we're pinning: tab switches from a mermaid
        // doc to a plain markdown doc must drop the runtime so the
        // next page doesn't inherit it.
        XCTAssertEqual(
            MarkdownRenderedView.nextMermaidInjectionState(
                currentlyInjected: true, documentWantsMermaid: false
            ),
            .evict
        )
    }

    /// Simulate the round-trip the orchestrator cares about:
    ///   mermaid doc → non-mermaid doc → mermaid doc
    /// The flag must end up `true` again with an `.install` action
    /// firing on the return trip — i.e. the user-scripts get
    /// re-attached after eviction.
    func test_mermaidInjection_roundTrip_mermaid_to_plain_to_mermaid() {
        // Tracks the "currentlyInjected" bit the way the coordinator
        // does — a Swift Bool driven by the action's return value.
        var injected = false

        // 1. Open a mermaid doc.
        var action = MarkdownRenderedView.nextMermaidInjectionState(
            currentlyInjected: injected,
            documentWantsMermaid: MarkdownRenderedView.htmlNeedsMermaid(
                "<div class=\"mdv-mermaid\">graph TD;A-->B</div>"
            )
        )
        XCTAssertEqual(action, .install)
        injected = true

        // 2. Switch to a plain markdown doc. Must evict.
        action = MarkdownRenderedView.nextMermaidInjectionState(
            currentlyInjected: injected,
            documentWantsMermaid: MarkdownRenderedView.htmlNeedsMermaid(
                "<p>Just text now.</p>"
            )
        )
        XCTAssertEqual(action, .evict, "non-mermaid doc must drop the runtime")
        injected = false

        // 3. Back to a mermaid doc. Must re-install.
        action = MarkdownRenderedView.nextMermaidInjectionState(
            currentlyInjected: injected,
            documentWantsMermaid: MarkdownRenderedView.htmlNeedsMermaid(
                "<div class=\"mdv-mermaid\">sequenceDiagram</div>"
            )
        )
        XCTAssertEqual(action, .install, "return to mermaid doc must re-attach the runtime")
        injected = true

        // 4. Same mermaid doc re-renders (e.g. zoom change). Must be a no-op.
        action = MarkdownRenderedView.nextMermaidInjectionState(
            currentlyInjected: injected,
            documentWantsMermaid: true
        )
        XCTAssertEqual(action, .noChange, "re-rendering same mermaid doc must not double-attach")
    }

    func test_coordinator_mermaidInjected_startsFalse() {
        // First-load timing pin: the flag must default to false so
        // the very first mermaid document triggers `.install` and
        // gets the runtime before `loadHTMLString` (matters because
        // mermaid is rendered at-document-end by the shim, which has
        // to be attached pre-load to fire).
        let coordinator = MarkdownRenderedView.Coordinator()
        XCTAssertFalse(coordinator.mermaidInjected)
    }

    // MARK: WV-7 — sole-owner user-script count invariant
    //
    // The `.install` / `.evict` branches in `updateNSView` assert that
    // `userContentController.userScripts` holds exactly the mermaid
    // scripts after install and zero after evict — relying on this view
    // being the *sole owner* of that controller's user-scripts. The
    // expected post-install count is centralized in
    // `expectedMermaidScriptCount` so the assertion and any future caller
    // share one definition. The live WKWebView assertion path runs in
    // VM-only hosting tests; here we pin the count helper itself.

    func test_expectedMermaidScriptCount_matchesBundleAvailability() {
        // Each non-empty mermaid resource contributes one user-script.
        let expected =
            (MermaidBundle.runtime.isEmpty ? 0 : 1)
            + (MermaidBundle.shimJS.isEmpty ? 0 : 1)
        XCTAssertEqual(MarkdownRenderedView.expectedMermaidScriptCount, expected)
        // Must be in the 0...2 range regardless of bundle state.
        XCTAssertGreaterThanOrEqual(MarkdownRenderedView.expectedMermaidScriptCount, 0)
        XCTAssertLessThanOrEqual(MarkdownRenderedView.expectedMermaidScriptCount, 2)
    }
}
