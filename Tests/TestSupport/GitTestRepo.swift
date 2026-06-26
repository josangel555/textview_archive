import Foundation

/// Shared git-fixture builder for the git-test classes (TSK-850).
///
/// Moved to its own `TestSupport` library target (TSK-1174) so BOTH
/// `ViewerCoreTests` and `ViewerUITests` can share one git-repo fixture builder
/// — test targets can't import each other, so the cross-target helper lives in a
/// plain (test-only, never shipped) library target both depend on.
///
/// The per-class `makeRepo()` was copy-pasted across ~10 classes, each spawning
/// FOUR separate `git` processes for the identical `init` + email/name/gpgsign
/// config. This batches those into ONE `/bin/bash -c` invocation — a
/// byte-identical repo with 3 fewer process spawns — and centralizes it. Tests
/// keep their own `run`/`writeFile` for the per-test commits and call those
/// after `makeRepo`. `branch`/`email`/`name` default to the values most git-test
/// classes use; the few that differ pass overrides.
public enum GitTestRepo {
    public struct SetupError: Error { public let output: String }

    /// A fresh repo in a unique temp dir: `git init -b <branch>` + the standard
    /// identity / gpgsign config, all in one shell call. Caller removes the dir.
    public static func makeRepo(prefix: String,
                                at fixedDir: URL? = nil,
                                branch: String = "main",
                                email: String = "t@example.com",
                                name: String = "Tester") throws -> URL {
        // `at:` lets a class init a dir it already created (e.g. a class-level
        // tmpDir); otherwise a fresh unique temp dir is made from `prefix`.
        let dir = fixedDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One shell, four git ops — byte-identical to four separate `git`
        // Process calls (same init + config → same commit SHAs), but 1 spawn.
        // Values are single-quoted so a name/email with a space stays one arg.
        let script = "git init -q -b '\(branch)'"
            + " && git config user.email '\(email)'"
            + " && git config user.name '\(name)'"
            + " && git config commit.gpgsign false"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.currentDirectoryURL = dir
        p.arguments = ["-c", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw SetupError(
                output: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return dir
    }
}
