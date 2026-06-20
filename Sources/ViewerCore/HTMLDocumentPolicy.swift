import Foundation

/// SECURITY POLICY for rendering raw `.html` files (NOT our own
/// generated markdown HTML — that is `HTMLRenderer` + `MarkdownRenderedView`,
/// which deliberately allows API-injected JS for find/mermaid).
///
/// An `.html` file is **untrusted, author-controlled, full-document
/// input**. Opening one is two attack surfaces at once:
///
///   1. **HTML / script injection** — the document can carry `<script>`,
///      inline event handlers, `javascript:` URLs, `<meta http-equiv
///      refresh>`, `<base>` retargeting, etc.
///   2. **Local file read / exfiltration** — a `file://` document can
///      pull sibling/parent files as sub-resources (`<img src>`,
///      `<link>`, fetch), or beacon their contents to a remote origin.
///
/// The defenses are layered defense-in-depth; **no single layer is
/// trusted alone**:
///
///   L0  Render-size cap. Mirror `markdownRenderMaxBytes` — never slurp
///       a multi-MB document into the WebContent process (`shouldRender`).
///   L1  Sanitizer allowlist. The document is routed through
///       `HTMLSanitizer.sanitize` before it ever reaches the WebView —
///       drops `<script>/<style>/<iframe>/<object>/<embed>/<form>/…`,
///       strips `on*=` handlers, neutralizes `javascript:`/`vbscript:`/
///       `data:text/html` URLs (`sanitize`).
///   L2  JavaScript DEFAULT-DENY. The `WKWebView` is configured with
///       `allowsContentJavaScript = false` unless the user has flipped
///       the explicit PER-TAB opt-in. There is **no** code path that
///       defaults JS on (`javaScriptEnabled`).
///   L3  No remote sub-resources + no `file://` beyond the document
///       itself. Enforced two ways: a strict CSP envelope (`cspMetaTag`,
///       `default-src 'none'`) injected into the document `<head>`, AND
///       a `WKNavigationDelegate` policy (`decideSubresource`) that
///       cancels any non-self navigation/sub-resource load.
///   L4  Link clicks route to the system browser (http/https/mailto)
///       or are cancelled; in-page `file:`/`data:`/`javascript:`
///       navigations are cancelled (`decideLink`).
///
/// Everything here is a **pure value/function** so the regression-
/// critical decisions are unit-testable headless — the live `WKWebView`
/// is the small visual residue, not where the policy lives.
public enum HTMLDocumentPolicy {

    // MARK: - L0: render-size cap

    /// Maximum byte size of an `.html` file we will route into the
    /// WebContent process. Mirrors `markdownRenderMaxBytes` (4 MB):
    /// the sanitizer pass + envelope + DOM materialization transiently
    /// allocate several multiples of the input, and an attacker-supplied
    /// multi-hundred-MB HTML file would otherwise pin the WebContent
    /// process. Above the cap the view shows a "view as source"
    /// placeholder — no rendering attempted.
    public static let renderMaxBytes: Int = markdownRenderMaxBytes

    /// L0 gate. `true` iff a document of `byteCount` bytes is within the
    /// render cap. Pure so the size-cap fork is testable without a file.
    public static func shouldRender(byteCount: Int) -> Bool {
        byteCount <= renderMaxBytes
    }

    // MARK: - L1: sanitizer

    /// Route the raw document through the allowlist sanitizer. Thin
    /// wrapper over `HTMLSanitizer.sanitize` so the HTML-file render
    /// path has a single named entry point (and so the policy's
    /// "always sanitize" contract is pinned by one test target).
    public static func sanitize(_ rawHTML: String, trusted: Bool = false) -> String {
        HTMLSanitizer.sanitize(rawHTML, trusted: trusted)
    }

    /// Diagnostic (TSK-1189, host-testable seam): does this raw `.html`
    /// document depend on script execution that the render path SUPPRESSES?
    ///
    /// The raw-HTML render path strips `<script>` (L1 sanitizer) and serves
    /// `script-src 'none'` with JS default-deny (L2/L3). For a plain
    /// document that's invisible. For a JS-DRIVEN bundled app (e.g. a
    /// self-contained single-file web app whose body is just a mount point a
    /// runtime fills in), the result is a partial / blank render — the page
    /// never paints because its own code never runs.
    ///
    /// This pure predicate lets the UI tell the two apart so it can surface an
    /// honest explanation ("this page's scripts were removed for safety")
    /// instead of a silently-broken render, and — once the owner approves the
    /// trust boundary — offer a per-document "run this page" opt-in. It does
    /// NOT change any rendering behavior on its own; it is a detector only.
    ///
    /// Heuristic (conservative — false POSITIVES are cheap, they just over-
    /// offer the explanation; false negatives leave the status quo): a `<script>`
    /// tag present in the RAW source whose contents the sanitizer drops. We sniff
    /// the raw bytes case-insensitively for an opening `<script` token; we do not
    /// parse, so an inert `<script type="application/json">` data island also
    /// trips it — acceptable for a "this page may need JS" hint.
    public static func dependsOnSuppressedScript(_ rawHTML: String) -> Bool {
        rawHTML.range(of: "<script", options: [.caseInsensitive]) != nil
    }

