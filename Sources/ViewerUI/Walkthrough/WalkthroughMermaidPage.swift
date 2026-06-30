import Foundation
import ViewerCore

/// TSK-1333 (slice-2 foundation) — builds the standalone HTML page for a walkthrough Mermaid
/// illustration: the source wrapped in a ```mermaid fence, run through `HTMLRenderer.renderPage`
/// with the Mermaid shim CSS, producing a page whose `.mermaid` host the shim renders.
///
/// The Mermaid RUNTIME + shim JS are injected at the WebView layer as `WKUserScript`s (per
/// `MarkdownRenderedView`) — they bypass the page CSP (`default-src 'none'`), which is why the
/// page itself carries no `<script>`. This is pure string construction → host-testable; the
/// `WKWebView` host that loads this page is occlusion-class (TSK-488) and must be built
/// `compositingGroup().zIndex` + T5-pixel-verified (the rest of TSK-1333).
enum WalkthroughMermaidPage {
    /// The full HTML page for `source`, ready to load into a Mermaid-injecting WebView.
    static func html(forSource source: String) -> String {
        let fenced = "```mermaid\n\(source)\n```"
        return HTMLRenderer().renderPage(fenced, stylesheet: MermaidBundle.shimCSS)
    }
}
