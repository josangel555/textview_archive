import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Headless coverage for "Save a Copy" (TSK-300): `DocumentModel.saveCopy`
/// writes the tab's CURRENT effective content to a NEW path while leaving the
/// open tab untouched. Three content sources (HEX-dirty bytes, editor-dirty
/// text, verbatim on-disk file) + the tab-unchanged invariant + overwrite +
/// error paths. All file IO is confined to a per-test temp dir.
@MainActor
final class SaveCopyTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SaveCopyTests-\(UUID().uuidString)"
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

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func target(_ name: String) -> URL { tmpDir.appendingPathComponent(name) }

    // MARK: - (3) Verbatim copy of a clean on-disk file

    func test_saveCopy_cleanFile_copiesVerbatim_leavesOriginalAndTab() throws {
        let src = try writeFile("orig.txt", "the original content\n")
        let dst = target("copy.txt")
        let model = makeModel()
        model.open(url: src)
        let idx = model.tabs.selectedIndex!

        XCTAssertTrue(try model.saveCopy(ofTabAt: idx, to: dst))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "the original content\n")
        // Original file untouched; tab not marked dirty by a copy.
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "the original content\n")
        XCTAssertFalse(model.tabs.tabs[idx].isDirty)
        XCTAssertEqual(model.tabs.tabs[idx].url, src, "copy must not retarget the tab")
    }

    func test_saveCopy_cleanFile_isByteExact() throws {
        let payload = "héllo 🌟 — café\nworld 🚀\n"
        let src = try writeFile("emoji.txt", payload)
        let dst = target("emoji-copy.txt")
        let model = makeModel()
        model.open(url: src)
        XCTAssertTrue(try model.saveCopy(ofTabAt: model.tabs.selectedIndex!, to: dst))
        XCTAssertEqual(try Data(contentsOf: dst), payload.data(using: .utf8))
    }

    // MARK: - (2) Editor-dirty: copy includes unsaved edits, original untouched

    func test_saveCopy_editorDirty_copyHasEdits_originalAndDirtyStatePreserved() throws {
        let src = try writeFile("doc.txt", "saved on disk")
        let dst = target("doc-copy.txt")
        let model = makeModel()
        model.open(url: src)
        let id = model.tabs.selected!.id
        let idx = model.tabs.selectedIndex!
        _ = model.editor.editorBuffer(forTabID: id)          // materialize
        model.editor.updateEditorText("UNSAVED edits here", forTabID: id)
        XCTAssertTrue(model.editor.editorBuffer(forTabID: id)?.isDirty == true)

        XCTAssertTrue(try model.saveCopy(ofTabAt: idx, to: dst))
        // Copy carries the live (unsaved) buffer text...
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "UNSAVED edits here")
        // ...the on-disk original is NOT modified (a copy is not a save)...
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "saved on disk")
        // ...and the buffer stays dirty (copy didn't clear it).
        XCTAssertTrue(model.editor.editorBuffer(forTabID: id)?.isDirty == true)
        XCTAssertTrue(model.tabs.tabs[idx].isDirty)
    }

    // MARK: - (1) HEX-dirty bytes win

    func test_saveCopy_hexDirty_usesStashedBytes() throws {
        let src = try writeFile("bin.dat", "on disk")
        let dst = target("bin-copy.dat")
        let model = makeModel()
        model.open(url: src)
        let id = model.tabs.selected!.id
        let idx = model.tabs.selectedIndex!
        let edited = Data([0x00, 0x01, 0xFF, 0xFE, 0x42])
        model.stashHexBytes(edited, forTabID: id)
        model.setHexDirty(true, forTabID: id)

        XCTAssertTrue(try model.saveCopy(ofTabAt: idx, to: dst))
        XCTAssertEqual(try Data(contentsOf: dst), edited)
        // Original on disk untouched.
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "on disk")
    }

    // MARK: - Overwrite an existing target

    func test_saveCopy_overwritesExistingTarget() throws {
        let src = try writeFile("src2.txt", "fresh content")
        let dst = try writeFile("existing.txt", "STALE — must be replaced")
        let model = makeModel()
        model.open(url: src)
        XCTAssertTrue(try model.saveCopy(ofTabAt: model.tabs.selectedIndex!, to: dst))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "fresh content")
    }

    // MARK: - Error paths

    func test_saveCopy_outOfRangeIndex_throwsNoTab() {
        let model = makeModel()
        XCTAssertThrowsError(try model.saveCopy(ofTabAt: 0, to: target("x.txt"))) { err in
            XCTAssertEqual(err as? DocumentModel.SaveCopyError, .noTab)
        }
    }

    func test_saveCopy_emptyTabNoURL_throwsEmptyTab() {
        let model = makeModel()
        model.newTab()   // a fresh tab with no URL and no edits
        let idx = model.tabs.selectedIndex!
        XCTAssertThrowsError(try model.saveCopy(ofTabAt: idx, to: target("y.txt"))) { err in
            XCTAssertEqual(err as? DocumentModel.SaveCopyError, .emptyTab)
        }
    }

    func test_saveCopyOfCurrentTab_noSelection_returnsFalse() throws {
        let model = makeModel()
        XCTAssertFalse(try model.saveCopyOfCurrentTab(to: target("z.txt")))
    }

    func test_saveCopyOfCurrentTab_savesSelected() throws {
        let src = try writeFile("cur.txt", "current tab content")
        let dst = target("cur-copy.txt")
        let model = makeModel()
        model.open(url: src)
        XCTAssertTrue(try model.saveCopyOfCurrentTab(to: dst))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "current tab content")
    }
}
