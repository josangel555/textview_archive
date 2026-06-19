import Foundation

/// The set of well-known URLs that locate a single dependency's source — the
/// "trace repo paths crate → github" core of the dependency-sourceview epic
/// (TSK-692). Given a normalized `DependencyPackage` (see `PackageManifest`),
/// this resolves the deterministic registry / docs / download / repo URLs you
/// would hit to obtain and browse that package's actual source.
///
/// PURE LOGIC — string construction only, no network I/O. Fetching + caching +
/// the in-app sourceview are deliberately separate, later slices of the epic;
/// nothing here opens a socket. That keeps the path-tracing fully host-testable
/// and deterministic, mirroring `PackageManifestParser` / `DotGraphParser`.
public struct DependencySource: Equatable, Sendable, Hashable {
    /// The package this resolves (carried so a caller can correlate without a
    /// side lookup).
    public var name: String
    public var version: String?
    public var source: DependencyPackage.Source

    /// The registry *metadata* API endpoint — the authoritative place a crate's
    /// / package's GitHub `repository` link lives. The consuming manifest does
    /// NOT carry a registry dep's repo URL, so this endpoint is how you trace
    /// crate → github. `nil` only when the name can't form a valid URL path.
    public var registryMetadataURL: URL?

    /// The human-facing registry page (crates.io / npmjs.com page for the
    /// package), suitable for "Open on crates.io".
    public var registryPageURL: URL?

    /// The rendered API-docs site for the package (docs.rs for Cargo; nil for
    /// npm, which has no universal equivalent).
    public var documentationURL: URL?

    /// The deterministic source-tarball download URL for the *pinned* version,
    /// when a concrete (non-range) version is known. `nil` when the version is a
    /// range/constraint or absent — the exact version must be resolved via the
    /// registry first. This is the artifact the fetch slice will download.
    public var tarballURL: URL?

    /// A normalized GitHub (or other forge) web URL when the repository is
    /// directly knowable from the manifest WITHOUT a network round-trip — i.e. a
    /// Cargo git dependency (`{ git = "…" }`). For ordinary registry deps this
    /// is `nil`: their repo must be traced through `registryMetadataURL`.
    public var repositoryURL: URL?

    public init(name: String,
                version: String?,
                source: DependencyPackage.Source,
                registryMetadataURL: URL?,
                registryPageURL: URL?,
                documentationURL: URL?,
                tarballURL: URL?,
                repositoryURL: URL?) {
        self.name = name
        self.version = version
        self.source = source
        self.registryMetadataURL = registryMetadataURL
        self.registryPageURL = registryPageURL
        self.documentationURL = documentationURL
        self.tarballURL = tarballURL
        self.repositoryURL = repositoryURL
    }
}

/// Resolves a `DependencyPackage` to its `DependencySource` URL set. Stateless,
/// pure, network-free.
public enum DependencySourceResolver {

    /// Resolve a single dependency. Never throws and never returns garbage URLs:
    /// any field whose inputs are unusable (empty name, unparseable version,
    /// non-pinned range) degrades to `nil`, mirroring the manifest parsers'
    /// graceful-degradation contract.
    public static func resolve(_ package: DependencyPackage) -> DependencySource {
        switch package.source {
        case .cargo: return resolveCargo(package)
        case .npm:   return resolveNPM(package)
        }
    }

    /// Resolve every package in a manifest, preserving order.
    public static func resolve(_ manifest: DependencyManifest) -> [DependencySource] {
        manifest.packages.map(resolve)
    }

    // MARK: - Cargo (crates.io)

    private static func resolveCargo(_ pkg: DependencyPackage) -> DependencySource {
        let name = pkg.name
        let pinned = pinnedVersion(pkg.version)

        let metadata = encodedPath(name).map { URL(string: "https://crates.io/api/v1/crates/\($0)") } ?? nil
        let page = encodedPath(name).map { URL(string: "https://crates.io/crates/\($0)") } ?? nil
        let docs: URL? = {
            guard let n = encodedPath(name) else { return nil }
            if let v = pinned, let ev = encodedPath(v) {
                return URL(string: "https://docs.rs/\(n)/\(ev)")
            }
            return URL(string: "https://docs.rs/\(n)")
        }()
        // crates.io static CDN tarball path is deterministic for a pinned version:
        //   https://static.crates.io/crates/<name>/<name>-<version>.crate
        let tarball: URL? = {
            guard let n = encodedPath(name), let v = pinned, let ev = encodedPath("\(name)-\(v).crate")
            else { return nil }
            return URL(string: "https://static.crates.io/crates/\(n)/\(ev)")
        }()

        return DependencySource(
            name: name,
            version: pkg.version,
            source: .cargo,
            registryMetadataURL: metadata,
            registryPageURL: page,
            documentationURL: docs,
            tarballURL: tarball,
            repositoryURL: normalizedRepositoryURL(pkg.repository))
    }

    // MARK: - npm (registry.npmjs.org)

