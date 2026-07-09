import XCTest
@testable import ViewerCore

/// TSK-1444 — `LSPPool.restart(language:)`, the "Restart" action behind the
/// status chip. Its key user value is clearing a `.dead` cooldown so a
/// crashed server can be revived on demand rather than waiting out the
/// cooldown window. Driven with a registry whose launcher points at a
/// non-existent binary: `LSPClient.init` throws `serverBinaryNotFound`
/// immediately (fast, no spawn), and with `maxRestartAttempts: 1` the entry
/// lands in `.dead` after a single failed acquire.
final class LSPPoolRestartTests: XCTestCase {

    private func deadCooldownRegistry() -> LSPLanguageRegistry {
        let entry = LSPLanguageEntry(
            language: .swift,
            fileExtensions: ["swift"],
            rootFinder: { $0.deletingLastPathComponent() },
            serverLauncher: { root in
                // Valid-looking config pointing at a binary that does not
                // exist → LSPClient.init throws at construction.
                LSPClient.Config(
                    executable: URL(fileURLWithPath: "/nonexistent/sourcekit-lsp"),
                    arguments: [],
                    workspaceRoot: root)
            })
        return LSPLanguageRegistry(entries: [entry])
    }

    private func fastDeadConfig() -> LSPPool.Config {
        LSPPool.Config(
            restartBackoff: [.zero],
            maxRestartAttempts: 1,
            deadCooldown: .seconds(60))
    }

    func test_restart_clearsDeadCooldownEntry() async {
        let pool = LSPPool(registry: deadCooldownRegistry(), config: fastDeadConfig())
        // Drive the key to `.dead` via a failed acquire.
        _ = try? await pool.client(for: URL(fileURLWithPath: "/tmp/proj/x.swift"))
        var snap = await pool.snapshot()
        XCTAssertEqual(snap.count, 1, "a failed spawn with maxRestartAttempts=1 should leave a dead entry")
        XCTAssertTrue(snap[0].isDead)

        // Restart clears it — the escape hatch from the cooldown.
        let restarted = await pool.restart(language: .swift)
        XCTAssertEqual(restarted, 1)
        snap = await pool.snapshot()
        XCTAssertEqual(snap.count, 0, "restart should drop the dead entry so the next request cold-starts")
    }

    func test_restart_emptyPool_returnsZero() async {
        let pool = LSPPool(registry: deadCooldownRegistry(), config: fastDeadConfig())
        let n = await pool.restart(language: .swift)
        XCTAssertEqual(n, 0)
    }

    func test_restart_onlyAffectsMatchingLanguage() async {
        let pool = LSPPool(registry: deadCooldownRegistry(), config: fastDeadConfig())
        _ = try? await pool.client(for: URL(fileURLWithPath: "/tmp/proj/x.swift"))
        // A different language has no entry — restarting it is a no-op and
        // must NOT clear the swift dead entry.
        let n = await pool.restart(language: .python)
        XCTAssertEqual(n, 0)
        let snap = await pool.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.first?.key.language, .swift)
    }

    func test_restart_afterCloseAll_returnsZero() async {
        let pool = LSPPool(registry: deadCooldownRegistry(), config: fastDeadConfig())
        _ = try? await pool.client(for: URL(fileURLWithPath: "/tmp/proj/x.swift"))
        await pool.closeAll()
        // Closed pool: restart is a no-op.
        let n = await pool.restart(language: .swift)
        XCTAssertEqual(n, 0)
    }
}
