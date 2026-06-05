import XCTest
import Darwin
@testable import ViewerCore

/// Regression coverage for the audit finding
/// `Sources/ViewerCore/EditorBuffer.swift:248` — EACCES on the
/// open-for-read classify step was treated as "no existing file", so a
/// save over an existing-but-unreadable file (e.g. a `0600`/`0200` secret
/// with read access stripped) silently inherited the temp file's umask
/// mode (`0644`), downgrading it to world-readable and dropping
/// owner/group.
///
/// The fix recovers mode/owner via `lstat` on EACCES and replays them
/// onto the replacement, or refuses the save — never silently downgrades.
final class Audit_Sources_ViewerCore_EditorBuffer_swift_EaccesTests: XCTestCase {

    /// A `0200` (write-only, owner-not-readable) file makes
    /// `open(O_RDONLY)` fail with EACCES. The save must NOT downgrade the
    /// mode to the umask default — it must preserve the original 0200.
    func test_save_unreadableExistingFile_preservesMode_notDowngraded() throws {
        try XCTSkipIf(getuid() == 0,
            "root can read any file, so open(O_RDONLY) won't return EACCES; skip under root")

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("write-only.txt")
        try "secret v1".write(to: url, atomically: true, encoding: .utf8)

        // Strip read access: 0200 = owner write-only. open(O_RDONLY) on
        // this returns EACCES (the exact bug condition).
        XCTAssertEqual(chmod(url.path, 0o200), 0, "test setup chmod failed")

        // Sanity: confirm the platform actually denies O_RDONLY here, so a
        // pass means we exercised the EACCES branch (not a no-op).
        let probe = open(url.path, O_RDONLY | O_NOFOLLOW)
        if probe >= 0 {
            close(probe)
            throw XCTSkip("environment allows reading a 0200 file (likely privileged); EACCES branch unreachable")
        }
        XCTAssertEqual(errno, EACCES, "expected EACCES on O_RDONLY of a 0200 file")

        _ = try EditorWriter.save("secret v2", to: url)

        // Re-loosen to read the result back for the content assertion.
        let perms = try posixPerms(url)
        XCTAssertEqual(perms, 0o200,
            "save over an unreadable (EACCES) file must preserve its mode, not downgrade to umask 0644")

        XCTAssertEqual(chmod(url.path, 0o600), 0, "post-check chmod failed")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "secret v2",
            "the new bytes must still be written")
    }

    /// The narrower, audit-named harm: a `0600` secret with read access
    /// later stripped to `0200` must not become world-readable after an
    /// in-editor save.
    func test_save_unreadableExistingFile_notWorldReadable() throws {
        try XCTSkipIf(getuid() == 0, "EACCES path unreachable under root")

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("token.txt")
        try "token v1".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(url.path, 0o200), 0, "test setup chmod failed")

        let probe = open(url.path, O_RDONLY | O_NOFOLLOW)
        if probe >= 0 {
            close(probe)
            throw XCTSkip("environment allows reading a 0200 file; EACCES branch unreachable")
        }

        _ = try EditorWriter.save("token v2", to: url)

        let perms = try posixPerms(url)
        XCTAssertEqual(perms & 0o077, 0,
            "save must not grant group/other any access to an EACCES secret")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorBufferEaccesTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func posixPerms(_ url: URL) throws -> mode_t {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw NSError(domain: "test", code: Int(errno))
        }
        return st.st_mode & 0o7777
    }
}
