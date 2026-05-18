import Foundation

/// Server binary lookup + per-language workspace-root discovery helpers.
///
/// The Swift-specific entry-points (`locateSourceKitLSP`,
/// `swiftPackageRoot`) are registered into `LSPLanguageRegistry.default`.
/// New languages should add similar binary/root-finder helpers here.
public enum LSPDiscovery {

    /// Resolved `sourcekit-lsp` binary path, or nil if missing.
    /// Checks (in order):
    ///   1. `xcrun -f sourcekit-lsp` (the only reliable source on macOS;
    ///      always points at the active Xcode toolchain)
    ///   2. `/usr/bin/sourcekit-lsp` (CLT-shipped fallback)
    public static func locateSourceKitLSP() -> URL? {
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
    }

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

    // MARK: -

    private static func runCapture(executable: String, arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
