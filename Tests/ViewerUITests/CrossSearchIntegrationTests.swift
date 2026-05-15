import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// L3 integration tests for the cross-file search panel + DocumentModel
/// wiring.
@MainActor
final class CrossSearchIntegrationTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossSearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "CrossSearch-\(UUID().uuidString)"
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
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("b.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func waitFor(timeout: TimeInterval, until predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    func test_initialState() throws {
        let model = makeModel()
        XCTAssertFalse(model.isCrossSearchPresented)
        XCTAssertEqual(model.crossSearchQuery, "")
        XCTAssertEqual(model.crossSearchResults.count, 0)
    }

    func test_showAndDismiss_toggles() throws {
        let model = makeModel()
        model.showCrossSearch()
        XCTAssertTrue(model.isCrossSearchPresented)
        model.dismissCrossSearch()
        XCTAssertFalse(model.isCrossSearchPresented)
        XCTAssertEqual(model.crossSearchQuery, "")
    }

    func test_runCrossSearch_withoutFolder_returnsNothing() async throws {
        let model = makeModel()
        model.crossSearchQuery = "anything"
        model.runCrossSearch()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.crossSearchResults.count, 0)
    }

    func test_runCrossSearch_findsMatches() async throws {
        try write("doc1.md", "alpha\nneedle here\n")
        try write("sub/doc2.md", "more needle\n")
        try write("other.md", "no match\n")
        let model = makeModel()
        model.sidebar.setRoot(tmpDir)
        model.crossSearchQuery = "needle"
        model.runCrossSearch()
        let gotResults = await waitFor(timeout: 3.0) {
            !model.crossSearchResults.isEmpty
        }
        XCTAssertTrue(gotResults, "Expected cross-search to find matches within 3s")
        XCTAssertEqual(model.crossSearchResults.count, 2)
        XCTAssertFalse(model.crossSearchIsRunning, "isRunning should reset to false on completion")
    }

    func test_emptyQuery_clearsResults() async throws {
        try write("a.md", "needle\n")
        let model = makeModel()
        model.sidebar.setRoot(tmpDir)
        model.crossSearchQuery = "needle"
        model.runCrossSearch()
        _ = await waitFor(timeout: 3.0) { !model.crossSearchResults.isEmpty }
        XCTAssertFalse(model.crossSearchResults.isEmpty)
        model.crossSearchQuery = ""
        model.runCrossSearch()
        XCTAssertTrue(model.crossSearchResults.isEmpty)
    }

    func test_caseSensitive_toggle() async throws {
        try write("a.md", "NEEDLE\nneedle\n")
        let model = makeModel()
        model.sidebar.setRoot(tmpDir)
        model.crossSearchQuery = "needle"
        model.crossSearchCaseSensitive = false
        model.runCrossSearch()
        _ = await waitFor(timeout: 3.0) { !model.crossSearchResults.isEmpty }
        let insensitiveCount = model.crossSearchResults.first?.matches.count ?? 0
        XCTAssertEqual(insensitiveCount, 2)

        model.crossSearchCaseSensitive = true
        model.runCrossSearch()
        _ = await waitFor(timeout: 3.0) {
            !model.crossSearchIsRunning && !model.crossSearchResults.isEmpty
        }
        let sensitiveCount = model.crossSearchResults.first?.matches.count ?? 0
        XCTAssertEqual(sensitiveCount, 1, "Case-sensitive should only match the lowercase 'needle' line")
    }
}
