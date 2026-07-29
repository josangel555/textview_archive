import SwiftUI
import WebKit
import ViewerCore

/// TSK-1596 — the WEB diff pane: granularity picker (Line | Word | Char) over
/// the `diffweb.html` WKWebView. Replaces the SwiftUI `DiffView` for every
/// READ-ONLY diff surface (`.diff` lens tab, File History, Unified History);
/// review mode keeps `DiffView` until the review follow-up ports threads.
struct WebDiffPane: View {
    let text: String
    @ObservedObject var doc: DocumentModel
    /// False for SINGLE-FILE surfaces (File History / version history), where
    /// a changed-files tree is noise (owner 2026-07-24): hides the Files
    /// toggle AND forces the nav off without touching the app-wide pref.
    var navAvailable: Bool = true

    /// The owner's Line|Word|Char intra-line granularity — an app-wide
    /// preference (not per-tab), persisted under `DiffGranularity.defaultsKey`.
    @AppStorage(DiffGranularity.defaultsKey)
    private var granularityRaw: String = DiffGranularity.default.rawValue
    /// TSK-1598: wrap-at-window-width + changed-files nav, both persisted.
    @AppStorage(DiffViewPrefs.wrapKey)
    private var wrapLines: Bool = DiffViewPrefs.wrapDefault
    @AppStorage(DiffViewPrefs.fileNavKey)
    private var showFileNav: Bool = DiffViewPrefs.fileNavDefault

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $granularityRaw) {
                    ForEach(DiffGranularity.allCases, id: \.rawValue) { g in
                        Text(g.displayName).tag(g.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: doc.uiSize(180))
                .help("Intra-line diff granularity: whole lines, word-level, or character-level")
                .accessibilityIdentifier("mdv.diff.granularity")
                Toggle("Wrap", isOn: $wrapLines)
                    .toggleStyle(.checkbox)
                    .help("Wrap long lines at the window width (off = scroll horizontally)")
                    .accessibilityIdentifier("mdv.diff.wrap")
                if navAvailable {
                    Toggle("Files", isOn: $showFileNav)
                        .toggleStyle(.checkbox)
                        .help("Show the changed-files tree — click a file to jump to it")
                        .accessibilityIdentifier("mdv.diff.fileNav")
                }
                Spacer()
            }
            .font(.system(size: doc.uiSize(11)))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Palette.windowBackground.opacity(0.3))
            .overlay(alignment: .bottom) { Divider() }
            DiffWebView(
                text: text,
                granularity: DiffGranularity.resolve(granularityRaw),
                isDark: doc.activeTheme.name == .xcodeDark,
                fontSize: doc.effectiveContentFontSize,
                wrapLines: wrapLines,
                showFileNav: navAvailable && showFileNav,
                onOpenVersion: { [weak doc] version, path, blob in
                    guard let doc else { return }
                    switch version {
                    case "current":
                        doc.diffOpenCurrentFile(path: path)
                    default:
                        guard let blob else {
                            ToastCenter.shared.post(
                                .info, "No \(version) version recorded in this diff")
                            return
                        }
                        doc.diffOpenBlob(sha: blob, path: path, versionLabel: version)
                    }
                }
            )
        }
        .accessibilityIdentifier("mdv.webDiffPane")
    }
}

/// Weak-ref proxy so the WKUserContentController does not retain the
/// coordinator (the standard WKScriptMessageHandler leak dodge — same
/// pattern as CanvasWebViewHost.MessageProxy).
private final class DiffMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var coordinator: DiffWebView.Coordinator?

    init(coordinator: DiffWebView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            coordinator?.receiveBridgeMessage(message.body)
        }
    }
}

