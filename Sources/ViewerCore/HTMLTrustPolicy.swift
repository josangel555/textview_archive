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
