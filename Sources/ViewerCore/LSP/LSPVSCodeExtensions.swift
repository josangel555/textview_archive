import Foundation

/// Discovery of language-server binaries that ship **inside an installed
/// VS Code-family editor's extensions** (TSK-797).
///
/// ## The homework: what toolchains do VS Code extensions give us?
///
/// VS Code itself is a thin editor — language intelligence comes from
/// *extensions*, and most language extensions bundle (or auto-download on
/// first use) a real LSP server binary into the editor's per-user
/// extensions directory. Concretely, on macOS the extensions live under:
///
///   `~/.vscode/extensions/`            (VS Code stable)
///   `~/.vscode-insiders/extensions/`   (VS Code Insiders)
///   `~/.vscodium/extensions/`          (VSCodium, the FOSS build)
///   `~/.cursor/extensions/`            (Cursor)
///   `~/.windsurf/extensions/`          (Windsurf)
///
/// Each extension is a directory named `<publisher>.<name>-<version>`
/// (sometimes with a trailing `-<platform>` tag, e.g.
/// `rust-lang.rust-analyzer-0.3.2937-darwin-arm64`), and ships its server
/// at a predictable relative sub-path. Verified on a real install:
///
///   - `rust-lang.rust-analyzer-<ver>-darwin-arm64/server/rust-analyzer`
///   - `llvm-vs-code-extensions.vscode-clangd-<ver>/<...>/clangd`
///
/// So a user who has VS Code (or Cursor) installed with the relevant
/// extensions ALREADY has working language servers on disk — even when
/// nothing is on their shell `PATH`. The pay-off for *this* app:
///
///   **For the languages it does NOT bundle (Swift/Java/TS/Python) the
///   app can find the server "for free" from the user's VS Code install,
///   so LSP Just Works without a separate `npm i -g` / `brew install`.**
///
/// What each language gets, per the standard extensions:
///
///   | Language   | VS Code extension                         | Server bundled                |
///   |------------|-------------------------------------------|-------------------------------|
///   | Swift      | `swiftlang.swift-vscode` (Swift for VSCode)| uses toolchain `sourcekit-lsp`* |
///   | Java       | `redhat.java` (Language Support for Java) | `jdtls` (Eclipse JDT.LS)      |
///   | TypeScript | built-in (`vscode.typescript-language-features`) | `tsserver`† |
///   | Python     | `ms-python.vscode-pylance`                | Pylance (proprietary)‡        |
///   | Rust       | `rust-lang.rust-analyzer`                 | `rust-analyzer` (bundled bin) |
///   | C/C++      | `llvm-vs-code-extensions.vscode-clangd`   | `clangd` (downloaded bin)     |
///
///   * The Swift extension drives the toolchain's `sourcekit-lsp` rather
///     than bundling its own — so our existing `xcrun`-based discovery is
///     the right path for Swift, and we do not look in the extension dir
///     for it.
///   † The built-in TS feature speaks the editor's private protocol, not
///     stdio LSP, so it is NOT reusable as a standalone server. The
///     reusable TS server is `typescript-language-server` (npm), which we
///     already discover on PATH. Hence no VS Code-extension entry for TS.
///   ‡ Pylance's license forbids use outside official Microsoft products,
///     so we deliberately do NOT discover it. `pyright` (the OSS server we
///     target) is on PATH/npm, not in the Pylance extension.
///
/// This helper therefore contributes the languages where an extension
/// ships a *standalone, license-clean, stdio-LSP* server we can spawn:
/// **Java** (`redhat.java` → `jdtls`) today, with the table above
/// documenting the rest for the wider feature.
///
/// ## Safety
///
/// Resolved paths are gated through `LSPDiscovery.isBinarySafeToSpawn`
/// exactly like PATH/Homebrew candidates — a world/group-writable
/// extension dir (or ancestor) is refused. The extensions root is under
/// the user's home, so this is normally owner-owned and safe.
public enum LSPVSCodeExtensions {

    /// One known VS Code-family editor's per-user extensions directory,
    /// relative to the user's home (so it is injectable in tests).
    public static let editorExtensionRoots: [String] = [
        ".vscode/extensions",
        ".vscode-insiders/extensions",
        ".vscodium/extensions",
        ".cursor/extensions",
        ".windsurf/extensions",
    ]

    /// A recipe for finding one language's server inside an extension.
    public struct ServerRecipe: Sendable, Equatable {
        /// The `<publisher>.<name>` prefix the extension directory starts
        /// with (the trailing `-<version>[-<platform>]` is matched
        /// separately). Case-insensitive match.
        public let extensionIDPrefix: String
        /// Relative path(s) from the extension directory to the server
        /// binary, tried in order. First existing + executable wins.
        public let relativeBinaryPaths: [String]

        public init(extensionIDPrefix: String, relativeBinaryPaths: [String]) {
            self.extensionIDPrefix = extensionIDPrefix
            self.relativeBinaryPaths = relativeBinaryPaths
        }
    }

