import Foundation

/// TSK-1189 — the GATE for "trust this local HTML" render mode.
/// See `docs/research/html-trust-mode-2026-06-20/`.
///
/// A *trusted* document is allowed to run its OWN scripts — the renderer's
/// L1/L2/L3 relaxation (keep `<script>`, enable JS, loosen CSP `script-src`)
/// keys **solely** off `isTrusted`; everything untrusted keeps the full hardened
/// path unchanged. The decision is **pure and FAIL-CLOSED** so the
/// regression-critical "is this safe to run" question is host-testable and can't
/// be accidentally inverted. The anti-exfiltration fence (remote sub-resources
/// cancelled, `file:` fenced to the doc directory, `connect-src 'none'`,
/// no universal/file-URL access) is NEVER relaxed — see `HTMLDocumentPolicy`.
public enum HTMLTrustPolicy {

    /// Is `url` even ELIGIBLE for trust? Necessary, not sufficient — eligibility
    /// gates whether the "Trust & Run" affordance is offered at all. Fail-closed:
    ///   * non-`file:` / remote (`http(s)`, custom schemes) / `nil` ⇒ never
    ///     eligible. Remote content can NEVER be trusted.
    ///   * quarantined (`com.apple.quarantine` — downloaded/received from outside)
    ///     ⇒ not eligible; the user must knowingly de-quarantine outside the app.
    /// Local, author-controlled files are eligible.
    public static func isTrustEligible(url: URL?, isQuarantined: Bool) -> Bool {
        guard let url, url.isFileURL else { return false }
        return !isQuarantined
    }

    /// Effective trust for a document: eligible AND the user has explicitly opted
    /// THIS document in. Fail-closed — any uncertainty ⇒ `false` ⇒ the untrusted
    /// hardened path. This is the single predicate the renderer's relaxation
    /// switches on.
    public static func isTrusted(
        url: URL?, isQuarantined: Bool, userOptedIn: Bool
    ) -> Bool {
        userOptedIn && isTrustEligible(url: url, isQuarantined: isQuarantined)
    }

    /// Canonical key for a document's trust opt-in: the standardized,
    /// symlink-resolved absolute path. Trusting one path never trusts another
    /// (no wildcards, no directory-wide trust) — same standardization the
    /// sub-resource fence (`HTMLDocumentPolicy.isWithinDocumentTree`) uses.
    public static func trustKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Per-document trust opt-in persistence (TSK-1189). Default OFF; explicit,
/// per-path, and revocable. Backed by `UserDefaults` so a trust survives reopen
/// but stays scoped to the EXACT file the user trusted — trusting A never trusts
/// a sibling B.
public final class HTMLTrustStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    static let storageKey = "MarkdownViewer.html.trustedPaths"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func trustedSet() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    /// Has the user opted THIS document in? Path-keyed; default `false`.
    public func isOptedIn(url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return trustedSet().contains(HTMLTrustPolicy.trustKey(for: url))
    }

    /// Set or clear the per-document trust opt-in.
    public func setOptedIn(_ optedIn: Bool, url: URL) {
        lock.lock(); defer { lock.unlock() }
        var set = trustedSet()
        let key = HTMLTrustPolicy.trustKey(for: url)
        if optedIn { set.insert(key) } else { set.remove(key) }
        defaults.set(Array(set).sorted(), forKey: Self.storageKey)
    }
}

/// Per-document NETWORK consent (TSK-1203) — a SECOND, separate escalation
/// BEYOND trust: a trusted page's `connect-src` stays `'none'` until the user
/// explicitly allows specific hosts for THAT page. Default empty; per-path;
/// revocable. Only meaningful for a page that is ALSO trusted — the CSP builder
/// ignores consented hosts for an untrusted document — so this can never widen an
/// untrusted page's fence. Same path-keying + persistence shape as `HTMLTrustStore`.
public final class HTMLNetworkConsentStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    static let storageKey = "MarkdownViewer.html.networkConsent"   // [trustKey: [host]]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func map() -> [String: [String]] {
        (defaults.dictionary(forKey: Self.storageKey) as? [String: [String]]) ?? [:]
    }

    /// The https hosts the user consented to for THIS document (sorted, deduped).
    public func allowedHosts(for url: URL) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return map()[HTMLTrustPolicy.trustKey(for: url)] ?? []
    }

    /// Consent to `host` for THIS document. Only hosts that validate as a bare
    /// https origin are stored (the CSP builder re-validates as defence-in-depth).
    /// A no-op for an invalid host. Returns whether the host was accepted.
    @discardableResult
    public func allow(host: String, for url: URL) -> Bool {
        guard HTMLDocumentPolicy.connectSource(forHost: host) != nil else { return false }
        let normalized = host.trimmingCharacters(in: .whitespaces).lowercased()
        lock.lock(); defer { lock.unlock() }
        var m = map()
        let key = HTMLTrustPolicy.trustKey(for: url)
        var hosts = Set(m[key] ?? [])
        hosts.insert(normalized)
        m[key] = Array(hosts).sorted()
        defaults.set(m, forKey: Self.storageKey)
        return true
    }

    /// Revoke ALL network consent for THIS document (the fence returns to `'none'`).
    public func revokeAll(for url: URL) {
        lock.lock(); defer { lock.unlock() }
        var m = map()
        m.removeValue(forKey: HTMLTrustPolicy.trustKey(for: url))
        defaults.set(m, forKey: Self.storageKey)
    }
}

/// Side-effecting quarantine probe (TSK-1189). The pure gate
/// (`HTMLTrustPolicy.isTrustEligible`) takes the result as a `Bool` so it stays
/// testable; this reads the actual xattr. A file carrying `com.apple.quarantine`
/// was downloaded/received from outside and is NOT trust-eligible.
public enum FileQuarantine {
    public static func isQuarantined(path: String) -> Bool {
        // getxattr with a zero-size buffer returns the attr length if present,
        // -1 (errno ENOATTR) if absent.
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}
