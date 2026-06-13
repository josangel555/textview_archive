import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-300 — the UI surface for "Save a Copy": the validateMenuItem gate
/// (`canSaveCopyOfCurrentTab`), the suggested filename, and the File-menu
/// wiring that routes to the already-tested engine. Owner greenlit the
/// wiring on 2026-06-11. Real temp dirs only.
@MainActor
final class SaveCopyWiringTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveCopyWiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SaveCopyWiring-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    func test_canSaveCopy_gate_followsTabContent() throws {
        let model = makeModel()
        XCTAssertFalse(model.canSaveCopyOfCurrentTab,
                       "no selected tab → the menu item disables")
        let src = tmpDir.appendingPathComponent("report.md")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        model.open(url: src)
        XCTAssertTrue(model.canSaveCopyOfCurrentTab,
                      "an open file is copyable → the menu item enables")
    }

    func test_suggestedName_isCurrentTabName_elseDefault() throws {
        let model = makeModel()
        XCTAssertEqual(model.saveCopySuggestedName, "Untitled.txt",
                       "no tab → a generic default fills the panel")
        let src = tmpDir.appendingPathComponent("notes.json")
        try "{}".write(to: src, atomically: true, encoding: .utf8)
        model.open(url: src)
        XCTAssertEqual(model.saveCopySuggestedName, "notes.json",
                       "the panel pre-fills with the current file's name")
    }

    /// The gate matches the engine: when `canSaveCopyOfCurrentTab` is true,
    /// `saveCopyOfCurrentTab` actually writes (no false-enable). Proves the
    /// menu's enablement predicate and the action target the same capability.
    func test_gateTrue_impliesEngineWrites() throws {
        let src = tmpDir.appendingPathComponent("src.txt")
        try "payload".write(to: src, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.open(url: src)
        XCTAssertTrue(model.canSaveCopyOfCurrentTab)
        let dst = tmpDir.appendingPathComponent("copy.txt")
        XCTAssertTrue(try model.saveCopyOfCurrentTab(to: dst))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "payload")
    }

    /// Wiring pin (dead-channel idiom): the File menu exposes "Save a Copy…",
    /// it routes to the action, the action calls the engine, and
    /// validateMenuItem gates on the capability. A tested engine with no menu
    /// entry point is exactly the gap TSK-300 reported.
    func test_fileMenu_isWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(
            contentsOf: root.appendingPathComponent("Sources/MarkdownViewer/main.swift"),
            encoding: .utf8)
        XCTAssertTrue(main.contains("title: \"Save a Copy…\""),
                      "the File menu must offer Save a Copy")
        XCTAssertTrue(main.contains("#selector(saveCopyAs(_:))"),
                      "the menu item must target the saveCopyAs action")
        XCTAssertTrue(main.contains("model.saveCopyOfCurrentTab(to: url)"),
                      "the action must call the model engine with the panel's URL")
        XCTAssertTrue(main.contains("case #selector(saveCopyAs(_:)):"),
                      "validateMenuItem must gate the Save a Copy item")
        XCTAssertTrue(main.contains("model.canSaveCopyOfCurrentTab"),
                      "the gate must use the capability predicate")
    }
}
