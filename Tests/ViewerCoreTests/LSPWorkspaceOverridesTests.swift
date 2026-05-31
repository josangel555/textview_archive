import XCTest
@testable import ViewerCore

/// Per-workspace `lsp.json` override loader (LSP_DESIGN.md §11,
/// workspace-root placement variant). Covers:
///   - schema validation: good shape, missing top-level keys, bad
///     JSON, unknown server keys, missing `command`, wrong types.
///   - override precedence over default discovery.
///   - env merge: override env layered on top of parent env.
///   - default-discovery behaviour preserved when no override file.
final class LSPWorkspaceOverridesTests: XCTestCase {

    private var tmpRoot: URL!
    /// A directory that is a *sibling* of `tmpRoot`, i.e. outside the
    /// workspace subtree. SEC-001 only honours an override `command`
    /// that resolves outside the workspace, so trusted-path tests put
    /// their fake binary here.
    private var trustedBinDir: URL!

    override func setUp() {
        super.setUp()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsp-override-\(UUID().uuidString)")
        let base = parent.appendingPathComponent("workspace")
        let bin = parent.appendingPathComponent("trusted-bin")
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: bin, withIntermediateDirectories: true)
        tmpRoot = base
        trustedBinDir = bin
        LSPLog.resetCaptured()
    }

    override func tearDown() {
        // Remove the shared parent of tmpRoot + trustedBinDir.
        if let tmpRoot = tmpRoot {
            try? FileManager.default.removeItem(
                at: tmpRoot.deletingLastPathComponent())
        }
        LSPLog.resetCaptured()
        super.tearDown()
    }

    // MARK: - File-presence behaviour

    func test_load_noFile_returnsNil() {
        XCTAssertNil(LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot))
    }

    func test_load_emptyFile_returnsNil() throws {
        try writeOverride("")
        XCTAssertNil(LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot))
        XCTAssertFalse(LSPLog.captured().isEmpty,
                       "empty file is malformed JSON; should warn")
    }

    func test_load_malformedJson_returnsNilWithWarning() throws {
        try writeOverride("{ not valid json")
        XCTAssertNil(LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot))
        XCTAssertTrue(
            LSPLog.captured().contains(where: { $0.contains("malformed") }),
            "expected malformed-JSON warning; got \(LSPLog.captured())")
    }

    func test_load_jsonArrayAtRoot_returnsNil() throws {
        try writeOverride("[]")
        XCTAssertNil(LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot))
    }

    func test_load_missingServersKey_returnsNil() throws {
        try writeOverride(#"{"globalTimeouts": {"hoverMs": 3000}}"#)
        XCTAssertNil(LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot))
    }

    // MARK: - Schema validation per entry

    func test_load_validSwiftEntry_parses() throws {
        let bin = makeFakeBinary(named: "sourcekit-lsp")
        try writeOverride("""
        {
          "servers": {
            "swift": {
              "command": "\(bin.path)",
              "args": ["-Xfrontend", "-debug"],
              "env": { "SOURCEKIT_LOGGING": "1" }
            }
          }
        }
        """)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot)
        XCTAssertNotNil(loaded)
        let entry = loaded?.servers[.swift]
        XCTAssertEqual(entry?.command, bin.path)
        XCTAssertEqual(entry?.arguments, ["-Xfrontend", "-debug"])
        XCTAssertEqual(entry?.environment["SOURCEKIT_LOGGING"], "1")
    }

    func test_load_camelCaseKey_accepted() throws {
        // §11 uses `sourcekitLSP` as the canonical key. Both forms
        // must work so the documented schema matches reality.
        try writeOverride("""
        {
          "servers": {
            "sourcekitLSP": {
              "command": "/usr/bin/true"
            }
          }
        }
        """)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot)
        XCTAssertEqual(loaded?.servers[.swift]?.command, "/usr/bin/true")
    }

    func test_load_missingCommand_dropsEntry() throws {
        try writeOverride("""
        {
          "servers": {
            "swift": { "args": ["--help"] },
            "python": { "command": "/usr/bin/true" }
          }
        }
        """)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot)
        XCTAssertNil(loaded?.servers[.swift], "missing command → dropped")
        XCTAssertNotNil(loaded?.servers[.python], "valid sibling kept")
        XCTAssertTrue(
            LSPLog.captured().contains(where: { $0.contains("missing") }))
    }

    func test_load_emptyCommand_dropsEntry() throws {
        try writeOverride("""
        {
          "servers": {
            "swift": { "command": "" }
          }
        }
        """)
        // Only invalid entries → loader returns nil (no surviving
        // overrides).
        XCTAssertNil(LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot))
    }

    func test_load_unknownServerKey_isIgnored() throws {
        try writeOverride("""
        {
          "servers": {
            "customLuaLS": {
              "command": "/usr/bin/true",
              "extensions": ["lua"]
            }
          }
        }
        """)
        // Unknown server key → §11: "Unknown server name → ignore that
        // entry." With no other entries, the override file resolves
        // to nil.
        XCTAssertNil(LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot))
    }

    func test_load_entryNotAnObject_isSkipped() throws {
        try writeOverride("""
        {
          "servers": {
            "swift": "not-an-object",
            "python": { "command": "/usr/bin/true" }
          }
        }
        """)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot)
        XCTAssertNil(loaded?.servers[.swift])
        XCTAssertNotNil(loaded?.servers[.python])
    }

    func test_load_argsWrongType_fallsBackToEmpty() throws {
        try writeOverride("""
        {
          "servers": {
            "swift": {
              "command": "/usr/bin/true",
              "args": "not-an-array"
            }
          }
        }
        """)
        let entry = LSPWorkspaceOverrides
            .load(workspaceRoot: tmpRoot)?.servers[.swift]
        XCTAssertEqual(entry?.arguments, [],
                       "bad args type → empty (don't reject the entry)")
    }

    func test_load_envWrongType_fallsBackToEmpty() throws {
        try writeOverride("""
        {
          "servers": {
            "swift": {
              "command": "/usr/bin/true",
              "env": [1, 2, 3]
            }
          }
        }
        """)
        let entry = LSPWorkspaceOverrides
            .load(workspaceRoot: tmpRoot)?.servers[.swift]
        XCTAssertEqual(entry?.environment, [:])
    }

    func test_load_initializationOptions_round_trips() throws {
        try writeOverride("""
        {
          "servers": {
            "rustAnalyzer": { "command": "/usr/bin/true" },
            "swift": {
              "command": "/usr/bin/true",
              "initializationOptions": {
                "checkOnSave": { "enable": false },
                "procMacro": { "enable": true }
              }
            }
          }
        }
        """)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot)
        guard let initData = loaded?.servers[.swift]?.initializationOptions
        else {
            XCTFail("expected initializationOptions data"); return
        }
        let obj = try JSONSerialization.jsonObject(with: initData) as? [String: Any]
        XCTAssertNotNil(obj?["checkOnSave"])
        XCTAssertNotNil(obj?["procMacro"])
    }

    // MARK: - Env merge

    func test_mergedEnvironment_returnsNilWhenOverrideEnvEmpty() throws {
        let bin = makeFakeBinary(named: "x")
        try writeOverride("""
        {
          "servers": {
            "swift": { "command": "\(bin.path)" }
          }
        }
        """)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot)
        let merged = loaded?.mergedEnvironment(
            for: .swift, parent: ["PATH": "/usr/bin"])
        XCTAssertNil(merged,
                     "empty override env → nil means 'inherit parent unchanged'")
    }

    func test_mergedEnvironment_overlaysOnParent() throws {
        let bin = makeFakeBinary(named: "x")
        try writeOverride("""
        {
          "servers": {
            "swift": {
              "command": "\(bin.path)",
              "env": { "SOURCEKIT_LOGGING": "1", "PATH": "/opt/swift/bin" }
            }
          }
        }
        """)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot)
        let parent = ["PATH": "/usr/bin", "HOME": "/Users/me"]
        let merged = loaded?.mergedEnvironment(for: .swift, parent: parent)
        XCTAssertEqual(merged?["HOME"], "/Users/me",
                       "parent-only key preserved")
        XCTAssertEqual(merged?["PATH"], "/opt/swift/bin",
                       "override wins on conflict")
        XCTAssertEqual(merged?["SOURCEKIT_LOGGING"], "1",
                       "override-only key added")
    }

    func test_mergedEnvironment_nilForLanguageWithoutOverride() throws {
        let bin = makeFakeBinary(named: "x")
        try writeOverride("""
        {
          "servers": {
            "swift": {
              "command": "\(bin.path)",
              "env": { "SOURCEKIT_LOGGING": "1" }
            }
          }
        }
        """)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: tmpRoot)
        XCTAssertNil(loaded?.mergedEnvironment(
            for: .python, parent: ["PATH": "/usr/bin"]))
    }

    // MARK: - Registry-level override precedence

    func test_registry_overrideConfig_returnsNilWhenNoFile() {
        let cfg = LSPLanguageRegistry.overrideConfig(
            for: .swift, workspaceRoot: tmpRoot, defaultArguments: [])
        XCTAssertNil(cfg)
    }

    func test_registry_overrideConfig_wiresExecutableArgsAndEnv() throws {
        let bin = makeFakeBinary(named: "fake-sourcekit-lsp")
        try writeOverride("""
        {
          "servers": {
            "swift": {
              "command": "\(bin.path)",
              "args": ["--mode", "stdio"],
              "env": { "SOURCEKIT_LOGGING": "1" }
            }
          }
        }
        """)
        let cfg = LSPLanguageRegistry.overrideConfig(
            for: .swift, workspaceRoot: tmpRoot, defaultArguments: [])
        XCTAssertEqual(cfg?.executable.path, bin.path)
        XCTAssertEqual(cfg?.arguments, ["--mode", "stdio"])
        XCTAssertEqual(cfg?.workspaceRoot.standardizedFileURL,
                       tmpRoot.standardizedFileURL)
        // env should be a merge of parent + override
        XCTAssertEqual(cfg?.environment?["SOURCEKIT_LOGGING"], "1")
        // sanity: at least one parent-env key carried through
        let parent = ProcessInfo.processInfo.environment
        if let path = parent["PATH"] {
            XCTAssertEqual(cfg?.environment?["PATH"], path)
        }
    }

    func test_registry_overrideConfig_brokenPathFallsBackWithWarning() throws {
        let nonexistent = tmpRoot.appendingPathComponent("not-here").path
        try writeOverride("""
        {
          "servers": {
            "swift": { "command": "\(nonexistent)" }
          }
        }
        """)
        let cfg = LSPLanguageRegistry.overrideConfig(
            for: .swift, workspaceRoot: tmpRoot, defaultArguments: [])
        XCTAssertNil(cfg, "broken override path → nil (falls back to default discovery upstream)")
        XCTAssertTrue(
            LSPLog.captured().contains(where: {
                $0.contains("not found on disk")
            }),
            "expected a 'not found' warning; got \(LSPLog.captured())")
    }

    func test_registry_overrideConfig_scrubsEnvWhenAbsent() throws {
        // SEC-002: an override with no `env` of its own must still get
        // an explicit, scrubbed env (NOT nil → which `LSPClient` reads
        // as "inherit the full parent env"). Credential-shaped vars in
        // the parent must not survive; PATH/HOME must.
        let bin = makeFakeBinary(named: "x")
        setenv("AWS_SECRET_ACCESS_KEY", "leakme", 1)
        defer { unsetenv("AWS_SECRET_ACCESS_KEY") }
        try writeOverride("""
        {
          "servers": {
            "swift": { "command": "\(bin.path)" }
          }
        }
        """)
        let cfg = LSPLanguageRegistry.overrideConfig(
            for: .swift, workspaceRoot: tmpRoot, defaultArguments: [])
        XCTAssertNotNil(cfg?.environment,
                        "scrubbed env must be explicit, never nil (SEC-002)")
        XCTAssertNil(cfg?.environment?["AWS_SECRET_ACCESS_KEY"],
                     "credential-shaped var must be scrubbed from LSP child env")
        // PATH carried through the allowlist.
        if let parentPath = ProcessInfo.processInfo.environment["PATH"] {
            XCTAssertEqual(cfg?.environment?["PATH"], parentPath)
        }
    }

    // MARK: - SEC-001 interim trust hardening

    func test_overrideConfig_refusesCommandInsideWorkspace() throws {
        // A binary checked into / dropped under the workspace is the
        // RCE vector. The override command must be refused and we must
        // NOT spawn it. (sourcekit-lsp may or may not be installed on
        // the host; if it is, we fall back to it — never to the
        // in-workspace path.)
        let evil = makeFakeBinary(named: "evil-lsp", inWorkspace: true)
        try writeOverride("""
        {
          "servers": {
            "swift": { "command": "\(evil.path)", "args": ["--pwn"] }
          }
        }
        """)
        let cfg = LSPLanguageRegistry.overrideConfig(
            for: .swift, workspaceRoot: tmpRoot, defaultArguments: [])
        if let cfg {
            XCTAssertNotEqual(cfg.executable.path, evil.path,
                              "must never spawn the in-workspace override binary")
            XCTAssertFalse(
                LSPLanguageRegistry.isPath(cfg.executable, inSubtreeOf: tmpRoot),
                "fallback binary must resolve outside the workspace")
        }
        XCTAssertTrue(
            LSPLog.captured().contains(where: { $0.contains("refused") }),
            "expected a refusal warning; got \(LSPLog.captured())")
    }

    func test_overrideConfig_honoursTrustedCommandOutsideWorkspace() throws {
        // Binary outside the workspace subtree, dir not world-writable
        // → trusted, honoured verbatim.
        let good = makeFakeBinary(named: "trusted-lsp")
        try writeOverride("""
        {
          "servers": {
            "swift": { "command": "\(good.path)", "args": ["--ok"] }
          }
        }
        """)
        let cfg = LSPLanguageRegistry.overrideConfig(
            for: .swift, workspaceRoot: tmpRoot, defaultArguments: [])
        XCTAssertEqual(cfg?.executable.path, good.path)
        XCTAssertEqual(cfg?.arguments, ["--ok"],
                       "trusted command uses user args verbatim (no defaults prepended)")
    }

    func test_overrideConfig_refusesCommandInWorldWritableDir() throws {
        // Even outside the workspace, a world-writable container dir
        // means anyone can swap the binary → refuse.
        let good = makeFakeBinary(named: "swappable-lsp")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: trustedBinDir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: trustedBinDir.path)
        }
        try writeOverride("""
        {
          "servers": {
            "swift": { "command": "\(good.path)" }
          }
        }
        """)
        let cfg = LSPLanguageRegistry.overrideConfig(
            for: .swift, workspaceRoot: tmpRoot, defaultArguments: [])
        if let cfg {
            XCTAssertNotEqual(cfg.executable.path, good.path,
                              "world-writable dir → command must be refused")
        }
        XCTAssertTrue(
            LSPLog.captured().contains(where: { $0.contains("refused") }))
    }

    func test_isPath_inSubtreeOf_componentWiseMatch() {
        let root = URL(fileURLWithPath: "/tmp/foo")
        XCTAssertTrue(LSPLanguageRegistry.isPath(
            URL(fileURLWithPath: "/tmp/foo/bin/x"), inSubtreeOf: root))
        XCTAssertTrue(LSPLanguageRegistry.isPath(
            URL(fileURLWithPath: "/tmp/foo"), inSubtreeOf: root))
        // `/tmp/foobar` must NOT be considered inside `/tmp/foo`.
        XCTAssertFalse(LSPLanguageRegistry.isPath(
            URL(fileURLWithPath: "/tmp/foobar/x"), inSubtreeOf: root))
        XCTAssertFalse(LSPLanguageRegistry.isPath(
            URL(fileURLWithPath: "/etc/passwd"), inSubtreeOf: root))
    }

    func test_scrubbedLaunchEnvironment_dropsCredsKeepsAllowlist() {
        let parent: [String: String] = [
            "PATH": "/usr/bin",
            "HOME": "/Users/me",
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "TMPDIR": "/var/folders/x",
            "AWS_SECRET_ACCESS_KEY": "leak",
            "GITHUB_TOKEN": "leak",
            "MY_API_SECRET": "leak",
            "ANTHROPIC_API_KEY": "leak",
        ]
        let scrubbed = LSPLanguageRegistry.scrubbedLaunchEnvironment(parent: parent)
        XCTAssertEqual(scrubbed["PATH"], "/usr/bin")
        XCTAssertEqual(scrubbed["HOME"], "/Users/me")
        XCTAssertEqual(scrubbed["LANG"], "en_US.UTF-8")
        XCTAssertEqual(scrubbed["LC_CTYPE"], "UTF-8")
        XCTAssertEqual(scrubbed["TMPDIR"], "/var/folders/x")
        XCTAssertNil(scrubbed["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(scrubbed["GITHUB_TOKEN"])
        XCTAssertNil(scrubbed["MY_API_SECRET"])
        XCTAssertNil(scrubbed["ANTHROPIC_API_KEY"])
    }

    // MARK: - Default-discovery preservation

    func test_defaultRegistry_unchangedWhenNoOverrideFile() {
        // No `lsp.json` in tmpRoot. The Swift launcher should behave
        // exactly as before: either resolve sourcekit-lsp via xcrun
        // and produce a Config, or return nil because the binary
        // wasn't found. The host running tests may or may not have
        // sourcekit-lsp, so we don't assert presence — only that the
        // override path didn't poison the call.
        guard let entry = LSPLanguageRegistry.default.entry(for: .swift)
        else {
            XCTFail("expected .swift entry in default registry"); return
        }
        let cfg = entry.serverLauncher(tmpRoot)
        if cfg != nil {
            // If discovery succeeded, the executable is whatever
            // xcrun resolved — definitely NOT inside our tmp dir.
            XCTAssertFalse(
                cfg!.executable.path.hasPrefix(tmpRoot.path),
                "default discovery shouldn't return a path under the workspace tmp dir")
            // No env override → inherit parent env (nil).
            XCTAssertNil(cfg!.environment)
        }
        // No warnings emitted when no override file exists.
        XCTAssertTrue(
            LSPLog.captured().isEmpty,
            "no warnings expected with no override file; got \(LSPLog.captured())")
    }

    func test_defaultRegistry_overridePrecedesDiscovery() throws {
        // Drop in a Swift override pointing at a known binary we own
        // (a shell script). The launcher should pick it up regardless
        // of whether sourcekit-lsp is on the host's PATH.
        let bin = makeFakeBinary(named: "fake-sourcekit-lsp")
        try writeOverride("""
        {
          "servers": {
            "swift": {
              "command": "\(bin.path)",
              "args": ["--fake"]
            }
          }
        }
        """)
        guard let entry = LSPLanguageRegistry.default.entry(for: .swift)
        else { XCTFail("missing .swift"); return }
        let cfg = entry.serverLauncher(tmpRoot)
        XCTAssertEqual(cfg?.executable.path, bin.path,
                       "override should beat default sourcekit-lsp discovery")
        XCTAssertEqual(cfg?.arguments, ["--fake"])
    }

    func test_defaultRegistry_javaOverrideSkipsJdtlsDataDir() throws {
        // Default Java launcher injects `-data <dir>` arguments. The
        // override path must NOT smuggle those in — the user owns
        // spawn config entirely once they've defined an override.
        let bin = makeFakeBinary(named: "fake-jdtls")
        try writeOverride("""
        {
          "servers": {
            "java": {
              "command": "\(bin.path)",
              "args": ["--my-args"]
            }
          }
        }
        """)
        guard let entry = LSPLanguageRegistry.default.entry(for: .java)
        else { XCTFail("missing .java"); return }
        let cfg = entry.serverLauncher(tmpRoot)
        XCTAssertEqual(cfg?.arguments, ["--my-args"])
        XCTAssertFalse(cfg?.arguments.contains("-data") ?? true,
                       "override path should not inject -data <dir>")
    }

    // MARK: - language-key helpers

    func test_languageFor_recognisesCanonicalAndAliasForms() {
        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "swift"), .swift)
        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "Swift"), .swift)
        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "sourcekitLSP"), .swift)
        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "sourcekit-lsp"), .swift)

        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "typescript"), .typescript)
        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "javascript"), .typescript)
        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "typescript-language-server"),
                       .typescript)

        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "python"), .python)
        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "pyright"), .python)
        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "pyright-langserver"),
                       .python)

        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "java"), .java)
        XCTAssertEqual(LSPWorkspaceOverrides.languageFor(key: "jdtls"), .java)

        XCTAssertNil(LSPWorkspaceOverrides.languageFor(key: "rust"))
        XCTAssertNil(LSPWorkspaceOverrides.languageFor(key: "go"))
        XCTAssertNil(LSPWorkspaceOverrides.languageFor(key: ""))
    }

    // MARK: - Helpers

    private func writeOverride(_ contents: String) throws {
        let file = tmpRoot.appendingPathComponent(LSPWorkspaceOverrides.fileName)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Make an executable file we can point an override `command` at.
    /// The override loader only checks `FileManager.fileExists`; we
    /// don't need to actually run it. Default location is the
    /// *trusted* (outside-workspace) bin dir so `overrideConfig`
    /// honours the command (SEC-001). Pass `inWorkspace: true` to
    /// exercise the refusal path.
    private func makeFakeBinary(named name: String, inWorkspace: Bool = false) -> URL {
        let dir = inWorkspace ? tmpRoot! : trustedBinDir!
        let bin = dir.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: bin.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
        return bin
    }
}
