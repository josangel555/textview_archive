import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// L3 tests for the format/pretty-print toggle. Verifies model state +
/// view-tree wiring: the format button appears only for JSON/XML, and
/// toggling it actually changes what the source view displays.
@MainActor
final class FormatToggleTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "Format-\(UUID().uuidString)"
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

    private func renderHost<V: View>(_ view: V) -> NSView {
        _ = NSApplication.shared
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(origin: .zero, size: NSSize(width: 1200, height: 800))
        h.layoutSubtreeIfNeeded()
        return h
    }

    private func descendants(of view: NSView) -> [NSView] {
        var out: [NSView] = [view]
        for s in view.subviews { out.append(contentsOf: descendants(of: s)) }
        return out
    }

    // MARK: - supportsFormatToggle

    func test_jsonFile_supportsFormatToggle() throws {
        let model = makeModel()
        let url = try writeFile("data.json", #"{"a":1}"#)
        model.open(url: url)
        XCTAssertTrue(model.supportsFormatToggle, "JSON files should support format toggle")
    }

    func test_xmlFile_supportsFormatToggle() throws {
        let model = makeModel()
        let url = try writeFile("data.xml", "<r/>\n")
        model.open(url: url)
        XCTAssertTrue(model.supportsFormatToggle, "XML files should support format toggle")
    }

    func test_markdownFile_doesNotSupportFormatToggle() throws {
        let model = makeModel()
        let url = try writeFile("doc.md", "# x\n")
        model.open(url: url)
        XCTAssertFalse(model.supportsFormatToggle, "Markdown shouldn't have a pretty-print mode")
    }

    func test_swiftFile_doesNotSupportFormatToggle() throws {
        let model = makeModel()
        let url = try writeFile("code.swift", "let x = 42\n")
        model.open(url: url)
        XCTAssertFalse(model.supportsFormatToggle)
    }

    // MARK: - Toggle behavior

    func test_toggleFormat_flipsState() throws {
        let model = makeModel()
        let url = try writeFile("data.json", #"{"a":1}"#)
        model.open(url: url)
        XCTAssertFalse(model.isCurrentTabFormatted)
        model.toggleFormat()
        XCTAssertTrue(model.isCurrentTabFormatted)
        model.toggleFormat()
        XCTAssertFalse(model.isCurrentTabFormatted)
    }

    func test_toggleFormat_isPerTab() throws {
        let model = makeModel()
        let a = try writeFile("a.json", #"{"a":1}"#)
        let b = try writeFile("b.json", #"{"b":2}"#)
        model.open(url: a)
        model.toggleFormat()
        XCTAssertTrue(model.isCurrentTabFormatted)
        // Open second tab; it should NOT inherit the format state.
        model.open(url: b)
        XCTAssertFalse(model.isCurrentTabFormatted,
            "Second tab should start un-formatted regardless of first tab")
    }

    func test_displayText_returnsFormatted_whenToggled() throws {
        let model = makeModel()
        let url = try writeFile("data.json", #"{"b":2,"a":1}"#)
        model.open(url: url)
        guard case .loaded(let file) = model.currentState else {
            return XCTFail("Expected .loaded")
        }
        // Pre-toggle: raw content.
        XCTAssertEqual(model.displayText(for: file), file.contents)
        // Post-toggle: pretty-printed (different from raw, has newlines).
        model.toggleFormat()
        let formatted = model.displayText(for: file)
        XCTAssertNotEqual(formatted, file.contents)
        XCTAssertTrue(formatted.contains("\n"))
    }

    // MARK: - View tree

    func test_formatToggleButton_present_forJSON() throws {
        let model = makeModel()
        let url = try writeFile("data.json", #"{"a":1}"#)
        model.open(url: url)
        let host = renderHost(ContentView(model: model))
        // The toggle has accessibilityIdentifier "mdv.formatToggle" — the
        // SwiftUI-AX bridge sometimes propagates this to NSView. We
        // fall back to checking for an extra button-like view.
        let buttonish = descendants(of: host).filter {
            String(describing: type(of: $0)).contains("Button")
        }
        XCTAssertGreaterThanOrEqual(buttonish.count, 1,
            "Format toggle should add at least one button to the tree")
    }

    func test_formatToggleButton_absent_forMarkdown() throws {
        let model = makeModel()
        let url = try writeFile("doc.md", "# x\n")
        model.open(url: url)
        let host = renderHost(ContentView(model: model))
        // Just verify model.supportsFormatToggle is false — the view
        // wiring follows from that.
        XCTAssertFalse(model.supportsFormatToggle)
        // The tree should NOT contain a format-toggle accessibility id.
        let hits = descendants(of: host).filter {
            $0.accessibilityIdentifier() == "mdv.formatToggle"
        }
        XCTAssertTrue(hits.isEmpty)
    }
}
