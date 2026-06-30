import WebKit
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1333 — the walkthrough mermaid RENDER, validated WITHOUT T5 screencapture. The page from
/// `WalkthroughMermaidPage.html(forSource:)`, loaded in a WKWebView with the mermaid runtime + shim
/// injected exactly as `WalkthroughMermaidWebView` does, must produce a rendered SVG (not raw source
/// text). This is the in-process webview-DOM proof that the diagram renders; the separate
/// occlusion-over-SwiftUI-sibling check is the only part that needs T5 pixels (TSK-1334).
/// Mirrors MermaidRenderProbeTests. `#192`-gated; listed in test-in-vm.sh's webview lane.
@MainActor
final class WalkthroughMermaidRenderWebViewTests: WebViewTestCase {

    private var webView: WKWebView!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    func test_walkthroughMermaidPage_rendersAnSVG_TSK1333() async throws {
        let page = WalkthroughMermaidPage.html(forSource: "graph TD; A[Start] --> B[Middle] --> C[End]")
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(
            source: MermaidBundle.runtime, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(
            source: MermaidBundle.shimJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.loadHTMLString(page, baseURL: nil)

        let deadline = Date().addingTimeInterval(15)
        var sawSVG = false
        while Date() < deadline, !sawSVG {
            if let ok = try? await webView.evaluateJavaScript(
                "Boolean(document.querySelector('.mdv-mermaid svg'))") as? Bool {
                sawSVG = ok
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertTrue(sawSVG,
            "the walkthrough mermaid page must render an SVG in the WebView DOM (TSK-1333 render path) "
            + "— raw source text would mean the runtime/shim failed to inject")
    }
}
