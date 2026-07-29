import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1605 (owner 2026-07-25: "rename is buggy … I don't see the new file, or
/// the old tab stays open, if I edit and save sometimes the Untitled.txt comes
/// back") — the rename FOLLOW-THROUGH contract, end to end at the model
/// boundary the sidebar's rename field calls.
///
/// The three symptoms are one chain: if the open tab isn't retargeted, its
/// editor buffer keeps the OLD url, and the next ⌘S writes the deleted file
/// back to disk — resurrecting `Untitled.txt`.
@MainActor
final class RenameFollowThroughTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        // NOTE: `temporaryDirectory` is under /var → /private/var (a SYMLINK).
        // That's exactly the normalization asymmetry the app hits in the wild,
        // so the fixture deliberately does NOT pre-resolve it.
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameFollowThrough-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "RenameFollowThrough-\(UUID().uuidString)"
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
            preferences: PreferencesStore(defaults: defaults))
    }

    /// The reported flow: New File → rename it → the tab must follow.
    func test_rename_openTabFollows_noStaleURL() throws {
        let m = makeModel()
        let created = try XCTUnwrap(m.createNewFile(in: tmpDir, baseName: "Untitled.txt"))
        XCTAssertEqual(m.tabs.tabs.count, 1, "the new file opened in a tab")

        let renamed = try XCTUnwrap(m.renameFile(at: created, to: "notes.md"),
                                    "rename must succeed")
        XCTAssertEqual(renamed.lastPathComponent, "notes.md")

        // THE BUG: the tab kept pointing at the old (now deleted) path.
        XCTAssertEqual(m.tabs.tabs.count, 1, "no duplicate tab is spawned")
        XCTAssertEqual(m.tabs.tabs[0].url?.lastPathComponent, "notes.md",
                       "the open tab must FOLLOW the rename, not strand on Untitled.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path),
                       "the old file is gone from disk")
    }

    /// The resurrection symptom: after a rename, saving the editor buffer must
    /// write to the NEW path — never re-create the old file.
    func test_rename_thenEdit_andSave_doesNotResurrectOldFile() throws {
        let m = makeModel()
        let created = try XCTUnwrap(m.createNewFile(in: tmpDir, baseName: "Untitled.txt"))
        let tabID = try XCTUnwrap(m.tabs.selected?.id)
        _ = m.editorBuffer(forTabID: tabID)          // materialize the buffer
        let renamed = try XCTUnwrap(m.renameFile(at: created, to: "renamed.txt"))

        // Edit + save, exactly as the user did.
        m.updateEditorText("edited after rename\n", forTabID: tabID)
        XCTAssertTrue(m.saveActiveEditor(), "save must succeed after a rename")

        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path),
                       "saving must NOT resurrect Untitled.txt")
        let onDisk = try String(contentsOf: renamed, encoding: .utf8)
        XCTAssertEqual(onDisk, "edited after rename\n",
                       "the edit landed in the RENAMED file")
    }

    /// The editor buffer itself must be re-keyed — it owns the save target.
    func test_rename_editorBufferRetargets() throws {
        let m = makeModel()
        let created = try XCTUnwrap(m.createNewFile(in: tmpDir, baseName: "Untitled.txt"))
        let tabID = try XCTUnwrap(m.tabs.selected?.id)
        _ = m.editorBuffer(forTabID: tabID)
        let renamed = try XCTUnwrap(m.renameFile(at: created, to: "buf.txt"))
        let buf = try XCTUnwrap(m.editorBuffers[tabID])
        XCTAssertEqual(buf.url.standardizedFileURL.resolvingSymlinksInPath(),
                       renamed.standardizedFileURL.resolvingSymlinksInPath(),
                       "the buffer's save target must be the NEW url")
    }

    /// TSK-1605 — the named-create path the prompt drives: the file lands with
    /// the EXACT name given (no `Untitled.txt`, no silent uniquifying) and
    /// opens in a tab, so the rename step isn't needed at all.
    func test_createWithExplicitName_landsWithThatName_andOpens() throws {
        let m = makeModel()
        let url = try XCTUnwrap(m.createNewFile(in: tmpDir, baseName: "design-notes.md"))
        XCTAssertEqual(url.lastPathComponent, "design-notes.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(m.tabs.tabs.count, 1)
        XCTAssertEqual(m.tabs.tabs[0].url?.lastPathComponent, "design-notes.md")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tmpDir.appendingPathComponent("Untitled.txt").path),
            "the named-create path must never leave an Untitled.txt behind")
    }

    /// Unsaved edits must survive the rename (not silently dropped).
    func test_rename_preservesUnsavedEdits() throws {
        let m = makeModel()
        let created = try XCTUnwrap(m.createNewFile(in: tmpDir, baseName: "Untitled.txt"))
        let tabID = try XCTUnwrap(m.tabs.selected?.id)
        _ = m.editorBuffer(forTabID: tabID)
        m.updateEditorText("work in progress\n", forTabID: tabID)
        XCTAssertTrue(m.tabs.tabs[0].isDirty, "precondition: dirty")

        _ = try XCTUnwrap(m.renameFile(at: created, to: "wip.txt"))
        let buf = try XCTUnwrap(m.editorBuffers[tabID])
        XCTAssertEqual(buf.text, "work in progress\n", "unsaved edits survive a rename")
        XCTAssertTrue(m.tabs.tabs[0].isDirty, "and the tab is still dirty")
    }
}