    private static func resolveNPM(_ pkg: DependencyPackage) -> DependencySource {
        let name = pkg.name
        let pinned = pinnedVersion(pkg.version)

        // Scoped names (`@scope/pkg`) keep their slash in the path; the registry
        // accepts the unencoded scoped form on the metadata endpoint.
        let metadata = npmRegistryPath(name).map { URL(string: "https://registry.npmjs.org/\($0)") } ?? nil
        let page = npmRegistryPath(name).map { URL(string: "https://www.npmjs.com/package/\($0)") } ?? nil
        // npm tarball is deterministic for an unscoped package:
        //   https://registry.npmjs.org/<name>/-/<name>-<version>.tgz
        // Scoped packages keep the scope on the dir but the bare name on the file.
        let tarball: URL? = {
            guard let path = npmRegistryPath(name), let v = pinned,
                  let file = encodedPath("\(unscopedName(name))-\(v).tgz")
            else { return nil }
            return URL(string: "https://registry.npmjs.org/\(path)/-/\(file)")
        }()

        return DependencySource(
            name: name,
            version: pkg.version,
            source: .npm,
            registryMetadataURL: metadata,
            registryPageURL: page,
            documentationURL: nil,
            tarballURL: tarball,
            repositoryURL: normalizedRepositoryURL(pkg.repository))
    }

    // MARK: - Repository URL normalization

    /// Normalize a raw repository / git URL from a manifest into a browsable
    /// `https://` web URL. Handles the common git remote spellings:
    ///   - `git+https://github.com/o/r.git`     → `https://github.com/o/r`
    ///   - `git://github.com/o/r.git`           → `https://github.com/o/r`
    ///   - `ssh://git@github.com/o/r.git`       → `https://github.com/o/r`
    ///   - `git@github.com:o/r.git`             → `https://github.com/o/r`
    ///   - `https://github.com/o/r.git`         → `https://github.com/o/r`
    /// Returns `nil` for empty / unparseable input.
    public static func normalizedRepositoryURL(_ raw: String?) -> URL? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }

        // `git+https://…` / `git+ssh://…` npm-style prefix.
        if s.hasPrefix("git+") { s = String(s.dropFirst(4)) }

        // `scp`-style `git@host:owner/repo` → `https://host/owner/repo`.
        if !s.contains("://"), let at = s.firstIndex(of: "@"), let colon = s.firstIndex(of: ":") {
            let host = String(s[s.index(after: at)..<colon])
            let path = String(s[s.index(after: colon)...])
            if !host.isEmpty && !path.isEmpty {
                s = "https://\(host)/\(path)"
            }
        }

        // git:// and ssh:// remotes browse over https.
        if s.hasPrefix("git://") { s = "https://" + s.dropFirst("git://".count) }
        if s.hasPrefix("ssh://git@") { s = "https://" + s.dropFirst("ssh://git@".count) }
        else if s.hasPrefix("ssh://") { s = "https://" + s.dropFirst("ssh://".count) }

        // Strip a trailing `.git` (only on the path's final component) and any
        // trailing slash so the result is a clean web URL.
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }

        // Only accept http(s) web URLs; reject anything still non-web.
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
        return URL(string: s)
    }

    // MARK: - Version helpers

    /// A *pinned* (single, concrete) version, or `nil` when the input is a
    /// range/constraint/empty. We only build a tarball URL for an exact version,
    /// because a range can't name a single artifact.
    ///
    /// Accepts: `"1.2.3"`, `"=1.2.3"` (Cargo exact), `"v1.2.3"`. Rejects ranges
    /// and wildcards: `"^1.2"`, `"~1.2"`, `">=1"`, `"1.*"`, `"1.x"`, `"*"`,
    /// `"latest"`, or anything carrying a space (`">= 1, < 2"`).
    static func pinnedVersion(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return nil
        }
        if v.hasPrefix("=") { v = String(v.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if v.hasPrefix("v") || v.hasPrefix("V") { v = String(v.dropFirst()) }
        guard !v.isEmpty else { return nil }

        // Any range/constraint operator, wildcard, separator, or whitespace
        // disqualifies it as a single pinned version.
        let rangeMarkers: Set<Character> = ["^", "~", ">", "<", "*", " ", ",", "|"]
        if v.contains(where: { rangeMarkers.contains($0) }) { return nil }
        if v.lowercased() == "latest" || v.lowercased() == "x" { return nil }
        // A trailing `.x` / `.*` wildcard segment (covered above for `*`, here `x`).
        if v.lowercased().hasSuffix(".x") { return nil }

        // First char must be a digit — a real semver starts numeric.
        guard let first = v.first, first.isNumber else { return nil }
        return v
    }

    // MARK: - Path encoding

    /// Percent-encode a single path component (the package name / version) so a
    /// weird-but-legal name can't break the URL. Returns `nil` for an empty
    /// component (an empty name has no resolvable URL).
    private static func encodedPath(_ component: String) -> String? {
        guard !component.isEmpty else { return nil }
        return component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }

    /// npm registry path for a (possibly scoped) name. The scoped form
    /// `@scope/pkg` keeps its `/`; both segments are individually encoded.
    private static func npmRegistryPath(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if name.hasPrefix("@") {
            let parts = name.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let scope = encodedPath(String(parts[0])),
                  let pkg = encodedPath(String(parts[1])),
                  !scope.isEmpty, !pkg.isEmpty
            else { return encodedPath(name) }   // malformed scope → fall back
            return "@\(scope)/\(pkg)"
        }
        return encodedPath(name)
    }

    /// The bare package name without an `@scope/` prefix — used for the npm
    /// tarball file name (`@scope/pkg` tarball is `pkg-<ver>.tgz`).
    private static func unscopedName(_ name: String) -> String {
        if name.hasPrefix("@"), let slash = name.firstIndex(of: "/") {
            return String(name[name.index(after: slash)...])
        }
        return name
    }
}
