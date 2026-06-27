import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-899 — ⌘1/⌘2/⌘3 select the Nth view mode in the current file's bar
/// (positional). Drives the model behavior the menu slots invoke.
@MainActor
final class ViewModeShortcutTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewModeShortcutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ViewModeShortcutTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
    }

    private func openMarkdownDoc() throws -> DocumentModel {
        let url = tmpDir.appendingPathComponent("mdv-vmshort-\(UUID().uuidString).md")
        try "# hi\n\ntext".write(to: url, atomically: true, encoding: .utf8)
        // Hermetic injected deps (mirrors DocumentModelTests.makeModel): the bare
        // DocumentModel() default-constructs the REAL HistoryStore + UserDefaults —
        // ~5s of real IO per instance (TSK-836). Same open(url:) path, fast deps.
        let doc = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        doc.open(url: url)
        return doc
    }

    func test_selectsTheNthAvailableMode() throws {
        let doc = try openMarkdownDoc()
        let modes = doc.availableViewModes
        XCTAssertGreaterThanOrEqual(modes.count, 2, "markdown should offer ≥2 modes")
        doc.selectViewMode(at: 1)
        XCTAssertEqual(doc.currentViewMode, modes[1])
        doc.selectViewMode(at: 0)
        XCTAssertEqual(doc.currentViewMode, modes[0])
    }

    func test_outOfRangeSlot_isNoOp() throws {
        let doc = try openMarkdownDoc()
        let modes = doc.availableViewModes
        doc.selectViewMode(at: 0)
        let before = doc.currentViewMode
        doc.selectViewMode(at: 99)   // no such slot
        XCTAssertEqual(doc.currentViewMode, before, "an absent slot must not change the mode")
        XCTAssertEqual(before, modes[0])
    }

    func test_displayName_coversEveryMode() {
        for m in ViewMode.allCases {
            XCTAssertFalse(m.displayName.isEmpty)
        }
    }
}
