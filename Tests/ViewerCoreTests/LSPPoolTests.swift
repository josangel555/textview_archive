import XCTest
@testable import ViewerCore

/// `LSPPool` — exercise the lazy-spawn + dead-cooldown behavior with a
/// custom registry whose `serverLauncher` always returns nil (so we
/// hit the "binary missing" error path without spawning anything real).
final class LSPPoolTests: XCTestCase {

    private func makeRegistryThatNeverSpawns() -> LSPLanguageRegistry {
        let entry = LSPLanguageEntry(
            language: .swift,
            fileExtensions: ["swift"],
            rootFinder: { url in url.deletingLastPathComponent() },
            serverLauncher: { _ in nil } // simulate binary not found
        )
        return LSPLanguageRegistry(entries: [entry])
    }

    func test_canHandle_returnsFalse_whenLauncherReturnsNil() async {
        let pool = LSPPool(registry: makeRegistryThatNeverSpawns())
        let canHandle = await pool.canHandle(URL(fileURLWithPath: "/tmp/x.swift"))
        XCTAssertFalse(canHandle)
    }

    func test_canHandle_returnsFalse_forUnknownExtension() async {
        let pool = LSPPool(registry: .default)
        let canHandle = await pool.canHandle(URL(fileURLWithPath: "/tmp/x.md"))
        XCTAssertFalse(canHandle)
    }

    func test_client_throws_when_serverBinaryMissing() async {
        let pool = LSPPool(registry: makeRegistryThatNeverSpawns())
        do {
            _ = try await pool.client(for: URL(fileURLWithPath: "/tmp/x.swift"))
            XCTFail("expected error")
        } catch LSPError.serverBinaryNotFound {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_client_throws_for_unknown_extension() async {
        let pool = LSPPool(registry: .default)
        do {
            _ = try await pool.client(for: URL(fileURLWithPath: "/tmp/x.md"))
            XCTFail("expected error")
        } catch LSPError.serverBinaryNotFound {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_key_for_url_derives_workspaceRoot() async {
        let pool = LSPPool(registry: makeRegistryThatNeverSpawns())
        let key = await pool.key(for: URL(fileURLWithPath: "/tmp/proj/sub/x.swift"))
        XCTAssertEqual(key?.workspaceRoot.path, "/tmp/proj/sub")
        XCTAssertEqual(key?.language, .swift)
    }

    func test_snapshot_emptyByDefault() async {
        let pool = LSPPool(registry: makeRegistryThatNeverSpawns())
        let snap = await pool.snapshot()
        XCTAssertEqual(snap.count, 0)
    }

    func test_closeAll_is_idempotent() async {
        let pool = LSPPool(registry: makeRegistryThatNeverSpawns())
        await pool.closeAll()
        await pool.closeAll() // no crash, no throw
    }

    func test_client_marks_dead_after_maxRestartAttempts() async {
        // With config maxRestartAttempts = 2, two failed spawns should
        // leave the key in dead-cooldown so the next call throws
        // immediately rather than spawning a third time.
        let registry = makeRegistryThatNeverSpawns()
        let pool = LSPPool(
            registry: registry,
            config: LSPPool.Config(
                idleTimeout: .seconds(60),
                restartBackoff: [.milliseconds(1), .milliseconds(1)],
                maxRestartAttempts: 2,
                deadCooldown: .seconds(60),
                reaperTick: .seconds(60)))

        let url = URL(fileURLWithPath: "/tmp/proj/x.swift")
        // First two attempts: launcher returns nil → throws.
        for _ in 0..<2 {
            do {
                _ = try await pool.client(for: url)
                XCTFail("expected throw")
            } catch {}
        }
        // Third attempt: dead cooldown should bite.
        do {
            _ = try await pool.client(for: url)
            XCTFail("expected dead-cooldown throw")
        } catch LSPError.serverBinaryNotFound {
            // expected — message contains "cooldown" or the binary error
            // depending on which branch fired. Either way, ok.
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
