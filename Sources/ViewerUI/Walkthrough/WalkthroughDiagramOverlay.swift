import SwiftUI
import ViewerCore

/// TSK-1119 — the walkthrough illustration overlay. Consumes the `diagram` verb's
/// `DiagramRequest` (model.diagram, bumped via diagramNonce) and renders the illustration by
/// medium: an ASCII/Unicode block as a monospace callout, an image from the resolved file URL,
/// and (interim, slice 1) the Mermaid source as a labeled callout. The rendered Mermaid WebView
/// is slice 2 — it composites a WKWebView beside SwiftUI siblings (the TSK-488 occlusion class),
/// so it MUST be built occlusion-safe (`compositingGroup().zIndex`) and T5-pixel-verified, NOT
/// validated via the in-process hosting test (which false-greens occlusion). This slice is
/// occlusion-free (pure SwiftUI) and fully host/in-process-testable.
///
/// The view is dismissed automatically when `model.diagram` goes nil (step transition) because
/// WalkthroughOverlay observes `model` and drops this branch from its ZStack.
struct WalkthroughDiagramOverlay: View {
    let request: WalkthroughBridge.DiagramRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
            if let caption = request.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            // Interim (slice 1): the Mermaid source in a labeled callout. The rendered
            // WebView (occlusion-safe + T5-verified) is slice 2.
            VStack(alignment: .leading, spacing: 4) {
                Text("Diagram (Mermaid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
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
