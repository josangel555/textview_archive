import Foundation

/// SECURITY POLICY for the built-in **localhost browser tab** (epic
/// TSK-676). Unlike `HTMLDocumentPolicy` — which sandboxes an *untrusted
/// author-controlled `.html` file* — this policy governs a real
/// `WKWebView` browsing a **live HTTP origin the user typed**, and the
/// whole point is to LOCK that browsing to loopback: a Jupyter server, a
/// local dev tool, `http://localhost:8787`, etc. ("dangerously load
/// websites" is the off switch, gated elsewhere; this is the default-safe
/// allowlist).
///
/// The threat model: a localhost page is generally trusted by the user,
/// but
///   1. it must not be able to **navigate the tab away** to an arbitrary
///      remote origin (a drive-by `window.location = 'https://evil.com'`
///      or a malicious redirect turns the loopback tab into a full
///      uncontrolled browser), and
///   2. it must never reach the local filesystem via `file://` (sibling-
///      file read / exfil — same class the `HTMLDocumentPolicy` fences).
///
/// What it deliberately does NOT do: it does not sanitize content, inject
/// a CSP, or disable JS — a localhost dev server is a first-party origin
/// the user chose to load, so JS is on and the page renders normally.
/// 3rd-party cookie blocking and the ATS loopback exception are
/// `WKWebViewConfiguration`/`WKWebsiteDataStore` concerns wired in the
/// (separate, VM-validated) WebKit slice — NOT pure URL logic, so they
/// live there, not here.
///
/// Everything in this enum is a **pure function of a `URL`** so the
/// regression-critical allow/cancel decisions are unit-testable headless;
/// the live `WKNavigationDelegate` is a thin shell that forwards to
/// `decideTopLevel` / `decideSubresource` and maps the result onto
/// `WKNavigationActionPolicy`.
public enum BrowserNavigationPolicy {

    /// Outcome of a navigation policy decision. Mirrors
    /// `HTMLDocumentPolicy.LoadDecision`'s `allow`/`cancel` shape (this
    /// policy has no "open externally" — there is no system-browser
    /// hand-off for a locked localhost tab; an off-host nav is simply
    /// cancelled).
    public enum LoadDecision: Equatable, Sendable {
        /// Permit the load (a loopback origin, or — in permissive mode —
        /// an off-host sub-resource).
        case allow
        /// Block the load (off-host top-level nav, `file://`, dangerous
        /// scheme, or an off-host sub-resource in strict mode).
        case cancel
    }

    // MARK: - Top-level navigation

    /// The URL schemes a **top-level** navigation may use. A locked
    /// localhost tab browses HTTP(S) origins and may upgrade to a
    /// WebSocket-style document load; anything else (`file:`, `data:`,
    /// `javascript:`, `about:` swaps, custom schemes, `ftp:`) is rejected
    /// at the top level.
    public static let topLevelSchemes: Set<String> = ["http", "https", "ws", "wss"]

    /// Decide a **top-level** navigation (the tab navigating to a new
    /// document — address-bar entry, link click that replaces the page,
    /// `window.location`, a server redirect). This is the core allowlist:
    /// **allow iff the target is a loopback host on an HTTP(S)/WS(S)
    /// scheme; cancel everything else, including every `file://`.**
    ///
    /// Rules:
    ///   * scheme ∉ {http, https, ws, wss}  → **cancel**  (covers
    ///     `file:`, `data:`, `javascript:`, `about:`, `ftp:`, custom).
    ///   * host is not loopback             → **cancel**  (off-host
    ///     remote origin — the drive-by-redirect escape).
    ///   * loopback host + allowed scheme   → **allow**   (any port).
    ///
    /// - Parameter url: the navigation target. `nil` → cancel (no target
    ///   to validate; the live delegate also gets `nil` for opaque
    ///   actions and must fail closed).
    public static func decideTopLevel(url: URL?) -> LoadDecision {
        guard let url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        guard topLevelSchemes.contains(scheme) else { return .cancel }
        return isLoopbackHost(url) ? .allow : .cancel
    }

    // MARK: - Sub-resource navigation

