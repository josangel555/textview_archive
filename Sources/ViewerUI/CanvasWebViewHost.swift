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
public final class CanvasWebViewHost: NSObject, WKNavigationDelegate {
    public let webView: WKWebView

    /// Set when WebKit reports the WebContent process died — the M0.S3 VM
    /// finding: an invisible webview's content process gets suspended/reaped
    /// under the GUI-lane session and every subsequent eval errors.
    public private(set) var contentProcessDied = false

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        contentProcessDied = true
        NSLog("CanvasWebViewHost: WebContent process TERMINATED")
    }

    /// Inbound-message callback (test/observation hook).
    public var onInbound: ((CVInboundMessage) -> Void)?

    /// Flip when the runtime posts `ready`.
    public private(set) var isReady = false

    /// Last evaluateJavaScript error, if any (diagnosis hook — a dead
    /// Swift→JS hop is otherwise silent).
    public private(set) var lastSendError: String?

    private static let handlerName = "mdvCanvas"

    override public init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        webView.navigationDelegate = self
        controller.add(MessageProxy(host: self), name: Self.handlerName)
    }

    /// Load the bundled canvas.html (one-shot `loadFileURL`, the CM6 pattern).
    public func load() {
        // T5 negative control (M3.S7 / TSK-1134 pattern): a DELIBERATE,
        // committed break behind MDV_ENABLE_BROKEN_CANVAS_OVERLAY — the
        // pixel test spawns the app with this env and must go RED, proving
        // the overlay-visibility guard has teeth.
        if MDVNegativeControl.isBroken("CANVAS_OVERLAY") {
            let script = WKUserScript(
                source: "window.__cvBrokenOverlay = true;",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true)
            webView.configuration.userContentController.addUserScript(script)
        }
        guard let htmlURL = Bundle.module.url(forResource: "canvas", withExtension: "html") else {
            assertionFailure("canvas.html missing from ViewerUI resources")
            return
        }
        let baseDir = htmlURL.deletingLastPathComponent()
        webView.loadFileURL(htmlURL, allowingReadAccessTo: baseDir)
        startReadyRecovery()
    }

    /// Send an outbound envelope to the JS runtime.
    ///
    /// The envelope goes in as a JS OBJECT LITERAL (`cvDispatch({...})`) —
    /// the exact shape production CM6 uses (`CodeMirrorEditorView.dispatch`,
    /// `window.cmDispatch(\(json));`), which is proven against the VM's older
    /// WebKit. A trailing `0` keeps the eval result serializable (WKError-5,
    /// the TSK-1047 class, observed live on the M0.S3 VM runs).
    public func send(_ message: CVOutboundMessage) {
        guard let json = try? CVBridgeCodec.encode(message) else {
            assertionFailure("CV encode failed for \(message)")
            return
        }
        webView.evaluateJavaScript("window.cvDispatch(\(json)); 0") { [weak self] _, error in
            if let error {
                MainActor.assumeIsolated {
                    self?.lastSendError = "\(error)"
                }
                NSLog("CanvasWebViewHost eval error: \(error)")
            }
        }
    }

    /// Diagnostic probe (M0): evaluate a JS expression, returning its
    /// stringified result or the error — decisively answers "did JS run".
    public func probe(_ js: String, completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript(js) { value, error in
            if let error {
                completion("ERR: \(error)")
            } else {
                completion("OK: \(String(describing: value))")
            }
        }
    }

    /// postIds already delivered (push or drain) — SET dedup, not a
    /// high-water mark: a drain may deliver id N before the push path
    /// delivers N-1, and a mark would then wrongly drop N-1. Bounded by the
    /// JS outbox (256); the M1 bridge revisits with a windowed set.
    private var deliveredPostIds = Set<UInt64>()
    /// Highest postId seen — the drain FLOOR (drains ask only for entries
    /// above `max - slack`, so a busy page never re-posts its whole outbox:
    /// the flood itself was killing the channel on the slow VM — TSK-1365).
    private var maxDeliveredPostId: UInt64 = 0
    private static let drainSlack: UInt64 = 32

    /// Chain counters (M0 diagnosis): where do replies die?
    public private(set) var pushDelivered = 0
    public private(set) var drainAttempts = 0
    public private(set) var drainResults = 0
    public private(set) var drainDelivered = 0
    public var chainCounters: String {
        "push=\(pushDelivered) drains=\(drainAttempts)/\(drainResults) drained=\(drainDelivered)"
    }

    fileprivate func receive(_ body: Any) {
        pushDelivered += 1
        deliver(json: body as? String)
    }

    private func deliver(json: String?) {
        guard let json else { return }
        // postId rides the envelope outside the typed messages; parse it for
        // dedup, then decode normally.
        if let data = json.data(using: .utf8),
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let postId = (dict["postId"] as? Int).flatMap(UInt64.init(exactly:))
        {
            if deliveredPostIds.contains(postId) { return }
            deliveredPostIds.insert(postId)
            maxDeliveredPostId = max(maxDeliveredPostId, postId)
        }
        guard let message = try? CVBridgeCodec.decode(json) else { return }
        if case .ready = message { isReady = true }
        onInbound?(message)
    }

    /// Pull-drain replies the push path dropped (the VM/older-WebKit
    /// script-message flake — M0.S3 finding: eval runs, DOM mutates, but
    /// ~30% of mid-session postMessage replies vanish). Safe to call
    /// repeatedly; the postId set makes it idempotent against push.
    public func drainMissedReplies() {
        drainAttempts += 1
        // Fire-and-forget: the drain RE-POSTS pending entries through the
        // script-message channel (see canvas.js) — nothing rides the eval
        // result, because eval results are themselves droppable on the VM's
        // older WebKit (the M3.S1b finding). Deliveries arrive via
        // receive(); the postId set dedups push/drain races.
        let floor = maxDeliveredPostId > Self.drainSlack
            ? maxDeliveredPostId - Self.drainSlack : 0
        webView.evaluateJavaScript(
            "window.__cvDrain ? window.__cvDrain(\(floor)) : 0"
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.drainResults += 1 }
        }
    }

    /// READY RECOVERY (TSK-1365 fix 2): the runtime's `ready` post itself
    /// can vanish on the VM's WebKit, and the CONTROLLER only listens — so
    /// the host self-drains on a timer until ready arrives (or 20s). This is
    /// a production path (the app's mount), not test plumbing.
    private var readyDrainTask: Task<Void, Never>?

    private func startReadyRecovery() {
        readyDrainTask?.cancel()
        readyDrainTask = Task { [weak self] in
            for _ in 0..<80 { // 80 × 250ms = 20s
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                if self.isReady { return }
                self.drainMissedReplies()
            }
        }
    }

    /// Break the retain cycle host → controller → proxy → host when done.
    public func teardown() {
        readyDrainTask?.cancel()
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
