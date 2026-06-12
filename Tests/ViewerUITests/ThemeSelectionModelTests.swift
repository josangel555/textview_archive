import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-641 stage 2 model wiring: the definition-based selection resolves
/// through DocumentModel.activeTheme, composes the rendered view's themed
/// stylesheet, and invalidates the rendered-HTML cache on change. Headless
/// (model layer; the picker pixels are the VM lane's).
final class ThemeSelectionModelTests: HeadlessUITestCase {

    @MainActor
    private func makeModel() -> DocumentModel { DocumentModel() }

    override func tearDown() {
        // The selection persists via ThemeStore.shared — leave no residue.
        ThemeStore.shared.selectedID = nil
        super.tearDown()
    }

    @MainActor
    func test_selectedDefinition_drivesActiveTheme() {
        let model = makeModel()
        model.selectedThemeID = "xcode-dark"
        XCTAssertEqual(model.activeThemeDefinition?.id, "xcode-dark")
        // The resolved SyntaxTheme matches the built-in it derives from.
        XCTAssertEqual(
            ThemeColor.hex(model.activeTheme.background),
            ThemeColor.hex(SyntaxTheme.xcodeDark.background))
        // Unknown id → definition resolution fails → legacy fallback path.
        model.selectedThemeID = "no-such-theme"
        XCTAssertNil(model.activeThemeDefinition)
    }

    @MainActor
    func test_themedExtraStylesheet_composesShimPlusTokCSS() {
        let model = makeModel()
        model.selectedThemeID = nil
        XCTAssertEqual(model.themedExtraStylesheet, MermaidBundle.shimCSS,
                       "no selection = the mermaid shim only (byte-identical legacy)")
        model.selectedThemeID = "xcode-dark"
        let css = model.themedExtraStylesheet
        XCTAssertTrue(css.hasPrefix(MermaidBundle.shimCSS), "shim always leads")
        XCTAssertTrue(css.contains("/* theme: xcode-dark */"))
        XCTAssertTrue(css.contains(".tok-keyword"))
    }

    // MARK: - Editor surface (TSK-641 stage 3)

    @MainActor
    func test_activeThemeCMPalette_followsSelection() throws {
        let model = makeModel()
        model.selectedThemeID = nil
        XCTAssertNil(model.activeThemeCMPalette,
                     "no selection = nil = the editor keeps the legacy pair")
        model.selectedThemeID = "xcode-dark"
        let def = try XCTUnwrap(model.activeThemeDefinition)
        XCTAssertEqual(model.activeThemeCMPalette, SyntaxTheme(from: def).cmPalette,
                       "the editor palette must derive from the SELECTED definition")
    }

    @MainActor
    func test_editorThemeWire_selectedPaletteWins_nilIsLegacyPair() {
        // nil → byte-identical TSK-602 appearance-keyed palettes.
        let light = CMEditorThemeWire.payload(dark: false, themePalette: nil)
        XCTAssertEqual(light.name, "light")
        XCTAssertEqual(light.palette, SyntaxTheme.named(.xcodeLight).cmPalette)
        let dark = CMEditorThemeWire.payload(dark: true, themePalette: nil)
        XCTAssertEqual(dark.name, "dark")
        XCTAssertEqual(dark.palette, SyntaxTheme.named(.xcodeDark).cmPalette)
        // A selected theme's palette wins verbatim, under either appearance.
        let themed = ["keyword": "#FF0000", "background": "#101010"]
        XCTAssertEqual(CMEditorThemeWire.payload(dark: true, themePalette: themed).palette,
                       themed)
        XCTAssertEqual(CMEditorThemeWire.payload(dark: false, themePalette: themed).palette,
                       themed)
    }

    /// The channel is only alive if ContentView actually passes it — the
    /// TSK-561 gutter lesson: an adapter nobody calls is dead code. Source
    /// pin, same idiom as the drag-source audits.
    func test_contentView_passesTheActivePalette() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/ViewerUI/ContentView.swift"),
            encoding: .utf8)
        XCTAssertTrue(text.contains("themePalette: model.activeThemeCMPalette"),
                      "ContentView no longer feeds the selected theme to the "
                      + "editor — the CM6 surface silently reverts to the "
                      + "legacy pair (TSK-641)")
    }

    @MainActor
    func test_changingTheme_invalidatesRenderedHTMLCache() {
        let model = makeModel()
        let file = TextFile(
            url: URL(fileURLWithPath: "/tmp/t.md"), contents: "# H\n",
            encoding: .utf8, byteCount: 4, modifiedTime: Date())
        let tabID = UUID()
        // Prime the cache through the synchronous render path.
        _ = model.renderedHTML(
            forTabID: tabID, file: file, contents: file.contents,
            renderer: HTMLRenderer(), stylesheet: "")
        XCTAssertNotNil(model.renderedHTMLIfCached(forTabID: tabID, file: file))
        model.selectedThemeID = "xcode-dark"
        XCTAssertNil(model.renderedHTMLIfCached(forTabID: tabID, file: file),
                     "a theme change must invalidate cached rendered pages")
    }
}
