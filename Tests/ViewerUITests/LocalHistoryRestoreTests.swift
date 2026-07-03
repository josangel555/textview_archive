import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1331 / TSK-1462 — teeth for `DocumentModel.restoreLocalHistoryVersion`,
/// the data-safety-reviewed restore path (design A: open-then-apply, NEVER a
/// direct disk write):
///
///   1. backup-before-restore — the current disk state (and a dirty buffer's
///      unsaved state) is snapshotted into Local History first;
///   2. open-tab restore lands as an undoable buffer edit with the tab forced
///      to editor mode (a buffer-only restore under a rendered pane would be
///      invisible state);
///   3. no-open-tab restore opens the file first, then applies;
///   4. the DISK is untouched in every case (the user must save explicitly);
///   5. failures are honest no-ops.
///
/// Also pins the File → Local History reroute to the UNIFIED viewer
/// (`showLocalHistory` → `openLocalHistory(for:)`).
@MainActor
final class LocalHistoryRestoreTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalHistRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel(_ lh: LocalHistoryStore) -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: UserDefaults(
                suiteName: "LocalHistRestore-\(UUID().uuidString)")!),
            localHistory: lh)
    }

    private func makeStore() -> LocalHistoryStore {
        LocalHistoryStore(directory: tmp.appendingPathComponent("lh-\(UUID().uuidString)"),
                          isEnabled: { true })
    }

    /// The store key the model uses (standardized path of the tab URL).
    private func storeKey(_ model: DocumentModel, _ url: URL) -> String {
        model.tabs.tabs.first { $0.url?.lastPathComponent == url.lastPathComponent }?
            .url?.standardizedFileURL.path ?? url.standardizedFileURL.path
    }

    // MARK: - Open-tab restore

    func test_restore_intoOpenTab_appliesUndoableEdit_andForcesEditorMode() throws {
        let lh = makeStore()
        let md = tmp.appendingPathComponent("doc.md")
        try "# current\n".write(to: md, atomically: true, encoding: .utf8)

        let model = makeModel(lh)
        model.open(url: md)
        XCTAssertNotEqual(model.tabs.tabs.first?.viewMode, .editor,
                          "precondition: markdown opens in a non-editor mode")

        let outcome = model.restoreLocalHistoryVersion("# old version\n", at: md)
        XCTAssertEqual(outcome, .appliedToOpenTab)

        let tab = try XCTUnwrap(model.tabs.tabs.first)
        XCTAssertEqual(tab.viewMode, .editor,
                       "restore must be VISIBLE — the tab switches to editor mode")
        let buf = try XCTUnwrap(model.editorBuffer(forTabID: tab.id))
        XCTAssertEqual(buf.text, "# old version\n")
        XCTAssertTrue(buf.isDirty, "restore is an unsaved edit, not a disk write")
        XCTAssertEqual(try String(contentsOf: md, encoding: .utf8), "# current\n",
                       "DISK must be untouched until the user saves")
    }

    func test_restore_backsUpDiskState_beforeApplying() throws {
        let lh = makeStore()
        let md = tmp.appendingPathComponent("doc.md")
        try "# disk state\n".write(to: md, atomically: true, encoding: .utf8)

        let model = makeModel(lh)
        model.open(url: md)
        let key = storeKey(model, md)
        XCTAssertTrue(lh.versions(for: key).isEmpty, "precondition: no history yet")

        _ = model.restoreLocalHistoryVersion("# restored\n", at: md)

        // The pre-restore DISK content is now recoverable from the timeline.
        let contents = lh.versions(for: key).compactMap { lh.contentString(of: $0, for: key) }
        XCTAssertTrue(contents.contains("# disk state\n"),
                      "backup-before-restore must snapshot the pre-restore disk state; got \(contents)")
    }

    func test_restore_backsUpDirtyBufferState_too() throws {
        let lh = makeStore()
        let md = tmp.appendingPathComponent("doc.md")
        try "# disk\n".write(to: md, atomically: true, encoding: .utf8)

        let model = makeModel(lh)
        model.open(url: md)
        let tab = try XCTUnwrap(model.tabs.tabs.first)
        // Unsaved edits in the open buffer — the exact state the owner has
        // been burned losing.
        model.updateEditorText("# unsaved draft\n", forTabID: tab.id)

        _ = model.restoreLocalHistoryVersion("# restored\n", at: md)

        let key = storeKey(model, md)
        let contents = lh.versions(for: key).compactMap { lh.contentString(of: $0, for: key) }
        XCTAssertTrue(contents.contains("# disk\n"), "disk state backed up")
        XCTAssertTrue(contents.contains("# unsaved draft\n"), "dirty buffer state backed up")
        XCTAssertEqual(model.editorBuffer(forTabID: tab.id)?.text, "# restored\n")
    }

    // MARK: - No-open-tab restore (the TSK-1331 tail)

    func test_restore_noOpenTab_opensFileThenApplies_diskUntouched() throws {
        let lh = makeStore()
        let md = tmp.appendingPathComponent("closed.md")
        try "# on disk\n".write(to: md, atomically: true, encoding: .utf8)

        let model = makeModel(lh)
        XCTAssertTrue(model.tabs.tabs.isEmpty, "precondition: file not open")

        let outcome = model.restoreLocalHistoryVersion("# from history\n", at: md)
        XCTAssertEqual(outcome, .openedAndApplied)

        let tab = try XCTUnwrap(model.tabs.tabs.first(where: {
            $0.url?.lastPathComponent == "closed.md"
        }), "restore must OPEN the file")
        XCTAssertEqual(tab.viewMode, .editor)
        XCTAssertEqual(model.editorBuffer(forTabID: tab.id)?.text, "# from history\n")
        XCTAssertEqual(model.editorBuffer(forTabID: tab.id)?.isDirty, true)
        XCTAssertEqual(try String(contentsOf: md, encoding: .utf8), "# on disk\n",
                       "restore NEVER writes the disk directly")
    }

    func test_restore_missingFile_failsHonestly() {
        let lh = makeStore()
        let model = makeModel(lh)
        let gone = tmp.appendingPathComponent("never-existed.md")
        let outcome = model.restoreLocalHistoryVersion("text", at: gone)
        guard case .failed = outcome else {
            return XCTFail("restoring a missing file must fail, got \(outcome)")
        }
        XCTAssertTrue(model.tabs.tabs.allSatisfy { $0.url != gone },
                      "no half-open tab left behind on failure")
    }

    // MARK: - File-menu reroute (TSK-1462 discoverability)

    func test_showLocalHistory_opensUnifiedViewer() throws {
        let lh = makeStore()
        let md = tmp.appendingPathComponent("doc.md")
        try "# v1\n".write(to: md, atomically: true, encoding: .utf8)

        let model = makeModel(lh)
        model.open(url: md)
        let key = storeKey(model, md)
        lh.snapshot(path: key, content: "# v1\n", at: Date(timeIntervalSince1970: 1_700_000_000))

        let count = model.showLocalHistory()
        XCTAssertEqual(count, 1)
        // The unified viewer's hosted tab is titled "History: <name>" — the old
        // minimal list used "History — <name>". Pin the reroute.
        let hosted = model.tabs.tabs.last
        XCTAssertEqual(hosted?.title, "History: doc.md",
                       "File → Local History must open the UNIFIED viewer")
    }
}
