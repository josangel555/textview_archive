import Foundation

/// A git remote URL parsed into a structured *forge identity* — the host,
/// owner (namespace), repository name, and a best-effort guess at which
/// hosting provider it is. From that identity we derive the canonical web
/// URLs a "GitHub / code review" surface needs: the repo page, a specific
/// commit, a branch, a tree path, a pull/merge request, an issue, and a
/// file-at-line permalink.
///
/// Foundation slice for the GitHub integration (TSK-346). Pure logic, no
/// `AppKit`/`SwiftUI` — fully host-testable. The UI layer's ad-hoc
/// `GitRemotesTab.webURL(from:)` now delegates here so the ssh→https
/// translation lives in one tested place.
///
/// The three remote shapes git produces, all handled:
/// - `https://github.com/owner/repo(.git)?`
/// - `git@github.com:owner/repo(.git)?`  (scp-style)
/// - `ssh://git@github.com/owner/repo(.git)?`
///
/// Deeper namespaces (e.g. GitLab subgroups `group/sub/repo`) keep their
/// full path: `owner` becomes everything before the final segment and
/// `repo` is the final segment.
public struct ForgeRemote: Equatable, Sendable {
    /// The recognised hosting providers. `generic` is any host we don't
    /// have a tailored URL scheme for — it still parses and produces a
    /// repo URL, but PR/issue paths are GitHub-shaped on a best-effort
    /// basis (they are correct for the dominant case).
    public enum Provider: String, Equatable, Sendable {
        case gitHub
        case gitLab
        case bitbucket
        case generic
    }

    /// The hosting host, e.g. `github.com`, `gitlab.com`, `git.example-forge.com`.
    public let host: String
    /// The namespace before the final path segment, e.g. `foo` in
    /// `foo/bar`, or `group/sub` in `group/sub/repo`.
    public let owner: String
    /// The final path segment, with any trailing `.git` stripped.
    public let repo: String
    /// Best-effort provider classification from `host`.
    public let provider: Provider

    public init(host: String, owner: String, repo: String, provider: Provider) {
        self.host = host
        self.owner = owner
        self.repo = repo
        self.provider = provider
    }

    /// `owner/repo` (or `group/sub/repo`) — the path portion of every URL.
    public var fullName: String { "\(owner)/\(repo)" }

    // MARK: - Parsing

