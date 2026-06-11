import XCTest

/// TSK-159 + TSK-160 — vm-smoke.sh path handling, pinned on the host.
///
/// TSK-159 (bug): the launch path must be the VM-ABSOLUTE translation of
/// the host argument — the audited bug prepended the wrong prefix /
/// produced a double-slash for files outside the project root, so the VM
/// launched a nonexistent path.
/// TSK-160 (security): the path is ultimately handed to a remote sudo'd
/// `sh -c`; the host-side allowlist must refuse shell metacharacters
/// BEFORE anything leaves the machine.
///
/// `MDV_SMOKE_DRY_RUN=1` makes the script compute + validate the VM path
/// and exit before any rsync/ssh/scp, so these tests run with zero
/// network and zero VM dependency.
final class VMSmokePathGuardTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ViewerCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
    private static let script = repoRoot.appendingPathComponent("scripts/vm-smoke.sh")

    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runSmoke(arg: String?) throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.script.path] + (arg.map { [$0] } ?? [])
        var env = ProcessInfo.processInfo.environment
        env["MDV_SMOKE_DRY_RUN"] = "1"
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(status: p.terminationStatus,
                   stdout: String(decoding: out, as: UTF8.self),
                   stderr: String(decoding: err, as: UTF8.self))
    }

    /// TSK-159: an in-root file maps to the rsync mirror's ABSOLUTE path
    /// (no prefix-prepend at the launch site, no double slash).
    func test_inRootFile_translatesToVMAbsolutePath() throws {
        let r = try runSmoke(arg: Self.repoRoot.appendingPathComponent("DESIGN.md").path)
        XCTAssertEqual(r.status, 0, "dry run failed: \(r.stderr)")
        XCTAssertTrue(r.stdout.contains("DRY-RUN VM path: /Users/vm-tester/markdown_viewer/DESIGN.md"),
            "wrong VM translation — got: \(r.stdout)")
        XCTAssertFalse(r.stdout.contains("//"), "double-slash in VM path: \(r.stdout)")
    }

    /// TSK-159: an out-of-root file routes through the scp staging path —
    /// a fixed VM-absolute location, not a bogus project-root-prefixed one.
    func test_outOfRootFile_routesToStagingPath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmsmoke-outside-\(UUID().uuidString).md")
        try "x\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let r = try runSmoke(arg: tmp.path)
        XCTAssertEqual(r.status, 0, "dry run failed: \(r.stderr)")
        XCTAssertTrue(r.stdout.contains("DRY-RUN VM path: /tmp/vm-smoke-input"),
            "out-of-root file must stage to /tmp/vm-smoke-input — got: \(r.stdout)")
    }

    /// TSK-160: a filename carrying shell metacharacters must be REFUSED
    /// by the host-side allowlist (exit 1, no path echoed) — this is the
    /// guard that keeps a hostile name out of the remote sudo'd sh -c.
    func test_hostileFilename_refusedByAllowlist() throws {
        // Fixture lives under .build/ (inside the root, gitignored) so it
        // takes the in-root branch where the hostile relpath survives
        // into FILE_ARG_VM.
        let dir = Self.repoRoot.appendingPathComponent(".build/vmsmoke-fixture")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hostile = dir.appendingPathComponent("evil;$(touch pwned).md")
        try "x\n".write(to: hostile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = try runSmoke(arg: hostile.path)
        XCTAssertEqual(r.status, 1, "hostile path must be refused — stdout: \(r.stdout)")
        XCTAssertTrue(r.stderr.contains("unsafe characters"),
            "expected the allowlist rejection — stderr: \(r.stderr)")
        XCTAssertFalse(r.stdout.contains("DRY-RUN VM path"),
            "hostile path leaked past the allowlist: \(r.stdout)")
    }
}
