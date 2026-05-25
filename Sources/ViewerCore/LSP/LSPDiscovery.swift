import Foundation
import CryptoKit

/// Server binary lookup + per-language workspace-root discovery helpers.
///
/// The Swift-specific entry-points (`locateSourceKitLSP`,
/// `swiftPackageRoot`) are registered into `LSPLanguageRegistry.default`.
/// New languages add their own root-finder + use the generic
/// `locate(binary:)` to find their server.
public enum LSPDiscovery {

    // MARK: - Sourcekit-LSP (special-cased — uses `xcrun`)

    /// Resolved `sourcekit-lsp` binary path, or nil if missing.
    /// Checks (in order):
    ///   1. `xcrun -f sourcekit-lsp` (the only reliable source on macOS;
    ///      always points at the active Xcode toolchain)
    ///   2. `/usr/bin/sourcekit-lsp` (CLT-shipped fallback)
    public static func locateSourceKitLSP() -> URL? {
        if let cached = cachedBinary(named: "sourcekit-lsp") { return cached }
        let resolved: URL? = {
            if let viaXcrun = runCapture(
                executable: "/usr/bin/xcrun", arguments: ["-f", "sourcekit-lsp"]
            ), !viaXcrun.isEmpty {
                let path = viaXcrun.trimmingCharacters(in: .whitespacesAndNewlines)
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
            let fallback = "/usr/bin/sourcekit-lsp"
            if FileManager.default.fileExists(atPath: fallback) {
                return URL(fileURLWithPath: fallback)
            }
            return nil
        }()
        cacheBinary(named: "sourcekit-lsp", url: resolved)
        return resolved
    }

    // MARK: - Generic binary locator (PATH + Homebrew + bundle)

    /// Resolved path to an LSP server binary, or nil if not found. Tries:
    ///   1. App bundle's `Contents/Resources/lsp/<binary>` (forward-compat
    ///      for a future bundled-fallback option — skipped if absent).
    ///   2. `which <binary>` against the user's PATH (augmented with
    ///      common Homebrew + npm prefixes since GUI-launched apps
    ///      don't inherit shell PATH).
    ///   3. Common Homebrew / system paths in fallback order.
    ///
    /// Cached for the process lifetime — discovery is idempotent and
    /// new server installs require a relaunch to pick up.
    public static func locate(binary name: String) -> URL? {
        if let cached = cachedBinary(named: name) { return cached }
        let resolved = resolveBinary(named: name)
        cacheBinary(named: name, url: resolved)
        return resolved
    }

    /// Reset the discovery cache. Tests use this to re-probe.
    public static func resetDiscoveryCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        binaryCache.removeAll()
    }