/// The WKWebView host for `diffweb.html`. Pushes the parsed-diff JSON payload
/// (`DiffWebPayload`) plus granularity/theme/font into the page, and VERIFIES
/// every render via the page's returned row count (the TSK-1587 lesson: a
/// fire-and-forget apply that fails silently leaves stale pixels) — a failed
/// render is retried once after `didFinish` and logged loudly otherwise.
struct DiffWebView: NSViewRepresentable {
    let text: String
    let granularity: DiffGranularity
    let isDark: Bool
    let fontSize: CGFloat
    let wrapLines: Bool
    let showFileNav: Bool
    /// TSK-1599: the file-header buttons — `(version "old"|"new"|"current",
    /// repo-relative path, blob sha or nil)`. Routed by `WebDiffPane` to the
    /// DocumentModel diff-navigation actions.
    var onOpenVersion: ((String, String, String?) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        // TSK-1599 bridge: weak proxy so the userContentController doesn't
        // retain the coordinator (the standard WKScriptMessageHandler dodge).
        config.userContentController.add(
            DiffMessageProxy(coordinator: context.coordinator), name: "mdvDiff")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.unregisterDraggedTypes()
        context.coordinator.webView = webView
        guard let htmlURL = Bundle.viewerUIResources.url(
            forResource: "diffweb", withExtension: "html") else {
            Obs.shared.emit(.error, "web-diff", "diffweb.html missing from Resources bundle")
            return webView
        }
        // readAccess = parent dir so the page can load the sibling
        // codemirror.js (SwiftPM flattens the resource subdirectory).
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.onOpenVersion = onOpenVersion
        if text != coord.lastText {
            coord.lastText = text
            // PERF (owner: "a bit slow"): the payload build — rust parse +
            // preamble + blob-sha scan + JSON encode — runs OFF-MAIN; the
            // render eval fires when it lands (generation-guarded, so a
            // rapid re-diff never applies a stale payload).
            coord.beginPayloadBuild(text: text)
        }
        coord.push(
            granularity: granularity, isDark: isDark,
            fontSize: fontSize, wrap: wrapLines, nav: showFileNav,
            payloadChanged: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastText: String?
        var lastPayloadJSON: String = "{\"files\":[]}"
        var onOpenVersion: ((String, String, String?) -> Void)?
        /// False until the first off-main payload build lands — didFinish
        /// must not render the placeholder-empty payload.
        private var payloadReady = false
        private var payloadGeneration = 0

        /// Build the page payload off-main (rust parse + preamble + blob scan
        /// are O(diff) and were a felt stall on big commit diffs when they ran
        /// in `updateNSView`). Generation-guarded: only the LATEST text lands.
        func beginPayloadBuild(text: String) {
            payloadGeneration += 1
            let gen = payloadGeneration
            Task.detached(priority: .userInitiated) {
                let json = DiffWebPayload.json(diffText: text)
                await MainActor.run { [weak self] in
                    guard let self, gen == self.payloadGeneration else { return }
                    self.lastPayloadJSON = json
                    self.payloadReady = true
                    if self.documentReady { self.pushPending(payloadChanged: true) }
                }
            }
        }

        /// TSK-1599: `{action:"open", version, path, blob?}` from the page's
        /// file-header buttons. Anything malformed is dropped (the page is
        /// ours, but the bridge stays defensive).
        func receiveBridgeMessage(_ body: Any) {
            guard let dict = body as? [String: Any],
                  dict["action"] as? String == "open",
                  let version = dict["version"] as? String,
                  ["old", "new", "current"].contains(version),
                  let path = dict["path"] as? String, !path.isEmpty
            else { return }
            onOpenVersion?(version, path, dict["blob"] as? String)
        }
        private var documentReady = false
        private var sentGranularity: DiffGranularity?
        private var sentDark: Bool?
        private var sentFontSize: CGFloat?
        private var sentWrap: Bool?
        private var sentNav: Bool?
        /// One retry after a failed verified render (page mid-load races).
        private var retriedRender = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            documentReady = true
            // First push after the page lands — everything is pending. The
            // payload render only fires once the off-main build has landed
            // (otherwise its completion triggers it).
            sentGranularity = nil; sentDark = nil; sentFontSize = nil
            sentWrap = nil; sentNav = nil
            pushPending(payloadChanged: payloadReady)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            documentReady = false
        }

        private var pendingGranularity: DiffGranularity = .default
        private var pendingDark = false
        private var pendingFontSize: CGFloat = 12
        private var pendingWrap = DiffViewPrefs.wrapDefault
        private var pendingNav = DiffViewPrefs.fileNavDefault

        func push(granularity: DiffGranularity, isDark: Bool,
                  fontSize: CGFloat, wrap: Bool, nav: Bool,
                  payloadChanged: Bool) {
            pendingGranularity = granularity
            pendingDark = isDark
            pendingFontSize = fontSize
            pendingWrap = wrap
            pendingNav = nav
            guard documentReady else { return }   // didFinish pushes everything
            pushPending(payloadChanged: payloadChanged)
        }

        private func pushPending(payloadChanged: Bool) {
            guard let webView else { return }
            if sentDark != pendingDark {
                sentDark = pendingDark
                webView.evaluateJavaScript(
                    "window.mdvDiffSetTheme(\(pendingDark ? "true" : "false"))",
                    completionHandler: nil)
            }
            if sentFontSize != pendingFontSize {
                sentFontSize = pendingFontSize
                webView.evaluateJavaScript(
                    "window.mdvDiffSetFontSize(\(Int(pendingFontSize)))",
                    completionHandler: nil)
            }
            if sentWrap != pendingWrap {
                sentWrap = pendingWrap
                webView.evaluateJavaScript(
                    "window.mdvDiffSetWrap(\(pendingWrap ? "true" : "false"))",
                    completionHandler: nil)
            }
            if sentNav != pendingNav {
                sentNav = pendingNav
                webView.evaluateJavaScript(
                    "window.mdvDiffSetNav(\(pendingNav ? "true" : "false"))",
                    completionHandler: nil)
            }
            // No render until the off-main payload build has landed — the
            // placeholder-empty payload would flash "No differences".
            guard payloadReady else { return }
            if payloadChanged || sentGranularity == nil {
                sentGranularity = pendingGranularity
                verifiedRender(
                    js: "window.mdvDiffRender(\(lastPayloadJSON), \"\(pendingGranularity.rawValue)\")")
            } else if sentGranularity != pendingGranularity {
                sentGranularity = pendingGranularity
                verifiedRender(
                    js: "window.mdvDiffSetGranularity(\"\(pendingGranularity.rawValue)\")")
            }
        }

        // (bridge receive lives above; navigation + render below)

        /// Evaluate a render call and VERIFY the returned row count. On error
        /// or a page-reported failure (-1): retry the FULL render once (the
        /// mid-load race), then log loudly — never silently stale (TSK-1587).
        private func verifiedRender(js: String) {
            guard let webView else { return }
            webView.evaluateJavaScript(js) { [weak self] value, error in
                let count = (value as? NSNumber)?.intValue ?? -1
                guard error != nil || count < 0 else {
                    self?.retriedRender = false
                    return
                }
                guard let self else { return }
                if !self.retriedRender {
                    self.retriedRender = true
                    self.verifiedRender(
                        js: "window.mdvDiffRender(\(self.lastPayloadJSON), \"\(self.pendingGranularity.rawValue)\")")
                } else {
                    Obs.shared.emit(
                        .error, "web-diff",
                        "diff render failed after retry: \(error.map(String.init(describing:)) ?? "page returned \(count)")")
                }
            }
        }
    }
}
