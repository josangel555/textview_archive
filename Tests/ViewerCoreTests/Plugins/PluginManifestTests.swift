import XCTest
@testable import ViewerCore

final class PluginManifestTests: XCTestCase {

    // Happy path — a minimal Tier A sidebar-section plugin parses
    // every field the registry needs.
    func test_decodes_minimal_sidebar_section_plugin() throws {
        let json = #"""
        {
          "id": "com.example.tv.notes",
          "name": "Notes",
          "version": "1.0.0",
          "author": { "name": "Example Co." },
          "hostVersion": ">=0.0.0",
          "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            {
              "type": "sidebar_section",
              "id": "notes",
              "title": "Notes",
              "icon": "note.text",
              "order": 100,
              "collapsedByDefault": true,
              "provider": { "tier": "A" }
            }
          ]
        }
        """#.data(using: .utf8)!

        let m = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(m.id, "com.example.tv.notes")
        XCTAssertEqual(m.capabilities, [.uiSidebar])
        XCTAssertEqual(m.contributes.count, 1)
        guard case .sidebarSection(let s) = m.contributes[0] else {
            return XCTFail("expected sidebar_section, got \(m.contributes[0])")
        }
        XCTAssertEqual(s.id, "notes")
        XCTAssertEqual(s.title, "Notes")
        XCTAssertEqual(s.order, 100)
        XCTAssertEqual(s.collapsedByDefault, true)
        XCTAssertEqual(s.provider, .a(rows: []))
    }

    // Forward-compat: unknown capability strings decode to `.unknown`
    // rather than throwing. Lets a plugin's compatible contributions
    // still load on a host that doesn't recognise every cap yet.
    func test_unknown_capability_decodes_to_unknown_not_throw() throws {
        let json = #"""
        {
          "id": "x", "name": "x", "version": "1.0.0",
          "author": { "name": "x" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar", "future.cap.we.dont.know"],
          "contributes": []
        }
        """#.data(using: .utf8)!
        let m = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(m.capabilities, [.uiSidebar, .unknown])
    }

    // Forward-compat: unknown contribution types decode to `.unknown`
    // and don't break sibling contributions in the same manifest.
    func test_unknown_contribution_type_decodes_to_unknown() throws {
        let json = #"""
        {
          "id": "x", "name": "x", "version": "1.0.0",
          "author": { "name": "x" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "view_mode", "id": "vm", "label": "VM",
              "fileTypes": [".proto"],
              "provider": { "tier": "B", "command": "decode" },
              "fallback": "hex" },
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "A" } }
          ]
        }
        """#.data(using: .utf8)!
        let m = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(m.contributes.count, 2)
        if case .unknown(let t) = m.contributes[0] {
            XCTAssertEqual(t, "view_mode")
        } else { XCTFail("expected unknown for view_mode") }
        if case .sidebarSection = m.contributes[1] {} else {
            XCTFail("expected sidebar_section second")
        }
    }

    // Missing required top-level field is a hard parse failure —
    // the registry surfaces this as `LoadResult.failed`.
    func test_missing_required_field_throws() {
        let json = #"""
        { "id": "x" }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: json))
    }

    // MARK: - Menu-item contributions (TSK-754)

    // A Tier A (noop) menu item parses every field the registry needs,
    // and `ui.menu` decodes to a known capability (not `.unknown`).
    func test_decodes_tier_a_menu_item() throws {
        let json = #"""
        {
          "id": "com.example.tv.tools",
          "name": "Tools", "version": "1.0.0",
          "author": { "name": "Example Co." },
          "hostVersion": ">=0.0.0", "manifestVersion": 1,
          "capabilities": ["ui.menu"],
          "contributes": [
            {
              "type": "menu_item",
              "id": "ping",
              "title": "Ping",
              "submenu": "Diagnostics",
              "order": 42,
              "action": { "tier": "A" }
            }
          ]
        }
        """#.data(using: .utf8)!

        let m = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(m.capabilities, [.uiMenu])
        guard case .menuItem(let item) = m.contributes[0] else {
            return XCTFail("expected menu_item, got \(m.contributes[0])")
        }
        XCTAssertEqual(item.id, "ping")
        XCTAssertEqual(item.title, "Ping")
        XCTAssertEqual(item.submenu, "Diagnostics")
        XCTAssertEqual(item.order, 42)
        XCTAssertEqual(item.action, .a)
    }

    // A Tier B menu item carries the subprocess bin/args/timeout, and the
    // contribution's required-capability set picks up `shell.exec` on top
    // of `ui.menu`.
    func test_decodes_tier_b_menu_item_and_required_caps() throws {
        let json = #"""
        {
          "id": "x", "name": "x", "version": "1.0.0",
          "author": { "name": "x" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.menu", "shell.exec"],
          "contributes": [
            {
              "type": "menu_item", "id": "run", "title": "Run It",
              "action": { "tier": "B", "bin": "tool", "args": ["--go"], "timeoutMs": 1234 }
            }
          ]
        }
        """#.data(using: .utf8)!
        let m = try JSONDecoder().decode(PluginManifest.self, from: json)
        guard case .menuItem(let item) = m.contributes[0] else {
            return XCTFail("expected menu_item")
        }
        XCTAssertNil(item.submenu)   // optional submenu absent ⇒ top-level
        XCTAssertEqual(item.action, .b(bin: "tool", args: ["--go"], timeoutMs: 1234))
        XCTAssertEqual(
            PluginManifest.Contribution.menuItem(item).requiredCapabilities,
            [.uiMenu, .shellExec]
        )
    }

    // A Tier A menu item requires only `ui.menu` (no shell.exec).
    func test_tier_a_menu_item_requires_only_ui_menu() throws {
        let item = PluginManifest.MenuItemContribution(
            id: "i", title: "T", action: .a
        )
        XCTAssertEqual(
            PluginManifest.Contribution.menuItem(item).requiredCapabilities,
            [.uiMenu]
        )
    }

    // A Tier B menu item missing its `bin` is a hard parse failure (the
    // same contract Tier B sidebar sections enforce) — caught at load,
    // not at invocation.
    func test_tier_b_menu_item_missing_bin_throws() {
        let json = #"""
        {
          "id": "x", "name": "x", "version": "1.0.0",
          "author": { "name": "x" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.menu", "shell.exec"],
          "contributes": [
            { "type": "menu_item", "id": "run", "title": "Run",
              "action": { "tier": "B" } }
          ]
        }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: json))
    }

    // An unknown action tier on a menu item decodes to `.unknown` (not a
    // throw), so a forward-compat manifest still loads its other items.
    func test_unknown_menu_item_tier_decodes_to_unknown() throws {
        let json = #"""
        {
          "id": "x", "name": "x", "version": "1.0.0",
          "author": { "name": "x" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.menu"],
          "contributes": [
            { "type": "menu_item", "id": "future", "title": "Future",
              "action": { "tier": "Z" } }
          ]
        }
        """#.data(using: .utf8)!
        let m = try JSONDecoder().decode(PluginManifest.self, from: json)
        guard case .menuItem(let item) = m.contributes[0] else {
            return XCTFail("expected menu_item")
        }
        XCTAssertEqual(item.action, .unknown(tier: "Z"))
    }

    // MARK: - Sidebar row actions / "buttons" (TSK-375)

    // A plain static row (no `action`) decodes with `action == nil` — the
    // pre-375 shape stays a plain text row (no button).
    func test_static_row_without_action_is_plain() throws {
        let json = #"""
        {
          "id": "x", "name": "x", "version": "1.0.0",
          "author": { "name": "x" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "A", "rows": [
                { "id": "r1", "label": "Plain", "detail": "no button" }
              ] } }
          ]
        }
        """#.data(using: .utf8)!
        let m = try JSONDecoder().decode(PluginManifest.self, from: json)
        guard case .sidebarSection(let s) = m.contributes[0],
              case .a(let rows) = s.provider else {
            return XCTFail("expected Tier A sidebar section")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].action, "a row without `action` must decode action == nil")
    }

    // A Tier A row action decodes to `.a` — a button that does nothing
    // host-side (declarative).
    func test_static_row_tier_a_action_decodes() throws {
        let json = #"""
        {
          "id": "x", "name": "x", "version": "1.0.0",
          "author": { "name": "x" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "A", "rows": [
                { "id": "r1", "label": "Noop", "action": { "tier": "A" } }
              ] } }
          ]
        }
        """#.data(using: .utf8)!
        let m = try JSONDecoder().decode(PluginManifest.self, from: json)
        guard case .sidebarSection(let s) = m.contributes[0],
              case .a(let rows) = s.provider else {
            return XCTFail("expected Tier A sidebar section")
        }
        XCTAssertEqual(rows[0].action, .a)
    }

    // A Tier B row action carries bin/args/timeout, and the SECTION's
    // required-capability set picks up `shell.exec` on top of `ui.sidebar`
    // (clicking the button spawns a subprocess).
    func test_static_row_tier_b_action_and_required_caps() throws {
        let json = #"""
        {
          "id": "x", "name": "x", "version": "1.0.0",
          "author": { "name": "x" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar", "shell.exec"],
          "contributes": [
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "A", "rows": [
                { "id": "r1", "label": "Copy as Crux URL",
                  "detail": "Copy",
                  "action": { "tier": "B", "bin": "copy.sh",
                              "args": ["--crux"], "timeoutMs": 2000 } }
              ] } }
          ]
        }
        """#.data(using: .utf8)!
        let m = try JSONDecoder().decode(PluginManifest.self, from: json)
        guard case .sidebarSection(let s) = m.contributes[0],
              case .a(let rows) = s.provider else {
            return XCTFail("expected Tier A sidebar section")
        }
        XCTAssertEqual(
            rows[0].action,
            .b(bin: "copy.sh", args: ["--crux"], timeoutMs: 2000)
        )
        XCTAssertEqual(
            PluginManifest.Contribution.sidebarSection(s).requiredCapabilities,
            [.uiSidebar, .shellExec],
            "a Tier B row action must lift the section's required caps to include shell.exec"
        )
    }

    // A Tier A section with ONLY plain rows requires only `ui.sidebar` (the
    // Tier B row-action gate must not over-fire).
    func test_static_rows_without_tier_b_action_require_only_ui_sidebar() throws {
        let s = PluginManifest.SidebarSectionContribution(
            id: "s", title: "S", icon: nil, order: nil,
            collapsedByDefault: nil,
            provider: .a(rows: [
                .init(id: "r1", label: "Plain"),
                .init(id: "r2", label: "Noop", action: .a),
            ])
        )
        XCTAssertEqual(
            PluginManifest.Contribution.sidebarSection(s).requiredCapabilities,
            [.uiSidebar]
        )
    }

    // A Tier B row action missing its `bin` is a hard parse failure (same
    // contract as a Tier B provider / menu item) — caught at load.
    func test_static_row_tier_b_action_missing_bin_throws() {
        let json = #"""
        {
          "id": "x", "name": "x", "version": "1.0.0",
          "author": { "name": "x" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar", "shell.exec"],
          "contributes": [
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "A", "rows": [
                { "id": "r1", "label": "Bad", "action": { "tier": "B" } }
              ] } }
          ]
        }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: json))
    }

    // An unknown row-action tier decodes to `.unknown` (not a throw), so a
    // forward-compat manifest still loads the rest of its rows.
    func test_static_row_unknown_action_tier_decodes_to_unknown() throws {
        let json = #"""
        {
          "id": "x", "name": "x", "version": "1.0.0",
          "author": { "name": "x" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "A", "rows": [
                { "id": "r1", "label": "Future", "action": { "tier": "Q" } }
              ] } }
          ]
        }
        """#.data(using: .utf8)!
        let m = try JSONDecoder().decode(PluginManifest.self, from: json)
        guard case .sidebarSection(let s) = m.contributes[0],
              case .a(let rows) = s.provider else {
            return XCTFail("expected Tier A sidebar section")
        }
        XCTAssertEqual(rows[0].action, .unknown(tier: "Q"))
    }
}
