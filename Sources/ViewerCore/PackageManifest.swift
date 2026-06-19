import Foundation

/// One declared dependency, normalized across manifest formats (npm
/// `package.json`, Cargo `Cargo.toml`, …) into a single shape a Dependency
/// Package explorer can list/filter/graph (TSK-319; pairs with the shipped
/// module/import graph TSK-280, `DotGraph`).
///
/// This is the host-testable *model core* — pure parsing, no UI. The explorer
/// VIEW (a node+edge surface like `DotGraph`'s) is a separate, VM-validated
/// phase; nothing here draws. Dependency-free + pure so it's fully
/// unit-testable, mirroring `DotGraphParser` / `CSVParser`.
public struct DependencyPackage: Equatable, Sendable, Hashable {
    /// How a dependency is consumed by the manifest's own package.
    public enum Kind: String, Equatable, Sendable, Hashable {
        /// A normal runtime dependency (npm `dependencies`, Cargo
        /// `[dependencies]`).
        case direct
        /// A dev/build/test-only dependency (npm `devDependencies`, Cargo
        /// `[dev-dependencies]` / `[build-dependencies]`).
        case dev
        /// A dependency-of-a-dependency. Manifests don't list these (only
        /// lockfiles do), so phase-1 parsers never emit it — modeled so a
        /// future lockfile reader has a home.
        case transitive
    }

    /// The ecosystem the package was declared in — also the manifest format.
    public enum Source: String, Equatable, Sendable, Hashable {
        case npm
        case cargo
    }

    /// The package id as written in the manifest (`"react"`, `"serde"`).
    public var name: String
    /// The version constraint/pin as written (`"^18.2.0"`, `"1.0"`), or `nil`
    /// when the manifest gives none (e.g. a Cargo path/git-only dep).
    public var version: String?
    public var kind: Kind
    public var source: Source
    /// A repository / git URL declared inline on the dependency itself, when the
    /// manifest carries one — e.g. a Cargo git dependency
    /// (`foo = { git = "https://github.com/owner/foo" }`). `nil` for ordinary
    /// registry deps, whose repo URL must be traced via registry metadata (see
    /// `DependencySourceResolver`). This is the *only* repo URL a manifest can
    /// give us without a network round-trip.
    public var repository: String?

    public init(name: String, version: String?, kind: Kind, source: Source,
                repository: String? = nil) {
        self.name = name
        self.version = version
        self.kind = kind
        self.source = source
        self.repository = repository
    }
}

/// A directed edge in the dependency graph: `from` depends on `to`. For a
/// single manifest the root package depends on each declared package, so every
/// edge is `root → dependency`. A future multi-manifest / lockfile reader can
/// add package→package edges with the same shape.
public struct DependencyEdge: Equatable, Sendable, Hashable {
    public var from: String
    public var to: String
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// The normalized result of parsing one package manifest: the manifest's own
/// package identity, its declared dependencies, and the root→dependency edge
/// set ready to feed a graph.
public struct DependencyManifest: Equatable, Sendable {
    /// The manifest's own package name (npm `name`, Cargo `[package] name`), or
    /// `nil` when the manifest omits it. Used as the graph root / edge `from`.
    public var rootName: String?
    /// The manifest's own version, if declared.
    public var rootVersion: String?
    public var source: DependencyPackage.Source
    /// Declared dependencies in first-seen order, de-duplicated by (name, kind).
    public var packages: [DependencyPackage]
    /// `root → dependency` edges, in `packages` order. Empty when `rootName`
    /// is `nil` (no stable node to anchor edges to).
    public var edges: [DependencyEdge]

    public init(rootName: String?,
                rootVersion: String?,
                source: DependencyPackage.Source,
                packages: [DependencyPackage],
                edges: [DependencyEdge]) {
        self.rootName = rootName
        self.rootVersion = rootVersion
        self.source = source
        self.packages = packages
        self.edges = edges
    }
}

/// Bounded-subset package-manifest parsers. Each parser tolerates malformed
/// input by degrading gracefully — it returns a partial result (or empty
/// `packages`) and NEVER throws, so a viewer can always render *something*.
///
/// Phase 1 scope: `package.json` (npm) + `Cargo.toml` (Cargo). Other formats
/// (`requirements.txt`/`pyproject.toml`, `Package.swift`) are deliberately
/// deferred to follow-on slices.
public enum PackageManifestParser {

    // MARK: package.json (npm)

    /// Parse an npm `package.json`. Reads `name`, `version`, and the dependency
    /// maps `dependencies` (→ `.direct`) and `devDependencies` /
    /// `peerDependencies` / `optionalDependencies` (→ `.dev`).
    ///
    /// Malformed JSON, a non-object root, or non-string version values degrade
    /// to a partial/empty result rather than throwing.
    public static func parsePackageJSON(_ source: String) -> DependencyManifest {
        let empty = DependencyManifest(rootName: nil, rootVersion: nil,
                                       source: .npm, packages: [], edges: [])
        guard let data = source.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return empty }

