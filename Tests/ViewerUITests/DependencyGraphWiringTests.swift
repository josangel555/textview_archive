import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1100 — teeth for wiring the built-but-unreachable DependencyGraphView to a
/// reachable entry. `showDependencyGraph()` builds the project import graph
/// off-main and opens it as a hosted tab; with no project root it's a no-op.
/// (The Canvas render itself is VM/review; this pins the reachability wiring.)
@MainActor
final class DependencyGraphWiringTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DepGraphWiring-\(UUID().uuidString)")
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
                suiteName: "DepGraph-\(UUID().uuidString)")!))
    }

    func test_showDependencyGraph_opensHostedTab() async throws {
        try "import B\nlet x = 1\n".write(
            to: tmp.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "let y = 2\n".write(
            to: tmp.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)

        let model = makeModel()
        model.sidebar.setRoot(tmp)
        let before = model.tabs.tabs.count

        model.showDependencyGraph()   // off-main graph build → hosted tab
        for _ in 0..<400 {
            if model.tabs.tabs.count > before { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(model.tabs.tabs.count, before,
                             "Dependency Graph opens a hosted tab (reachable)")
    }

    func test_showDependencyGraph_noProjectRoot_isNoOp() async throws {
        let model = makeModel()   // no setRoot → no project root
        let before = model.tabs.tabs.count
        model.showDependencyGraph()
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.tabs.tabs.count, before,
                       "no project root → no-op (no spurious tab)")
    }
}
