import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1121 — teeth for wiring SourceAnnotationScanner into a reachable
/// "Annotations" jump-list. `showAnnotations()` scans the ACTIVE text file and
/// opens a hosted tab (returning the marker count); with no active file it's a
/// no-op. (The list render + the jump are VM/review; this pins the model wiring,
/// and the scan itself is covered by SourceAnnotationScannerTests.)
@MainActor
final class AnnotationsWiringTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotWiring-\(UUID().uuidString)")
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
                suiteName: "Annot-\(UUID().uuidString)")!))
    }

    func test_showAnnotations_opensTabWithActiveFileMarkers() throws {
        let url = tmp.appendingPathComponent("notes.swift")
        try "let x = 1 // TODO: wire this\n// FIXME broken\nlet y = 2\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.open(url: url)
        let before = model.tabs.tabs.count

        let count = model.showAnnotations()
        XCTAssertEqual(count, 2, "found TODO + FIXME in the active file")
        XCTAssertGreaterThan(model.tabs.tabs.count, before,
                             "opens the annotations hosted tab (reachable)")
    }

    func test_showAnnotations_noActiveFile_isNoOp() {
        let model = makeModel()
        let before = model.tabs.tabs.count
        XCTAssertEqual(model.showAnnotations(), 0, "no active file → 0 annotations")
        XCTAssertEqual(model.tabs.tabs.count, before, "no spurious tab")
    }
}
