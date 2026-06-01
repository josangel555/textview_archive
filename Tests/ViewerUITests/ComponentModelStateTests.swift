import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// T1m model-state tests split out of `ComponentVisualTests` by the §3.2
/// migration.
///
/// These cover the same components (mode bar, hex, error, palette,
/// sidebar) but at the layer where the regression actually lives: the
/// `DocumentModel` / `ViewModeOptions` state, not the realized view tree.
/// They never call `renderHost`, never host `ContentView`, never mint a
/// `WKWebView` — so they DON'T pay the `#192` `MDV_RUN_WEBVIEW_TESTS` gate
/// the view-tree half (`ComponentVisualTests`) still needs. Host-headless,
/// part of the merge gate.
@MainActor
final class ComponentModelStateTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComponentModelState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ComponentModelState-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func writeBinary(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Mode bar mode list

    func test_modeBar_xmlFile_showsModesIncludingFormat() throws {
        // Post mode-normalization: every file gets at least
        // [Source, HEX]. XML additionally gets Format. So the
        // segmented picker IS expected. (Prior to that change this
        // test asserted the opposite — XML was the no-toggle case.
        // Now it's a positive: XML shows 3 segments.)
        let url = try writeFile("a.xml", "<r/>\n")
        let modes = ViewModeOptions.availableModes(for: url)
        XCTAssertTrue(modes.contains(.source))
        XCTAssertTrue(modes.contains(.hex))
        XCTAssertTrue(modes.contains(.formatted))
        XCTAssertFalse(modes.contains(.rendered),
            "Rendered should only appear for markdown")
    }

    // MARK: - Hex / binary state

    func test_hexView_binaryFile_landsInBinaryState() throws {
        let model = makeModel()
        let url = try writeBinary("img.bin",
            [0x00, 0x01, 0x02, 0xFF, 0xFE, 0x10, 0x20, 0x30, 0x40, 0x50])
        model.open(url: url)
        guard case .binary = model.currentState else {
            return XCTFail("Binary file should land in .binary state, got \(model.currentState)")
        }
    }

    // MARK: - Error state

    func test_errorState_missingFile_landsInErrorState() throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("does-not-exist.md")
        model.open(url: url)
        guard case .error = model.currentState else {
            return XCTFail("Opening a missing file should land in .error, got \(model.currentState)")
        }
    }

    // MARK: - Palette presented flag

    func test_palette_isPresented_togglesViaModel() throws {
        let model = makeModel()
        XCTAssertFalse(model.isPalettePresented)
        model.showPalette()
        XCTAssertTrue(model.isPalettePresented)
        model.dismissPalette()
        XCTAssertFalse(model.isPalettePresented)
    }

    // MARK: - Sidebar default visibility seeds from preferences

    func test_sidebar_defaultVisibility_followsPreferences() throws {
        // The default `sidebarVisible` value is `true` and the model
        // seeds `sidebar.isVisible` from it on init. We pre-flip the
        // preference to a known value (`false`) BEFORE constructing
        // the model, then assert the model adopts it. Previously this
        // test compared two values constructed seconds apart from the
        // same defaults store — a tautology that always passed.
        defaults.set(false, forKey: "MarkdownViewer.sidebarVisible")
        let model = makeModel()
        XCTAssertFalse(model.sidebar.isVisible,
            "sidebar.isVisible must seed from PreferencesStore.sidebarVisible (preset false)")
        // Now seed `true` and re-init: same shape, opposite branch.
        defaults.set(true, forKey: "MarkdownViewer.sidebarVisible")
        let model2 = makeModel()
        XCTAssertTrue(model2.sidebar.isVisible,
            "sidebar.isVisible must seed from PreferencesStore.sidebarVisible (preset true)")
    }
}
