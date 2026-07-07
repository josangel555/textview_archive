import XCTest
@testable import ViewerCore

/// TSK-1481 — the Settings IA catalog (pinned sections, searchable, drift-guarded).
final class SettingsCatalogTests: XCTestCase {

    func test_idsAreUnique_andPrefixed() {
        let ids = SettingsCatalog.items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate setting ids")
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("mdv.settings.") },
                      "every id carries the mdv.settings. AX prefix")
    }

    func test_everyItemDescribed() {
        for item in SettingsCatalog.items {
            XCTAssertFalse(item.title.isEmpty, "\(item.id) needs a title")
            XCTAssertFalse(item.description.isEmpty,
                           "\(item.id) needs a one-line description (the ticket's bar)")
        }
    }

    func test_sections_canonicalOrder_nonEmpty() {
        let secs = SettingsCatalog.sections()
        XCTAssertFalse(secs.isEmpty)
        XCTAssertTrue(secs.allSatisfy { !$0.items.isEmpty }, "no empty section renders")
        // Monotonic in the canonical declaration order.
        let order = SettingsCatalog.Section.allCases
        let idxs = secs.map { s in order.firstIndex(of: s.section)! }
        XCTAssertEqual(idxs, idxs.sorted(), "sections in canonical order")
    }

    func test_filter_findsByTitleAndDescription_caseAndDiacriticInsensitive() {
        let fonts = SettingsCatalog.filter("FONT")
        XCTAssertTrue(fonts.contains { $0.id == "mdv.settings.fontPicker" })
        XCTAssertTrue(fonts.contains { $0.id == "mdv.settings.contentFontSize" },
                      "matches on description too (\"font\" not in the Text Size title)")
        // Diacritic-insensitive: "términal" still finds the terminal rows.
        XCTAssertTrue(SettingsCatalog.filter("términal")
            .contains { $0.id == "mdv.settings.terminal.colorScheme" })
        // Empty query → everything.
        XCTAssertEqual(SettingsCatalog.filter("  ").count, SettingsCatalog.items.count)
        // No match → empty.
        XCTAssertTrue(SettingsCatalog.filter("zzz-no-such-setting").isEmpty)
    }

    /// DRIFT GUARD: every STATIC `mdv.settings.*` accessibility id in the
    /// live SettingsView source must exist in the catalog — a new settings
    /// row without a catalog entry goes RED here (the IA can't silently rot).
    /// Dynamic ids (string interpolation) and pure status ids are exempt.
    func test_liveSettingsView_idsAreCatalogued() throws {
        let viewSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/ViewerUI/SettingsView.swift")
        let source = try String(contentsOf: viewSource, encoding: .utf8)

        let exempt: Set<String> = [
            "mdv.settings.audio.ffmpegStatus",  // a status readout, not a setting
        ]
        let catalogued = Set(SettingsCatalog.items.map(\.id))
        var missing: [String] = []
        for line in source.split(separator: "\n") {
            guard let range = line.range(of: "accessibilityIdentifier(\"mdv.settings.") else { continue }
            let after = line[range.upperBound...]
            guard let close = after.firstIndex(of: "\"") else { continue }
            let id = "mdv.settings." + after[..<close]
            if id.contains("\\(") { continue }              // dynamic per-row ids
            if exempt.contains(id) { continue }
            if !catalogued.contains(id) { missing.append(id) }
        }
        XCTAssertTrue(missing.isEmpty,
                      "SettingsView rows missing from SettingsCatalog (add them): \(missing)")
    }
}
