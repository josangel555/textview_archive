import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1204 — the data-safety teeth: `saveEditor` must REFUSE a read-only
/// (extracted) buffer so a user who edits the displayed extracted text and ⌘S
/// cannot overwrite + corrupt the binary source. If this regresses, a docx/rtf
/// source could be destroyed on save.
@MainActor
final class ReadOnlySaveGuardTests: XCTestCase {

    private func makeModel(_ tmp: URL) -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: UserDefaults(
                suiteName: "ROGuard-\(UUID().uuidString)")!))
    }

    func test_saveEditor_refusesReadOnlyBuffer_sourceUntouched() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ROGuard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = tmp.appendingPathComponent("doc.rtf")
        try "ORIGINAL SOURCE BYTES".write(to: url, atomically: true, encoding: .utf8)

        let model = makeModel(tmp)
        model.open(url: url)
        let id = model.tabs.selected!.id

        // Install a READ-ONLY extracted buffer (simulates a docx/rtf extracted
        // view): drop whatever open() made, then ensure one from a read-only file.
        model.discardEditorBuffer(forTabID: id)
        let roFile = TextFile(url: url, contents: "extracted view text",
                              encoding: .utf8, byteCount: 19, isExtractedReadOnly: true)
        model.ensureEditorBuffer(for: roFile, tabID: id)
        model.updateEditorText("user accidentally edited the extracted view", forTabID: id)

        XCTAssertFalse(model.editor.saveEditor(forTabID: id),
                       "saveEditor MUST refuse a read-only extracted buffer")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ORIGINAL SOURCE BYTES",
                       "the source file must be byte-for-byte untouched — no corruption")
    }

    func test_saveEditor_allowsNormalBuffer() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ROGuard2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = tmp.appendingPathComponent("doc.txt")
        try "before".write(to: url, atomically: true, encoding: .utf8)

        let model = makeModel(tmp)
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.updateEditorText("after", forTabID: id)   // open() made an editable buffer

        XCTAssertTrue(model.editor.saveEditor(forTabID: id),
                      "a normal editable buffer still saves (guard is scoped to read-only)")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "after",
                       "the edit lands for a normal buffer")
    }
}
