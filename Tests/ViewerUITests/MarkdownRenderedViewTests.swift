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
}
