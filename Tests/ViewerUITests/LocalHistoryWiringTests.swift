import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1103 — teeth for wiring LocalHistoryStore into a reachable "History" list.
/// `showLocalHistory()` lists the active file's snapshots in a hosted tab
/// (returning the version count); no active file → no-op. (The list/version
/// render is VM; the store + snapshotting are covered by LocalHistoryStore tests.)
@MainActor
final class LocalHistoryWiringTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalHistWiring-\(UUID().uuidString)")
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
                suiteName: "LocalHist-\(UUID().uuidString)")!),
            localHistory: lh)
    }

    func test_showLocalHistory_opensTabWithVersions() throws {
        let lh = LocalHistoryStore(directory: tmp.appendingPathComponent("lh"), isEnabled: { true })
        let md = tmp.appendingPathComponent("doc.md")
        try "# version one".write(to: md, atomically: true, encoding: .utf8)
        XCTAssertNotNil(lh.snapshot(path: md.path, content: "# version one",
                                    at: Date(timeIntervalSince1970: 1_700_000_000)))

        let model = makeModel(lh)
        model.open(url: md)
        let before = model.tabs.tabs.count

        let count = model.showLocalHistory()
        XCTAssertEqual(count, 1, "one snapshot listed")
        XCTAssertGreaterThan(model.tabs.tabs.count, before, "opens the history hosted tab")
    }

    func test_showLocalHistory_noActiveFile_isZero() {
        let lh = LocalHistoryStore(directory: tmp.appendingPathComponent("lh2"), isEnabled: { true })
        let model = makeModel(lh)
        XCTAssertEqual(model.showLocalHistory(), 0)
    }

    /// Owner 2026-08-29 — the tab's history source carries the "On disk"
    /// entry exactly while the live buffer differs from disk (the unsaved
    /// delta), reading the LIVE buffer and the REAL file.
    func test_tabHistorySource_listsOnDiskEntry_whileBufferIsDirty() throws {
        let lh = LocalHistoryStore(directory: tmp.appendingPathComponent("lh3"), isEnabled: { true })
        let md = tmp.appendingPathComponent("edit.md")
        try "on disk\n".write(to: md, atomically: true, encoding: .utf8)
        let model = makeModel(lh)
        model.open(url: md)
        let tabID = try XCTUnwrap(model.tabs.selected?.id)
        let source = try XCTUnwrap(model.makeLocalHistorySource(for: md, tabID: tabID))
        XCTAssertFalse(source.listVersions().contains { $0.kind == .onDisk },
                       "clean tab: no unsaved delta to show")

        model.setCurrentViewMode(.editor)
        model.updateEditorText("on disk\nunsaved edit\n", forTabID: tabID)
        let list = source.listVersions()
        XCTAssertEqual(list.first?.kind, .onDisk, "dirty tab: the On-disk entry appears")
        XCTAssertEqual(source.content(of: list[0]), "on disk\n")
        XCTAssertTrue(source.diffAgainstCurrent(list[0]).contains("+unsaved edit"),
                      "diff vs current is the unsaved delta (disk → buffer)")
    }

    /// Dead-channel pin: the verb is reachable from the tab context menu and
    /// routes through the model.
    func test_tabContextMenu_mountsShowUnsavedChanges() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/ViewerUI/TabBar.swift"),
                             encoding: .utf8)
        XCTAssertTrue(bar.contains("Show Unsaved Changes"))
        XCTAssertTrue(bar.contains("showUnsavedChanges(forTabID: tab.id)"))
    }
}
