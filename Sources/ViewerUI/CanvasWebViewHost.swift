import Foundation
import SwiftUI
import ViewerCore
import WebKit

// Canvas M0 spike (TSK-1353) — the WKWebView host for the canvas runtime,
// mirroring the CM6 hosting pattern: bundle-hosted canvas.html via
// loadFileURL, one script-message handler (`mdvCanvas`), one JS entry
// (`window.cvDispatch`). Deliberately minimal: the S3 webview-lane test drives
// this host directly; SwiftUI exposure is the thin `CanvasSurfaceView` below.

/// Hosts the canvas WebView and speaks the CV envelope both ways.
@MainActor
public final class CanvasWebViewHost: NSObject {
    public let webView: WKWebView

    /// Inbound-message callback (test/observation hook).
    public var onInbound: ((CVInboundMessage) -> Void)?

    /// Flip when the runtime posts `ready`.
    public private(set) var isReady = false

    private static let handlerName = "mdvCanvas"

    override public init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        controller.add(MessageProxy(host: self), name: Self.handlerName)
    }

    /// Load the bundled canvas.html (one-shot `loadFileURL`, the CM6 pattern).
    public func load() {
        guard let htmlURL = Bundle.module.url(forResource: "canvas", withExtension: "html") else {
            assertionFailure("canvas.html missing from ViewerUI resources")
            return
        }
        let baseDir = htmlURL.deletingLastPathComponent()
        webView.loadFileURL(htmlURL, allowingReadAccessTo: baseDir)
    }

    /// Send an outbound envelope to the JS runtime.
    public func send(_ message: CVOutboundMessage) {
        guard let json = try? CVBridgeCodec.encode(message) else {
            assertionFailure("CV encode failed for \(message)")
            return
        }
        // The envelope is a JSON string literal argument to cvDispatch — encode
        // the *string itself* as JSON to get correct escaping.
        guard let literalData = try? JSONSerialization.data(withJSONObject: [json]),
              var literal = String(data: literalData, encoding: .utf8)
        else { return }
        // [ "..." ] → "..."
        literal = String(literal.dropFirst().dropLast())
        webView.evaluateJavaScript("window.cvDispatch(\(literal))", completionHandler: nil)
    }

    fileprivate func receive(_ body: Any) {
        guard let message = try? CVBridgeCodec.decode(body) else { return }
        if case .ready = message { isReady = true }
        onInbound?(message)
    }

    /// Break the retain cycle host → controller → proxy → host when done.
    public func teardown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
    }
}

/// Weak-ref proxy so the WKUserContentController does not retain the host
/// (the standard WKScriptMessageHandler leak dodge).
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    private weak var host: CanvasWebViewHost?

    init(host: CanvasWebViewHost) {
        self.host = host
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            host?.receive(message.body)
        }
    }
}

/// Thin SwiftUI wrapper (M0: exists so later slices have the seam; the real
/// editor surface is M3).
public struct CanvasSurfaceView: NSViewRepresentable {
    private let host: CanvasWebViewHost

    public init(host: CanvasWebViewHost) {
        self.host = host
    }

    public func makeNSView(context: Context) -> WKWebView {
        host.load()
        return host.webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
}
