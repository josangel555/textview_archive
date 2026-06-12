import WebKit
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-650 — the live half: a real mermaid document, the runtime + shim
/// injected exactly as `MarkdownRenderedView` does, must produce an SVG in
/// the host div (the failure mode was raw source text shown forever:
/// `MermaidBundle.runtime` resolved empty and the shim aborted). The
/// owner-repro document (docs/ARCHITECTURE_LAYERS.md) is the fixture via a
/// representative inline copy — subgraphs + <br/> labels, the features it
/// uses. `#192`-gated; listed in `test-in-vm.sh` AND `nightly-vm.yml`.
@MainActor
final class MermaidRenderProbeTests: XCTestCase {

    private var webView: WKWebView!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    func test_flowchartWithSubgraphsAndBrLabels_rendersAnSVG() async throws {
        let md = """
        # Title

        ```mermaid
        flowchart TB

        subgraph UI["SwiftUI app - ViewerUI (stays Swift)"]
            CV["ContentView / DocumentModel<br/>TabCoordinator, StatusBar"]
            LENSES["View lenses:<br/>Rendered, Source, Editor"]
        end

        subgraph CORE["rust core"]
            R1["engines"]
        end

        UI --> CORE
        ```
        """
        let page = HTMLRenderer().renderPage(
            md, stylesheet: MarkdownStylesheet.load(),
            extraStylesheet: MermaidBundle.shimCSS)
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(
            source: MermaidBundle.runtime, injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(
            source: MermaidBundle.shimJS, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            configuration: config)
        webView.loadHTMLString(page, baseURL: nil)

        let deadline = Date().addingTimeInterval(15)
        var sawSVG = false
        while Date() < deadline, !sawSVG {
            if let ok = try? await webView.evaluateJavaScript("""
            Boolean(document.querySelector('.mdv-mermaid svg'))
            """) as? Bool {
                sawSVG = ok
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertTrue(sawSVG,
            "the mermaid host must contain a rendered SVG — raw source text "
            + "means the runtime failed to inject (TSK-650)")
    }
}
