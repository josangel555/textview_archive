import XCTest
@testable import ViewerCore

/// Regression coverage for the S3/leak audit finding on
/// `Sources/ViewerCore/LSP/LSPPool.swift:68`: a warm pool entry
/// accumulates `openedFiles` / `fileVersions` / `fileHashes` forever
/// because `ensureOpened` only inserts and `didChange` only updates —
/// there was no prune path. `LSPPool.closeFile(fileURL:)` removes the
/// URL from all three structures so a long-lived workspace doesn't grow
/// unboundedly as distinct files are browsed.
///
/// Mirrors `LSPPoolFakeServerTests`' scaffolding (own registry injection
/// + `MDVFakeLSPServer`). Self-skips (not fails) when the fake-server
/// binary can't be located, so it stays host-safe in the headless gate.
final class LSPPoolCloseFile_Audit_Sources_ViewerCore_LSP_LSPPool_swift_Tests: XCTestCase {

    // MARK: - Scaffolding (matches LSPPoolFakeServerTests)

    private func makeRegistry(binary: URL) -> LSPLanguageRegistry {
        let env = ProcessInfo.processInfo.environment
        let entry = LSPLanguageEntry(
            language: .swift,
            fileExtensions: ["fakelsp"],
            rootFinder: { fileURL in fileURL.deletingLastPathComponent() },
            serverLauncher: { workspaceRoot in
                LSPClient.Config(
                    executable: binary,
                    arguments: [],
                    workspaceRoot: workspaceRoot,
                    environment: env)
            }
        )
        return LSPLanguageRegistry(entries: [entry])
    }

    private func makeTempFile(named: String = "sample.fakelsp") throws -> (root: URL, file: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSPPoolCloseFile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent(named)
        try Data("// fake".utf8).write(to: file)
        return (tmp, file)
    }

    private func tightConfig() -> LSPPool.Config {
        return LSPPool.Config(
            idleTimeout: .seconds(60),
            restartBackoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)],
            maxRestartAttempts: 3,
            deadCooldown: .milliseconds(50),
            reaperTick: .seconds(60))
    }

    // MARK: - Tests

    /// `closeFile` prunes the per-file version map. After close, the
    /// test-only version accessor returns nil — the dict entry is gone,
    /// not merely reset.
    func test_closeFile_prunesPerFileState() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary), config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        try await pool.ensureOpened(fileURL: file, text: "let a = 1")
        let opened = await pool._testFileVersion(for: file)
        XCTAssertEqual(opened, 1,
            "precondition: ensureOpened seeds version 1")

        await pool.closeFile(fileURL: file)
        let afterClose = await pool._testFileVersion(for: file)
        XCTAssertNil(afterClose,
            "closeFile must drop the per-file version entry, not just reset it")

        // The live entry itself survives (other files / future opens use
        // the same warm server) — closeFile is per-file, not per-key.
        let snap = await pool.snapshot()
        XCTAssertEqual(snap.count, 1, "closeFile must not drop the pool entry")
        XCTAssertTrue(snap.first?.isLive == true,
            "the workspace server stays live after a single file closes")
    }

    /// After `closeFile`, a fresh `ensureOpened` re-seeds version 1 — the
    /// file is treated as newly opened, proving the `openedFiles` set was
    /// pruned (otherwise `ensureOpened` short-circuits on `contains`).
    func test_closeFile_thenReopen_reseedsVersionOne() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary), config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        try await pool.ensureOpened(fileURL: file, text: "let a = 1")
        try await pool.didChange(fileURL: file, text: "let a = 2")
        let bumped = await pool._testFileVersion(for: file)
        XCTAssertEqual(bumped, 2, "precondition: a real edit bumped version to 2")

        await pool.closeFile(fileURL: file)
        let afterClose = await pool._testFileVersion(for: file)
        XCTAssertNil(afterClose,
            "closeFile drops the version entry")

        // Re-open. If openedFiles still contained the URL, ensureOpened
        // would no-op and leave the version unset; instead it must
        // re-didOpen and re-seed version 1.
        try await pool.ensureOpened(fileURL: file, text: "let a = 1")
        let reopened = await pool._testFileVersion(for: file)
        XCTAssertEqual(reopened, 1,
            "re-opening a closed file must re-seed version 1 (openedFiles was pruned)")
    }

    /// `closeFile` is idempotent and a no-op for an untracked file / no
    /// live entry — it must not spawn a server or throw.
    func test_closeFile_isNoop_whenUntracked() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary), config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        // Never opened → no entry. closeFile must not create one.
        await pool.closeFile(fileURL: file)
        let count = await pool.snapshot().count
        XCTAssertEqual(count, 0,
            "closeFile on an untracked file must not spawn a server / create an entry")

        // Idempotent after a real open+close.
        try await pool.ensureOpened(fileURL: file, text: "// x")
        await pool.closeFile(fileURL: file)
        await pool.closeFile(fileURL: file)
        let afterDoubleClose = await pool._testFileVersion(for: file)
        XCTAssertNil(afterDoubleClose,
            "double closeFile stays a no-op after the first prune")
    }
}