    /// Decide a **sub-resource** load (an `<img>`/`<link>`/`<script>`/
    /// `fetch`/XHR the page pulls — `WKNavigationType.other` /
    /// non-main-frame). This is design-question 2.2 in
    /// `docs/FEATURE_EXPLORATION_2026-06-16.md` §2 — "may a localhost page
    /// pull sub-resources from off-host (CDN scripts/fonts)?":
    ///
    ///   * **strict** (`permissive == false`) — block ALL off-host
    ///     sub-resources. Tightest: nothing leaves the loopback origin, so
    ///     no CDN tracking / exfil surface, but it breaks apps that load a
    ///     `cdn.jsdelivr.net` bundle or a Google Font.
    ///   * **permissive** (`permissive == true`) — the usual safe middle:
    ///     **allow** off-host sub-resources (CDN scripts/fonts), while the
    ///     *top-level* allowlist still blocks navigating the tab AWAY from
    ///     loopback. The page can fetch its dependencies but can't be
    ///     hijacked to a remote document.
    ///
    /// In BOTH modes, loopback sub-resources are allowed and `file://`
    /// (plus other non-network schemes) are **always cancelled** — the
    /// permissive switch only ever relaxes off-host *network* fetches,
    /// never local-file access.
    ///
    /// - Parameters:
    ///   - url: the sub-resource target. `nil` → cancel.
    ///   - permissive: `false` = strict (loopback only); `true` = allow
    ///     off-host network sub-resources.
    public static func decideSubresource(url: URL?, permissive: Bool) -> LoadDecision {
        guard let url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https", "ws", "wss":
            if isLoopbackHost(url) { return .allow }       // same loopback origin
            return permissive ? .allow : .cancel           // off-host CDN fetch
        case "data", "about":
            // Inline data URIs and inert about: pages are not network or
            // file access; permit so data-URL images / about:blank frames
            // the page legitimately uses render. (`data:` documents at the
            // TOP level are still blocked by `decideTopLevel`.)
            return .allow
        default:
            // file:, javascript:, vbscript:, ftp:, custom — never. The
            // permissive switch does not unlock local-file or script
            // schemes.
            return .cancel
        }
    }

    // MARK: - Helpers

    /// `true` iff `url`'s host is a loopback address: `localhost` (with an
    /// optional trailing dot, case-insensitive), any `127.0.0.0/8` IPv4
    /// (the *entire* block is loopback, not just `127.0.0.1`), or the IPv6
    /// loopback `::1` / `[::1]`.
    ///
    /// `URL.host` strips the IPv6 bracketing, so a `[::1]` authority is
    /// reported as `::1`; we accept both forms defensively. The 127/8
    /// check is segment-aware so `127.0.0.1.evil.com` (host
    /// `"127.0.0.1.evil.com"`) does NOT match.
    public static func isLoopbackHost(_ url: URL) -> Bool {
        guard let rawHost = url.host, !rawHost.isEmpty else { return false }
        return isLoopbackHostName(rawHost)
    }

    /// Host-string form of `isLoopbackHost`, factored out so the matcher
    /// is testable on bare host strings independent of `URL` parsing.
    public static func isLoopbackHostName(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        // A fully-qualified `localhost.` carries a trailing dot.
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return false }

        if host == "localhost" { return true }
        // IPv6 loopback — `URL.host` drops the brackets, but accept the
        // bracketed form too for callers passing a raw authority.
        if host == "::1" || host == "[::1]" { return true }
        // IPv4 loopback block 127.0.0.0/8.
        return isLoopbackIPv4(host)
    }

    /// `true` iff `host` is a dotted-quad in `127.0.0.0/8`. Strict: exactly
    /// four numeric octets, each 0...255, first == 127. Rejects
    /// `127.0.0.1.evil.com`, `1270.0.0.1`, and `127.0.0.256`.
    private static func isLoopbackIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            // Reject empty / non-numeric / out-of-range / leading-sign forms.
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isNumber }),
                  let value = Int(part), value >= 0, value <= 255 else {
                return false
            }
            octets.append(value)
        }
        return octets[0] == 127
    }
}
