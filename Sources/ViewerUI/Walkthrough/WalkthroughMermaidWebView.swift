import SwiftUI
import WebKit

/// TSK-1333 — the Mermaid-rendering WebView for the walkthrough illustration overlay. Loads
/// `WalkthroughMermaidPage.html(forSource:)` into a `WKWebView` with the Mermaid runtime + shim
/// injected as `WKUserScript`s (the `MarkdownRenderedView` pattern: runtime at
/// `.atDocumentStart`, shim at `.atDocumentEnd`, main-frame-only; they bypass the page CSP
/// `default-src 'none'`).
///
/// STANDALONE component — deliberately NOT yet wired into `WalkthroughDiagramOverlay` (which
/// still shows the mermaid SOURCE as the interim). Wiring it in is OCCLUSION-CLASS (TSK-488): the
/// `WKWebView` composites beside the overlay's SwiftUI siblings, so the wiring must add
/// `compositingGroup().zIndex` and be T5-pixel-verified (the in-process test false-greens
/// occlusion). That wiring + the T5 PixelTestCase are the atomic completing unit of TSK-1333.
struct WalkthroughMermaidWebView: NSViewRepresentable {
    let source: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastSource: String?
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = config.userContentController
        // Sole-owner userContentController (WV-7): only the mermaid scripts.
        if !MermaidBundle.runtime.isEmpty {
            userContent.addUserScript(WKUserScript(
                source: MermaidBundle.runtime,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        }
        if !MermaidBundle.shimJS.isEmpty {
            userContent.addUserScript(WKUserScript(
                source: MermaidBundle.shimJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.lastSource = source
        webView.loadHTMLString(WalkthroughMermaidPage.html(forSource: source), baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Reload only when the source actually changes (avoid reloading on every re-render).
        guard context.coordinator.lastSource != source else { return }
        context.coordinator.lastSource = source
        webView.loadHTMLString(WalkthroughMermaidPage.html(forSource: source), baseURL: nil)
    }
}
