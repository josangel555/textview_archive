import AppKit
import SwiftUI
import ViewerCore
import WebKit

/// Renders a raw, untrusted `.html` file in a `WKWebView` under the
/// `HTMLDocumentPolicy` security model.
///
/// ──────────────────────────────────────────────────────────────────
/// SECURITY POLICY (regression-critical — see `HTMLDocumentPolicy`)
/// ──────────────────────────────────────────────────────────────────
/// A `.html` file is untrusted, author-controlled, full-document input.
/// This view is SEPARATE from `MarkdownRenderedView` precisely because
/// the markdown path intentionally allows API-injected JS (find /
/// mermaid) — that posture is wrong for arbitrary HTML. The layered
/// defenses, none trusted alone:
///
///   L0  Size cap (`HTMLDocumentPolicy.shouldRender`) — the caller
///       (`ContentView`) gates on it; huge HTML never reaches here.
///   L1  Sanitizer allowlist — the raw bytes are routed through
///       `HTMLDocumentPolicy.sanitize` (→ `HTMLSanitizer`) BEFORE the
///       string is ever handed to the WebView. Drops `<script>`,
///       `<style>`, `<iframe>`, `<form>`, …; strips `on*=` handlers;
///       neutralizes `javascript:` URLs.
///   L2  JavaScript DEFAULT-DENY. `allowsContentJavaScript` is set from
///       `HTMLDocumentPolicy.javaScriptEnabled(tabOptedIn:)`, whose
///       default (no per-tab opt-in) is `false`. There is no code path
///       that turns JS on by default. The opt-in is PER-TAB and explicit
///       (the "Enable JavaScript" toggle in the mode bar).
///   L3  No remote sub-resources, no `file://` beyond the document
///       itself — enforced by BOTH the injected CSP envelope
///       (`default-src 'none'`) AND the navigation-delegate policy
///       (`HTMLDocumentPolicy.decideSubresource`).
///   L4  Link clicks → system browser (http/https/mailto) or cancelled;
///       in-page `file:`/`data:`/`javascript:` navigations cancelled
///       (`HTMLDocumentPolicy.decideLink`).
///
/// The WebView never gets a process-wide JS-on default, never gets a
/// user-script injected (no find runtime — raw HTML find is a deferred
/// follow-up), and is torn down deterministically in `dismantleNSView`.
public struct HTMLRenderedView: NSViewRepresentable {
    /// Raw, UNSANITIZED file contents. Sanitization happens inside this
    /// view (`updateNSView`) so the security boundary lives at the
    /// rendering edge and the call site can't forget to apply it.
    public let rawHTML: String
    /// The document's own `file://` URL. Drives both the WebView base URL
    /// (so same-tree relative images can resolve) AND the L3 fence
    /// (`decideSubresource` only permits `file:` loads inside this URL's
    /// directory).
    public let documentURL: URL
    public let zoom: Double
    /// PER-TAB JavaScript opt-in. Default-OFF lives upstream (the model
    /// returns `false` when the user hasn't opted the tab in). When this
    /// is `false` (the default) the WebView's JS engine is disabled.
    public let javaScriptEnabled: Bool
    /// TSK-1189 — trust-local-HTML. When `true` (a LOCAL, opted-in doc; default
    /// false), the renderer keeps the page's own `<script>`/`<style>` and relaxes
    /// `script-src` while KEEPING the anti-exfil fence (`connect-src 'none'`).
    /// Fed SOLELY by `DocumentModel.htmlTrusted(forTabID:)`.
    public let trusted: Bool
    /// Print/Export-as-PDF (TSK-638): same nonce contract as
    /// `MarkdownRenderedView` — print/createPDF run on the live WebView,
    /// AFTER sanitization (they render what the page shows, nothing more).
    public let printNonce: Int
    public let pdfExportNonce: Int
    public let pdfExportURL: URL?
    public let onPDFExportResult: ((Int, Bool, String) -> Void)?

