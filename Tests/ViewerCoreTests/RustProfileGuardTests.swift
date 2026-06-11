import XCTest

/// TSK-161 — the rust-core app-link profile gate (build-rust-core.sh),
/// pinned on the host. The staged .a links into the GUI host, so it MUST
/// be a panic=unwind profile — `release` is panic=abort, which turns the
/// FFI catch_unwind shims into no-ops (a core panic SIGABRTs the app).
/// The script REJECTS disallowed profiles before any cargo work, so the
/// negative path is instant and network/toolchain-free.
final class RustProfileGuardTests: XCTestCase {

    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/build-rust-core.sh")

    private func runBuildScript(profile: String) throws -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.script.path]
        var env = ProcessInfo.processInfo.environment
        env["MDV_RUST_PROFILE"] = profile
        p.environment = env
        let err = Pipe()
        p.standardOutput = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func test_releaseProfile_rejectedBeforeAnyBuild() throws {
        let r = try runBuildScript(profile: "release")
        XCTAssertEqual(r.status, 1,
            "panic=abort 'release' must be refused for the app-link path")
        XCTAssertTrue(r.stderr.contains("not allowed"), r.stderr)
        XCTAssertTrue(r.stderr.contains("panic=unwind"), r.stderr)
    }

    func test_unknownCustomProfile_rejected() throws {
        // Custom profiles inherit release's panic=abort unless they opt
        // back in — the allowlist must refuse anything it can't vouch for.
        let r = try runBuildScript(profile: "speedy-custom")
        XCTAssertEqual(r.status, 1, "unknown profile must be refused")
        XCTAssertTrue(r.stderr.contains("not allowed"), r.stderr)
    }
}
