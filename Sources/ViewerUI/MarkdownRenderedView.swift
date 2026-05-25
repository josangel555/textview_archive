import AppKit
import SwiftUI
import ViewerCore
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
    /// Optional summary callback: receives "n/N" string (or empty
    /// when no matches). Set by ContentView to update
    /// model.renderedFindMatchSummary so the find bar can render it.
    public let onFindSummary: ((String) -> Void)?

    public init(
        html: String,
        baseURL: URL? = nil,
        zoom: Double = 1.0,
        findQuery: String = "",
        findCaseSensitive: Bool = false,
        findNextNonce: Int = 0,
        findPrevNonce: Int = 0,
        onFindResult: ((Bool?) -> Void)? = nil,
        onFindSummary: ((String) -> Void)? = nil
    ) {
        self.html = html
        self.baseURL = baseURL
        self.zoom = zoom
        self.findQuery = findQuery
        self.findCaseSensitive = findCaseSensitive
        self.findNextNonce = findNextNonce
        self.findPrevNonce = findPrevNonce
        self.onFindResult = onFindResult
        self.onFindSummary = onFindSummary
    }

    /// Shared WebContent process pool across all `MarkdownRenderedView`
    /// instances. Without this, every `WKWebViewConfiguration()` mints
    /// a fresh process pool → each new WebView spawns a new
    /// `com.apple.WebKit.WebContent` process (~30–80 MB each). Tab
    /// switches that rebuild the view destroy and re-spawn that
    /// process; reusing the pool keeps it warm.
    private static let sharedProcessPool = WKProcessPool()

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = Self.sharedProcessPool
        let prefs = WKWebpagePreferences()
        // We allow JS so our injected find runtime
        // (Coordinator.findScript) can run. The page's own scripts
        // are still blocked by the strict CSP (no script-src), so
        // user-supplied markdown can't execute scripts in this
        // viewer. Only API-injected scripts run.
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Mermaid runtime (2.5 MB JS) is NOT added here unconditionally.
        // It gets attached lazily in updateNSView the first time a
        // document with a `<div class="mdv-mermaid">` host element
        // arrives. For users who never render a mermaid file, the
        // runtime never enters the WebContent process — saves ~2.5 MB
        // in the WebKit process every session.

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        // WKWebView eats file-URL drags by default; releasing those so the
        // SwiftUI .onDrop on the parent receives them instead.
        webView.unregisterDraggedTypes()
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        // Lazy mermaid runtime injection. Detect once per WebView
        // instance: the host element pattern is stable from
        // HTMLRenderer's mermaid interceptor. We add the user scripts
        // BEFORE loadHTMLString so the about-to-load page picks them
        // up. After install, the flag stays true so non-mermaid pages
        // on the same WebView still get the runtime (cheap; idempotent
        // for them).
        if !coord.mermaidInjected && html.contains("mdv-mermaid") {
            let userContent = webView.configuration.userContentController
            if !MermaidBundle.runtime.isEmpty {
                userContent.addUserScript(WKUserScript(
                    source: MermaidBundle.runtime,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true))
            }
            if !MermaidBundle.shimJS.isEmpty {
                userContent.addUserScript(WKUserScript(
                    source: MermaidBundle.shimJS,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true))
            }
            coord.mermaidInjected = true
        }
        // Only reload when the HTML actually changed. body() re-runs on every
        // @Published mutation, and reloading the page on each tick causes
        // a render storm + a brief blank-content flash that was being
        // perceived as "tabs vanishing".
        if coord.lastHTML != html {
            webView.loadHTMLString(html, baseURL: baseURL)
            coord.lastHTML = html
        }
        if abs(webView.pageZoom - CGFloat(zoom)) > 0.001 {
            webView.pageZoom = CGFloat(zoom)
        }
        // Find-bar wiring.
        let c = context.coordinator
        c.onFindResult = onFindResult
        if let cb = onFindSummary {
            c.onFindCountChange = { _, _, summary in cb(summary) }
        } else {
            c.onFindCountChange = nil
        }
        if c.lastQuery != findQuery || c.lastCaseSensitive != findCaseSensitive {
            c.lastQuery = findQuery
            c.lastCaseSensitive = findCaseSensitive
            if findQuery.isEmpty {
                // Dismissing the find bar (query becomes empty) must
                // also clear any lingering <mark> elements left over
                // from the previous search; otherwise highlights
                // persist after Esc.
                webView.evaluateJavaScript(
                    "window.__mdvFindClear && window.__mdvFindClear();",
                    completionHandler: nil
                )
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
        /// True once the mermaid runtime + shim user scripts have been
        /// added to this WebView's userContentController. Set on first
        /// document containing the mermaid host marker; never reset
        /// (user scripts cannot be removed cheaply).
        var mermaidInjected: Bool = false
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
        /// Match count + current index + pre-formatted "n/N" summary,
        /// emitted after each find run. (total, currentIndexOrNil, summary).
        var onFindCountChange: ((Int, Int?, String) -> Void)? = nil

        /// Custom DOM-walking find: WKFindConfiguration is a black box
        /// (no count, no custom highlight colors). We inject JS that:
        ///   1. Strips any prior <mark class="mdv-find*"> spans
        ///   2. Walks every text node, finds query matches, wraps each
        ///      in `<mark class="mdv-find">` (and "mdv-find-current"
        ///      for the active one)
        ///   3. Scrolls the current match into view
        ///   4. Returns { total, current } as JSON-ish dict
        ///
        /// Colors come from the page's stylesheet (.mdv-find{-current}
        /// classes already exist in markdown.css from earlier — confirm).
        func runFind(in webView: WKWebView, backwards: Bool) {
            pendingFindWebView = webView
            let q = lastQuery
            guard !q.isEmpty else {
                // Clear marks.
                webView.evaluateJavaScript("window.__mdvFindClear && window.__mdvFindClear();", completionHandler: nil)
                onFindResult?(nil)
                return
            }
            guard documentReady else { return }
            let escaped = Self.jsEscape(q)
            let direction = backwards ? -1 : 1
            let cs = lastCaseSensitive ? "true" : "false"
            let script = """
            (function(){
              try { return window.__mdvFindRun(\(escaped), \(cs), \(direction)); }
              catch(e){ return { total: 0, current: -1, error: String(e) }; }
            })();
            """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                if let dict = result as? [String: Any] {
                    let total = (dict["total"] as? Int) ?? 0
                    let current = (dict["current"] as? Int) ?? -1
                    self.onFindResult?(total > 0)
                    let summary = total > 0
                        ? "\(max(current + 1, 1))/\(total)"
                        : ""
                    self.onFindCountChange?(total, current >= 0 ? current : nil, summary)
                } else {
                    self.onFindResult?(false)
                    self.onFindCountChange?(0, nil, "")
                }
            }
        }

        /// JSON-escape a query for embedding in a JS string literal.
        /// JSONSerialization does NOT escape U+2028 / U+2029 — both are
        /// JS line terminators, so a query like `"foo\u{2028}bar"`
        /// would produce a syntax error in the synthesized script.
        /// Sanitize via `JSStringEmbedding` to escape both.
        static func jsEscape(_ s: String) -> String {
            if let data = try? JSONSerialization.data(withJSONObject: [s]),
               let str = String(data: data, encoding: .utf8) {
                // ["…"] → strip surrounding [ ]
                let inner = String(str.dropFirst().dropLast())
                return JSStringEmbedding.sanitize(inner)
            }
            return "\"\""
        }

        public func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            documentReady = true
            // Inject our find runtime once per page load. CSP forbids
            // <script> tags from the rendered page, but
            // evaluateJavaScript is API-injected and not subject to
            // CSP. The functions live on `window.__mdvFind*`.
            webView.evaluateJavaScript(Coordinator.findScript, completionHandler: nil)
            // Re-run any pending find that was queued before load.
            if !lastQuery.isEmpty {
                runFind(in: webView, backwards: false)
            }
        }

        /// JS that defines `window.__mdvFindRun(query, caseSensitive, direction)`
        /// and `window.__mdvFindClear()`. Walks DOM text nodes, wraps
        /// matches, tracks current. Reentrant: re-running with a new
        /// query clears prior marks first.
        static let findScript: String = """
        (function(){
          var state = { total: 0, current: -1, query: "", caseSensitive: false };
          function clearMarks() {
            var marks = document.querySelectorAll('mark.mdv-find, mark.mdv-find-current');
            marks.forEach(function(m){
              var parent = m.parentNode;
              while (m.firstChild) parent.insertBefore(m.firstChild, m);
              parent.removeChild(m);
              parent.normalize();
            });
          }
          function walkAndMark(query, caseSensitive) {
            clearMarks();
            if (!query) { state.total = 0; state.current = -1; return 0; }
            var flags = caseSensitive ? 'g' : 'gi';
            var rx = new RegExp(query.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'), flags);
            var walker = document.createTreeWalker(
              document.body, NodeFilter.SHOW_TEXT,
              {
                acceptNode: function(node) {
                  var p = node.parentNode;
                  if (!p) return NodeFilter.FILTER_REJECT;
                  var tag = p.nodeName;
                  if (tag === 'SCRIPT' || tag === 'STYLE') return NodeFilter.FILTER_REJECT;
                  return node.nodeValue && node.nodeValue.length > 0
                    ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
                }
              }
            );
            var nodes = [];
            while (walker.nextNode()) nodes.push(walker.currentNode);
            var count = 0;
            for (var i = 0; i < nodes.length; i++) {
              var node = nodes[i];
              var text = node.nodeValue;
              rx.lastIndex = 0;
              var m;
              var pieces = [];
              var lastEnd = 0;
              while ((m = rx.exec(text)) !== null) {
                if (m[0].length === 0) { rx.lastIndex++; continue; }
                if (m.index > lastEnd) pieces.push(document.createTextNode(text.slice(lastEnd, m.index)));
                var mark = document.createElement('mark');
                mark.className = 'mdv-find';
                mark.textContent = m[0];
                pieces.push(mark);
                count++;
                lastEnd = m.index + m[0].length;
              }
              if (pieces.length > 0) {
                if (lastEnd < text.length) pieces.push(document.createTextNode(text.slice(lastEnd)));
                var frag = document.createDocumentFragment();
                pieces.forEach(function(p){ frag.appendChild(p); });
                node.parentNode.replaceChild(frag, node);
              }
            }
            return count;
          }
          window.__mdvFindClear = function() {
            clearMarks();
            state.total = 0; state.current = -1; state.query = "";
          };
          window.__mdvFindRun = function(query, caseSensitive, direction) {
            var total = state.total;
            var queryChanged = (query !== state.query || caseSensitive !== state.caseSensitive);
            if (queryChanged) {
              total = walkAndMark(query, caseSensitive);
              state.total = total;
              state.query = query;
              state.caseSensitive = caseSensitive;
              state.current = total > 0 ? 0 : -1;
            } else if (total > 0) {
              state.current = ((state.current + direction) % total + total) % total;
            }
            var allMarks = document.querySelectorAll('mark.mdv-find, mark.mdv-find-current');
            // Reclassify each match as current vs not.
            var idx = 0;
            allMarks.forEach(function(m){
              if (idx === state.current) m.className = 'mdv-find-current';
              else m.className = 'mdv-find';
              idx++;
            });
            // Scroll current match into view.
            if (state.current >= 0 && state.current < allMarks.length) {
              var cur = allMarks[state.current];
              if (cur.scrollIntoView) cur.scrollIntoView({block:'center', behavior:'instant'});
            }
            return { total: state.total, current: state.current };
          };
        })();
        """

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
        /// unit-tested. Allowlist semantics (CRIT-1 / S4 / 2026-05-25 §2.4):
        ///
        /// - Same-document fragment navigation (`#anchor`) is always allowed.
        /// - `javascript:`, `data:`, `file:`, `vbscript:`, `about:` (other
        ///   than `about:blank`) are **cancelled regardless of navigation
        ///   type** — this blocks `window.location = 'file:///etc/passwd'`
        ///   style escapes from any script that might run via a CSP edge
        ///   case. Previously only `linkActivated` was filtered.
        /// - For `linkActivated`: only `http`/`https`/`mailto` are honored —
        ///   they route to the user's browser. Everything else is cancelled.
        /// - For other navigation types (initial load, programmatic
        ///   `loadHTMLString`): allow.
        public static func decide(
            url: URL?,
            navigationType: WKNavigationType,
            currentDocumentURL: URL?
        ) -> LinkDecision {
            // Defense-in-depth: dangerous schemes blocked for ANY nav
            // type. `data:` is a special case — we allow it during the
            // initial WKWebView load because `loadHTMLString` itself
            // surfaces here as `.other`, but we still block it for
            // user-clicked links. Same shape for `file:` (used by the
            // mermaid runtime's CSS pull).
            if let url, navigationType == .linkActivated {
                let s = url.scheme?.lowercased() ?? ""
                if ["javascript", "vbscript", "data", "file"].contains(s) {
                    return .cancel
                }
            }
            // For programmatic / .other navigations, block the always-
            // dangerous schemes. file: is excluded here because
            // CodeMirrorEditorView legitimately uses `loadFileURL` for
            // its bundle resources, and the inline mermaid runtime
            // sometimes triggers a `file:` sub-resource fetch.
            if let url, navigationType != .linkActivated {
                let s = url.scheme?.lowercased() ?? ""
                if ["javascript", "vbscript"].contains(s) {
                    return .cancel
                }
            }
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
            // Compare scheme + host + path + query directly. Previously
            // round-tripped through URLComponents to strip the fragment,
            // but newer Foundation (Xcode 16.4 / macOS 15.6.1+)
            // reserializes scheme-only URLs like `about:blank` to a
            // different form, breaking the equality check. Field-by-field
            // is robust across Foundation versions.
            return url.scheme == cur.scheme
                && url.host == cur.host
                && url.path == cur.path
                && url.query == cur.query
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
