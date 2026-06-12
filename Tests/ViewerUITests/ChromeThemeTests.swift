import XCTest
import SwiftUI
@testable import ViewerCore
@testable import ViewerUI

/// TSK-641 stage 4 — the CHROME surface. Pins the headless half: slot
/// derivation (explicit chrome slots win, background/gutterBackground
/// fallbacks otherwise), the Palette consultation, the model wiring, and
/// JSON back-compat. The painted pixels are the VM/owner-glance half.
@MainActor
final class ChromeThemeTests: HeadlessUITestCase {

    override func tearDown() async throws {
        ChromeTheme.current = nil
        ThemeStore.shared.selectedID = nil
    }

    private func definition(
        sidebar: String? = nil, bar: String? = nil, panel: String? = nil
    ) -> ThemeDefinition {
        ThemeDefinition(
            id: "t", displayName: "T", isDark: true,
            background: "#101015", foreground: "#EEEEEE",
            gutterText: "#888888", gutterBackground: "#202028",
            tokens: [:],
            sidebarBackground: sidebar, barBackground: bar, panelBackground: panel
        )
    }

    func test_chromeColors_fallbackDerivation() {
        // No explicit chrome slots: sidebar/content ← background,
        // bars + panel cards ← gutterBackground.
        let c = ChromeColors(from: definition())
        XCTAssertEqual(c.textBackground, Color(nsColor: ThemeColor.parse("#101015")!))
        XCTAssertEqual(c.windowBackground, Color(nsColor: ThemeColor.parse("#202028")!))
        XCTAssertEqual(c.sidebarPanelBackground, Color(nsColor: ThemeColor.parse("#202028")!))
    }

    func test_chromeColors_explicitSlotsWin_andMalformedDegradesToFallback() {
        let c = ChromeColors(from: definition(
            sidebar: "#112233", bar: "#445566", panel: "not-a-color"))
        XCTAssertEqual(c.textBackground, Color(nsColor: ThemeColor.parse("#112233")!))
        XCTAssertEqual(c.windowBackground, Color(nsColor: ThemeColor.parse("#445566")!))
        XCTAssertEqual(c.sidebarPanelBackground,
                       Color(nsColor: ThemeColor.parse("#202028")!),
                       "a malformed slot degrades to its fallback, never crashes")
    }

    func test_palette_consultsTheme_andFallsBackWhenCleared() {
        let themed = ChromeColors(from: definition(sidebar: "#112233", bar: "#445566"))
        ChromeTheme.current = themed
        XCTAssertEqual(Palette.textBackground, themed.textBackground)
        XCTAssertEqual(Palette.windowBackground, themed.windowBackground)
        XCTAssertEqual(Palette.sidebarPanelBackground, themed.sidebarPanelBackground)
        ChromeTheme.current = nil
        XCTAssertNotEqual(Palette.textBackground, themed.textBackground,
                          "cleared theme must revert to the system surface")
        XCTAssertNotEqual(Palette.windowBackground, themed.windowBackground)
    }

    func test_model_selectionDrivesChromeTheme_bothDirections() {
        let model = DocumentModel()
        model.selectedThemeID = "xcode-dark"
        XCTAssertNotNil(ChromeTheme.current,
                        "selecting a catalog theme must theme the chrome")
        // The xcode-dark built-in has no explicit chrome slots — the
        // derivation maps its background into the sidebar surface.
        XCTAssertEqual(
            Palette.textBackground,
            Color(nsColor: ThemeColor.parse(
                ThemeDefinition.builtIns.first { $0.id == "xcode-dark" }!.background)!))
        model.selectedThemeID = nil
        XCTAssertNil(ChromeTheme.current,
                     "clearing the selection must restore system-native chrome")
    }

    func test_themeDefinition_decodesLegacyJSON_withoutChromeSlots() throws {
        // Persisted user themes predate stage 4 — they must keep decoding,
        // with nil chrome slots (fallback derivation takes over).
        let legacy = #"""
        {"id":"old","displayName":"Old","isDark":false,
         "background":"#FFFFFF","foreground":"#000000",
         "gutterText":"#666666","gutterBackground":"#F0F0F0",
         "tokens":{"keyword":"#AA00AA"}}
        """#
        let def = try JSONDecoder().decode(ThemeDefinition.self, from: Data(legacy.utf8))
        XCTAssertNil(def.sidebarBackground)
        XCTAssertNil(def.barBackground)
        XCTAssertNil(def.panelBackground)
        XCTAssertEqual(def.tokens["keyword"], "#AA00AA")
    }

    func test_vscodeImporter_mapsWorkbenchChromeSlots() throws {
        let json = #"""
        {"name":"Chromey","type":"dark",
         "colors":{"editor.background":"#1E1E1E","editor.foreground":"#D4D4D4",
                   "sideBar.background":"#252526",
                   "editorGroupHeader.tabsBackground":"#2D2D30",
                   "sideBarSectionHeader.background":"#303031"},
         "tokenColors":[]}
        """#
        let def = try VSCodeThemeImporter.parse(Data(json.utf8), fallbackName: "x")
        XCTAssertEqual(def.sidebarBackground, "#252526")
        XCTAssertEqual(def.barBackground, "#2D2D30")
        XCTAssertEqual(def.panelBackground, "#303031")
        // statusBar.background is the bar fallback when the tab-strip key
        // is absent.
        let json2 = #"""
        {"name":"Barfall","type":"dark",
         "colors":{"editor.background":"#111111","editor.foreground":"#EEEEEE",
                   "statusBar.background":"#222222"},
         "tokenColors":[]}
        """#
        let def2 = try VSCodeThemeImporter.parse(Data(json2.utf8), fallbackName: "y")
        XCTAssertEqual(def2.barBackground, "#222222")
        XCTAssertNil(def2.sidebarBackground)
    }
}