    /// Parse a raw git remote string. Returns `nil` for unsupported
    /// schemes (e.g. `file://`, a bare local path) or a malformed URL with
    /// no `owner/repo` pair.
    public static func parse(_ remote: String) -> ForgeRemote? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // host + "owner/.../repo" path, scheme-independent once extracted.
        let host: String
        let path: String

        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            guard let (h, p) = splitHostPath(afterScheme: trimmed) else { return nil }
            host = h
            path = p
        } else if trimmed.hasPrefix("ssh://") {
            // ssh://[git@]host[:port]/owner/repo
            var rest = Substring(trimmed.dropFirst("ssh://".count))
            if let at = rest.firstIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = stripPort(String(rest[..<slash]))
            path = String(rest[rest.index(after: slash)...])
        } else if trimmed.hasPrefix("git@") || isScpStyle(trimmed) {
            // scp-style: [user@]host:owner/repo
            let body = trimmed.hasPrefix("git@")
                ? String(trimmed.dropFirst("git@".count))
                : trimmed
            // strip any non-git user@ prefix on scp-style
            let afterUser: String
            if !trimmed.hasPrefix("git@"), let at = body.firstIndex(of: "@") {
                afterUser = String(body[body.index(after: at)...])
            } else {
                afterUser = body
            }
            guard let colon = afterUser.firstIndex(of: ":") else { return nil }
            host = String(afterUser[..<colon])
            path = String(afterUser[afterUser.index(after: colon)...])
        } else {
            return nil
        }

        return make(host: host, rawPath: path)
    }

    /// Split `scheme://[user@]host[:port]/path` into host (port-stripped)
    /// and path, given the full string still carrying its scheme.
    private static func splitHostPath(afterScheme s: String) -> (String, String)? {
        guard let schemeRange = s.range(of: "://") else { return nil }
        var rest = Substring(s[schemeRange.upperBound...])
        if let at = rest.firstIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = stripPort(String(rest[..<slash]))
        let path = String(rest[rest.index(after: slash)...])
        return (host, path)
    }

    /// `host:port` → `host`. Leaves a bare host untouched.
    private static func stripPort(_ host: String) -> String {
        guard let colon = host.firstIndex(of: ":") else { return host }
        return String(host[..<colon])
    }

    /// Heuristic for scp-style (`host:owner/repo`) without a `git@` prefix:
    /// has a `:` whose right side is NOT a port number (i.e. not pure
    /// digits) and there is no `://` scheme. Guards against treating a
    /// `host:1234` authority as scp-style.
    private static func isScpStyle(_ s: String) -> Bool {
        guard !s.contains("://"), let colon = s.firstIndex(of: ":") else { return false }
        let after = s[s.index(after: colon)...]
        // a port is all digits up to an optional following slash
        let firstSeg = after.prefix { $0 != "/" }
        return !(!firstSeg.isEmpty && firstSeg.allSatisfy { $0.isNumber })
    }

    /// Build from a host and a raw path, normalising the path (strip a
    /// leading slash, a trailing `.git`, and any trailing slash) and
    /// splitting into owner/repo.
    private static func make(host: String, rawPath: String) -> ForgeRemote? {
        guard !host.isEmpty else { return nil }
        var path = rawPath
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        guard !path.isEmpty else { return nil }

        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2 else { return nil }
        let repo = String(segments.last!)
        let owner = segments.dropLast().joined(separator: "/")
        guard !owner.isEmpty, !repo.isEmpty else { return nil }

        return ForgeRemote(
            host: host,
            owner: owner,
            repo: repo,
            provider: provider(forHost: host)
        )
    }

    /// Classify a host into a provider from the canonical SaaS hosts plus
    /// obvious enterprise sub-/sibling-domain patterns
    /// (`github.<corp>` / `<corp>.github.com`). Self-hosted instances we
    /// can't fingerprint stay `.generic` — which still yields a correct
    /// repo URL and GitHub-shaped PR/issue paths (the dominant case).
    static func provider(forHost host: String) -> Provider {
        let h = host.lowercased()
        if h == "github.com" || h.hasSuffix(".github.com") || h.hasPrefix("github.") {
            return .gitHub
        }
        if h == "gitlab.com" || h.hasSuffix(".gitlab.com") || h.hasPrefix("gitlab.") {
            return .gitLab
        }
        if h == "bitbucket.org" || h.hasSuffix(".bitbucket.org") || h.hasPrefix("bitbucket.") {
            return .bitbucket
        }
        return .generic
    }

    // MARK: - Derived web URLs

    /// `https://host/owner/repo` — the repository landing page.
    public var webURL: URL? {
        URL(string: "https://\(host)/\(fullName)")
    }

    /// Permalink to a single commit.
    /// GitHub/generic: `…/commit/<sha>`; GitLab: `…/-/commit/<sha>`;
    /// Bitbucket: `…/commits/<sha>`.
    public func commitURL(_ sha: String) -> URL? {
        let s = encode(sha)
        switch provider {
        case .gitLab:    return base("/-/commit/\(s)")
        case .bitbucket: return base("/commits/\(s)")
        case .gitHub, .generic: return base("/commit/\(s)")
        }
    }

    /// A branch (or any ref) view.
    /// GitHub/generic: `…/tree/<ref>`; GitLab: `…/-/tree/<ref>`;
    /// Bitbucket: `…/branch/<ref>`.
    public func branchURL(_ ref: String) -> URL? {
        let r = encodePath(ref)
        switch provider {
        case .gitLab:    return base("/-/tree/\(r)")
        case .bitbucket: return base("/branch/\(r)")
        case .gitHub, .generic: return base("/tree/\(r)")
        }
    }

    /// A pull request (GitHub/Bitbucket) / merge request (GitLab) by number.
    public func pullRequestURL(_ number: Int) -> URL? {
        switch provider {
        case .gitLab:    return base("/-/merge_requests/\(number)")
        case .bitbucket: return base("/pull-requests/\(number)")
        case .gitHub, .generic: return base("/pull/\(number)")
        }
    }

    /// An issue by number.
    public func issueURL(_ number: Int) -> URL? {
        switch provider {
        case .gitLab:    return base("/-/issues/\(number)")
        case .gitHub, .bitbucket, .generic: return base("/issues/\(number)")
        }
    }

    /// A permalink to a file at a ref, optionally anchored to a line.
    /// GitHub/generic: `…/blob/<ref>/<path>#L<n>`;
    /// GitLab: `…/-/blob/<ref>/<path>#L<n>`;
    /// Bitbucket: `…/src/<ref>/<path>#lines-<n>`.
    public func fileURL(ref: String, path filePath: String, line: Int? = nil) -> URL? {
        let r = encodePath(ref)
        let p = encodePath(filePath)
        let lineFragment: String
        if let line {
            lineFragment = provider == .bitbucket ? "#lines-\(line)" : "#L\(line)"
        } else {
            lineFragment = ""
        }
        switch provider {
        case .gitLab:    return base("/-/blob/\(r)/\(p)\(lineFragment)")
        case .bitbucket: return base("/src/\(r)/\(p)\(lineFragment)")
        case .gitHub, .generic: return base("/blob/\(r)/\(p)\(lineFragment)")
        }
    }

    private func base(_ suffix: String) -> URL? {
        URL(string: "https://\(host)/\(fullName)\(suffix)")
    }

    /// Percent-encode a single path component (a sha or number) — they
    /// shouldn't contain reserved chars, but be defensive.
    private func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// Percent-encode a path that may legitimately contain `/` (a ref like
    /// `feature/x`, or a nested file path) — `.urlPathAllowed` keeps the
    /// slashes.
    private func encodePath(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
