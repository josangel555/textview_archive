import Foundation

/// Small helpers for the PoC: locate `sourcekit-lsp` and walk up to a
/// `Package.swift` (the only workspace marker we care about for Swift).
///
/// Why so narrow? See `docs/LSP_DESIGN.md` §3.8. A real implementation
/// would route through `LSPLanguage` + a marker-table; PoC only needs
/// Swift, so we hardcode.
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
    /// a parent monorepo (design doc §3.8).
    public static func swiftPackageRoot(for fileURL: URL) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var dir = fileURL.deletingLastPathComponent().standardizedFileURL
        let fm = FileManager.default
        while true {
            let pkg = dir.appendingPathComponent("Package.swift")
            if fm.fileExists(atPath: pkg.path) { return dir }
            // .git boundary — stop walking up to avoid parent monorepo.
            let dotGit = dir.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path) { return dir }
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
