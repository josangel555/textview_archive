import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1153 — teeth for wiring LogPatternClusterer into a reachable "Patterns"
/// panel. `showLogPatterns()` clusters the ACTIVE text file and opens a hosted
/// tab (returning the distinct-pattern count); with no active file it's a no-op.
/// (The list render is VM/review; clustering is covered by LogPatternClustererTests.)
@MainActor
final class LogPatternsWiringTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogPatWiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: UserDefaults(
                suiteName: "LogPat-\(UUID().uuidString)")!))
    }

    func test_showLogPatterns_opensTabWithActiveFilePatterns() throws {
        let url = tmp.appendingPathComponent("app.log")
        // Two distinct templates: "Request <NUM> took <NUM>ms" (×2) and "starting up" (×1).
        try "Request 1 took 5ms\nRequest 2 took 9ms\nstarting up\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.open(url: url)
        let before = model.tabs.tabs.count

        let patterns = model.showLogPatterns()
        XCTAssertEqual(patterns, 2, "two distinct line templates clustered")
        XCTAssertGreaterThan(model.tabs.tabs.count, before, "opens the patterns hosted tab")
    }

    func test_showLogPatterns_noActiveFile_isNoOp() {
        let model = makeModel()
        let before = model.tabs.tabs.count
        XCTAssertEqual(model.showLogPatterns(), 0, "no active file → 0 patterns")
        XCTAssertEqual(model.tabs.tabs.count, before, "no spurious tab")
    }
}
