import XCTest
@testable import ViewerCore

/// TSK-1129 — ENFORCEMENT of the workspace-local LSP-binary guard at the
/// real spawn site (owner-resolved: prompt-first-then-block). The decision
/// core + store have their own suites; these pin the LSPClient.init gate:
/// fail-closed with no handler, block on decline, trust-and-spawn on
/// confirm (persisted — no second prompt), and zero friction for
/// outside-workspace binaries.
final class LSPTrustEnforcementTests: XCTestCase {

    private var savedHandler: ((URL, URL) -> Bool)?
    private var workspace: URL!
    private var localBinary: URL!

    override func setUpWithError() throws {
        savedHandler = LSPTrustPrompt.confirmHandler
        LSPTrustPrompt.confirmHandler = nil
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("node_modules/.bin"),
            withIntermediateDirectories: true)
        // A benign real executable INSIDE the workspace = the threat shape.
        localBinary = workspace.appendingPathComponent("node_modules/.bin/fake-server")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/cat"), to: localBinary)
    }

    override func tearDownWithError() throws {
        LSPTrustPrompt.confirmHandler = savedHandler
        _ = LSPTrustStore.shared.revoke(localBinary)
        try? FileManager.default.removeItem(at: workspace)
    }

    private func config() -> LSPClient.Config {
        LSPClient.Config(
            executable: localBinary, arguments: [],
            workspaceRoot: workspace, environment: nil)
    }

    func test_failsClosed_withNoPromptHandler() {
        XCTAssertThrowsError(try LSPClient(config: config())) { error in
            guard case LSPError.untrustedBinary(let path)? = error as? LSPError else {
                return XCTFail("expected untrustedBinary, got \(error)")
            }
            XCTAssertEqual(path, localBinary.path)
        }
        XCTAssertFalse(LSPTrustStore.shared.isTrusted(localBinary))
    }

    func test_declineBlocks_andDoesNotPersistTrust() {
        LSPTrustPrompt.confirmHandler = { _, _ in false }
        XCTAssertThrowsError(try LSPClient(config: config()))
        XCTAssertFalse(LSPTrustStore.shared.isTrusted(localBinary),
                       "a decline must not grant trust")
    }

    func test_confirmSpawns_persistsTrust_andNeverRepromptsForTheSameBinary() throws {
        nonisolated(unsafe) var prompts = 0
        LSPTrustPrompt.confirmHandler = { _, _ in prompts += 1; return true }
        _ = try LSPClient(config: config())   // spawns /bin/cat; EOF reaps it
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(LSPTrustStore.shared.isTrusted(localBinary),
                      "confirm grants PERSISTENT trust")
        _ = try LSPClient(config: config())
        XCTAssertEqual(prompts, 1, "trusted binary must not re-prompt")
    }

    func test_outsideWorkspaceBinary_spawnsWithoutAnyPrompt() throws {
        nonisolated(unsafe) var prompts = 0
        LSPTrustPrompt.confirmHandler = { _, _ in prompts += 1; return true }
        let cfg = LSPClient.Config(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
            workspaceRoot: workspace, environment: nil)
        _ = try LSPClient(config: cfg)
        XCTAssertEqual(prompts, 0, "system binaries stay frictionless")
    }
}
