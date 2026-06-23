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
    /// Print/Export-as-PDF (TSK-638): nonce-bumped requests (the find
    /// pattern). The representable owns the live WKWebView, so the AppKit
    /// print operation and createPDF run here.
    public let printNonce: Int
    public let pdfExportNonce: Int
    public let pdfExportURL: URL?
    /// (nonce, ok, message) reported after createPDF resolves.
    public let onPDFExportResult: ((Int, Bool, String) -> Void)?
    /// TSK-905: nonce-bumped (the find/print pattern) when this rendered preview
    /// becomes the active tab's content. On a change we `makeFirstResponder` the
    /// WKWebView so ↑/↓/PageUp scroll it — WKWebViews are
    /// first-responder-by-tab-position by default, so a preview that isn't the
    /// last tab is otherwise dead to arrow keys.
    public let focusRequest: Int
    /// TSK-821 (rendered scroll persistence): the file URL this pane shows
    /// (keys the per-file scroll memory) + the bridge to the model's
    /// `renderedScrollByURL`. `onScrollCapture` reports the OUTGOING file's
    /// `window.scrollY` at a reload boundary; `restoreScrollY` is the stored
    /// offset to re-apply on `didFinish` for the incoming file (nil ⇒ top).
    /// Defaulted so the split pane (no scroll persistence) needn't pass them.
    public let fileURL: URL?
    public let restoreScrollY: Double?
    public let onScrollCapture: ((URL, Double) -> Void)?
    /// Rendered-markdown content scale (TSK-358): `markdown.css` multiplies its
    /// intrinsic px by `var(--mdv-content-scale)`; 1.0 = neutral. Applied live
    /// via JS (no reload), mirroring `pageZoom`, so the render cache is untouched.
    public let contentScale: Double

    /// Perf P1 (TSK-1042): stable cache key for the app-level warm-WKWebView
    /// cache. When non-nil, `dismantleNSView` parks this pane's WebView under
    /// the key and `makeNSView` re-attaches a parked WebView for the same key
    /// instead of rebuilding — so a session switch (which mints fresh `Tab.id`s
    /// and so defeats the `Tab.id`-keyed `MountedPanesLRU`) doesn't re-pay the
    /// ~94% WebKit first-open cost (TSK-598 / the TSK-1040 audit). Derived from
    /// `fileURL` (the resolved file path is stable across the switch — it's what
    /// the session snapshot persists). nil ⇒ this pane opts OUT of the cache
    /// (the split pane passes no `fileURL`, so it never collides with the main
    /// pane's cached WebView for the same file).

    public init(
        html: String,
        baseURL: URL? = nil,
        zoom: Double = 1.0,
        contentScale: Double = 1.0,
        findQuery: String = "",
        findCaseSensitive: Bool = false,
        findNextNonce: Int = 0,
        findPrevNonce: Int = 0,
        onFindResult: ((Bool?) -> Void)? = nil,
        onFindSummary: ((String) -> Void)? = nil,
        printNonce: Int = 0,
        pdfExportNonce: Int = 0,
        pdfExportURL: URL? = nil,
        onPDFExportResult: ((Int, Bool, String) -> Void)? = nil,
        focusRequest: Int = 0,
        fileURL: URL? = nil,
        restoreScrollY: Double? = nil,
        onScrollCapture: ((URL, Double) -> Void)? = nil
    ) {
        self.html = html
        self.baseURL = baseURL
        self.zoom = zoom
        self.contentScale = contentScale
        self.findQuery = findQuery
        self.findCaseSensitive = findCaseSensitive
        self.findNextNonce = findNextNonce
        self.findPrevNonce = findPrevNonce
        self.onFindResult = onFindResult
        self.onFindSummary = onFindSummary
        self.printNonce = printNonce
        self.pdfExportNonce = pdfExportNonce
        self.pdfExportURL = pdfExportURL
        self.onPDFExportResult = onPDFExportResult
        self.focusRequest = focusRequest
        self.fileURL = fileURL
        self.restoreScrollY = restoreScrollY
        self.onScrollCapture = onScrollCapture
    }

    /// Perf P1 (TSK-1042): the warm-WebView cache key for this pane, or nil to
    /// opt out. Keyed on the resolved file path so it's stable across a session
    /// switch (the snapshot persists the path, not the `Tab.id`). Panes without
    /// a `fileURL` (the split pane) opt out and never share a cached WebView.
    var cacheKey: String? {
        guard let fileURL else { return nil }
        return fileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Shared WebContent process pool across all `MarkdownRenderedView`
    /// instances. Without this, every `WKWebViewConfiguration()` mints
    /// a fresh process pool → each new WebView spawns a new
    /// `com.apple.WebKit.WebContent` process (~30–80 MB each). Tab
    /// switches that rebuild the view destroy and re-spawn that
    /// process; reusing the pool keeps it warm.
    private static let sharedProcessPool = WKProcessPool()

    /// Push the content-scale to the page's `--mdv-content-scale` CSS var (TSK-358)
    /// — live, no reload (mirrors `pageZoom`), so the render cache is untouched.
    /// `markdown.css` reads it via `calc(15px * var(--mdv-content-scale, 1))`.
    static func applyContentScale(_ scale: Double, to webView: WKWebView) {
        let v = String(format: "%.4f", scale)
        webView.evaluateJavaScript(
            "document.documentElement.style.setProperty('--mdv-content-scale', '\(v)')",
            completionHandler: nil)
    }

    public func makeNSView(context: Context) -> WKWebView {
        // Record the cache key on the (fresh) coordinator so `dismantleNSView`
        // — which only receives the coordinator, not the view — knows where to
        // park this pane's WebView. Set even on the cache-MISS path below.
        context.coordinator.cacheKey = cacheKey
        // Perf P1 (TSK-1042): re-attach a parked WebView for this file instead
        // of building a fresh one. We copy the parked coordinator's in-flight
        // navigation state onto THIS (SwiftUI-owned) coordinator and re-point
        // the WebView's delegate at it, so `updateNSView`'s `lastHTML == html`
        // reload gate is a no-op — no `loadHTMLString`/`didFinish` round-trip,
        // i.e. no WebKit first-open cost on switch-back.
        if let key = cacheKey,
           let parked = WarmWebViewCache.shared.retrieve(forKey: key) {
            let webView = parked.webView
            context.coordinator.adoptNavigationState(from: parked.coordinator)
            webView.navigationDelegate = context.coordinator
            // TSK-1046: keep the live-preview registry current on a warm
            // re-attach too (idempotent — `register` dedups), so the
            // `capture-rendered-scroll` probe resolves the re-attached pane.
            MarkdownRenderedRegistry.shared.register(webView)
            return webView
        }

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
        // TSK-1046: track the live rendered-preview WebViews so the VM UI test's
        // `capture-rendered-scroll` probe can read the on-screen `window.scrollY`
        // (the only authority for "did the rendered scroll actually restore").
        // Mirrors `CodeMirrorEditorRegistry`; weak refs, pruned on dismantle.
        MarkdownRenderedRegistry.shared.register(webView)
        #if DEBUG
        MountProbe.webViewMakes += 1   // Fix#1 mount-count probe (TSK-108)
        #endif
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        // Keep the parking key current — the pane's file can change within one
        // representable lifecycle (a tab reused for a different file), and
        // `dismantleNSView` parks under whatever this resolves to.
        coord.cacheKey = cacheKey
        // Lazy mermaid runtime injection / eviction. The host element
        // pattern is stable from HTMLRenderer's mermaid interceptor.
        // User scripts are added BEFORE loadHTMLString so the
        // about-to-load page picks them up.
        //
        // SECURITY (2026-05-29): previously the flag was set once and
        // never reset, so a markdown file with one mermaid block
        // followed by a non-mermaid file in the same tab kept the 2.5
        // MB runtime + shim attached to that WebView for its entire
        // lifetime. Two problems: (a) extra JS attack surface on docs
        // that don't need it — `addUserScript` bypasses CSP, so any
        // runtime bug becomes exploitable from pages that should be
        // script-free; (b) ~2.5 MB of JS parsed + JITted on every
        // subsequent page-load in that WebView.
        //
        // Fix: decide injection state per document via the pure
        // `nextMermaidInjectionState` helper, evict via
        // `removeAllUserScripts()` when transitioning away from
        // mermaid, and re-attach when transitioning back. Only the
        // mermaid runtime + shim are managed here, so the blanket
        // removeAll is safe (no other code adds user scripts to this
        // WebView).
        let wantsMermaid = MarkdownRenderedView.htmlNeedsMermaid(html)
        let action = MarkdownRenderedView.nextMermaidInjectionState(
            currentlyInjected: coord.mermaidInjected,
            documentWantsMermaid: wantsMermaid
        )
        switch action {
        case .noChange:
            break
        case .install:
            // WV-7 invariant: `updateNSView` is the *sole owner* of this
            // WebView's `userContentController` user-scripts — the
            // find-runtime is injected via `evaluateJavaScript` (not a
            // user-script), and nothing else adds any. So after a fresh
            // install the controller must hold exactly the mermaid scripts
            // and nothing pre-existing. We only reach `.install` from the
            // (false → true) transition, so the controller should be empty
            // here; assert that before adding, to catch any future code
            // that quietly starts adding its own user-scripts (which would
            // break the blanket-`removeAllUserScripts()` eviction below).
            let userContent = webView.configuration.userContentController
            assert(
                userContent.userScripts.isEmpty,
                "WV-7: userContentController must be empty before mermaid "
                + "install (sole-owner invariant violated — \(userContent.userScripts.count) "
                + "pre-existing user-scripts). If another subsystem now adds "
                + "user-scripts, isolate mermaid into a named WKContentWorld "
                + "instead of relying on removeAllUserScripts()."
            )
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
            // Post-install invariant: exactly the non-empty mermaid scripts.
            assert(
                userContent.userScripts.count == Self.expectedMermaidScriptCount,
                "WV-7: post-install user-script count "
                + "\(userContent.userScripts.count) != expected "
                + "\(Self.expectedMermaidScriptCount)"
            )
        case .evict:
            // `removeAllUserScripts` is the only API for removing
            // a previously-added script. We don't add any other
            // user scripts to this WebView (find-runtime uses
            // `evaluateJavaScript` per-load instead), so blanket
            // removal is safe today — this is the WV-7 sole-owner
            // invariant. If that ever changes, switch to a dedicated
            // `WKContentWorld` for mermaid so eviction is scoped.
            let userContent = webView.configuration.userContentController
            userContent.removeAllUserScripts()
            coord.mermaidInjected = false
            // Post-evict invariant: zero user-scripts remain.
            assert(
                userContent.userScripts.isEmpty,
                "WV-7: post-evict user-script count "
                + "\(userContent.userScripts.count) != 0"
            )
        }
        // Only reload when the HTML actually changed. body() re-runs on every
        // @Published mutation, and reloading the page on each tick causes
        // a render storm + a brief blank-content flash that was being
        // perceived as "tabs vanishing".
        if coord.lastHTML != html {
            // TSK-821: before this reload (a file switch / re-render into the
            // MountedPanesLRU-retained WebView) resets scroll to the top,
            // capture the OUTGOING file's scrollY so a later return restores it,
            // and stash the INCOMING file's remembered offset for `didFinish`.
            if let outgoing = coord.currentURL, let capture = onScrollCapture {
                webView.evaluateJavaScript("window.scrollY") { value, _ in
                    if let y = (value as? NSNumber)?.doubleValue, y > 0 {
                        capture(outgoing, y)
                    }
                }
            }
            coord.currentURL = fileURL
            coord.pendingRestoreY = restoreScrollY
            // WV-4: mark this as OUR programmatic load so the nav-policy
            // guard doesn't mistake it for an in-page script escape. A
            // `loadHTMLString(_:baseURL:)` reload surfaces in
            // `decidePolicyFor` as a `.other` navigation to the (file:)
            // baseURL — indistinguishable by scheme alone from a
            // `window.location = 'file://…'` escape. The flag is consumed
            // (cleared) by the next `.other` policy decision.
            coord.expectingProgrammaticLoad = true
            // TSK-598 attribution: the WebKit half of an MD open
            // (HTML hand-off → parse/layout → didFinish) was the one
            // unmeasured span in docs/PERFORMANCE_PROFILING.md. Begin
            // here, end in the Coordinator's didFinish.
            coord.loadToFinishToken = PerfSignpost.begin(
                .render, "WKWebView.loadToFinish")
            webView.loadHTMLString(html, baseURL: baseURL)
            coord.lastHTML = html
            // TSK-1046: this fresh reload will apply `pendingRestoreY` in
            // `didFinish`. Mark that as the value we'll have applied so the
            // no-reload re-apply block below doesn't double-fire it.
            coord.lastAppliedRestoreY = restoreScrollY
        } else if coord.currentURL == fileURL,
                  coord.documentReady,
                  let y = restoreScrollY, y > 0,
                  coord.lastAppliedRestoreY != y {
            // TSK-1046 (render-path scroll restore, no-reload path): a restored
            // scroll offset can arrive for an ALREADY-LOADED page with no HTML
            // change — so `didFinish` never re-fires to apply it. Three ways this
            // happens on a session/tab switch-IN: (a) a WARM-CACHE re-attach
            // (TSK-1042) — `adoptNavigationState` copies `lastHTML` so the reload
            // gate is a deliberate no-op, and the parked WebView's scroll is
            // wherever it was parked, NOT the persisted offset; (b) a
            // `MountedPanesLRU`-RETAINED pane re-shown (no rebuild, no reload);
            // (c) a REBUILT pane whose SwiftUI body captured `restoreScrollY` as
            // nil because it rendered BEFORE `DocumentModel.restoreScroll` seeded
            // `renderedScrollByURL`, then a later `updateNSView` carries the
            // now-non-nil offset but the reload gate (lastHTML == html) is closed.
            // Apply it directly here. (`adoptNavigationState` intentionally does
            // NOT copy `lastAppliedRestoreY`, so a warm re-attach re-applies the
            // persisted offset exactly once.)
            // `documentReady` guards against scrolling before the DOM has height;
            // `lastAppliedRestoreY` makes it idempotent (one apply per distinct
            // restored value), so this never fights a live scroll the user makes
            // afterward (that doesn't change `restoreScrollY`).
            coord.lastAppliedRestoreY = y
            coord.pendingRestoreY = nil
            webView.evaluateJavaScript(
                "window.scrollTo({top: \(y), behavior: 'instant'});",
                completionHandler: nil)
        }
        if abs(webView.pageZoom - CGFloat(zoom)) > 0.001 {
            webView.pageZoom = CGFloat(zoom)
        }
        // TSK-358: live content-scale push (no reload), mirroring pageZoom.
        coord.contentScale = contentScale
        if abs(coord.lastAppliedScale - contentScale) > 0.0001 {
            coord.lastAppliedScale = contentScale
            Self.applyContentScale(contentScale, to: webView)
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
        // Preview focus (TSK-905): on a change, take first responder so the
        // active rendered preview gets arrow/PageUp key events. window?. so a
        // not-yet-attached webView no-ops safely (only the live, on-screen
        // active tab's view is in a window — background tabs aren't realized).
        if c.lastFocusRequest != focusRequest {
            c.lastFocusRequest = focusRequest
            webView.window?.makeFirstResponder(webView)
        }
        // Print / Export-as-PDF (TSK-638).
        if c.lastPrintNonce != printNonce {
            c.lastPrintNonce = printNonce
            Self.runPrintOperation(webView)
        }
        if c.lastPDFExportNonce != pdfExportNonce, let url = pdfExportURL {
            c.lastPDFExportNonce = pdfExportNonce
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

    /// `⌘P`: the AppKit print operation for the live page. WKWebView's
    /// printOperation needs its operation view given a real frame before
    /// running, and runs as a window-attached panel.
    static func runPrintOperation(_ webView: WKWebView) {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.view?.frame = webView.bounds
        if let window = webView.window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// RC-6: deterministic teardown when SwiftUI discards the
    /// representable (tab close, view replaced). Without this, the
    /// `WKWebView` is released only when ARC happens to drop it, and a
    /// load in flight can keep firing navigation-delegate callbacks into
    /// a Coordinator that's about to go away.
    ///
    /// - `stopLoading()` cancels any in-flight navigation/sub-resource
    ///   fetch so no further `didFinish`/`decidePolicyFor` callbacks land.
    /// - `navigationDelegate = nil` severs the (unowned) delegate link to
    ///   the Coordinator immediately.
    /// - `removeAllUserScripts()` drops the mermaid runtime + shim so the
    ///   pooled `WKProcessPool`'s WebContent process doesn't carry stale
    ///   user-scripts forward (hygiene; the controller is per-WebView, but
    ///   we don't rely on dealloc timing for that to clear).
    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Perf P1 (TSK-1042): instead of tearing the WebView down, PARK it in
        // the app-level warm cache keyed by file path so a returning tab (after
        // a session switch that minted a fresh `Tab.id` and so defeated the
        // `MountedPanesLRU`) re-attaches it with NO reload. We keep the loaded
        // DOM, the mermaid user-scripts, and the coordinator's nav state intact
        // (the coordinator is parked alongside) — the make path re-points the
        // delegate and copies the state across. Only opt-out panes (nil key,
        // e.g. the split pane) take the real teardown below.
        if let key = coordinator.cacheKey {
            // Detach the live delegate link so no stray callback lands on this
            // coordinator while parked; the make path installs the new delegate.
            webView.navigationDelegate = nil
            coordinator.pendingFindWebView = nil
            WarmWebViewCache.shared.stash(webView, coordinator: coordinator, forKey: key)
            return
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        coordinator.mermaidInjected = false
        coordinator.pendingFindWebView = nil
        // TSK-1046: drop the weak registry ref (it self-prunes too, but this is
        // deterministic).
        MarkdownRenderedRegistry.shared.unregister(webView)
        #if DEBUG
        MountProbe.webViewDismantles += 1   // Fix#1 mount-count probe (TSK-108)
        #endif
    }

    /// Outcome of a single navigation policy decision. Exposed as a pure value
    /// so the (otherwise hard-to-test) Coordinator delegate method has a
    /// testable kernel — see `Coordinator.decide(url:navigationType:currentDocumentURL:)`.
    public enum LinkDecision: Equatable, Sendable {
        case allow
        case cancel
        case openExternally(URL)
    }

    /// Resolution of the per-update injection decision. Pure value so the
    /// state-transition logic for `mermaidInjected` is testable host-side
    /// without an actual `WKWebView`.
    public enum MermaidInjectionAction: Equatable, Sendable {
        /// Current state matches the document — do nothing.
        case noChange
        /// Document wants mermaid; runtime + shim must be attached.
        case install
        /// Document doesn't want mermaid but runtime is currently
        /// attached — evict before the new HTML loads, so the next
        /// page doesn't inherit unnecessary script surface.
        case evict
    }

    /// Cheap content-sniff: does this HTML payload reference the
    /// mermaid host element? Exposed as a `static` helper so tests
    /// can pin the contract without a `WKWebView`.
    public static func htmlNeedsMermaid(_ html: String) -> Bool {
        html.contains("mdv-mermaid")
    }

    /// WV-7: number of `WKUserScript`s the `.install` branch attaches —
    /// one each for the non-empty mermaid runtime and shim. Empty
    /// resources (missing from the bundle) are skipped, so this is 0–2.
    /// Exposed so the invariant assertion and host tests share one
    /// source of truth for the expected post-install count.
    static var expectedMermaidScriptCount: Int {
        (MermaidBundle.runtime.isEmpty ? 0 : 1)
            + (MermaidBundle.shimJS.isEmpty ? 0 : 1)
    }

    /// Decide what to do with the WebView's mermaid user-scripts on
    /// the current `updateNSView` tick.
    ///
    /// State transitions:
    ///   - (injected=false, wants=false) → `.noChange`
    ///   - (injected=false, wants=true ) → `.install`
    ///   - (injected=true,  wants=true ) → `.noChange`  (idempotent re-render)
    ///   - (injected=true,  wants=false) → `.evict`     (security: drop runtime
    ///                                                   so the next non-mermaid
    ///                                                   doc doesn't inherit
    ///                                                   the 2.5 MB JS surface
    ///                                                   nor the CSP-bypass)
    public static func nextMermaidInjectionState(
        currentlyInjected: Bool,
        documentWantsMermaid: Bool
    ) -> MermaidInjectionAction {
        switch (currentlyInjected, documentWantsMermaid) {
        case (false, false): return .noChange
        case (false, true):  return .install
        case (true,  true):  return .noChange
        case (true,  false): return .evict
        }
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate {
        /// Perf P1 (TSK-1042): the warm-WebView cache key (file path) this
        /// pane's WebView is parked under on `dismantleNSView`. Set from
        /// `MarkdownRenderedView.cacheKey` in make/update. nil ⇒ this pane opts
        /// out of the cache (real teardown on dismantle).
        var cacheKey: String?

        /// Last HTML payload sent to `loadHTMLString`. Updated only when the
        /// view actually changed, so repeated `updateNSView` calls with the
        /// same content don't re-load the page (CRIT-4 fix for the
        /// "vanishing tabs" reload storm).
        var lastHTML: String?
        /// TSK-821: the file URL currently loaded here (keys the scroll
        /// capture) + the scroll offset to re-apply once the next load
        /// finishes (consumed in `didFinish`; nil ⇒ leave at top).
        var currentURL: URL?
        var pendingRestoreY: Double?
        /// TSK-1046: the last restored scroll offset we actually applied to THIS
        /// WebView (via `didFinish` after a reload, or the no-reload re-apply
        /// block in `updateNSView`). Makes the no-reload restore idempotent —
        /// one apply per distinct restored value — so a retained / rebuilt pane
        /// that re-receives the same `restoreScrollY` doesn't re-scroll on every
        /// `updateNSView` tick (which would fight a live scroll the user made).
        var lastAppliedRestoreY: Double?
        /// TSK-358: the live content-scale (mirrors zoom tracking). Stored so
        /// `didFinish` can re-apply the `--mdv-content-scale` CSS var after a
        /// reload resets the DOM; `lastAppliedScale` debounces the live push.
        var contentScale: Double = 1
        var lastAppliedScale: Double = 1
        /// True iff the mermaid runtime + shim user scripts are
        /// currently attached to this WebView's
        /// userContentController. Set on first document containing
        /// the mermaid host marker; **reset** when the active
        /// document no longer contains the marker (security: prevents
        /// non-mermaid docs from inheriting the 2.5 MB JS surface +
        /// CSP-bypass of `addUserScript`). See
        /// `MarkdownRenderedView.nextMermaidInjectionState(...)` for
        /// the transition table.
        var mermaidInjected: Bool = false
        /// True once the current document has reported didFinish. Used
        /// to gate find() — calling it before the DOM is ready silently
        /// fails with matchFound=false, so we defer until ready.
        var documentReady: Bool = false
        /// WV-4: true once the current document has finished its initial
        /// load. Drives `decide(..., initialLoadComplete:)` so that a
        /// post-load top-level `.other` navigation to `file:`/`data:`
        /// (i.e. an in-page script escape) is cancelled, while the
        /// bootstrap `loadHTMLString`/`loadFileURL` (also `.other`) is
        /// allowed. Reset on each new provisional navigation so a
        /// genuine tab switch / reload re-opens the permissive window.
        var didFinishFirstLoad: Bool = false
        /// WV-4: set immediately before each `loadHTMLString` WE initiate
        /// (content change / tab switch). A `loadHTMLString(_:baseURL:)`
        /// reload arrives in `decidePolicyFor` as a `.other` navigation to
        /// the `file:` baseURL — by scheme alone it is indistinguishable
        /// from a `window.location = 'file://…'` escape. This flag lets the
        /// policy handler tell the two apart: an expected programmatic load
        /// is allowed and the flag is cleared; an UNexpected post-load
        /// `.other` file:/data: is a script escape and is cancelled.
        var expectingProgrammaticLoad: Bool = false
        /// In-flight `render | WKWebView.loadToFinish` signpost interval
        /// (TSK-598): begun at `loadHTMLString`, ended in `didFinish`.
        /// Hollow token when `MDV_SIGNPOSTS` is unset — zero overhead.
        var loadToFinishToken: PerfSignpost.Token?
        /// Holds the webView weakly so `webView(_:didFinish:)` can
        /// re-run any find that was queued before the page was ready.
        weak var pendingFindWebView: WKWebView?

        // Find-bar state observed by updateNSView.
        var lastQuery: String = ""
        var lastCaseSensitive: Bool = false
        var lastNextNonce: Int = 0
        var lastPrevNonce: Int = 0
        var lastPrintNonce: Int = 0
        var lastPDFExportNonce: Int = 0
        var lastFocusRequest: Int = 0
        /// Reported back via SwiftUI: true/false = last find's matchFound.
        var onFindResult: ((Bool?) -> Void)? = nil
        /// Match count + current index + pre-formatted "n/N" summary,
        /// emitted after each find run. (total, currentIndexOrNil, summary).
        var onFindCountChange: ((Int, Int?, String) -> Void)? = nil

        /// Perf P1 (TSK-1042): copy the navigation/render state that determines
        /// whether `updateNSView` reloads the page from a PARKED coordinator
        /// onto this (fresh, SwiftUI-owned) one when a warm WebView is
        /// re-attached. After this, `lastHTML == html` for the same document so
        /// the reload gate is a no-op — the whole point of the warm cache.
        ///
        /// We copy the document-identity + already-applied-state fields, NOT
        /// the per-tick find/print nonces (those resync from the model on the
        /// next `updateNSView`) and NOT the SwiftUI callback closures (the new
        /// representable supplies its own). `documentReady`/`didFinishFirstLoad`
        /// are preserved so find runs immediately and the nav-policy window
        /// stays correct without waiting for a (non-occurring) reload.
        func adoptNavigationState(from parked: Coordinator) {
            lastHTML = parked.lastHTML
            currentURL = parked.currentURL
            pendingRestoreY = parked.pendingRestoreY
            contentScale = parked.contentScale
            lastAppliedScale = parked.lastAppliedScale
            mermaidInjected = parked.mermaidInjected
            documentReady = parked.documentReady
            didFinishFirstLoad = parked.didFinishFirstLoad
            expectingProgrammaticLoad = parked.expectingProgrammaticLoad
        }

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

        /// Close the in-flight load signpost (idempotent). Every
        /// navigation OUTCOME — finish, fail, provisional fail, process
        /// death — must route here or the interval leaks open (the
        /// TSK-624 trace artifact: loadToFinish truncated at recording
        /// stop because only didFinish ended it).
        func endLoadToFinish() {
            if let token = loadToFinishToken {
                PerfSignpost.end(token)
                loadToFinishToken = nil
            }
        }

        /// TSK-624 — failure paths were UNIMPLEMENTED: a failed load or a
        /// WebContent process death left `documentReady` false forever
        /// (spinner/blank with no recovery — the classic WKWebView
        /// white-screen footgun, and a credible mechanism for the
        /// owner-felt "delay opening files" / "retry loads fast" reports).
        public func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!, withError error: Error
        ) {
            endLoadToFinish()
            // Clear the dedup baseline so the next updateNSView tick
            // re-issues the load instead of believing the page is current.
            lastHTML = nil
        }

        public func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            endLoadToFinish()
            lastHTML = nil
        }

        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            endLoadToFinish()
            // The renderer died (jetsam/crash): the view is now a blank
            // white surface that never recovers on its own. Drop the
            // dedup baseline + reload the window's content on the next
            // tick; also nudge an immediate reload so recovery doesn't
            // wait for an unrelated SwiftUI update.
            lastHTML = nil
            documentReady = false
            webView.reload()
        }

        public func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            endLoadToFinish()
            documentReady = true
            // WV-4: from here on, any top-level `.other` navigation to
            // file:/data: is an in-page script escape, not the bootstrap
            // load — see `decide(..., initialLoadComplete:)`.
            didFinishFirstLoad = true
            // Inject our find runtime once per page load. CSP forbids
            // <script> tags from the rendered page, but
            // evaluateJavaScript is API-injected and not subject to
            // CSP. The functions live on `window.__mdvFind*`.
            webView.evaluateJavaScript(Coordinator.findScript, completionHandler: nil)
            // TSK-358: a reload reset the DOM, so re-apply the content-scale var
            // (skip the neutral default — markdown.css's var() fallback covers 1).
            if abs(contentScale - 1) > 0.0001 {
                MarkdownRenderedView.applyContentScale(contentScale, to: webView)
            }
            // TSK-821: restore this file's remembered rendered scroll offset
            // (captured at the previous reload boundary). The DOM is parsed by
            // didFinish; `instant` so the jump doesn't animate.
            if let y = pendingRestoreY, y > 0 {
                pendingRestoreY = nil
                webView.evaluateJavaScript(
                    "window.scrollTo({top: \(y), behavior: 'instant'});",
                    completionHandler: nil)
            }
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
            // WV-4: the WV-4 guard only fires for a post-first-load `.other`
            // file:/data: navigation that we did NOT initiate. Our own
            // `loadHTMLString` reloads set `expectingProgrammaticLoad`; the
            // first such `.other` decision consumes (clears) it so a later
            // script-driven `.other` is no longer mistaken for our load.
            let wasExpectingOurLoad = expectingProgrammaticLoad
            if navigationAction.navigationType == .other {
                expectingProgrammaticLoad = false
            }
            // Treat the initial load as "complete" for guarding purposes
            // only when first load finished AND this `.other` isn't the
            // programmatic reload we just kicked off.
            let guardAsPostLoad = didFinishFirstLoad && !wasExpectingOurLoad
            let decision = Coordinator.decide(
                url: navigationAction.request.url,
                navigationType: navigationAction.navigationType,
                currentDocumentURL: webView.url,
                initialLoadComplete: guardAsPostLoad
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
        /// unit-tested. Allowlist semantics (CRIT-1 / S4 / 2026-05-25 §2.4,
        /// WV-4 2026-05-30):
        ///
        /// - Same-document fragment navigation (`#anchor`) is always allowed.
        /// - `javascript:` and `vbscript:` are **cancelled regardless of
        ///   navigation type** — blocks `window.location = 'javascript:…'`
        ///   style escapes from any script that might run via a CSP edge
        ///   case. Previously only `linkActivated` was filtered.
        /// - For `linkActivated`: only `http`/`https`/`mailto` are honored —
        ///   they route to the user's browser. `data:`/`file:` and every
        ///   other scheme are cancelled.
        /// - For `.other` (programmatic / `loadHTMLString` / `loadFileURL`)
        ///   navigations, `file:`/`data:` are allowed **unless this is a
        ///   post-initial-load navigation that we did not initiate**. WV-4:
        ///   once the first load has reported `didFinish`, a top-level
        ///   `.other` to `file:`/`data:` that isn't one of our own
        ///   `loadHTMLString` reloads can only come from in-page script
        ///   (`window.location = 'file:///etc/passwd'`,
        ///   `location.replace('data:text/html,…')`) — there is no legitimate
        ///   programmatic re-navigation to those schemes from the page, so we
        ///   cancel it. The caller distinguishes its own reloads via
        ///   `Coordinator.expectingProgrammaticLoad` and only passes
        ///   `initialLoadComplete: true` for the un-expected case.
        /// - Any other `.other` navigation: allow.
        ///
        /// - Parameter initialLoadComplete: the post-load script-escape
        ///   guard signal. The caller passes `true` only when the first load
        ///   has finished AND this `.other` navigation was NOT a reload it
        ///   just initiated (see `Coordinator.decidePolicyFor`). Defaults to
        ///   `false` so the bootstrap load and our own reloads stay
        ///   permissive; a `true` value blocks `file:`/`data:` `.other`.
        public static func decide(
            url: URL?,
            navigationType: WKNavigationType,
            currentDocumentURL: URL?,
            initialLoadComplete: Bool = false
        ) -> LinkDecision {
            // Defense-in-depth: dangerous schemes blocked for ANY nav
            // type. `data:` is a special case — we allow it during the
            // initial WKWebView load because `loadHTMLString` itself
            // surfaces here as `.other`, but we still block it for
            // user-clicked links. Same shape for `file:` (used by the
            // mermaid runtime's CSS pull).
            if let url, navigationType == .linkActivated {
                let s = url.scheme?.lowercased() ?? ""
                // Same-document #fragment navigation (in-page anchor / TOC) is
                // safe and MUST be allowed BEFORE the file: block below —
                // otherwise anchor links in the file://-loaded rendered
                // markdown are cancelled. This regressed on 2026-05-25
                // (8da6efbb) when `file` was added to the block list above the
                // same-doc check at the bottom of decide(). isSameDocumentFragment
                // requires identical scheme+host+path+query, so a file: link to
                // a DIFFERENT document still can't slip through here; the
                // dangerous schemes stay blocked unconditionally just below.
                if !["javascript", "vbscript", "data"].contains(s),
                   URLFragmentPolicy.isSameDocument(url, as: currentDocumentURL) {
                    return .allow
                }
                if ["javascript", "vbscript", "data", "file"].contains(s) {
                    return .cancel
                }
            }
            // For programmatic / .other navigations, block the always-
            // dangerous schemes. file: is excluded from the *unconditional*
            // block here because CodeMirrorEditorView legitimately uses
            // `loadFileURL` for its bundle resources, and the inline mermaid
            // runtime sometimes triggers a `file:` sub-resource fetch — but
            // only during the bootstrap load (see the WV-4 guard below).
            if let url, navigationType != .linkActivated {
                let s = url.scheme?.lowercased() ?? ""
                if ["javascript", "vbscript"].contains(s) {
                    return .cancel
                }
                // WV-4: after the initial load completes, a top-level
                // `.other` navigation to `file:`/`data:` can only be an
                // in-page script escape (there is no legitimate programmatic
                // re-navigation to those schemes once the page is up). Cancel
                // it. During the bootstrap (`initialLoadComplete == false`)
                // these remain allowed so `loadHTMLString`/`loadFileURL`
                // render at all.
                if initialLoadComplete, ["file", "data"].contains(s) {
                    return .cancel
                }
            }
            guard navigationType == .linkActivated else { return .allow }
            guard let url else { return .cancel }
            if URLFragmentPolicy.isSameDocument(url, as: currentDocumentURL) {
                return .allow
            }
            switch url.scheme?.lowercased() ?? "" {
            case "http", "https", "mailto":
                return .openExternally(url)
            default:
                return .cancel
            }
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

/// TSK-1046 — tracks the currently-mounted rendered-Markdown `WKWebView`s so the
/// VM UI test's `capture-rendered-scroll` script verb can read the LIVE on-screen
/// `window.scrollY` (the only authority for "did the rendered preview actually
/// restore its scroll on a session/tab switch-IN"). The model dump is pure model
/// state and cannot see the WebView's real scroll — which is exactly why this
/// render-path bug was invisible to headless tests.
///
/// Mirrors `CodeMirrorEditorRegistry`: weak refs (the WebViews are owned by
/// SwiftUI/AppKit), pruned on dismantle and lazily; `current()` returns the
/// preview in the key window, falling back to the most-recently-registered one.
@MainActor
public final class MarkdownRenderedRegistry {
    public static let shared = MarkdownRenderedRegistry()
    private final class Weak { weak var value: WKWebView?; init(_ v: WKWebView) { value = v } }
    private var entries: [Weak] = []

    public func register(_ webView: WKWebView) {
        prune()
        if entries.contains(where: { $0.value === webView }) { return }
        entries.append(Weak(webView))
    }

    public func unregister(_ webView: WKWebView) {
        entries.removeAll { $0.value === webView || $0.value == nil }
    }

    /// The rendered preview WebView whose window is currently key, else the
    /// most-recently-registered one. Returns nil in a headless process (no
    /// `NSApp` / no preview mounted).
    public func current() -> WKWebView? {
        prune()
        let app: NSApplication? = NSApp
        if let key = app?.keyWindow,
           let inKey = entries.lazy.compactMap({ $0.value })
            .first(where: { $0.window === key }) {
            return inKey
        }
        return entries.last?.value
    }

    private func prune() {
        entries.removeAll { $0.value == nil }
    }

    /// TSK-1046 diag: count of live (non-nil) registered preview WebViews.
    public var liveEntryCount: Int { entries.compactMap { $0.value }.count }
}

/// TSK-1046 — a side-channel the `capture-rendered-scroll` script verb writes the
/// live rendered `window.scrollY` into, so the very next per-step diagnostic dump
/// can surface it (`renderedScrollY`). The verb evaluates JS asynchronously, so
/// it stashes the result here for the dump that follows the verb's settle delay —
/// the same self-describing-side-channel pattern as `UIEventSynth.lastTrace`.
@MainActor
public enum LiveScrollProbe {
    /// The most recently probed live `window.scrollY` of the active rendered
    /// preview. `-1` until the first `capture-rendered-scroll` verb resolves;
    /// reset between scenarios by the harness via `reset()`.
    public static var renderedScrollY: Double = -1
    /// TSK-1046 diag: why the last rendered probe produced its value — distinguishes
    /// no-current-webview vs eval-pending (async unresolved before the dump) vs
    /// eval-failed (JS returned nil / errored) vs ok. Surfaced in the dump.
    public static var lastProbeDiag: String = "init"
    /// TSK-1047 diag: why the last editor probe produced its value — no-current
    /// (CM6 not registered) / ok=false (mounted but __mdvView/CM6 not up) / throw /
    /// ok. Surfaced in the dump as editorProbeDiag.
    public static var lastEditorProbeDiag: String = "init"

    /// TSK-1047 — the most recently probed LIVE CM6 editor scroll, read straight
    /// off the active editor WebView's `__mdvView.scrollDOM.scrollTop`. This is
    /// the RENDER AUTHORITY for the editor scroll-restore: unlike the model field
    /// `editorScrollTopLine` (which only updates when CM6 re-posts `scrollChanged`
    /// for the CURRENT `Tab.id` — stale/empty after a switch mints a fresh id),
    /// these read the pixel/line the WebView ACTUALLY holds on screen. `-1` until
    /// the first `capture-editor-scroll` verb resolves.
    public static var editorScrollTop: Double = -1
    /// 1-based viewport top line CM6 computes from its own viewport, captured by
    /// `captureEditorScroll()`. `-1` until first probe / no editor mounted.
    public static var editorTopLine: Int = -1

    public static func reset() {
        renderedScrollY = -1
        editorScrollTop = -1
        editorTopLine = -1
    }

    /// Read the active rendered preview's live `window.scrollY` and stash it in
    /// `renderedScrollY`. Async (WKWebView JS); the result lands before the
    /// post-verb settle delay elapses, so the next dump reflects it. No-op (and
    /// leaves the prior value) when no preview is mounted.
    public static func captureRenderedScroll() {
        let n = MarkdownRenderedRegistry.shared.liveEntryCount
        guard let webView = MarkdownRenderedRegistry.shared.current() else {
            renderedScrollY = -1
            lastProbeDiag = "no-current entries=\(n)"
            return
        }
        lastProbeDiag = "pending entries=\(n) hasURL=\(webView.url != nil) key=\(webView.window?.isKeyWindow ?? false)"
        webView.evaluateJavaScript("window.scrollY") { value, err in
            if let y = (value as? NSNumber)?.doubleValue {
                LiveScrollProbe.renderedScrollY = y
                LiveScrollProbe.lastProbeDiag = "ok y=\(y)"
            } else {
                LiveScrollProbe.lastProbeDiag =
                    "eval-fail v=\(String(describing: value)) e=\(String(describing: err))"
            }
        }
    }

    /// JS that reads the live CM6 scroll off `__mdvView` (the diagnostic handle
    /// the host HTML exposes): `{ok, top, line}` where `top` is the px scrollTop
    /// and `line` is the 1-based viewport top line. Shared by the capture verb
    /// (stash for the next dump) and the wait-for-settle poll (read synchronously
    /// into the completion handler). Returns `{ok:false}` before CM6 is up.
    /// `public` so the `MarkdownViewer` module's `--script` wait-for-settle verbs
    /// reuse the exact same read.
    public static let editorScrollReadJS = """
    (function () {
      try {
        var v = window.__mdvView;
        if (!v) return {ok:false};
        var top = Math.round(v.scrollDOM.scrollTop);
        var vp = v.viewport;
        var line = v.state.doc.lineAt(vp.from).number;
        return {ok:true, top: top, line: line};
      } catch (e) { return {ok:false, err: String(e)}; }
    })()
    """

    /// Read the active CM6 editor's LIVE scroll (`__mdvView.scrollDOM.scrollTop`
    /// + viewport top line) and stash it in `editorScrollTop` / `editorTopLine`,
    /// which the NEXT per-step dump surfaces as `liveEditorScrollTop` /
    /// `liveEditorTopLine`. Async (WKWebView JS); resolves within the post-verb
    /// settle delay. No-op (clears to −1) when no editor is mounted.
    public static func captureEditorScroll() {
        guard let webView = CodeMirrorEditorRegistry.shared.current() else {
            editorScrollTop = -1
            editorTopLine = -1
            return
        }
        webView.evaluateJavaScript(editorScrollReadJS) { value, _ in
            let dict = value as? [String: Any]
            let ok = (dict?["ok"] as? Bool) ?? false
            if ok {
                LiveScrollProbe.editorScrollTop =
                    (dict?["top"] as? NSNumber)?.doubleValue ?? -1
                LiveScrollProbe.editorTopLine =
                    (dict?["line"] as? NSNumber)?.intValue ?? -1
            }
        }
    }
}
