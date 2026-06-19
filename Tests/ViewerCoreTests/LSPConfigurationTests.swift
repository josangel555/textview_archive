import XCTest
import Foundation
@testable import ViewerCore

/// TSK-963(a) — the single discovery + override + status snapshot model
/// (`LSPConfiguration`). All I/O is injected, so these exercise the real
/// composition logic (and the REAL trust gate for the refusal case) with
/// no xcrun/which/disk.
final class LSPConfigurationTests: XCTestCase {

    private let workspace = URL(fileURLWithPath: "/tmp/ws-963")

    // MARK: - installed vs missing

    func test_installedVsMissing_reflectsResolver() {
        // Only Swift "installed" in this fake environment.
        let fakePath = URL(fileURLWithPath: "/opt/fake/sourcekit-lsp")
        let configs = LSPConfiguration.configuration(
            for: workspace,
            resolve: { $0 == .swift ? fakePath : nil },
            loadOverrides: { _ in nil },
            searchPaths: { ["/opt/homebrew/bin"] },
            isTrusted: { _, _ in true })

        // One config per language, complete + in allCases order.
        XCTAssertEqual(configs.map(\.language), LSPLanguage.allCases,
                       "every LSPLanguage appears exactly once, in order")

        let swift = configs.first { $0.language == .swift }
        XCTAssertEqual(swift?.available, true, "Swift resolved → available")
        XCTAssertEqual(swift?.resolvedPath, fakePath.path,
                       "available config carries the resolved binary path")
        XCTAssertNil(swift?.activeOverride, "no override present")

        for c in configs where c.language != .swift {
            XCTAssertFalse(c.available, "\(c.language) unresolved → not available")
            XCTAssertNil(c.resolvedPath, "missing server has no path")
        }
    }

    // MARK: - search path list

    func test_searchPaths_nonemptyAndCarriedPerConfig() {
        // The real augmentedSearchPaths(): $PATH + common Homebrew/npm
        // prefixes. Never empty (always appends fixed prefixes).
        let configs = LSPConfiguration.configuration(
            for: workspace,
            resolve: { _ in nil },
            loadOverrides: { _ in nil })
        XCTAssertFalse(configs.isEmpty)
        for c in configs {
            XCTAssertFalse(c.searchPathsProbed.isEmpty,
                           "\(c.language) must carry the probed search-path list")
        }
        // Every config shares the same list (discovery is binary-keyed).
        let first = configs.first!.searchPathsProbed
        for c in configs {
            XCTAssertEqual(c.searchPathsProbed, first,
                           "search-path list is uniform across languages")
        }
        // Sanity: the known fixed prefix is present.
        XCTAssertTrue(first.contains("/opt/homebrew/bin"),
                      "augmented search paths include the Homebrew arm64 prefix")
    }

    // MARK: - override present and honored

    func test_overridePresentAndHonored() {
        // A trusted command (outside workspace, non-writable dir). We inject
        // the trust gate as "trusted" to isolate the carry-through behaviour.
        let cmd = "/opt/homebrew/bin/typescript-language-server"
        let overrides = makeOverrides(
            language: .typescript,
            override: .init(
                command: cmd,
                arguments: ["--stdio", "--log-level", "4"],
                environment: ["NODE_OPTIONS": "--max-old-space-size=4096"],
                initializationOptions: nil))

        let configs = LSPConfiguration.configuration(
            for: workspace,
            resolve: { _ in nil },
            loadOverrides: { _ in overrides },
            searchPaths: { ["/opt/homebrew/bin"] },
            isTrusted: { _, _ in true })

        let ts = configs.first { $0.language == .typescript }
        let active = try? XCTUnwrap(ts?.activeOverride)
        XCTAssertEqual(active?.command, cmd)
        XCTAssertEqual(active?.arguments, ["--stdio", "--log-level", "4"])
        XCTAssertTrue(active?.definesEnvironment ?? false,
                      "override declared env → flagged (values not leaked)")
        XCTAssertEqual(active?.sourceFile, overrides.sourceFile.path)
        XCTAssertEqual(active?.overrideHonored, true)
        XCTAssertNil(active?.overrideRefusedReason,
                     "honored override has no refusal reason")

        // Languages with no override entry carry nil.
        for c in configs where c.language != .typescript {
            XCTAssertNil(c.activeOverride, "\(c.language) has no override entry")
        }
    }

    // MARK: - override present but refused (REAL trust gate)

    func test_overridePresentButRefused_inWorkspace_realGate() {
        // A command path INSIDE the workspace subtree — the RCE vector the
        // real isOverrideCommandTrusted refuses. We use the DEFAULT (real)
        // trust gate here, not an injected stub, to pin the actual policy.
        let inWorkspaceCmd = workspace
            .appendingPathComponent("node_modules/.bin/typescript-language-server")
            .path
        let overrides = makeOverrides(
            language: .typescript,
            override: .init(command: inWorkspaceCmd, arguments: ["--stdio"]))

        let configs = LSPConfiguration.configuration(
            for: workspace,
            resolve: { _ in nil },
            loadOverrides: { _ in overrides },
            searchPaths: { ["/opt/homebrew/bin"] })
            // isTrusted defaults to the REAL LSPLanguageRegistry gate.

        let ts = configs.first { $0.language == .typescript }
        let active = ts?.activeOverride
        XCTAssertNotNil(active, "override entry is still surfaced even when refused")
        XCTAssertEqual(active?.command, inWorkspaceCmd)
        XCTAssertEqual(active?.overrideHonored, false,
                       "in-workspace command is refused by the real gate")
        XCTAssertNotNil(active?.overrideRefusedReason,
                        "refused override carries a human-readable reason")
        XCTAssertEqual(active?.overrideRefusedReason,
                       LSPConfiguration.RefusalReason.insideWorkspace.message,
                       "reason identifies the in-workspace cause")
    }

    func test_refusalReason_writableDir() throws {
        // A real, world-writable directory OUTSIDE the workspace → the
        // writable-dir check fires (and wins, being first), proving the
        // reason maps to the binary-safety branch rather than in-workspace.
        // (isBinarySafeToSpawn / attributesOfItem do NOT follow a final
        // symlink, so we need a real dir whose own perms are group/world-
        // writable — `/tmp/evil-lsp` would resolve to the /tmp *symlink*
        // attrs, not /private/tmp's, and read as safe.)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("lsp-cfg-writable-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dir.path)
        let writableCmd = dir.appendingPathComponent("evil-lsp")

        let reason = LSPConfiguration.refusalReason(
            for: writableCmd, workspaceRoot: workspace)
        XCTAssertEqual(reason, .writableDir,
                       "world-writable command dir → writable-dir refusal")
    }

    func test_noOverrideFile_allConfigsHaveNilOverride() {
        let configs = LSPConfiguration.configuration(
            for: workspace,
            resolve: { lang in URL(fileURLWithPath: "/opt/bin/\(lang.rawValue)") },
            loadOverrides: { _ in nil },
            searchPaths: { ["/opt/bin"] })
        XCTAssertTrue(configs.allSatisfy { $0.activeOverride == nil },
                      "no lsp.json → no active override on any language")
        XCTAssertTrue(configs.allSatisfy { $0.available },
                      "resolver returned a path for every language")
    }

    // MARK: - helpers

    private func makeOverrides(
        language: LSPLanguage,
        override: LSPWorkspaceOverrides.ServerOverride
    ) -> LSPWorkspaceOverrides {
        LSPWorkspaceOverrides(
            servers: [language: override],
            sourceFile: workspace.appendingPathComponent("lsp.json"))
    }
}