    /// Recipes for the languages whose VS Code extension ships a
    /// standalone, license-clean, stdio-LSP server we can reuse.
    ///
    /// Swift is intentionally absent (extension defers to the toolchain's
    /// `sourcekit-lsp`, found via `xcrun`); TypeScript is absent (the
    /// built-in feature isn't a standalone stdio server); Python is absent
    /// (Pylance is proprietary, `pyright` is on PATH/npm).
    public static func recipes(for language: LSPLanguage) -> [ServerRecipe] {
        switch language {
        case .java:
            // Red Hat "Language Support for Java" ships a `jdtls` launcher
            // wrapper. Its bin dir varies by version; probe the documented
            // locations. The user's own `jdtls` on PATH still wins (this is
            // a fallback in LSPDiscovery's ordering).
            return [
                ServerRecipe(
                    extensionIDPrefix: "redhat.java",
                    relativeBinaryPaths: [
                        "bin/jdtls",
                        "server/bin/jdtls",
                    ]
                ),
            ]
        case .swift, .typescript, .python:
            return []
        }
    }

    // MARK: - Resolution

    /// Locate `language`'s server inside any installed VS Code-family
    /// editor's extensions. Returns the newest-version match that exists,
    /// is executable, and passes the spawn-safety gate — or nil.
    ///
    /// `home` and `fileExists`/`isExecutable`/`isSafe` are injected so the
    /// whole thing is host-testable against a fabricated tmp tree with no
    /// real VS Code install. The app uses the production defaults.
    public static func locateServer(
        for language: LSPLanguage,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        listExtensionDirs: (URL) -> [String] = Self.defaultListDirs,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        isSafe: (String) -> Bool = Self.defaultIsSafe
    ) -> URL? {
        let recipes = recipes(for: language)
        guard !recipes.isEmpty else { return nil }

        for rootRel in editorExtensionRoots {
            let root = home.appendingPathComponent(rootRel, isDirectory: true)
            let dirNames = listExtensionDirs(root)
            guard !dirNames.isEmpty else { continue }

            for recipe in recipes {
                // Collect candidate extension dirs whose name matches the
                // publisher.name prefix, paired with their parsed version so
                // we can pick the newest.
                let candidates = dirNames
                    .filter { Self.matches(dirName: $0, prefix: recipe.extensionIDPrefix) }
                    .map { (name: $0, version: parseVersion(fromDirName: $0, prefix: recipe.extensionIDPrefix)) }
                    .sorted { lhs, rhs in versionLess(lhs.version, rhs.version) }
                    .reversed() // newest first

                for match in candidates {
                    let extDir = root.appendingPathComponent(match.name, isDirectory: true)
                    for rel in recipe.relativeBinaryPaths {
                        let bin = extDir.appendingPathComponent(rel)
                        if isExecutable(bin.path), isSafe(bin.path) {
                            return bin
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Default directory listing — names of immediate children of `root`
    /// (the extension folders). Empty if `root` doesn't exist.
    public static func defaultListDirs(_ root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    /// Public wrapper over the (internal) spawn-safety gate so it can be
    /// the default argument for `locateServer(isSafe:)`. Production callers
    /// use this; tests inject a stub.
    public static func defaultIsSafe(_ path: String) -> Bool {
        LSPDiscovery.isBinarySafeToSpawn(atPath: path)
    }

    // MARK: - Name / version parsing (internal, tested directly)

    /// True iff `dirName` is `<prefix>-<version...>` (case-insensitive on
    /// the prefix). We require the `-` so `redhat.java` does not also match
    /// a hypothetical `redhat.javaee-...` extension.
    static func matches(dirName: String, prefix: String) -> Bool {
        let needle = prefix.lowercased() + "-"
        return dirName.lowercased().hasPrefix(needle)
    }

    /// Parse the version segment from `<prefix>-<a.b.c>[-<platform>]`.
    /// Returns the numeric `[a, b, c]` components (missing → []). The
    /// trailing platform tag (e.g. `-darwin-arm64`) is non-numeric and is
    /// dropped by the digit-only filter. A dir with no parseable version
    /// sorts lowest, so a versioned dir is always preferred.
    static func parseVersion(fromDirName dirName: String, prefix: String) -> [Int] {
        // Strip the matched prefix + the separating '-'.
        let dropCount = prefix.count + 1
        guard dirName.count > dropCount else { return [] }
        let tail = String(dirName.dropFirst(dropCount))
        // The version is the leading dotted-number run; stop at the first
        // segment that isn't a pure integer (that's the platform tag).
        var components: [Int] = []
        for seg in tail.split(separator: ".") {
            // A segment may itself carry the platform suffix on the LAST
            // numeric component (`2937-darwin`); take the leading digits.
            let leadingDigits = seg.prefix { $0.isNumber }
            if leadingDigits.isEmpty { break }
            // Reject if there is a non-platform mix we can't trust: only
            // accept if the segment is all digits OR digits-then-dash
            // (the platform tag boundary).
            if leadingDigits.count == seg.count {
                components.append(Int(leadingDigits) ?? 0)
            } else if seg[seg.index(seg.startIndex, offsetBy: leadingDigits.count)] == "-" {
                components.append(Int(leadingDigits) ?? 0)
                break // everything after the dash is the platform tag
            } else {
                break
            }
        }
        return components
    }

    /// Numeric semver-ish comparison of two component arrays. Shorter
    /// arrays are zero-padded for the compare, so `[0,3,2929]` < `[0,3,2937]`
    /// and `[1,0]` > `[0,9,9]`. An empty array (unparseable) is the lowest.
    static func versionLess(_ a: [Int], _ b: [Int]) -> Bool {
        let n = max(a.count, b.count)
        for i in 0..<n {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l < r }
        }
        return false // equal
    }
}