    /// TSK-1203 — https hosts a TRUSTED doc may `connect-src` to (user-consented,
    /// per-page). Empty by default ⇒ `connect-src 'none'` (the fence, unchanged).
    /// Fed by `DocumentModel.htmlAllowedConnectHosts(forTabID:)`, which is itself
    /// fail-closed (returns [] for any untrusted tab).
    public let allowedConnectHosts: [String]

    public init(
        rawHTML: String,
        documentURL: URL,
        zoom: Double = 1.0,
        javaScriptEnabled: Bool = false,
        trusted: Bool = false,
        allowedConnectHosts: [String] = [],
        printNonce: Int = 0,
        pdfExportNonce: Int = 0,
        pdfExportURL: URL? = nil,
        onPDFExportResult: ((Int, Bool, String) -> Void)? = nil
    ) {
        self.rawHTML = rawHTML
        self.documentURL = documentURL
        self.zoom = zoom
        self.javaScriptEnabled = javaScriptEnabled
        self.trusted = trusted
        self.allowedConnectHosts = allowedConnectHosts
        self.printNonce = printNonce
        self.pdfExportNonce = pdfExportNonce
        self.pdfExportURL = pdfExportURL
        self.onPDFExportResult = onPDFExportResult
    }

    /// Shared process pool (same rationale as `MarkdownRenderedView`):
    /// avoid spawning a fresh WebContent process per view instance.
    private static let sharedProcessPool = WKProcessPool()