    private static func resolveBinary(named name: String) -> URL? {
        // 1. Bundled fallback. App bundle path is reachable via
        //    Bundle.main on the live app; in tests Bundle.main is the
        //    xctest binary so this branch is a no-op there.
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/lsp")
            .appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // 2. Augmented PATH probe. We deliberately walk a known prefix
        //    list rather than calling `/usr/bin/which` directly — GUI-
        //    launched processes don't inherit a useful $PATH from the
        //    user's shell, so `which` would miss anything outside the
        //    system defaults. The list mirrors the design doc (§6).
        let candidatePrefixes: [String] = augmentedSearchPaths()
        for prefix in candidatePrefixes {
            let candidate = (prefix as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate),
               isBinarySafeToSpawn(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        // 3. Last-resort `which`, in case the user's environment has
        //    unusual install paths beyond the augmented list.
        if let viaWhich = runCapture(
            executable: "/usr/bin/which", arguments: [name]
        ) {
            let path = viaWhich.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path),
               isBinarySafeToSpawn(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Ownership + permission safety check (S3.1, 2026-05-25).
    ///
    /// We refuse to spawn an LSP binary whose **containing directory**
    /// is group- or world-writable. A directory writable by `other`
    /// can have any file inside it replaced by a non-owner — so a
    /// compromised npm postinstall (or a malicious package on a
    /// shared dev machine) could swap in a hostile `pyright` /
    /// `typescript-language-server` and we'd hand it inherited env +
    /// stdio.
    ///
    /// We deliberately do NOT enforce ownership on the binary itself:
    /// `~/.npm-global/bin/pyright` is legitimately owned by the
    /// current user (that's the whole point of a user-prefix install).
    /// The container dir's perms are the meaningful signal.
    ///
    /// Returns true (= safe) for any path we can't stat — better to
    /// preserve "language servers Just Work" than to lock out a user
    /// whose dev setup we don't understand. The narrow case we're
    /// blocking is the obviously-bad `0o777` lab-machine scenario.
    static func isBinarySafeToSpawn(atPath path: String) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dir),
              let perms = attrs[.posixPermissions] as? NSNumber else {
            return true
        }
        let mode = perms.uint16Value
        // Group-write (020) or world-write (002) on the dir means
        // someone else can drop a binary in or replace the existing
        // one. Refuse.
        if (mode & 0o022) != 0 {
            return false
        }
        return true
    }

    /// Path prefixes searched when locating LSP server binaries. Order
    /// matters — Homebrew arm64 (`/opt/homebrew/bin`) wins over Homebrew
    /// Intel (`/usr/local/bin`) on Apple Silicon, and both win over the
    /// system path.
    static func augmentedSearchPaths() -> [String] {
        var paths: [String] = []
        // User's $PATH (best-effort — GUI launches may have a minimal
        // one, but if it's there we honor it first).
        if let env = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: env.split(separator: ":").map(String.init))
        }
        // Common install locations not necessarily on the GUI PATH.
        paths.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/homebrew/opt/node/bin",
            "/usr/local/opt/node/bin",
            "/usr/bin",
        ])
        // npm global-prefix bin, when present. Reading
        // `~/.npm-global/bin` covers `npm config set prefix
        // ~/.npm-global` users; `~/.npm/bin` covers the default config
        // for some installs.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(contentsOf: [
            (home as NSString).appendingPathComponent(".npm-global/bin"),
            (home as NSString).appendingPathComponent(".npm/bin"),
            (home as NSString).appendingPathComponent(".local/bin"),
        ])
        // De-dup preserving order — `Array(Set(_))` would scramble.
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    // MARK: - Per-language workspace root finders

    /// Find the nearest enclosing directory containing `Package.swift`.
    /// Stops at `.git` boundary or home directory to avoid pulling in
    /// a parent monorepo (design doc §3.8). If no `Package.swift` is
    /// found before the `.git` boundary, the `.git` directory itself
    /// is returned — sourcekit-lsp still handles single-file mode from
    /// any directory, degrading gracefully to no cross-file features.
    public static func swiftPackageRoot(for fileURL: URL) -> URL? {
        return walkUp(from: fileURL) { dir in
            let pkg = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) { return true }
            // .git boundary — accept *this* directory as the root, but
            // don't keep walking. This is what the PoC did, and it
            // produces a usable root for loose-file projects.
            let dotGit = dir.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: dotGit.path) { return true }
            return false
        }
    }

    /// TS/JS workspace root: walk up for `tsconfig.json` →
    /// `jsconfig.json` → `package.json`. Fall back to the file's parent
    /// directory (single-file mode); the server handles loose files
    /// without cross-file navigation.
    public static func tsWorkspaceRoot(for fileURL: URL) -> URL? {
        if let found = walkUp(from: fileURL, match: { dir in
            let markers = ["tsconfig.json", "jsconfig.json", "package.json"]
            return markers.contains { name in
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(name).path)
            }
        }) {
            return found
        }
        // Single-file fallback. Always returns something so loose files
        // (one-off scratch.ts on the Desktop) still get an LSP session.
        return fileURL.deletingLastPathComponent().standardizedFileURL
    }

    /// Java workspace root: walk up for Maven / Gradle / Eclipse project
    /// markers. Falls back to nil — single-file mode is degenerate for
    /// jdtls (the server needs a real source root to index against).
    public static func javaWorkspaceRoot(for fileURL: URL) -> URL? {
        return walkUp(from: fileURL) { dir in
            let markers = [
                "pom.xml", "build.gradle", "build.gradle.kts",
                "settings.gradle", "settings.gradle.kts", ".project",
            ]
            return markers.contains { name in
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(name).path)
            }
        }
    }

    /// Python workspace root: walk up for `pyproject.toml` →
    /// `pyrightconfig.json` → `setup.py` → `setup.cfg` → `Pipfile` →
    /// `requirements.txt`. Fall back to the file's parent directory
    /// (pyright handles loose files).
    public static func pythonWorkspaceRoot(for fileURL: URL) -> URL? {
        if let found = walkUp(from: fileURL, match: { dir in
            let markers = [
                "pyproject.toml", "pyrightconfig.json",
                "setup.py", "setup.cfg", "Pipfile", "requirements.txt",
            ]
            return markers.contains { name in
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(name).path)
            }
        }) {
            return found
        }
        return fileURL.deletingLastPathComponent().standardizedFileURL
    }

    /// Per-workspace data directory for jdtls's `-data <dir>` argument.
    /// Lives under app support keyed by a stable hash of the workspace
    /// path — jdtls writes a (large, growing) index here that survives
    /// across launches. Created on demand if missing.
    ///
    /// Location:
    ///   `~/Library/Application Support/com.markdownviewer.MarkdownViewer/jdtls-data/<hash>/`
    public static func jdtlsDataDirectory(for workspaceRoot: URL) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let base = appSupport
            .appendingPathComponent("com.markdownviewer.MarkdownViewer", isDirectory: true)
            .appendingPathComponent("jdtls-data", isDirectory: true)
        let hash = workspaceHash(for: workspaceRoot)
        let dir = base.appendingPathComponent(hash, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Short stable hash of a workspace path. SHA-256 first 12 hex
    /// digits — collision-free for any realistic number of jdtls
    /// workspaces a single user touches.
    static func workspaceHash(for url: URL) -> String {
        let data = Data(url.standardizedFileURL.path.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
            .description
    }

    /// Generic upward walk used by language root-finders. Callers
    /// receive each ancestor directory in turn (starting at the file's
    /// parent) and return true to claim it as the root. Stops at the
    /// home directory and filesystem root; returns nil if no claim.
    /// Exposed as a public extension point so future language entries
    /// can stop on `Cargo.toml`, `pyproject.toml`, etc.
    public static func walkUp(
        from fileURL: URL,
        match: (URL) -> Bool
    ) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL
        var dir = fileURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if match(dir) { return dir }
            if dir == home { return nil }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent == dir { return nil } // hit /
            dir = parent
        }
    }

    // MARK: - Discovery cache

    nonisolated(unsafe) private static var binaryCache: [String: URL?] = [:]
    private static let cacheLock = NSLock()

    private static func cachedBinary(named name: String) -> URL? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = binaryCache[name] { return hit }
        return nil
    }

    private static func cacheBinary(named name: String, url: URL?) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        binaryCache[name] = url
    }

    // MARK: -

    private static func runCapture(executable: String, arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        // Use the shared drain helper (H, 2026-05-25). The previous
        // open-coded path read only stdout (stderr stayed un-drained),
        // which was a latent pipe-buffer deadlock against a chatty
        // `--version` flag on some servers.
        guard let result = try? ProcessRunner.run(p) else { return nil }
        guard result.terminationStatus == 0 else { return nil }
        return String(data: result.stdout, encoding: .utf8)
    }
}
