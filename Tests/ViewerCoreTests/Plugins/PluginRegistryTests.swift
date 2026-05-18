import XCTest
@testable import ViewerCore

@MainActor
final class PluginRegistryTests: XCTestCase {

    private func makePluginsDir() throws -> URL {
        // Use the temporary directory (per `CLAUDE.md`: never touch
        // ~/Documents from automated paths).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDVPluginsTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePlugin(in pluginsDir: URL, id: String, manifestJSON: String) throws -> URL {
        let folder = pluginsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifestJSON.data(using: .utf8)!.write(
            to: folder.appendingPathComponent("plugin.json")
        )
        return folder
    }

    /// Per-test temp grant store. We point the shared registry at a
    /// fresh file under `tmp/` so the host's real grants.json is never
    /// touched, then auto-grant the test plugins' caps (the v1 grant
    /// gate would otherwise return `.awaitingGrant` for every fixture).
    private var grantStoreFile: URL!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDVGrantsTest-\(UUID().uuidString).json")
        grantStoreFile = tmp
        await MainActor.run {
            PluginRegistry.shared._resetForTests()
            PluginRegistry.shared.grantStore = PluginGrantStore(url: tmp)
        }
    }

    override func tearDown() async throws {
        if let f = grantStoreFile {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Convenience: pre-grant a plugin's capabilities so loadOne won't
    /// stop at `.awaitingGrant`. Tests that exercise the grant gate
    /// itself skip this and call `record` directly.
    @MainActor
    private func grant(_ pluginID: String, _ caps: [String], version: String = "1.0.0") {
        PluginRegistry.shared.grantStore.record(
            pluginID: pluginID, version: version,
            capabilities: caps, decision: .granted
        )
    }

    func test_loadAll_skips_missing_directory_silently() {
        let bogus = URL(fileURLWithPath: "/var/folders/this/does/not/exist/MDVPluginsTest-nope")
        let results = PluginRegistry.shared.loadAll(from: bogus)
        XCTAssertTrue(results.isEmpty)
    }

    func test_loads_valid_tier_a_sidebar_plugin() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writePlugin(in: dir, id: "com.test.ok", manifestJSON: #"""
        {
          "id": "com.test.ok", "name": "OK", "version": "1.0.0",
          "author": { "name": "Test" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "s1", "title": "S1",
              "provider": { "tier": "A" } }
          ]
        }
        """#)
        grant("com.test.ok", ["ui.sidebar"])

        let results = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].pluginID, "com.test.ok")
        if case .loaded = results[0].status {} else {
            XCTFail("expected .loaded, got \(results[0].status)")
        }
        let entries = PluginRegistry.shared.sidebarSections.all
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sectionID, "s1")
    }

    // Fail isolation: a broken plugin must not prevent a good plugin
    // in the same Plugins/ folder from loading.
    func test_malformed_plugin_does_not_block_sibling() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writePlugin(in: dir, id: "com.test.bad", manifestJSON: "{ not json")
        _ = try writePlugin(in: dir, id: "com.test.good", manifestJSON: #"""
        {
          "id": "com.test.good", "name": "Good", "version": "1.0.0",
          "author": { "name": "Test" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "good", "title": "Good",
              "provider": { "tier": "A" } }
          ]
        }
        """#)
        grant("com.test.good", ["ui.sidebar"])

        let results = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(results.count, 2)
        let good = results.first { $0.pluginID == "com.test.good" }
        let bad = results.first { $0.pluginID == nil }
        XCTAssertNotNil(good)
        XCTAssertNotNil(bad)
        if case .failed = bad?.status {} else { XCTFail("expected failed for malformed") }
        if case .loaded = good?.status {} else { XCTFail("expected loaded for good sibling") }
        XCTAssertEqual(PluginRegistry.shared.sidebarSections.all.map(\.sectionID), ["good"])
    }

    // Capability gate: contribution requiring `ui.sidebar` but plugin
    // didn't declare it → contribution dropped, plugin still registers
    // (with warning). Matches design §5 "no silent escalation."
    func test_contribution_missing_required_capability_is_dropped() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writePlugin(in: dir, id: "com.test.nocap", manifestJSON: #"""
        {
          "id": "com.test.nocap", "name": "NoCap", "version": "1.0.0",
          "author": { "name": "Test" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": [],
          "contributes": [
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "A" } }
          ]
        }
        """#)
        let results = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(results.count, 1)
        if case .loadedWithWarnings(let w) = results[0].status {
            XCTAssertTrue(w.contains { $0.contains("uiSidebar") || $0.contains("ui.sidebar") },
                          "expected warning mentioning the missing cap, got: \(w)")
        } else {
            XCTFail("expected warnings, got \(results[0].status)")
        }
        XCTAssertTrue(PluginRegistry.shared.sidebarSections.all.isEmpty)
    }

    // Tier C parses but is rejected in v1 (WebView is Phase 2).
    func test_tier_c_sidebar_section_is_skipped_with_warning() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writePlugin(in: dir, id: "com.test.c", manifestJSON: #"""
        {
          "id": "com.test.c", "name": "C", "version": "1.0.0",
          "author": { "name": "Test" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "C" } }
          ]
        }
        """#)
        grant("com.test.c", ["ui.sidebar"])
        let results = PluginRegistry.shared.loadAll(from: dir)
        if case .loadedWithWarnings(let w) = results[0].status {
            XCTAssertTrue(w.contains { $0.contains("tier C") })
        } else {
            XCTFail("expected warnings, got \(results[0].status)")
        }
        XCTAssertTrue(PluginRegistry.shared.sidebarSections.all.isEmpty)
    }

    // Tier B without `bin` is a hard decode error.
    func test_tier_b_without_bin_fails_to_parse() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writePlugin(in: dir, id: "com.test.b.nobin", manifestJSON: #"""
        {
          "id": "com.test.b.nobin", "name": "B", "version": "1.0.0",
          "author": { "name": "Test" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar", "shell.exec"],
          "contributes": [
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "B" } }
          ]
        }
        """#)
        let results = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(results.count, 1)
        if case .failed = results[0].status {} else {
            XCTFail("expected .failed (missing bin), got \(results[0].status)")
        }
    }

    // Plugin that declares caps but user hasn't decided yet → awaitingGrant.
    func test_awaitingGrant_when_no_decision_recorded() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writePlugin(in: dir, id: "com.test.needsgrant", manifestJSON: #"""
        {
          "id": "com.test.needsgrant", "name": "N", "version": "1.0.0",
          "author": { "name": "T" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "A" } }
          ]
        }
        """#)
        let results = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(results.count, 1)
        if case .awaitingGrant(let caps) = results[0].status {
            XCTAssertEqual(caps, ["ui.sidebar"])
        } else {
            XCTFail("expected .awaitingGrant, got \(results[0].status)")
        }
        // Sidebar section is NOT registered yet.
        XCTAssertTrue(PluginRegistry.shared.sidebarSections.all.isEmpty)
        // Now the user grants and we reload.
        grant("com.test.needsgrant", ["ui.sidebar"])
        let after = PluginRegistry.shared.reloadOne(folder: dir.appendingPathComponent("com.test.needsgrant"))
        if case .loaded = after.status {} else {
            XCTFail("expected .loaded after grant, got \(after.status)")
        }
        XCTAssertEqual(PluginRegistry.shared.sidebarSections.all.count, 1)
    }

    // User said "no" → contributions stay unregistered, plugin still
    // listed under loaded (so Settings can revoke + retry).
    func test_denied_grant_blocks_contributions() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writePlugin(in: dir, id: "com.test.denied", manifestJSON: #"""
        {
          "id": "com.test.denied", "name": "D", "version": "1.0.0",
          "author": { "name": "T" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "A" } }
          ]
        }
        """#)
        PluginRegistry.shared.grantStore.record(
            pluginID: "com.test.denied", version: "1.0.0",
            capabilities: ["ui.sidebar"], decision: .denied
        )
        let results = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(results.count, 1)
        if case .loadedWithWarnings(let w) = results[0].status {
            XCTAssertTrue(w.contains { $0.contains("denied") })
        } else {
            XCTFail("expected loadedWithWarnings, got \(results[0].status)")
        }
        XCTAssertTrue(PluginRegistry.shared.sidebarSections.all.isEmpty)
        // The plugin entry IS present (so Settings can list + offer retry).
        XCTAssertNotNil(PluginRegistry.shared.loaded["com.test.denied"])
    }

    // setEnabled drops contributions when off; re-registers when on.
    func test_setEnabled_drops_and_restores_contributions() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writePlugin(in: dir, id: "com.test.toggle", manifestJSON: #"""
        {
          "id": "com.test.toggle", "name": "T", "version": "1.0.0",
          "author": { "name": "T" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "z", "title": "Z",
              "provider": { "tier": "A" } }
          ]
        }
        """#)
        grant("com.test.toggle", ["ui.sidebar"])
        _ = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(PluginRegistry.shared.sidebarSections.all.count, 1)
        PluginRegistry.shared.setEnabled("com.test.toggle", enabled: false)
        XCTAssertTrue(PluginRegistry.shared.sidebarSections.all.isEmpty)
        PluginRegistry.shared.setEnabled("com.test.toggle", enabled: true)
        XCTAssertEqual(PluginRegistry.shared.sidebarSections.all.count, 1)
    }

    // Lifecycle: unload drops the plugin's contributions atomically.
    func test_unload_removes_contributions() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writePlugin(in: dir, id: "com.test.unload", manifestJSON: #"""
        {
          "id": "com.test.unload", "name": "U", "version": "1.0.0",
          "author": { "name": "T" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "z", "title": "Z",
              "provider": { "tier": "A" } }
          ]
        }
        """#)
        grant("com.test.unload", ["ui.sidebar"])
        _ = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(PluginRegistry.shared.sidebarSections.all.count, 1)
        PluginRegistry.shared.unload("com.test.unload")
        XCTAssertTrue(PluginRegistry.shared.sidebarSections.all.isEmpty)
    }

    // Idempotence: calling loadAll twice on the same dir doesn't
    // double-register the same contributions.
    func test_loadAll_is_idempotent() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writePlugin(in: dir, id: "com.test.idem", manifestJSON: #"""
        {
          "id": "com.test.idem", "name": "I", "version": "1.0.0",
          "author": { "name": "T" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "z", "title": "Z",
              "provider": { "tier": "A" } }
          ]
        }
        """#)
        grant("com.test.idem", ["ui.sidebar"])
        _ = PluginRegistry.shared.loadAll(from: dir)
        _ = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(PluginRegistry.shared.sidebarSections.all.count, 1)
    }

    // End-to-end: a Tier B sidebar section, with a real shell-script
    // bin, loads + returns rows from the subprocess.
    func test_tier_b_end_to_end_provides_rows_from_subprocess() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try writePlugin(in: dir, id: "com.test.tierb", manifestJSON: #"""
        {
          "id": "com.test.tierb", "name": "B", "version": "1.0.0",
          "author": { "name": "T" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar", "shell.exec"],
          "contributes": [
            { "type": "sidebar_section", "id": "rows", "title": "ROWS",
              "provider": { "tier": "B", "bin": "bin.sh", "args": [] } }
          ]
        }
        """#)
        let binURL = folder.appendingPathComponent("bin.sh")
        try """
        #!/bin/sh
        cat >/dev/null
        echo '{"rows":[{"id":"r1","label":"row one","detail":"yes"}]}'
        """.data(using: .utf8)!.write(to: binURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: binURL.path)

        grant("com.test.tierb", ["shell.exec", "ui.sidebar"])
        let results = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(results.count, 1)
        if case .loaded = results[0].status {} else {
            XCTFail("expected .loaded, got \(results[0].status)")
        }
        let entries = PluginRegistry.shared.sidebarSections.all
        XCTAssertEqual(entries.count, 1)
        let rows = entries[0].provider(.init(openFileContents: [:]))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "row one")
        XCTAssertEqual(rows[0].detail, "yes")
    }

    // Tier B that declares Tier B provider but is missing `shell.exec`
    // capability: contribution dropped with warning.
    func test_tier_b_without_shell_exec_capability_is_skipped() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writePlugin(in: dir, id: "com.test.tierb.nocap", manifestJSON: #"""
        {
          "id": "com.test.tierb.nocap", "name": "B", "version": "1.0.0",
          "author": { "name": "T" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "rows", "title": "R",
              "provider": { "tier": "B", "bin": "bin.sh", "args": [] } }
          ]
        }
        """#)
        grant("com.test.tierb.nocap", ["ui.sidebar"])
        let results = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(results.count, 1)
        if case .loadedWithWarnings(let w) = results[0].status {
            XCTAssertTrue(w.contains { $0.contains("shellExec") || $0.contains("shell.exec") })
        } else {
            XCTFail("expected loadedWithWarnings, got \(results[0].status)")
        }
        XCTAssertTrue(PluginRegistry.shared.sidebarSections.all.isEmpty)
    }
}
