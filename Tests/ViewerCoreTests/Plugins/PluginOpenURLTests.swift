import XCTest
@testable import ViewerCore

/// TSK-782 — Tier U (`openURL`) menu-item action: manifest decode +
/// capability gating + end-to-end registry wiring. The foundation for
/// office/web integrations (Docs, Wiki, Code Review, CodeSearch). These
/// pin the model + the invocation BEHAVIOUR (which URL gets opened) so a
/// logic regression fails on the host gate even though the real menu
/// click is VM-only.
@MainActor
final class PluginOpenURLTests: XCTestCase {

    // MARK: - setup mirroring PluginRegistryTests

    private var grantStoreFile: URL!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDVGrantsOpenURL-\(UUID().uuidString).json")
        grantStoreFile = tmp
        await MainActor.run {
            PluginRegistry.shared._resetForTests()
            PluginRegistry.shared.grantStore = PluginGrantStore(url: tmp)
            // Reset the URL seams between tests (a prior test's stub
            // opener/context must not leak).
            PluginRegistry.shared._setURLOpener { _ in }
            PluginRegistry.shared._setURLContextProvider { .init() }
        }
    }

    override func tearDown() async throws {
        if let f = grantStoreFile { try? FileManager.default.removeItem(at: f) }
    }

    private func makePluginsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDVOpenURLTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writePlugin(in pluginsDir: URL, id: String, manifestJSON: String) throws -> URL {
        let folder = pluginsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifestJSON.data(using: .utf8)!.write(
            to: folder.appendingPathComponent("plugin.json")
        )
        return folder
    }

    private func grant(_ pluginID: String, _ caps: [String], version: String = "1.0.0") {
        PluginRegistry.shared.grantStore.record(
            pluginID: pluginID, version: version,
            capabilities: caps, decision: .granted
        )
    }

    // MARK: - Manifest decode

    func test_decodes_tier_U_menu_item() throws {
        let json = #"""
        {
          "id": "com.example.codesearch", "name": "CodeSearch", "version": "1.0.0",
          "author": { "name": "Example" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.menu", "web.open"],
          "contributes": [
            { "type": "menu_item", "id": "search", "title": "Search in CodeSearch",
              "action": { "tier": "U", "urlTemplate": "https://cs.example.com/?q={query}" } }
          ]
        }
        """#.data(using: .utf8)!
        let m = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(m.capabilities, [.uiMenu, .webOpen])
        guard case .menuItem(let mi) = m.contributes[0] else {
            return XCTFail("expected menu_item, got \(m.contributes[0])")
        }
        guard case .openURL(let template) = mi.action else {
            return XCTFail("expected .openURL, got \(mi.action)")
        }
        XCTAssertEqual(template, "https://cs.example.com/?q={query}")
    }

    // Tier U with no `urlTemplate` is a decode error (fail at load, not
    // silently inert) — same contract as Tier B's missing `bin`.
    func test_tier_U_missing_template_is_decode_error() {
        let json = #"""
        {
          "id": "x", "name": "x", "version": "1.0.0", "author": { "name": "x" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.menu", "web.open"],
          "contributes": [
            { "type": "menu_item", "id": "m", "title": "M",
              "action": { "tier": "U" } }
          ]
        }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: json))
    }

    func test_openURL_action_requires_web_open_capability() {
        let action = PluginManifest.MenuItemContribution.Action.openURL(
            urlTemplate: "https://x.example.com")
        let contribution = PluginManifest.Contribution.menuItem(
            .init(id: "m", title: "M", action: action))
        XCTAssertEqual(
            contribution.requiredCapabilities,
            [.uiMenu, .webOpen]
        )
    }

    // MARK: - Registry wiring + invocation behaviour

    func test_loads_tier_U_menu_item_and_invoke_opens_validated_url() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePlugin(in: dir, id: "com.example.cr", manifestJSON: #"""
        {
          "id": "com.example.cr", "name": "Code Review", "version": "1.0.0",
          "author": { "name": "Example" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.menu", "web.open"],
          "contributes": [
            { "type": "menu_item", "id": "open-cr", "title": "Open in Code Review",
              "action": { "tier": "U",
                "urlTemplate": "https://cr.example.com/c?path={path}&line={line}" } }
          ]
        }
        """#)
        grant("com.example.cr", ["ui.menu", "web.open"])

        // Inject a capturing opener + a host context.
        var opened: [URL] = []
        PluginRegistry.shared._setURLOpener { opened.append($0) }
        PluginRegistry.shared._setURLContextProvider {
            .init(path: "/repo/src/main.swift", line: 42)
        }

        let results = PluginRegistry.shared.loadAll(from: dir)
        XCTAssertEqual(results.count, 1)
        if case .loaded = results[0].status {} else {
            XCTFail("expected .loaded, got \(results[0].status)")
        }

        // The menu entry registered and its invoke fires the opener with
        // the expanded + validated URL.
        let entry = PluginRegistry.shared.menuItems.all.first { $0.itemID == "open-cr" }
        XCTAssertNotNil(entry)
        XCTAssertNotNil(entry?.invoke, "Tier U item must be enabled (has an invoke)")
        entry?.invoke?()

        XCTAssertEqual(opened.map(\.absoluteString),
                       ["https://cr.example.com/c?path=%2Frepo%2Fsrc%2Fmain.swift&line=42"])
    }

    // Tier U item missing the `web.open` grant declaration is gated out:
    // it never registers, so no menu entry exists to click.
    func test_tier_U_without_web_open_capability_is_skipped() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePlugin(in: dir, id: "com.example.nocap", manifestJSON: #"""
        {
          "id": "com.example.nocap", "name": "NoCap", "version": "1.0.0",
          "author": { "name": "Example" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.menu"],
          "contributes": [
            { "type": "menu_item", "id": "x", "title": "X",
              "action": { "tier": "U", "urlTemplate": "https://x.example.com" } }
          ]
        }
        """#)
        grant("com.example.nocap", ["ui.menu"])

        let results = PluginRegistry.shared.loadAll(from: dir)
        guard case .loadedWithWarnings(let warnings) = results[0].status else {
            return XCTFail("expected warnings, got \(results[0].status)")
        }
        XCTAssertTrue(warnings.contains { $0.contains("web.open") },
                      "warning should name the missing capability: \(warnings)")
        XCTAssertNil(PluginRegistry.shared.menuItems.all.first { $0.itemID == "x" })
    }

    // A Tier U item whose template fails validation at invoke time (bad
    // scheme) does NOT open anything — the perimeter is enforced in the
    // registry, not deferred to the opener.
    func test_invoke_with_disallowed_scheme_opens_nothing() {
        var opened: [URL] = []
        PluginRegistry.shared._setURLOpener { opened.append($0) }
        PluginRegistry.shared._setURLContextProvider { .init(path: "/etc/passwd") }

        let result = PluginRegistry.shared.invokeOpenURL(
            template: "file://localhost/{path}")
        if case .success = result { XCTFail("expected failure for file scheme") }
        XCTAssertTrue(opened.isEmpty, "no URL should be opened on validation failure")
    }

    // invokeOpenURL expands against the LIVE context provider, so the
    // same template opens different URLs as the focused doc changes.
    func test_invoke_reexpands_against_live_context() {
        var opened: [URL] = []
        PluginRegistry.shared._setURLOpener { opened.append($0) }

        PluginRegistry.shared._setURLContextProvider { .init(query: "first") }
        PluginRegistry.shared.invokeOpenURL(
            template: "https://s.example.com/?q={query}")

        PluginRegistry.shared._setURLContextProvider { .init(query: "second") }
        PluginRegistry.shared.invokeOpenURL(
            template: "https://s.example.com/?q={query}")

        XCTAssertEqual(opened.map(\.absoluteString), [
            "https://s.example.com/?q=first",
            "https://s.example.com/?q=second",
        ])
    }
}
