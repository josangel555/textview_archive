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
}