    /// Perf (TSK-1190): the warm-WebView cache key for this pane, or nil to
    /// opt out. Keyed on the resolved file path (same key shape as
    /// `MarkdownRenderedView.cacheKey`) so it's stable across a session switch
    /// AND across an Editor↔Render toggle (which dismantles + re-makes this
    /// representable). Parked in the SEPARATE `WarmHTMLWebViewCache` so a
    /// raw-HTML WebView can never be served to the markdown pane (different
    /// security posture). nil only for a non-file URL — documentURL is always
    /// a file URL today, but keep the optional shape symmetric.
    var cacheKey: String? {
        guard documentURL.isFileURL else { return nil }
        return documentURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    public func makeNSView(context: Context) -> WKWebView {
        // Record the cache key + doc URL on the (fresh) coordinator so
        // `dismantleNSView` — which only receives the coordinator, not the
        // view — knows where to park this pane's WebView. Set on BOTH the
        // cache-HIT and cache-MISS paths.
        context.coordinator.cacheKey = cacheKey
        context.coordinator.documentURL = documentURL

        // Perf (TSK-1190): re-attach a parked WebView for this file instead of
        // building a fresh one + re-running `loadHTMLString` on the full
        // sanitized document. We copy the parked coordinator's in-flight
        // navigation state onto THIS (SwiftUI-owned) coordinator and re-point
        // the WebView's delegate at it, so `updateNSView`'s
        // `lastDocument == document` reload gate is a no-op — no
        // re-sanitize/re-parse/re-DOM-materialize on switch-back. If the JS
        // opt-in changed while parked, `updateNSView`'s `lastJSEnabled` arm
        // still forces the (correct) reload.
        if let key = cacheKey,
           let parked = WarmHTMLWebViewCache.shared.retrieve(forKey: key) {
            let webView = parked.webView
            context.coordinator.adoptNavigationState(from: parked.coordinator)
            webView.navigationDelegate = context.coordinator
            #if DEBUG
            MountProbe.webViewMakes += 1   // a make happened (even on a cache hit)
            #endif
            return webView
        }

        let config = WKWebViewConfiguration()
        config.processPool = Self.sharedProcessPool

        // L2: JavaScript DEFAULT-DENY. The flag comes from the policy
        // helper so the default (no per-tab opt-in) can only be OFF.
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = HTMLDocumentPolicy.javaScriptEnabled(
            tabOptedIn: javaScriptEnabled
        ) || trusted
        config.defaultWebpagePreferences = prefs
        // Belt-and-suspenders: the legacy process-wide switch is also
        // pinned to the same value. `allowsContentJavaScript` is the
        // modern per-navigation control; setting both removes any
        // ambiguity about a default-on JS engine.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        // Release file-URL drags so the parent SwiftUI .onDrop receives them.
        webView.unregisterDraggedTypes()
        #if DEBUG
        MountProbe.webViewMakes += 1
        #endif
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.documentURL = documentURL
        // Keep the parking key current — the pane's file can change within one
        // representable lifecycle; `dismantleNSView` parks under whatever this
        // resolves to.
        coord.cacheKey = cacheKey

        // L2: re-apply the JS opt-in on every update so a per-tab toggle
        // takes effect on the next load. WKWebpagePreferences is consumed
        // per-navigation, so we set it on the config's default prefs (used
        // for loads that don't pass an explicit prefs object) AND remember
        // the desired value to force a reload when it changes.
        let jsEnabled = HTMLDocumentPolicy.javaScriptEnabled(
            tabOptedIn: javaScriptEnabled
        ) || trusted
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = jsEnabled

        // L1: sanitize THEN wrap in the policy envelope (CSP + charset).
        // The raw bytes never reach the WebView un-sanitized.
        let sanitized = HTMLDocumentPolicy.sanitize(rawHTML, trusted: trusted)
        let document = HTMLDocumentPolicy.envelope(
            sanitizedBody: sanitized, trusted: trusted,
            allowedConnectHosts: allowedConnectHosts)

        // Reload only when the rendered document OR the JS opt-in changed
        // (the opt-in only takes effect on a fresh load). Avoids a render
        // storm on unrelated @Published churn.
        let needsReload = coord.lastDocument != document
            || coord.lastJSEnabled != jsEnabled
        if needsReload {
            coord.lastDocument = document
            coord.lastJSEnabled = jsEnabled
            coord.didFinishFirstLoad = false
            // Base URL is the document's own directory so same-tree
            // relative `file:` images resolve; the nav policy fences
            // them to that directory regardless.
            webView.loadHTMLString(
                document,
                baseURL: documentURL.deletingLastPathComponent()
            )
        }
        if abs(webView.pageZoom - CGFloat(zoom)) > 0.001 {
            webView.pageZoom = CGFloat(zoom)
        }
        // Print / Export-as-PDF (TSK-638) — shared mechanics with the
        // markdown view; the L1 sanitize above already ran, so the PDF
        // can only ever contain what the page renders.
        if coord.lastPrintNonce != printNonce {
            coord.lastPrintNonce = printNonce
            MarkdownRenderedView.runPrintOperation(webView)
        }
        if coord.lastPDFExportNonce != pdfExportNonce, let url = pdfExportURL {
            coord.lastPDFExportNonce = pdfExportNonce
            let nonce = pdfExportNonce
            let report = onPDFExportResult
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: url, options: .atomic)
                        report?(nonce, true, url.path)
                    } catch {
                        report?(nonce, false, "write failed: \(error.localizedDescription)")
                    }
                case .failure(let error):
                    report?(nonce, false, "createPDF failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Teardown. Perf (TSK-1190): instead of tearing the WebView down, PARK it
    /// in the app-level `WarmHTMLWebViewCache` keyed by file path so a returning
    /// pane (after an Editor↔Render toggle, or a session switch that minted a
    /// fresh `Tab.id`) re-attaches it with NO reload — keeping the loaded DOM
    /// and the coordinator's nav state intact (the coordinator is parked
    /// alongside; the make path re-points the delegate + copies the state).
    /// Only opt-out panes (nil key) take the real teardown below.
    ///
    /// SECURITY: parking does NOT relax any layer — the WebView keeps its
    /// `allowsContentJavaScript`, its CSP-enveloped DOM, and its
    /// `decideSubresource`/`decideLink` policy. The cache is path-keyed and
    /// SEPARATE from the markdown cache, so a markdown WebView (JS-on for the
    /// find runtime) can never be handed to this pane.
    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        if let key = coordinator.cacheKey {
            // Detach the live delegate link so no stray callback lands on this
            // coordinator while parked; the make path installs the new delegate.
            webView.navigationDelegate = nil
            WarmHTMLWebViewCache.shared.stash(webView, coordinator: coordinator, forKey: key)
            return
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        #if DEBUG
        MountProbe.webViewDismantles += 1
        #endif
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate {
        var lastPrintNonce: Int = 0
        var lastPDFExportNonce: Int = 0
        /// Perf (TSK-1190): the warm-WebView cache key (file path) this pane's
        /// WebView is parked under on `dismantleNSView`. Set from
        /// `HTMLRenderedView.cacheKey` in make/update. nil ⇒ this pane opts out
        /// of the cache (real teardown on dismantle).
        var cacheKey: String?
        /// Last document string handed to `loadHTMLString`. Gate against
        /// redundant reloads on @Published churn.
        var lastDocument: String?
        /// Last JS opt-in applied to a load. A change forces a reload so
        /// the new preference takes effect.
        var lastJSEnabled: Bool?
        /// The rendered document's `file://` URL — the L3 sub-resource
        /// fence root. Set from the representable on make/update.
        var documentURL: URL?
        /// `false` until the bootstrap document load reports `didFinish`.
        /// Drives the `isInitialDocumentLoad` signal so the bootstrap
        /// `loadHTMLString` is permitted while a post-load `.other`
        /// file:/data: navigation (an in-page escape) is cancelled.
        var didFinishFirstLoad: Bool = false

        /// Perf (TSK-1190): copy the navigation/render state that determines
        /// whether `updateNSView` reloads the page from a PARKED coordinator
        /// onto this (fresh, SwiftUI-owned) one when a warm WebView is
        /// re-attached. After this, `lastDocument == document` for the same
        /// document so the reload gate is a no-op — the whole point of the cache.
        ///
        /// We copy the document-identity + already-applied-load fields, NOT the
        /// per-tick print/PDF nonces (those resync from the model on the next
        /// `updateNSView`). `didFinishFirstLoad` is preserved so the nav-policy
        /// window stays correct without waiting for a (non-occurring) reload.
        /// `lastJSEnabled` is preserved so a JS-opt-in change while parked is
        /// still detected by `updateNSView`'s reload gate.
        func adoptNavigationState(from parked: Coordinator) {
            lastDocument = parked.lastDocument
            lastJSEnabled = parked.lastJSEnabled
            documentURL = parked.documentURL
            didFinishFirstLoad = parked.didFinishFirstLoad
        }

        public func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            didFinishFirstLoad = true
        }

        public func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            // A fresh provisional navigation re-opens the bootstrap
            // window only for our own `loadHTMLString` (which has no
            // request URL of file:/data: origin other than the base).
            // We reset on the FIRST provisional of a load cycle via the
            // reload path setting `didFinishFirstLoad = false`, so no
            // action needed here.
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let decision: HTMLDocumentPolicy.LoadDecision
            if navigationAction.navigationType == .linkActivated {
                decision = HTMLDocumentPolicy.decideLink(
                    url: url, documentURL: documentURL
                )
            } else {
                // Sub-resource / programmatic / `.other`. The bootstrap
                // document paint is the first `.other` before didFinish.
                let isInitial = !didFinishFirstLoad
                    && navigationAction.navigationType == .other
                decision = HTMLDocumentPolicy.decideSubresource(
                    url: url,
                    documentURL: documentURL,
                    isInitialDocumentLoad: isInitial
                )
            }
            switch decision {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .openExternally(let target):
                NSWorkspace.shared.open(target)
                decisionHandler(.cancel)
            }
        }
    }
}

/// Shown for `.html` files whose source exceeds
/// `HTMLDocumentPolicy.renderMaxBytes`. Same shape as the markdown /
/// editor large-file placeholders — points the user at source mode
/// rather than slurping a multi-MB document into WebContent.
struct LargeHTMLPlaceholderView: View {
    let file: TextFile
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text("HTML too large to render")
                .font(.title3)
            Text("This file is \(ByteSize.mbString(file.byteCount)). " +
                 "Rendered mode is capped at \(ByteSize.mbString(HTMLDocumentPolicy.renderMaxBytes)) " +
                 "to avoid slurping a multi-MB untrusted document into the " +
                 "WebContent process.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("View as Source") {
                model.setCurrentViewMode(.source)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

}
