import Foundation

/// TSK-1572 — the PURE plan for the launchpad's "clone a git remote" action. Turns
/// a remote string (as `OmniResolver` classifies `.gitRemote`) into a normalized
/// clone URL + the repo name + the local target directory. Host-testable; the
/// actual `git clone` IO + opening the checkout are the thin shell over this.
public struct GitClonePlan: Equatable, Sendable {

    /// The URL/spec handed to `git clone` (unchanged for scp-style / explicit
    /// schemes; `https://…` synthesized for a bare `host/owner/repo`).
    public let cloneURL: String
    /// The repository name (the last path component, minus a trailing `.git`) —
    /// the directory `git clone` creates.
    public let repoName: String
    /// The absolute local directory the checkout will land in (`parent/repoName`).
    public let targetDirectory: String

    /// Build a plan for `remote`, cloning into `parentDirectory`. Returns nil when
    /// no repo name can be derived (so the caller can refuse rather than clone into
    /// a junk dir). `parentDirectory` is used verbatim (caller resolves ~/etc).
    public static func make(fromRemote remote: String, into parentDirectory: String) -> GitClonePlan? {
        let raw = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let name = repoName(from: raw), !name.isEmpty else { return nil }
        let url = normalizedCloneURL(raw)
        let parent = parentDirectory.hasSuffix("/")
            ? String(parentDirectory.dropLast()) : parentDirectory
        return GitClonePlan(cloneURL: url, repoName: name, targetDirectory: "\(parent)/\(name)")
    }

    /// Normalize a remote to a clone spec. scp-style (`git@host:o/r`) and any
    /// explicit `scheme://` are passed through; a bare forge `host/owner/repo`
    /// becomes `https://host/owner/repo`.
    static func normalizedCloneURL(_ raw: String) -> String {
        if raw.hasPrefix("git@") { return raw }                    // scp-style
        if raw.contains("://") { return raw }                      // explicit scheme
        return "https://\(raw)"                                    // bare forge path
    }

    /// The repo name = last path component with a single trailing `.git` removed.
    /// Handles `git@host:o/r(.git)`, `https://host/o/r(.git)`, `host/o/r`. Requires
    /// at least TWO path components (an owner/namespace before the repo), so a bare
    /// host like `github.com/` — no repo — yields nil rather than the host name.
    static func repoName(from raw: String) -> String? {
        // scp-style: everything after the ':' is the path.
        var path = raw
        if raw.hasPrefix("git@"), let colon = raw.firstIndex(of: ":") {
            path = String(raw[raw.index(after: colon)...])
        } else if let schemeRange = raw.range(of: "://") {
            path = String(raw[schemeRange.upperBound...])
            // keep the host — the repo is still the LAST component; the ≥2-component
            // rule below rejects a host-only path.
        }
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2, let last = components.last else { return nil }
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        return name.isEmpty ? nil : name
    }
}
