import XCTest
import ViewerKit
@testable import ViewerUI

/// TSK-899 — ⌘1/⌘2/⌘3 select the Nth view mode in the current file's bar
/// (positional). Drives the model behavior the menu slots invoke.
@MainActor
final class ViewModeShortcutTests: XCTestCase {

    private func openMarkdownDoc() throws -> DocumentModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-vmshort-\(UUID().uuidString).md")
        try "# hi\n\ntext".write(to: url, atomically: true, encoding: .utf8)
        let doc = DocumentModel()
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
