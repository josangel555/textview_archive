import SwiftUI
import ViewerCore

/// TSK-1119 — the walkthrough illustration overlay. Consumes the `diagram` verb's
/// `DiagramRequest` (model.diagram, bumped via diagramNonce) and renders the illustration by
/// medium: an ASCII/Unicode block as a monospace callout, an image from the resolved file URL,
/// and (TSK-1333) the Mermaid source RENDERED in a WKWebView. The Mermaid branch is the TSK-488
/// occlusion class (the WKWebView composites beside the SwiftUI caption), so the caption is given
/// its own composited layer ABOVE the surface (`compositingGroup().zIndex` in `body`). The render
/// itself is webview-validated (WalkthroughMermaidRenderWebViewTests) and the mount is
/// in-process-validated; the occlusion COMPOSITE is the one slice that needs T5-pixel verification
/// (TSK-1334) — NOT the in-process hosting test, which false-greens occlusion.
///
/// The view is dismissed automatically when `model.diagram` goes nil (step transition) because
/// WalkthroughOverlay observes `model` and drops this branch from its ZStack.
struct WalkthroughDiagramOverlay: View {
    let request: WalkthroughBridge.DiagramRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Occlusion-safe layering (TSK-488): the diagram surface (a WKWebView for .mermaid) sits
            // at zIndex 0; the caption gets its own composited layer above it so the WebView can't
            // occlude it. Harmless for the pure-SwiftUI branches (ascii/image).
            content
                .zIndex(0)
            if let caption = request.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .compositingGroup()
                    .zIndex(1)
                    .accessibilityIdentifier("mdv.walkthrough.diagram.caption")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 540)
        .accessibilityIdentifier("mdv.walkthrough.diagram")
    }

    @ViewBuilder private var content: some View {
        switch WalkthroughDiagramPresentation.of(request) {
        case .ascii(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("mdv.walkthrough.diagram.ascii")
        case .mermaid(let source):
            // Slice 2 (TSK-1333): the rendered Mermaid diagram in a WKWebView. OCCLUSION-CLASS
            // (TSK-488) — the WebView composites beside the SwiftUI caption sibling, so the caption
            // is layered above it (compositingGroup().zIndex in `body`). The render itself is
            // webview-validated (WalkthroughMermaidRenderWebViewTests); the mount is
            // in-process-validated; only the occlusion COMPOSITE needs T5-pixel verification (TSK-1334).
            WalkthroughMermaidWebView(source: source)
                .frame(maxWidth: 500, minHeight: 160, maxHeight: 380)
                .accessibilityIdentifier("mdv.walkthrough.diagram.mermaid")
        case .image(let url):
            imageView(url)
                .accessibilityIdentifier("mdv.walkthrough.diagram.image")
        case .empty:
            EmptyView()
        }
    }

    @ViewBuilder private func imageView(_ url: URL) -> some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 500, maxHeight: 380)
        } else {
            Text("(image unavailable)")
                .foregroundStyle(.secondary)
        }
    }
}

/// Pure input-mapping from a `DiagramRequest` to its presentation medium — host-tested
/// independently of the SwiftUI view (TSK-1119). Captures the edge cases: an empty payload
/// renders nothing; a `.image` with no resolved URL falls back to showing its path text.
enum WalkthroughDiagramPresentation: Equatable {
    case mermaid(source: String)
    case ascii(text: String)
    case image(url: URL)
    case empty

    static func of(_ request: WalkthroughBridge.DiagramRequest) -> WalkthroughDiagramPresentation {
        switch request.kind {
        case .mermaid:
            return request.data.isEmpty ? .empty : .mermaid(source: request.data)
        case .ascii:
            return request.data.isEmpty ? .empty : .ascii(text: request.data)
        case .image:
            if let url = request.imageURL { return .image(url: url) }
            // .image with no resolved URL: show the path text rather than nothing.
            return request.data.isEmpty ? .empty : .ascii(text: request.data)
        }
    }
}