        let rootName = obj["name"] as? String
        let rootVersion = obj["version"] as? String

        // (mapKey, kind). Order matters: first-seen wins on a name collision.
        let maps: [(String, DependencyPackage.Kind)] = [
            ("dependencies", .direct),
            ("devDependencies", .dev),
            ("peerDependencies", .dev),
            ("optionalDependencies", .dev),
        ]

        var packages: [DependencyPackage] = []
        var seen = Set<String>()   // de-dup key: "name\u{0}kind"
        for (key, kind) in maps {
            guard let map = obj[key] as? [String: Any] else { continue }
            // JSON objects are unordered; sort by name for a deterministic list.
            for name in map.keys.sorted() {
                // Version values that aren't strings (an object, array, number)
                // are tolerated as "no pin captured".
                let version = map[name] as? String
                let dedup = "\(name)\u{0}\(kind.rawValue)"
                guard seen.insert(dedup).inserted else { continue }
                packages.append(DependencyPackage(name: name, version: version,
                                                  kind: kind, source: .npm))
            }
        }

        let edges = makeRootEdges(rootName: rootName, packages: packages)
        return DependencyManifest(rootName: rootName, rootVersion: rootVersion,
                                  source: .npm, packages: packages, edges: edges)
    }

    // MARK: Cargo.toml (Cargo)

