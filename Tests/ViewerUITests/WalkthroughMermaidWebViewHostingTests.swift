import XCTest
import AppKit
import SwiftUI
import WebKit
@testable import ViewerUI

/// TSK-1333 — mount-validation of the standalone Mermaid WebView component. Hosts
/// `WalkthroughMermaidWebView` in a real `NSHostingView`/`NSWindow` and confirms it MOUNTS a
/// `WKWebView` (the runtime/shim injection + page load wire up). This is a MOUNT test, NOT an
/// occlusion test — occlusion (the WebView vs sibling SwiftUI) is T5-pixel-only (TSK-488) and is
/// verified when the component is wired into the overlay (the completing unit). Mount ≠ occlusion,
/// so this in-process check is valid (not a false-green).
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM/nightly lane — it embeds a live WKWebView).
@MainActor
final class WalkthroughMermaidWebViewHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
    }

    func test_component_mountsAWKWebView() async throws {
        let host = NSHostingView(rootView:
            WalkthroughMermaidWebView(source: "graph TD; A-->B"))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.frame.width, 0)
        let webViewClass: AnyClass = NSClassFromString("WKWebView")!
        let descendants = Self.descendants(of: host)
        XCTAssertTrue(descendants.contains { $0.isKind(of: webViewClass) },
            "the Mermaid component must mount a WKWebView")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
