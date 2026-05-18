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
        XCTAssertEqual(s.provider, .a)
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
}
