import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-352 — host coverage for "Convert Encoding": re-save the active file's
/// text in a target encoding, then reload so the app re-detects it. Verifies
/// the on-disk bytes change to the target encoding, the text is preserved, and
/// a non-representable conversion is refused (file untouched). The encoding
/// submenu render is the VM tail. Host-safe (temp files, no window).
@MainActor
final class EncodingConvertTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncodingConvertTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "EncodingConvertTests-\(UUID().uuidString)"
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
            preferences: PreferencesStore(defaults: defaults))
    }

    /// Open a UTF-8 file in editor mode, seed its buffer; return (id, url).
    @discardableResult
    private func openEditor(_ name: String, _ body: String,
                            in model: DocumentModel) throws -> (id: UUID, url: URL) {
        let url = tmpDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        let id = model.tabs.selected!.id
        var t = model.tabs.tabs[0]
        t.viewMode = .editor
        model.tabCoordinator.replace(at: 0, with: t)
        _ = model.editor.editorBuffer(forTabID: id)  // seed from .loaded
        return (id, url)
    }

    func test_convertUTF8toUTF16_rewritesDisk_andPreservesText() throws {
        let model = makeModel()
        let (id, url) = try openEditor("doc.txt", "café", in: model)
        XCTAssertTrue(model.canConvertActiveFileEncoding)
        XCTAssertTrue(model.convertActiveFileEncoding(to: .utf16))

        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(String(data: bytes, encoding: .utf16), "café",
                       "on-disk file is now UTF-16 (BOM) and decodes to the same text")
        XCTAssertNotEqual(String(data: bytes, encoding: .utf8), "café",
                          "it is no longer UTF-8 — the encoding actually changed")
        // The reloaded buffer keeps the text and is no longer UTF-8.
        XCTAssertEqual(model.editor.editorBuffer(forTabID: id)?.text, "café")
        XCTAssertNotEqual(model.editor.editorBuffer(forTabID: id)?.encoding, .utf8,
                          "the reloaded buffer re-detected the new encoding")
    }

    func test_convertPreservesUnsavedEdits() throws {
        let model = makeModel()
        let (id, url) = try openEditor("doc.txt", "original", in: model)
        // Make an unsaved edit, then convert — the edit must be written, not lost.
        model.editor.updateEditorText("edited unsaved", forTabID: id)
        XCTAssertTrue(model.convertActiveFileEncoding(to: .utf16))
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(String(data: bytes, encoding: .utf16), "edited unsaved",
                       "the current (unsaved) text is what gets re-encoded")
    }

    func test_nonRepresentable_refused_fileUntouched() throws {
        let model = makeModel()
        let (_, url) = try openEditor("emoji.txt", "🎉", in: model)
        // 🎉 (U+1F389) can't be encoded in Latin-1 → refuse, leave the file alone.
        XCTAssertFalse(model.convertActiveFileEncoding(to: .isoLatin1))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "🎉",
                       "a non-representable convert leaves the on-disk file untouched")
    }

    func test_canConvert_falseWithNoTab() {
        let model = makeModel()
        XCTAssertFalse(model.canConvertActiveFileEncoding, "no active text file → nothing to convert")
        XCTAssertFalse(model.convertActiveFileEncoding(to: .utf8))
    }
}
