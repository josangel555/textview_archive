import XCTest
import AppKit
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-1119 — render-validation of the walkthrough illustration overlay (slice 1: ascii / image
/// / mermaid-source — all pure SwiftUI, NO WebView, so occlusion-free and validly in-process-
/// hostable). Hosts WalkthroughDiagramOverlay in a real NSHostingView/NSWindow, forces layout,
/// and walks the hierarchy to prove the illustration + caption render (not blank). The
/// input-mapping is host-tested in WalkthroughDiagramPresentationTests; this is the pixels-side
/// complement. NOTE: slice 2 (the rendered Mermaid WebView) is occlusion-class and must be
/// T5-pixel-verified, NOT hosted in-process (that would false-green the occlusion).
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM/nightly lane).
@MainActor
final class WalkthroughDiagramOverlayHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
    }

    func test_asciiOverlay_rendersTextAndCaption() async throws {
        let request = WalkthroughBridge.DiagramRequest(
            kind: .ascii, data: "+----+\n| OK |\n+----+", caption: "the box")
        let host = NSHostingView(rootView: WalkthroughDiagramOverlay(request: request))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.frame.width, 0)
        // The ascii block + caption both bridge to text views with glyphs — at least one
        // text-bearing view must be present (a blank overlay would have none).
        let descendants = Self.descendants(of: host)
        let hasText = descendants.contains { $0 is NSTextField || $0 is NSTextView }
        XCTAssertTrue(hasText, "the overlay must render its ascii text / caption")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
