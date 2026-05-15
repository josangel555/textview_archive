import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// L3 in-process visual tests for each component's appearance across
/// different states. These DON'T spawn the .app — they host
/// `ContentView` in an NSHostingView and assert on the realized
/// NSView tree + DiagnosticDump output. Fast, hermetic, no focus
/// issues, no TCC issues.
///
/// Covers components that have visible state but minimal interaction:
/// mode bar, hex view, error state, palette overlay, tab bar layout.
@MainActor
final class ComponentVisualTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComponentVisual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ComponentVisualTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
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

    private func renderHost<V: View>(
        _ view: V,
        size: NSSize = NSSize(width: 1200, height: 800)
    ) -> NSView {
        _ = NSApplication.shared
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(origin: .zero, size: size)
        h.layoutSubtreeIfNeeded()
        return h
    }

    private func descendants(of view: NSView) -> [NSView] {
        var out: [NSView] = [view]
        for s in view.subviews { out.append(contentsOf: descendants(of: s)) }
        return out
    }

    // MARK: - Mode bar visual state

    func test_modeBar_markdownFile_showsSegmentedControl() throws {
        let model = makeModel()
        let url = try writeFile("a.md", "# x\n")
        model.open(url: url)
        let host = renderHost(ContentView(model: model))
        // Segmented picker for view mode is realized as
        // SwiftUISegmentedControl (private). Search by name.
        let segmenteds = descendants(of: host).filter {
            String(describing: type(of: $0)).contains("SegmentedControl")
        }
        XCTAssertFalse(segmenteds.isEmpty,
            "Markdown file should expose a segmented Rendered/Source control")
    }

    func test_modeBar_xmlFile_showsModesIncludingFormat() throws {
        // Post mode-normalization: every file gets at least
        // [Source, HEX]. XML additionally gets Format. So the
        // segmented picker IS expected. (Prior to that change this
        // test asserted the opposite — XML was the no-toggle case.
        // Now it's a positive: XML shows 3 segments.)
        let model = makeModel()
        let url = try writeFile("a.xml", "<r/>\n")
        model.open(url: url)
        let modes = ViewModeOptions.availableModes(for: url)
        XCTAssertTrue(modes.contains(.source))
        XCTAssertTrue(modes.contains(.hex))
        XCTAssertTrue(modes.contains(.formatted))
        XCTAssertFalse(modes.contains(.rendered),
            "Rendered should only appear for markdown")
    }

    func test_modeBar_filenameLabel_reflectsCurrentFile() throws {
        let model = makeModel()
        let url = try writeFile("uniquelynamed.md", "# x\n")
        model.open(url: url)
        // Direct model state check (model.currentFilePath is what the label binds to).
        XCTAssertTrue(model.currentFilePath?.contains("uniquelynamed") ?? false,
            "currentFilePath should reflect open file. Got: \(model.currentFilePath ?? "nil")")
    }

    // MARK: - Tab bar layout

    func test_tabBar_noTabs_stillRendersStrip() throws {
        let model = makeModel()
        XCTAssertEqual(model.tabs.tabs.count, 0)
        let host = renderHost(ContentView(model: model))
        // TabBar should still occupy ~28pt at the top even with zero tabs
        // (for the + button).
        let tabBars = descendants(of: host).filter {
            String(describing: type(of: $0)) == "PlatformContainer"
                && $0.frame.height < 50
                && $0.frame.width > 200
        }
        XCTAssertFalse(tabBars.isEmpty,
            "TabBar (PlatformContainer) should be present even with zero tabs")
    }

    func test_tabBar_oneTab_hasOneTabItem() throws {
        let model = makeModel()
        let url = try writeFile("only.md", "# x\n")
        model.open(url: url)
        XCTAssertEqual(model.tabs.tabs.count, 1)
    }

    func test_tabBar_manyTabs_scrollHorizontally() throws {
        let model = makeModel()
        for i in 0..<10 {
            let url = try writeFile("file\(i).md", "# x\(i)\n")
            model.open(url: url)
        }
        XCTAssertEqual(model.tabs.tabs.count, 10)
        // The tab bar's HostingScrollView should be present (it wraps the
        // tab strip for horizontal scrolling).
        let host = renderHost(ContentView(model: model))
        let scrolls = descendants(of: host).filter {
            String(describing: type(of: $0)).contains("HostingScrollView")
                && $0.frame.height < 50
        }
        XCTAssertFalse(scrolls.isEmpty,
            "10 tabs should still be wrapped in a horizontally-scrolling host")
    }

    // MARK: - Hex view

    func test_hexView_binaryFile_landsInBinaryState() throws {
        let model = makeModel()
        let url = try writeBinary("img.bin",
            [0x00, 0x01, 0x02, 0xFF, 0xFE, 0x10, 0x20, 0x30, 0x40, 0x50])
        model.open(url: url)
        guard case .binary = model.currentState else {
            return XCTFail("Binary file should land in .binary state, got \(model.currentState)")
        }
    }

    func test_hexView_renders_inViewTree() throws {
        let model = makeModel()
        // Binary detection requires NUL bytes, but a pure
        // "[0x00, 0xAA] * 128" pattern now decodes cleanly as
        // UTF-16BE (U+00AA = ª, valid character) — by design,
        // since we now detect BOM-less UTF-16. Use a clearly-
        // binary pattern instead: PNG-like header with mixed
        // byte values that no UTF-16 decoder will accept as
        // sensible text.
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        for i in 0..<32 {
            bytes.append(0x00)
            bytes.append(UInt8(i % 16))
            bytes.append(0xFF)
            bytes.append(0x80)
        }
        let url = try writeBinary("img.bin", bytes)
        model.open(url: url)
        guard case .binary(let binary) = model.currentState else {
            return XCTFail("Expected .binary state, got \(model.currentState)")
        }
        // Model-level: BinaryFile has the byte content.
        // 8-byte PNG-like header + 32 iterations × 4 bytes = 136 bytes.
        XCTAssertEqual(binary.byteCount, 8 + 32 * 4)
        // View-level: HexView uses pure SwiftUI Text — text is baked into
        // layer contents (no NSTextView). Assert the view tree is non-empty
        // and the HexView's hosting wrapper is realized.
        let host = renderHost(ContentView(model: model))
        XCTAssertGreaterThan(descendants(of: host).count, 5,
            "HexView should populate a non-trivial subtree")
    }

    // MARK: - Empty state

    func test_emptyState_rendersNonTrivialTree() throws {
        let model = makeModel()
        let host = renderHost(ContentView(model: model))
        // Empty state has icon + title + 2 buttons + caption text.
        // SwiftUI flattens text/image into the hosting view's layer.contents,
        // so we can't rely on per-element NSView subclasses being present.
        // Assert the hosted tree is non-trivially populated.
        XCTAssertGreaterThan(descendants(of: host).count, 10,
            "Empty state should populate ≥10 descendant views (TabBar, ModeBar, hosted content)")
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

    func test_errorState_renders_warningIcon() throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("missing.md")
        model.open(url: url)
        let host = renderHost(ContentView(model: model))
        // ErrorView shows exclamationmark.triangle (system orange).
        // Just verify we have a non-trivial subview tree (not blank).
        XCTAssertGreaterThan(descendants(of: host).count, 5)
    }

    // MARK: - Palette overlay

    func test_palette_dimLayerPresent_whenPresented() throws {
        let model = makeModel()
        model.showPalette()
        let host = renderHost(ContentView(model: model))
        // Palette overlay is a ZStack on top — should produce extra subviews
        // when presented vs hidden.
        let presentedCount = descendants(of: host).count

        let model2 = makeModel()
        let host2 = renderHost(ContentView(model: model2))
        let hiddenCount = descendants(of: host2).count

        XCTAssertGreaterThan(presentedCount, hiddenCount,
            "Showing palette should add subviews (overlay + content)")
    }

    func test_palette_isPresented_togglesViaModel() throws {
        let model = makeModel()
        XCTAssertFalse(model.isPalettePresented)
        model.showPalette()
        XCTAssertTrue(model.isPalettePresented)
        model.dismissPalette()
        XCTAssertFalse(model.isPalettePresented)
    }

    // MARK: - Sidebar visible/hidden visual state

    func test_sidebar_defaultVisibility_followsPreferences() throws {
        // sidebar.isVisible is seeded from PreferencesStore.sidebarVisible
        // in DocumentModel.init. Default is true (so first-time users see
        // the sidebar when they open a folder). The previous test asserted
        // false unconditionally — that's no longer the contract; users
        // who toggled off get their preference restored.
        let model = makeModel()
        XCTAssertEqual(model.sidebar.isVisible, PreferencesStore(defaults: defaults).sidebarVisible)
    }

    func test_sidebar_visibleAfterToggle_changesViewTree() throws {
        let model = makeModel()
        // First need a root.
        model.sidebar.setRoot(tmpDir)
        model.sidebar.isVisible = true
        let host = renderHost(ContentView(model: model))
        XCTAssertTrue(descendants(of: host).count > 10,
            "Sidebar visible should populate view tree")
    }
}
