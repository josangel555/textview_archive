import WebKit
import XCTest
import SwiftUI
import AppKit
import ViewerCore
@testable import ViewerUI

/// TSK-1333 — the WIRING teeth: WalkthroughDiagramOverlay must mount a WKWebView (the rendered
/// Mermaid surface) for a `.mermaid` request, and NOT for the pure-SwiftUI `.ascii` branch. The
/// render itself is webview-validated (WalkthroughMermaidRenderWebViewTests) and the
/// kind→presentation routing is host-tested (WalkthroughDiagramPresentationTests); this confirms
/// the overlay actually instantiates the WebView. NOTE: this does NOT (and can't) validate the
/// occlusion-composite — that's the T5-pixel slice (TSK-1334); the in-process tree false-greens it.
/// `#192`-gated; listed in test-in-vm.sh's webview lane.
@MainActor
final class WalkthroughDiagramOverlayMountTests: WebViewTestCase {

    private var hosted: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
    }

    private func host(_ request: WalkthroughBridge.DiagramRequest) -> NSView {
        let h = NSHostingView(rootView: WalkthroughDiagramOverlay(request: request))
        h.frame = NSRect(x: 0, y: 0, width: 560, height: 440)
        let window = NSWindow(contentRect: h.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = h
        hosted.append(h)
        h.layoutSubtreeIfNeeded()
        return h
    }

    private func containsWebView(_ v: NSView) -> Bool {
        if v is WKWebView { return true }
        return v.subviews.contains { containsWebView($0) }
    }

    func test_mermaidRequest_mountsAWebView_butAsciiDoesNot_TSK1333() async throws {
        let mermaid = host(WalkthroughBridge.DiagramRequest(kind: .mermaid, data: "graph TD; A-->B"))
        XCTAssertTrue(containsWebView(mermaid),
            "the overlay must mount a WKWebView for a .mermaid diagram (TSK-1333 wiring)")

        let ascii = host(WalkthroughBridge.DiagramRequest(kind: .ascii, data: "+--+\n|  |\n+--+"))
        XCTAssertFalse(containsWebView(ascii),
            "the .ascii branch is pure SwiftUI — it must NOT mount a WebView")
    }
}
