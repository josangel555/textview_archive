import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-726 — host coverage for the DocumentModel orchestration of project-wide
/// replace: the async `runCrossFileReplace` (off-main rewrite → status + results
/// cleared) and the pure `replaceStatusText` formatter. The engine itself is
/// pinned exhaustively in `ViewerCoreTests.CrossFileReplaceTests`; this is the
/// model wiring. Host-safe (temp files, no window).
@MainActor
final class CrossFileReplaceModelTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossFileReplaceModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "CrossFileReplaceModelTests-\(UUID().uuidString)"
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
    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - replaceStatusText (pure)

    func test_replaceStatusText_pluralization() {
        func status(_ occ: Int, _ files: Int, fails: Int = 0) -> String {
            var outs: [CrossFileReplace.FileOutcome] = []
            // `occ` spread across `files` successful files (1 each is enough for
            // the count math; the formatter sums replacements + counts files).
            for i in 0..<files {
                outs.append(.init(url: tmpDir.appendingPathComponent("f\(i)"),
                                  replacements: i == 0 ? occ - (files - 1) : 1,
                                  error: nil))
            }
            for i in 0..<fails {
                outs.append(.init(url: tmpDir.appendingPathComponent("x\(i)"),
                                  replacements: 0, error: "boom"))
            }
            return DocumentModel.replaceStatusText(CrossFileReplace.Summary(outcomes: outs))
        }
        XCTAssertEqual(status(1, 1), "Replaced 1 occurrence in 1 file")
        XCTAssertEqual(status(3, 2), "Replaced 3 occurrences in 2 files")
        XCTAssertEqual(DocumentModel.replaceStatusText(
            CrossFileReplace.Summary(outcomes: [])), "No occurrences replaced")
        XCTAssertEqual(status(2, 1, fails: 1),
                       "Replaced 2 occurrences in 1 file · 1 file failed")
    }

    // MARK: - runCrossFileReplace (async)

    func test_runCrossFileReplace_rewritesFiles_andClearsResults() throws {
        let a = try write("a.txt", "foo and foo")
        let b = try write("b.txt", "foo")
        let model = makeModel()
        model.crossSearchQuery = "foo"
        model.crossSearchReplacement = "bar"
        model.crossSearchCaseSensitive = true
        model.crossSearchResults = [
            CrossFileSearch.FileMatches(url: a, matches: []),
            CrossFileSearch.FileMatches(url: b, matches: []),
        ]

        let done = expectation(description: "replace status posted")
        let cancellable = model.$crossSearchReplaceStatus.dropFirst().sink { status in
            if status != nil { done.fulfill() }
        }
        model.runCrossFileReplace()
        wait(for: [done], timeout: 5)
        cancellable.cancel()

        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "bar and bar")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "bar")
        XCTAssertEqual(model.crossSearchReplaceStatus, "Replaced 3 occurrences in 2 files")
        XCTAssertTrue(model.crossSearchResults.isEmpty,
                      "stale matches are cleared after a rewrite")
    }

    func test_runCrossFileReplace_filenameMode_isNoOp() throws {
        let a = try write("a.txt", "foo")
        let model = makeModel()
        model.crossSearchFilenameMode = true
        model.crossSearchQuery = "foo"
        model.crossSearchReplacement = "bar"
        model.crossSearchResults = [CrossFileSearch.FileMatches(url: a, matches: [])]
        model.runCrossFileReplace()
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "foo",
                       "filename-mode replace must not rewrite file contents")
        XCTAssertNil(model.crossSearchReplaceStatus)
    }

    func test_runCrossFileReplace_emptyResults_isNoOp() {
        let model = makeModel()
        model.crossSearchQuery = "foo"
        model.crossSearchReplacement = "bar"
        model.crossSearchResults = []
        model.runCrossFileReplace()
        XCTAssertNil(model.crossSearchReplaceStatus)
    }
}
