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

    // MARK: - L-eh2(d): encoding the buffer can't represent THROWS (TSK-1008)

    /// A dirty editor buffer whose declared encoding (`.ascii`) cannot
    /// represent its text (a non-ASCII char) must throw
    /// `SaveCopyError.encodingFailed` — NOT silently re-encode to UTF-8 and
    /// write a byte stream that no longer matches the buffer's declared
    /// encoding (data corruption). The old `?? buf.text.data(using: .utf8)`
    /// fallback made the throw dead code; this test FAILS on that code
    /// (it would have written a file and returned true instead of throwing).
    func test_saveCopy_encodingCannotRepresent_throwsEncodingFailed() throws {
        let src = try writeFile("ascii.txt", "plain ascii")
        let dst = target("ascii-copy.txt")
        let model = makeModel()
        model.open(url: src)
        let id = model.tabs.selected!.id
        let idx = model.tabs.selectedIndex!
        // Inject a DIRTY buffer declared `.ascii` but holding a non-ASCII
        // char ("é" / U+00E9) that ASCII cannot encode.
        let buf = EditorBuffer(
            url: src, original: "plain ascii", encoding: .ascii)
        var dirty = buf
        dirty.setText("caf\u{00E9} crème")      // non-ASCII → ascii-uncodable
        XCTAssertTrue(dirty.isDirty)
        model.tabCoordinator.setEditorBuffer(dirty, forTabID: id)

        XCTAssertThrowsError(try model.saveCopy(ofTabAt: idx, to: dst)) { err in
            XCTAssertEqual(err as? DocumentModel.SaveCopyError, .encodingFailed)
        }
        // No corrupt UTF-8 file silently left behind on the failure path.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path))
    }

    /// Control: a dirty buffer whose encoding CAN represent its text still
    /// saves cleanly (proves the throw is conditioned on encodability, not
    /// blanket-broken).
    func test_saveCopy_encodingCanRepresent_savesCleanly() throws {
        let src = try writeFile("ascii2.txt", "plain ascii")
        let dst = target("ascii2-copy.txt")
        let model = makeModel()
        model.open(url: src)
        let id = model.tabs.selected!.id
        let idx = model.tabs.selectedIndex!
        var dirty = EditorBuffer(url: src, original: "plain ascii", encoding: .ascii)
        dirty.setText("all ascii here")
        model.tabCoordinator.setEditorBuffer(dirty, forTabID: id)
        XCTAssertTrue(try model.saveCopy(ofTabAt: idx, to: dst))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .ascii), "all ascii here")
    }

    // MARK: - L-eh2(a): git-log tab branches on the write result (TSK-1008)

    /// The pure markdown body carries every commit row and pipe-escapes
    /// subjects. (Logic anchor for the rendered tab.)
    func test_gitLogMarkdown_buildsCommitRows_escapesPipes() {
        let repo = URL(fileURLWithPath: "/repo")
        let entries = [
            GitClient.LogEntry(sha: "abc1234", author: "Jos",
                               date: "2026-06-18", subject: "first | piped"),
            GitClient.LogEntry(sha: "def5678", author: "Pat",
                               date: "2026-06-17", subject: "second"),
        ]
        let md = DocumentModel.gitLogMarkdown(
            entries: entries, url: URL(fileURLWithPath: "/repo/a.txt"),
            repoRoot: repo, scope: .file)
        XCTAssertTrue(md.contains("# History: a.txt"))
        XCTAssertTrue(md.contains("| `abc1234` | first \\| piped | Jos | 2026-06-18 |"),
                      "pipe in the subject is escaped so the table doesn't break")
        XCTAssertTrue(md.contains("| `def5678` | second | Pat | 2026-06-17 |"))
        XCTAssertFalse(md.contains("_No commits._"))
    }

    /// A successful write returns the freshly-written URL whose contents
    /// match the markdown we asked to write.
    func test_writeGitLog_success_returnsFreshFileWithContents() throws {
        let repo = URL(fileURLWithPath: "/some/repo")
        let md = "# History: repo\n\n_No commits._\n"
        let out = try DocumentModel.writeGitLog(
            markdown: md, repoRoot: repo, relPath: nil, cacheRoot: tmpDir)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), md)
    }

    /// A write FAILURE must THROW (so `showGitLog` never opens a stale
    /// hashed path). The old `try? md.write(...)` swallowed the failure and
    /// still opened the hashed file — re-surfacing a STALE prior git-log
    /// for the same (repo, relPath) hash. Forcing the cache root to a
    /// regular FILE (not a directory) makes `createDirectory` fail.
    func test_writeGitLog_writeFailure_throws_doesNotReturnStalePath() throws {
        // Make the cache root a *file*, so creating a subdirectory under it
        // is impossible → createDirectory throws.
        let fileAsRoot = tmpDir.appendingPathComponent("not-a-dir")
        try "i am a file".write(to: fileAsRoot, atomically: true, encoding: .utf8)
        let repo = URL(fileURLWithPath: "/some/repo")
        XCTAssertThrowsError(
            try DocumentModel.writeGitLog(
                markdown: "# x\n", repoRoot: repo, relPath: nil, cacheRoot: fileAsRoot),
            "a write failure must propagate, not be swallowed")
    }
}
