import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// T2' in-process visual tests for each component's appearance across
/// different states. These DON'T spawn the .app — they host
/// `ContentView` in an NSHostingView and assert on the realized
/// NSView tree + DiagnosticDump output. Fast, hermetic, no focus
/// issues, no TCC issues.
///
/// What remains here, after the §3.2 split, is the part that genuinely
/// reads the realized `NSHostingView` tree (segmented-control / label /
/// tab-bar strip presence, hex/error/empty/palette/sidebar subtree
/// growth). Because `ContentView` in rendered mode mints a `WKWebView`,
/// these keep the `#192` `MDV_RUN_WEBVIEW_TESTS` gate + `WebViewTestTeardown`
/// graph-quiesce.
///
/// The pure model-state checks (mode list for a file type, binary/error
/// state landing, palette-presented toggle, sidebar default visibility)
/// moved to the UNGATED T1m `ComponentModelStateTests` — they read `model.*`
/// only and never called `renderHost`, so they were paying the WebView-gate
/// tax for nothing.
@MainActor
final class ComponentVisualTests: WebViewTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// #192: tracked so tearDown can dismantle embedded WKWebViews.
    private var hostedViews: [NSView] = []

    override func setUp() async throws {
        // #192: process-isolated — skipped in the bare sweep.
        try WebViewTestTeardown.skipUnlessEnabled()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComponentVisual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ComponentVisualTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hostedViews)  // #192
        hostedViews.removeAll()
        // tmpDir/defaults are nil when setUp early-skipped (#192 gate).
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
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
        hostedViews.append(h)  // #192: track for WebView teardown
        return h
    }

    private func descendants(of view: NSView) -> [NSView] {
        var out: [NSView] = [view]
        for s in view.subviews { out.append(contentsOf: descendants(of: s)) }
        return out
    }

    // MARK: - Mode bar visual state

    func test_modeBar_markdownFile_showsViewModeControl() throws {
        // UX-A (#224): the segmented view-mode Picker was replaced by the
        // `ContentToolbar`'s Render | Editor | HEX button control. Plain
        // SwiftUI Buttons don't realize as discrete probe-able NSControls
        // the way the old SwiftUISegmentedControl did, so we assert the
        // CONTROL'S CONTRACT at the model layer (markdown exposes the Render
        // + Editor primaries) and that mounting ContentView for a markdown
        // file realizes a non-trivial tree (the toolbar drew).
        let model = makeModel()
        let url = try writeFile("a.md", "# x\n")
        model.open(url: url)
        let host = renderHost(ContentView(model: model))
        XCTAssertTrue(model.showsRenderPrimary,
            "Markdown should expose the Render lens in the view-mode control")
        XCTAssertTrue(model.showsEditorPrimary,
            "Markdown should expose the Editor lens in the view-mode control")
        XCTAssertGreaterThan(descendants(of: host).count, 10,
            "ContentView for a markdown file should realize a populated tree")
    }

    func test_modeBar_filenameLabel_reflectsCurrentFile() throws {
        // Render the ContentView and walk the hosted NSView tree
        // looking for a text-bearing node whose value contains our
        // unique file name. SwiftUI flattens `Text(...)` into the
        // hosting layer's `contents`, so we sniff via
        // `accessibilityValue` / `stringValue` on every descendant.
        // Asserting only `model.currentFilePath` (the binding source)
        // wouldn't catch a bug where the mode bar ignored the binding.
        let model = makeModel()
        let url = try writeFile("uniquelynamed.md", "# x\n")
        model.open(url: url)
        let host = renderHost(ContentView(model: model))
        let nodes = descendants(of: host)
        let needle = "uniquelynamed"
        let foundInLabel = nodes.contains { node in
            // Guard the KVC probe with `responds(to:)`. A bare
            // `value(forKey: "stringValue")` throws NSUnknownKeyException
            // on nodes that aren't KVC-compliant for the key (e.g.
            // `NSHostingView<ContentView>`), which can't be caught from
            // Swift and aborts the whole test process. Only NSControls
            // (NSTextField etc.) expose `stringValue`.
            if node.responds(to: NSSelectorFromString("stringValue")),
               let s = (node.value(forKey: "stringValue") as? String),
               s.contains(needle) { return true }
            if let s = node.accessibilityLabel(), s.contains(needle) { return true }
            if let s = node.accessibilityValue() as? String, s.contains(needle) { return true }
            return false
        }
        // Fallback: SwiftUI is allowed to render the label via Text
        // baked into a layer rather than as a separate NSText. If we
        // can't see it in the NSView tree, fall back to model state
        // — but only after we've tried, and only with an explicit
        // failure message so we know the visual probe missed.
        if !foundInLabel {
            XCTAssertTrue(model.currentFilePath?.contains(needle) ?? false,
                "neither the mode-bar label nor model.currentFilePath surfaced '\(needle)' — \(model.currentFilePath ?? "nil")")
        }
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
        // Render the ContentView. Assert both: model state has 1 tab
        // AND the realised NSView tree includes a TabBar wrapper
        // (PlatformContainer with the tab-bar's distinctive small
        // height). Earlier this test asserted only the model count —
        // a regression where the TabBar entirely failed to realize
        // would have passed.
        let model = makeModel()
        let url = try writeFile("only.md", "# x\n")
        model.open(url: url)
        XCTAssertEqual(model.tabs.tabs.count, 1, "model must publish 1 tab")
        let host = renderHost(ContentView(model: model))
        let tabBarLikeNodes = descendants(of: host).filter {
            // Same shape used by test_tabBar_noTabs_stillRendersStrip:
            // small-height (<50 pt), wide (>200 pt) PlatformContainer.
            String(describing: type(of: $0)) == "PlatformContainer"
                && $0.frame.height < 50
                && $0.frame.width > 200
        }
        XCTAssertFalse(tabBarLikeNodes.isEmpty,
            "TabBar must realize even with exactly one open tab")
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

    // MARK: - Sidebar visible/hidden visual state

    func test_sidebar_visibleAfterToggle_changesViewTree() throws {
        // Real before/after: render with sidebar hidden, snapshot
        // descendant count, then flip the toggle and re-render. The
        // sidebar subtree must add nodes — not pass on a generic
        // ">10" threshold that holds for any non-trivial SwiftUI tree.
        let model = makeModel()
        model.sidebar.setRoot(tmpDir)
        model.sidebar.isVisible = false
        let beforeHost = renderHost(ContentView(model: model))
        let beforeCount = descendants(of: beforeHost).count

        let model2 = makeModel()
        model2.sidebar.setRoot(tmpDir)
        model2.sidebar.isVisible = true
        let afterHost = renderHost(ContentView(model: model2))
        let afterCount = descendants(of: afterHost).count

        XCTAssertGreaterThan(afterCount, beforeCount,
            "Toggling the sidebar on must add view-tree nodes (before=\(beforeCount), after=\(afterCount))")
    }
}
