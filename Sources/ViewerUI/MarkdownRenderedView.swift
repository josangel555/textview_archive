import AppKit
import SwiftUI
import WebKit

/// Loads a self-contained HTML string into a `WKWebView`. JavaScript is disabled
/// by default — we don't need it (TreeSitter pre-renders highlight spans into
/// the HTML at parse time per DESIGN.md §11).
public struct MarkdownRenderedView: NSViewRepresentable {
    public let html: String
    public let baseURL: URL?
    public let zoom: Double
    public let findQuery: String
    public let findCaseSensitive: Bool
    public let findNextNonce: Int
    public let findPrevNonce: Int
    /// Callback that fires after each find() call with the result.
    /// Nil means "not currently searching" (empty query / find bar
    /// dismissed). True/false reports the last find's matchFound.
    public let onFindResult: ((Bool?) -> Void)?

    public init(
        html: String,
        baseURL: URL? = nil,
        zoom: Double = 1.0,
        findQuery: String = "",
        findCaseSensitive: Bool = false,
        findNextNonce: Int = 0,
        findPrevNonce: Int = 0,
        onFindResult: ((Bool?) -> Void)? = nil
    ) {
        self.html = html
        self.baseURL = baseURL
        self.zoom = zoom
        self.findQuery = findQuery
        self.findCaseSensitive = findCaseSensitive
        self.findNextNonce = findNextNonce
        self.findPrevNonce = findPrevNonce
        self.onFindResult = onFindResult
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        // WKWebView eats file-URL drags by default; releasing those so the
        // SwiftUI .onDrop on the parent receives them instead.
        webView.unregisterDraggedTypes()
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload when the HTML actually changed. body() re-runs on every
        // @Published mutation, and reloading the page on each tick causes
        // a render storm + a brief blank-content flash that was being
        // perceived as "tabs vanishing".
        if context.coordinator.lastHTML != html {
            webView.loadHTMLString(html, baseURL: baseURL)
            context.coordinator.lastHTML = html
        }
        if abs(webView.pageZoom - CGFloat(zoom)) > 0.001 {
            webView.pageZoom = CGFloat(zoom)
        }
        // Find-bar wiring.
        let c = context.coordinator
        c.onFindResult = onFindResult
        if c.lastQuery != findQuery || c.lastCaseSensitive != findCaseSensitive {
            c.lastQuery = findQuery
            c.lastCaseSensitive = findCaseSensitive
            if findQuery.isEmpty {
                onFindResult?(nil)
            } else {
                c.runFind(in: webView, backwards: false)
            }
        }
        if c.lastNextNonce != findNextNonce {
            c.lastNextNonce = findNextNonce
            c.runFind(in: webView, backwards: false)
        }
        if c.lastPrevNonce != findPrevNonce {
            c.lastPrevNonce = findPrevNonce
            c.runFind(in: webView, backwards: true)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Outcome of a single navigation policy decision. Exposed as a pure value
    /// so the (otherwise hard-to-test) Coordinator delegate method has a
    /// testable kernel — see `Coordinator.decide(url:navigationType:currentDocumentURL:)`.
    public enum LinkDecision: Equatable, Sendable {
        case allow
        case cancel
        case openExternally(URL)
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate {
        /// Last HTML payload sent to `loadHTMLString`. Updated only when the
        /// view actually changed, so repeated `updateNSView` calls with the
        /// same content don't re-load the page (CRIT-4 fix for the
        /// "vanishing tabs" reload storm).
        var lastHTML: String?
        /// True once the current document has reported didFinish. Used
        /// to gate find() — calling it before the DOM is ready silently
        /// fails with matchFound=false, so we defer until ready.
        var documentReady: Bool = false
        /// Holds the webView weakly so `webView(_:didFinish:)` can
        /// re-run any find that was queued before the page was ready.
        weak var pendingFindWebView: WKWebView?

        // Find-bar state observed by updateNSView.
        var lastQuery: String = ""
        var lastCaseSensitive: Bool = false
        var lastNextNonce: Int = 0
        var lastPrevNonce: Int = 0
        /// Reported back via SwiftUI: true/false = last find's matchFound.
        var onFindResult: ((Bool?) -> Void)? = nil

        /// Run `WKWebView.find` with the current query/options. The
        /// `wraps=true` flag means WKWebView's find continues from the
        /// last match position when the query is unchanged.
        ///
        /// If the document hasn't finished loading yet, the find is
        /// queued — `webView(_:didFinish:)` re-runs it. This fixes the
        /// race where typing into the find bar before the DOM is ready
        /// silently fails.
        func runFind(in webView: WKWebView, backwards: Bool) {
            pendingFindWebView = webView
            let q = lastQuery
            guard !q.isEmpty else { return }
            guard documentReady else {
                // didFinish will retry.
                return
            }
            let config = WKFindConfiguration()
            config.backwards = backwards
            config.caseSensitive = lastCaseSensitive
            config.wraps = true
            webView.find(q, configuration: config) { [weak self] result in
                self?.onFindResult?(result.matchFound)
            }
        }

        public func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            documentReady = true
            // Re-run any pending find that was queued before load.
            if !lastQuery.isEmpty {
                runFind(in: webView, backwards: false)
            }
        }

        // Reset documentReady when a new navigation starts (e.g. when
        // loadHTMLString is called for a new file).
        public func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            documentReady = false
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let decision = Coordinator.decide(
                url: navigationAction.request.url,
                navigationType: navigationAction.navigationType,
                currentDocumentURL: webView.url
            )
            switch decision {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .openExternally(let url):
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        /// Decide what to do with a navigation. Pure function so it can be
        /// unit-tested. Allowlist semantics (CRIT-1 / S4):
        /// - Anything other than a `linkActivated` click (initial load,
        ///   programmatic reload, etc.) is allowed.
        /// - Same-document fragment navigation (`#anchor`) is allowed.
        /// - Otherwise: only `http`/`https`/`mailto` are honored — they route
        ///   to the user's browser. `javascript:`, `data:`, `file:`, custom
        ///   app schemes, etc. are cancelled.
        public static func decide(
            url: URL?,
            navigationType: WKNavigationType,
            currentDocumentURL: URL?
        ) -> LinkDecision {
            guard navigationType == .linkActivated else { return .allow }
            guard let url else { return .cancel }
            if isSameDocumentFragment(url, currentDocumentURL: currentDocumentURL) {
                return .allow
            }
            switch url.scheme?.lowercased() ?? "" {
            case "http", "https", "mailto":
                return .openExternally(url)
            default:
                return .cancel
            }
        }

        private static func isSameDocumentFragment(_ url: URL, currentDocumentURL: URL?) -> Bool {
            guard let fragment = url.fragment, !fragment.isEmpty else { return false }
            guard let cur = currentDocumentURL else {
                // No current page yet — treat as a stand-alone fragment OK
                // (rare; happens before first load completes).
                return url.scheme == nil
            }
            return strippedFragment(url) == strippedFragment(cur)
        }

        private static func strippedFragment(_ url: URL) -> URL? {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.fragment = nil
            return c?.url
        }
    }
}

/// Loads the bundled `markdown.css` from the ViewerUI module bundle.
/// Cached in a `static let` (P3) so the disk read happens exactly once
/// per process — `ContentView.init` is called on every parent recomposition.
public enum MarkdownStylesheet {
    public static let cached: String = loadFromBundle()

    /// Force a reload from disk. Used by tests; production callers use `cached`.
    public static func load() -> String { cached }

    private static func loadFromBundle() -> String {
        guard let url = Bundle.module.url(forResource: "markdown", withExtension: "css"),
              let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }
}