    // MARK: - L2: JavaScript default-deny

    /// The JS-enabled state for a given per-tab opt-in flag. There is
    /// exactly one source of truth: JS is on **iff** the user explicitly
    /// opted that tab in. The default (no opt-in recorded) is `false`.
    /// Exposed as an identity-ish helper so callers can't accidentally
    /// invert the default — and so the "default is OFF" invariant is a
    /// named, tested contract rather than an inline ternary.
    public static func javaScriptEnabled(tabOptedIn: Bool) -> Bool {
        tabOptedIn
    }

    // MARK: - L3: CSP envelope + sub-resource policy

    /// The Content-Security-Policy applied to a rendered raw-HTML
    /// document, as the value for an injected
    /// `<meta http-equiv="Content-Security-Policy">`.
    ///
    /// `default-src 'none'` is the backstop: nothing loads unless an
    /// explicit directive re-permits it. We permit only:
    ///   * `img-src file: data:` — inline data URIs + same-tree local
    ///     images (the WebView's own `file://` access is *additionally*
    ///     fenced to the document's directory by the navigation policy).
    ///   * `style-src 'unsafe-inline'` + `font-src data:` — the document's
    ///     own `<style>` is dropped by the sanitizer, but inline
    ///     `style=` attributes survive and need this.
    ///   * `script-src 'none'` (implied by default-src) — even when the
    ///     per-tab JS opt-in is ON, the *page's own* `<script>` tags are
    ///     already stripped by the sanitizer; the opt-in only re-enables
    ///     the WebView's JS engine for already-present inline handlers
    ///     the user knowingly wants. We do NOT loosen script-src.
    ///   * `connect-src 'none'`, `frame-src 'none'`, `object-src 'none'`,
    ///     `base-uri 'none'`, `form-action 'none'` — block beacons,
    ///     framed remote content, plugins, `<base>` retargeting, and
    ///     form posts respectively.
    ///
    /// Note this is byte-compatible in spirit with `HTMLRenderer`'s
    /// markdown CSP; kept as its own constant so the two can diverge
    /// (the HTML path may tighten further) without cross-coupling.
    public static let csp: String =
        "default-src 'none'; img-src file: data:; style-src 'unsafe-inline'; "
        + "font-src data:; connect-src 'none'; frame-src 'none'; "
        + "object-src 'none'; base-uri 'none'; form-action 'none';"

