import Foundation
import XCTest
@testable import ViewerCore

/// Helper that locates the `MDVFakeLSPServer` binary in `.build/` so
/// `LSPClient` tests can spawn it without sourcekit-lsp on PATH. Walks
/// up from `#filePath` to the package root (the directory containing
/// `Package.swift`), then scans `.build/<triple>/<config>/` for the
/// executable. Skips the test if the binary isn't there — callers can
/// pre-build it with `swift build --product MDVFakeLSPServer`.
///
/// The fake server is a separate executable target in `Package.swift`;
/// `swift test` builds it as a transitive dependency of any test that
/// references the binary path, so under normal usage callers don't
/// need a manual pre-build step.
enum FakeLSPServerHelper {

    /// Locate the fake server binary. Throws `XCTSkip` if it can't be
    /// found — keeps the test out of the failure column on machines
    /// without a recent build.
    static func locate(file: StaticString = #filePath) throws -> URL {
        // Walk up from this source file to find the Package.swift
        // (package root). `#filePath` is the absolute path of *this*
        // helper at compile time — robust against test-bundle copying.
        let here = URL(fileURLWithPath: "\(file)")
        var dir = here.deletingLastPathComponent()
        let fm = FileManager.default
        while dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        guard fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path)
        else {
            throw XCTSkip("could not locate Package.swift walking up from \(here.path)")
        }
        let build = dir.appendingPathComponent(".build")
        // Search for `MDVFakeLSPServer` under any `<triple>/<config>/`.
        // Prefer debug (faster builds, matches `swift test`'s default).
        for config in ["debug", "release"] {
            if let triples = try? fm.contentsOfDirectory(
                at: build, includingPropertiesForKeys: nil) {
                for triple in triples {
                    let candidate = triple
                        .appendingPathComponent(config)
                        .appendingPathComponent("MDVFakeLSPServer")
                    if fm.isExecutableFile(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }
        throw XCTSkip("""
            MDVFakeLSPServer binary not found under \(build.path). \
            Run `swift build --product MDVFakeLSPServer` first.
            """)
    }

    /// Build an `LSPClient.Config` that targets the fake server. The
    /// workspace root is a fresh tmpdir per call so concurrent tests
    /// don't trip over each other (and so the file URIs we hand the
    /// server are stable and distinct). Env overlay sets just the
    /// MDV_FAKE_LSP_* knobs — when non-nil the full env is replaced,
    /// so we copy the parent's env first to keep PATH etc. usable.
    static func makeConfig(
        scenario: String? = nil,
        hoverDelayMs: Int? = nil,
        publishDiagnostics: Bool = false,
        file: StaticString = #filePath
    ) throws -> (config: LSPClient.Config, root: URL) {
        let binary = try locate(file: file)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeLSP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        var env: [String: String] = ProcessInfo.processInfo.environment
        if let s = scenario { env["MDV_FAKE_LSP_SCENARIO"] = s }
        if let d = hoverDelayMs { env["MDV_FAKE_LSP_HOVER_DELAY_MS"] = "\(d)" }
        if publishDiagnostics { env["MDV_FAKE_LSP_PUBLISH_DIAGNOSTICS"] = "1" }
        return (
            LSPClient.Config(
                executable: binary, arguments: [],
                workspaceRoot: tmp, environment: env),
            tmp
        )
    }

    /// Cleanup: best-effort directory remove.
    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
