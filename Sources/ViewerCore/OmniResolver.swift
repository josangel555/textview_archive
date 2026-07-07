import Foundation

/// TSK-1489 — the new-tab omnibox resolution table: classify one typed (or
/// pasted) string into the action the new-tab launchpad should take. Pure
/// classification by SHAPE + an injected existence check; the view wires
/// the resulting action (open path / open URL / new-tab search / paste).
public enum OmniResolver {

    public enum Action: Equatable, Sendable {
        /// A filesystem path that exists → open it (folder or file).
        case openPath(String, isDirectory: Bool)
        /// An http/https/ftp URL → hand to the browser/feed policy.
        case openURL(String)
        /// A git remote (…/x.git, git@host:…, github.com/o/r) → clone/open flow.
        case gitRemote(String)
        /// Empty input → the launchpad's default (paste target / recents).
        case empty
        /// Anything else → treat as a cross-file search query.
        case search(String)
    }

    /// Classify `raw`. `pathExists(path) -> isDirectory?` returns nil when
    /// the path doesn't exist, else whether it's a directory — injected so
    /// this stays pure/host-testable (production passes a FileManager probe).
    public static func classify(
        _ raw: String,
        pathExists: (String) -> Bool?
    ) -> Action {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }

        // Git remotes first — an scp-style `git@host:o/r` isn't a URL, and a
        // `.git` https URL is a remote, not a page to browse.
        if isGitRemote(trimmed) { return .gitRemote(trimmed) }

        // Web URLs.
        if let scheme = urlScheme(trimmed),
           ["http", "https", "ftp"].contains(scheme) {
            return .openURL(trimmed)
        }

        // Filesystem paths: absolute, ~-relative, or file://.
        if let path = filesystemPath(trimmed) {
            if let isDir = pathExists(path) {
                return .openPath(path, isDirectory: isDir)
            }
            // A path-SHAPED string that doesn't exist still isn't a search;
            // route it as a (missing) path open so the caller can surface a
            // "no such file" rather than silently searching for "/x/y".
            return .openPath(path, isDirectory: false)
        }

        // Everything else: a search query.
        return .search(trimmed)
    }

    // MARK: - Shape helpers

    static func isGitRemote(_ s: String) -> Bool {
        if s.hasPrefix("git@") && s.contains(":") { return true }
        if s.hasSuffix(".git") { return true }
        // Bare host/owner/repo for the common forges.
        for host in ["github.com/", "gitlab.com/", "bitbucket.org/"] {
            if s.hasPrefix(host) || s.hasPrefix("www.\(host)") { return true }
        }
        return false
    }

    /// The URL scheme if `s` is `scheme://…` (lowercased), else nil.
    static func urlScheme(_ s: String) -> String? {
        guard let range = s.range(of: "://"), range.lowerBound != s.startIndex else {
            return nil
        }
        let scheme = s[s.startIndex..<range.lowerBound].lowercased()
        // A scheme is letters/digits/+-.; reject "C:\..." etc.
        guard scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }),
              scheme.first?.isLetter == true else { return nil }
        return scheme
    }

    /// The absolute filesystem path if `s` looks like one (~ expanded,
    /// file:// stripped), else nil.
    static func filesystemPath(_ s: String) -> String? {
        if s.hasPrefix("file://") {
            return String(s.dropFirst("file://".count)).removingPercentEncoding
                ?? String(s.dropFirst("file://".count))
        }
        if s.hasPrefix("/") { return s }
        if s == "~" { return NSHomeDirectory() }
        if s.hasPrefix("~/") {
            return NSHomeDirectory() + String(s.dropFirst(1))
        }
        return nil
    }
}
