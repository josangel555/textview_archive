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
