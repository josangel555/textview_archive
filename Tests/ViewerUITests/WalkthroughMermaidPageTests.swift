import XCTest
@testable import ViewerUI

/// TSK-1333 (slice-2 foundation) — the walkthrough Mermaid HTML-page builder. Pure host teeth:
/// the page wraps the source in a renderable Mermaid host + a complete HTML document.
final class WalkthroughMermaidPageTests: XCTestCase {

    func test_html_embedsSourceInACompletePage() {
        let page = WalkthroughMermaidPage.html(forSource: "graph TD; A-->B")
        XCTAssertTrue(page.contains("<!DOCTYPE html>"), "must be a complete HTML page")
        XCTAssertTrue(page.contains("graph TD"), "must embed the Mermaid source for the shim")
        XCTAssertTrue(page.contains("mermaid"), "must carry a .mermaid host / shim styling")
    }

    func test_html_isSelfContained_noExternalScriptOrNetwork() {
        // The runtime is injected as a WKUserScript at the WebView layer, not in the page —
        // and the page CSP must stay locked down (default-src 'none').
        let page = WalkthroughMermaidPage.html(forSource: "graph LR; X-->Y")
        XCTAssertTrue(page.contains("Content-Security-Policy"))
        XCTAssertTrue(page.contains("default-src 'none'"))
    }
}
