import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-719 — host coverage for the DocumentModel glue that turns the selected
/// editor tab's fold regions + scroll position into the published
/// `stickyScrollHeaders`. The pure pin logic is pinned in
/// `ViewerCoreTests.StickyScrollHeadersTests`; this verifies the live recompute
/// fires on scroll and clears off the editor. Host-safe (no window/WebView).
@MainActor
final class StickyScrollModelTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StickyScrollModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "StickyScrollModelTests-\(UUID().uuidString)"
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

    private let source = """
    class Foo {
        func bar() {
            let x = 1
            return x
        }
    }
    """

    /// Open `source` as an editor-mode tab with the given fold regions injected.
    private func openEditorTab(_ model: DocumentModel) throws -> UUID {
        let url = tmpDir.appendingPathComponent("Foo.swift")
        try source.write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        let id = model.tabs.selected!.id
        var t = model.tabs.tabs[0]
        t.viewMode = .editor
        model.tabCoordinator.replace(at: 0, with: t)
        model.editor.setEditorFoldRegions(
            [FoldRegion(startLine: 1, endLine: 6, kind: .type),
             FoldRegion(startLine: 2, endLine: 5, kind: .function)],
            forTabID: id)
        return id
    }

    func test_scrollIntoNestedScope_pinsEnclosingHeaders() throws {
        let model = makeModel()
        let id = try openEditorTab(model)
        // Top-visible line 3 (inside func bar) → pin the class + the func.
        model.recordEditorScroll(
            CMScrollPosition(top: 40, left: 0, viewportFromLine: 3, viewportToLine: 10),
            forTabID: id)
        XCTAssertEqual(model.stickyScrollHeaders.map(\.text),
                       ["class Foo {", "func bar() {"])
        XCTAssertEqual(model.stickyScrollHeaders.map(\.kind), [.type, .function])
    }

    func test_scrolledToTop_pinsNothing() throws {
        let model = makeModel()
        let id = try openEditorTab(model)
        model.recordEditorScroll(
            CMScrollPosition(top: 0, left: 0, viewportFromLine: 1, viewportToLine: 8),
            forTabID: id)
        XCTAssertTrue(model.stickyScrollHeaders.isEmpty,
                      "at the top, every header is on screen — nothing to pin")
    }

    func test_switchingOutOfEditorMode_clearsHeaders() throws {
        let model = makeModel()
        let id = try openEditorTab(model)
        model.recordEditorScroll(
            CMScrollPosition(top: 40, left: 0, viewportFromLine: 3, viewportToLine: 10),
            forTabID: id)
        XCTAssertFalse(model.stickyScrollHeaders.isEmpty)

        // Flip the selected tab out of editor mode + recompute → cleared.
        var t = model.tabs.tabs[0]
        t.viewMode = .source
        model.tabCoordinator.replace(at: 0, with: t)
        model.recomputeStickyScrollHeaders()
        XCTAssertTrue(model.stickyScrollHeaders.isEmpty,
                      "sticky scroll is editor-mode only")
    }
}
