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

    // Format toggle was unified into the segmented ViewMode picker
    // (commit 169a4de). Mode-bar tests are now under
    // ComponentVisualTests.test_modeBar_xmlFile_showsModesIncludingFormat
    // and the model-level supportsFormatToggle assertions above still
    // verify the underlying ViewMode availability.
    func test_jsonFile_hasFormatModeAvailable() throws {
        let model = makeModel()
        let url = try writeFile("data.json", #"{"a":1}"#)
        model.open(url: url)
        let modes = ViewModeOptions.availableModes(for: url)
        XCTAssertTrue(modes.contains(.formatted))
        XCTAssertTrue(modes.contains(.source))
        XCTAssertTrue(modes.contains(.hex))
    }

    func test_markdownFile_hasNoFormatMode() throws {
        let url = try writeFile("doc.md", "# x\n")
        let modes = ViewModeOptions.availableModes(for: url)
        XCTAssertFalse(modes.contains(.formatted))
        XCTAssertTrue(modes.contains(.rendered))
        XCTAssertTrue(modes.contains(.source))
        XCTAssertTrue(modes.contains(.hex))
    }
}