    /// The `<meta>` tag carrying the CSP, ready to splice into `<head>`.
    public static var cspMetaTag: String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
    }

    /// TSK-1189 — CSP for a TRUSTED local document. Relaxes `script-src` to run
    /// the page's OWN scripts (`'self' 'unsafe-inline' 'unsafe-eval'` — bundled
    /// apps use all three) but KEEPS the anti-exfiltration fence UNCHANGED:
    /// `connect-src 'none'` (no beacon/fetch — the page renders but cannot phone
    /// home), plus `object/frame/base/form-action 'none'` and local+inline
    /// img/style/font. `trusted == false` returns the strict `csp` constant
    /// byte-for-byte. A trusted page is a local web page, NOT an exfiltrator.
    public static func cspString(trusted: Bool) -> String {
        guard trusted else { return csp }
        return "default-src 'none'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; "
            + "img-src file: data:; style-src 'unsafe-inline'; font-src data:; "
            + "connect-src 'none'; frame-src 'none'; object-src 'none'; "
            + "base-uri 'none'; form-action 'none';"
    }

    /// The `<meta>` CSP tag for the given trust level.
    public static func cspMeta(trusted: Bool) -> String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(cspString(trusted: trusted))\">"
    }

    /// Outcome of a sub-resource / navigation policy decision for the
    /// raw-HTML WebView. Pure value so the navigation delegate has a
    /// testable kernel.
    public enum LoadDecision: Equatable, Sendable {
        /// Permit the load (the document itself, or an allowed local
        /// image inside the document's own directory).
        case allow
        /// Block the load (remote sub-resource, out-of-tree `file://`,
        /// dangerous scheme, in-page script escape).
        case cancel
        /// A user-activated link to a browser-routable scheme — hand to
        /// the system browser, cancel in-WebView.
        case openExternally(URL)
    }

    /// Decide a NON-link (sub-resource / programmatic / `.other`)
    /// navigation. This is the L3 enforcement that, together with the
    /// CSP, guarantees "no remote sub-resource loads, no `file://`
    /// beyond the document itself".
    ///
    /// Rules:
    ///   * The bootstrap document load (`documentURL == nil` initial
    ///     `loadFileURL`/`loadHTMLString`) is allowed — otherwise the
    ///     page never renders. Identified by `isInitialDocumentLoad`.
    ///   * `http`/`https`/`ws`/`wss`/`ftp` sub-resources → **cancel**.
    ///     No remote loads, period.
    ///   * `javascript:`/`vbscript:`/`data:` → **cancel** for any
    ///     non-initial navigation (in-page script escape / data-URL
    ///     document swap).
    ///   * `file:` → allowed **only** if the target is inside the
    ///     document's own directory subtree (`isWithinDocumentTree`).
    ///     A `file:///etc/passwd` pull from a doc in `/tmp/site/` is
    ///     cancelled.
    ///   * Anything else → cancel.
    ///
    /// - Parameters:
    ///   - url: the navigation target.
    ///   - documentURL: the `file://` URL of the rendered document
    ///     (its directory is the allowed sub-resource root). `nil`
    ///     before the document is established.
    ///   - isInitialDocumentLoad: `true` for the bootstrap load only.
    public static func decideSubresource(
        url: URL?,
        documentURL: URL?,
        isInitialDocumentLoad: Bool
    ) -> LoadDecision {
        // The bootstrap load that paints the document is always allowed.
        if isInitialDocumentLoad { return .allow }
        guard let url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https", "ws", "wss", "ftp", "ftps":
            // No remote sub-resource loads — exfil + tracking surface.
            return .cancel
        case "javascript", "vbscript", "data":
            // In-page script escape / data-URL document swap.
            return .cancel
        case "file":
            // Local file access fenced to the document's own directory.
            return isWithinDocumentTree(url, documentURL: documentURL)
                ? .allow : .cancel
        case "about":
            // about:blank etc. are inert; permit (WKWebView uses them
            // internally and they expose nothing).
            return .allow
        default:
            return .cancel
        }
    }

    // MARK: - L4: link-click policy

    /// Decide a user-activated link click. Mirrors the markdown view's
    /// posture: browser-routable schemes open externally; everything
    /// else (including same-tree `file:` link clicks, which would
    /// navigate the WebView away from the sandboxed document) is
    /// cancelled. Same-document `#fragment` clicks are allowed so
    /// in-page anchors work.
    public static func decideLink(
        url: URL?,
        documentURL: URL?
    ) -> LoadDecision {
        guard let url else { return .cancel }
        if URLFragmentPolicy.isSameDocument(url, as: documentURL) {
            return .allow
        }
        switch url.scheme?.lowercased() ?? "" {
        case "http", "https", "mailto":
            return .openExternally(url)
        default:
            // file:, data:, javascript:, vbscript:, custom schemes — all
            // cancelled. A user click must never navigate the WebView to
            // another local file (that would escape the sandboxed doc).
            return .cancel
        }
    }

    // MARK: - Helpers

    /// `true` iff `url` is a `file://` URL whose resolved path lies at
    /// or below the directory containing `documentURL`. This is the
    /// "no `file://` beyond the doc itself" fence: a local image next
    /// to the HTML loads; a traversal to `../../secrets` or an absolute
    /// `/etc/passwd` does not.
    ///
    /// Path comparison is done on standardized (symlink-and-`..`-
    /// resolved) absolute paths with a trailing-separator guard so that
    /// `/tmp/site` does NOT match a sibling `/tmp/site-secrets`.
    public static func isWithinDocumentTree(
        _ url: URL,
        documentURL: URL?
    ) -> Bool {
        guard url.isFileURL,
              let documentURL, documentURL.isFileURL else { return false }
        // Allow the document loading itself.
        let docStd = documentURL.standardizedFileURL.resolvingSymlinksInPath()
        let urlStd = url.standardizedFileURL.resolvingSymlinksInPath()
        if urlStd.path == docStd.path { return true }
        var dir = docStd.deletingLastPathComponent().path
        if !dir.hasSuffix("/") { dir += "/" }
        let target = urlStd.path
        // Reject a bare prefix that isn't a real path-segment boundary
        // (`/a/site` must not match `/a/site-secret/x`); the trailing
        // slash on `dir` enforces the boundary.
        return target.hasPrefix(dir)
    }

    // MARK: - Document envelope

    /// Wrap a *sanitized* HTML body in the policy envelope: charset +
    /// CSP meta + viewport. We always inject our own `<head>` CSP rather
    /// than trusting any CSP the document declared (an attacker controls
    /// the document, so its self-declared CSP is meaningless).
    ///
    /// `sanitizedBody` MUST already have passed through `sanitize`. This
    /// function does not re-sanitize (single-responsibility) — but it is
    /// the only supported way to build the load string, so the call site
    /// always sanitizes first.
    ///
    /// We deliberately do NOT attempt to parse the document and surgically
    /// insert into an existing `<head>`: ViewerCore has no DOM. Wrapping
    /// is robust — the browser merges our injected `<head>` metadata with
    /// any `<head>` the (sanitized) document also carries, and the CSP
    /// `<meta>` is honored as long as it appears before the content it
    /// governs. We prepend it.
    public static func envelope(sanitizedBody: String, trusted: Bool = false) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        \(cspMeta(trusted: trusted))
        <meta name="viewport" content="width=device-width, initial-scale=1">
        </head>
        <body>
        \(sanitizedBody)
        </body>
        </html>
        """
    }
}