    /// Parse a Cargo `Cargo.toml`. Reads `[package] name`/`version`, and the
    /// tables `[dependencies]` (→ `.direct`), `[dev-dependencies]` /
    /// `[build-dependencies]` (→ `.dev`). Both the short form
    /// (`serde = "1.0"`) and the inline-table form
    /// (`serde = { version = "1.0", features = [...] }`) capture the version
    /// pin; a path/git-only dep records `version: nil`.
    ///
    /// This is a *bounded* TOML reader scoped to what dependency tables need —
    /// not a general TOML parser. It tolerates anything it doesn't understand
    /// (comments, arrays, other tables, malformed lines) by skipping it.
    public static func parseCargoTOML(_ source: String) -> DependencyManifest {
        var rootName: String?
        var rootVersion: String?

        // The current `[table]` context. A `.subDep` carries the package the
        // header named (`[dependencies.foo]`) so a later `version = …` line can
        // attach to it — all state stays local to this call (reentrant).
        enum Section: Equatable {
            case package
            case dependencies
            case dev
            /// Inside a `[dependencies.NAME]` / `[dev-dependencies.NAME]`
            /// single-package sub-table: the package name + its kind.
            case subDep(name: String, kind: DependencyPackage.Kind)
            case other
        }
        var section: Section = .other

        var packages: [DependencyPackage] = []
        var seen = Set<String>()

        func add(_ name: String, _ version: String?, _ kind: DependencyPackage.Kind,
                 _ repository: String? = nil) {
            let dedup = "\(name)\u{0}\(kind.rawValue)"
            guard seen.insert(dedup).inserted else { return }
            packages.append(DependencyPackage(name: name, version: version,
                                              kind: kind, source: .cargo,
                                              repository: repository))
        }

        func updateVersion(of name: String, kind: DependencyPackage.Kind, to version: String) {
            guard !version.isEmpty else { return }
            if let idx = packages.firstIndex(where: { $0.name == name && $0.kind == kind }) {
                packages[idx].version = version
            }
        }

        func updateRepository(of name: String, kind: DependencyPackage.Kind, to repo: String) {
            guard !repo.isEmpty else { return }
            if let idx = packages.firstIndex(where: { $0.name == name && $0.kind == kind }) {
                packages[idx].repository = repo
            }
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Table header: `[name]` or `[a.b.c]`. (Array-of-tables `[[…]]`
            // collapses to `[…]` here; none of those are dependency tables.)
            if line.hasPrefix("[") {
                let header = line
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .trimmingCharacters(in: .whitespaces)
                switch header {
                case "package":
                    section = .package
                case "dependencies", "target.dependencies":
                    section = .dependencies
                case "dev-dependencies", "build-dependencies":
                    section = .dev
                default:
                    // `[dependencies.foo]` / `[dev-dependencies.foo]` — a
                    // single-package sub-table. Register the leaf package now
                    // (nil version) and switch to a `.subDep` context so a
                    // following `version = …` line attaches to it.
                    if let (kind, leaf) = depSubTable(header) {
                        add(leaf, nil, kind)
                        section = .subDep(name: leaf, kind: kind)
                    } else {
                        section = .other
                    }
                }
                continue
            }

            // key = value line.
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            switch section {
            case .package:
                if key == "name" { rootName = unquoteTOML(value) }
                else if key == "version" { rootVersion = unquoteTOML(value) }

            case .dependencies, .dev:
                let kind: DependencyPackage.Kind = (section == .dev) ? .dev : .direct
                let name = unquoteTOML(key)
                guard !name.isEmpty else { continue }
                add(name, cargoVersion(from: value), kind, cargoRepository(from: value))

            case .subDep(let pkg, let kind):
                // `version` and `git` are the keys we care about on the
                // already-added sub-table package; path/features lines are ignored.
                if key == "version" {
                    updateVersion(of: pkg, kind: kind, to: unquoteTOML(value))
                } else if key == "git" {
                    updateRepository(of: pkg, kind: kind, to: unquoteTOML(value))
                }

            case .other:
                continue
            }
        }

        let edges = makeRootEdges(rootName: rootName, packages: packages)
        return DependencyManifest(rootName: rootName, rootVersion: rootVersion,
                                  source: .cargo, packages: packages, edges: edges)
    }

    // MARK: - Cargo helpers

    /// `[dependencies.foo]` → (.direct, "foo"); `[dev-dependencies.bar]` /
    /// `[build-dependencies.baz]` → (.dev, leaf). `nil` for any other dotted
    /// header. (`[target.'cfg(...)'.dependencies.foo]` isn't matched — an
    /// uncommon shape deliberately out of phase-1 scope.)
    private static func depSubTable(_ header: String) -> (DependencyPackage.Kind, String)? {
        guard header.contains(".") else { return nil }
        let parts = header.split(separator: ".")
        guard let leaf = parts.last.map(String.init), !leaf.isEmpty else { return nil }
        if header.hasPrefix("dependencies.") { return (.direct, leaf) }
        if header.hasPrefix("dev-dependencies.") || header.hasPrefix("build-dependencies.") {
            return (.dev, leaf)
        }
        return nil
    }

    /// Extract the version pin from a Cargo dependency value. Handles:
    ///   - `"1.0"`               → `1.0`
    ///   - `{ version = "1.0" }` → `1.0`
    ///   - `{ path = "../x" }`   → nil (no version pin)
    private static func cargoVersion(from value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("{") {
            // Inline table: find a `version = "…"` entry.
            return inlineTableValue(v, key: "version")
        }
        let s = unquoteTOML(v)
        return s.isEmpty ? nil : s
    }

    /// Extract the `git = "…"` repository URL from a Cargo dependency value, for
    /// the inline-table git form (`foo = { git = "https://github.com/o/foo" }`).
    /// `nil` for a registry/path dep (no `git` key) or a bare-string value.
    private static func cargoRepository(from value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.hasPrefix("{") else { return nil }
        return inlineTableValue(v, key: "git")
    }

    /// Pull `key = "value"` out of a one-line inline table `{ … }`.
    private static func inlineTableValue(_ inline: String, key: String) -> String? {
        // Strip the outer braces, split on commas (good enough for the
        // version key — version values never contain a comma).
        let body = inline
            .trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
        for entry in body.split(separator: ",") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let k = String(entry[..<eq]).trimmingCharacters(in: .whitespaces)
            if k == key {
                let raw = String(entry[entry.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                let s = unquoteTOML(raw)
                return s.isEmpty ? nil : s
            }
        }
        return nil
    }

    /// Drop a trailing `#` comment, respecting quoted strings so a `#` inside
    /// `"…"` (a legal value char) survives.
    private static func stripTOMLComment(_ line: String) -> String {
        var out = String()
        var inQuotes = false
        var quote: Character = "\""
        var iter = line.makeIterator()
        var prev: Character?
        while let c = iter.next() {
            if inQuotes {
                out.append(c)
                if c == quote && prev != "\\" { inQuotes = false }
            } else if c == "\"" || c == "'" {
                inQuotes = true; quote = c; out.append(c)
            } else if c == "#" {
                break
            } else {
                out.append(c)
            }
            prev = c
        }
        return out
    }

    /// Strip surrounding `"…"` / `'…'` quotes from a TOML scalar; leave bare
    /// values as-is.
    private static func unquoteTOML(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2 {
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) ||
               (v.hasPrefix("'") && v.hasSuffix("'")) {
                return String(v.dropFirst().dropLast())
            }
        }
        return v
    }

    // MARK: - Shared

    /// Build `root → dependency` edges. Empty when there's no root node to
    /// anchor to.
    private static func makeRootEdges(rootName: String?,
                                      packages: [DependencyPackage]) -> [DependencyEdge] {
        guard let root = rootName, !root.isEmpty else { return [] }
        return packages.map { DependencyEdge(from: root, to: $0.name) }
    }
}
