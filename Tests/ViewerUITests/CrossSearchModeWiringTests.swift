import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-758 — DocumentModel cross-search wiring for the Text|FileName mode and
/// the regex toggle. Host-safe (T1m): drives `runCrossSearch(scope:)` against a
/// temp fixture folder and reads the published state. No window.
@MainActor
final class CrossSearchModeWiringTests: XCTestCase {
    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossSearchWiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // A file whose NAME contains the needle but whose CONTENT does not — so
        // text mode finds nothing and filename mode finds it.
        try "plain content\n".write(
            to: tmpDir.appendingPathComponent("zzunique_name.txt"),
            atomically: true, encoding: .utf8)
        suiteName = "CrossSearchWiring-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    /// Poll until the background search settles (or the deadline lapses).
    private func awaitSearch(_ m: DocumentModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while m.crossSearchIsRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // One extra tick so the main-queue result hop lands.
        try await Task.sleep(for: .milliseconds(40))
    }

    // MARK: Regex-error gate (synchronous)

    func test_invalidRegex_setsErrorAndSkips_synchronously() {
        let m = makeModel()
        m.crossSearchUseRegex = true
        m.crossSearchQuery = "(a+)+"  // ReDoS shape — rejected up front
        m.runCrossSearch(scope: tmpDir)
        XCTAssertNotNil(m.crossSearchRegexError, "a rejected regex surfaces a reason")
        XCTAssertTrue(m.crossSearchResults.isEmpty)
        XCTAssertFalse(m.crossSearchIsRunning, "the walk is skipped — no background run")
    }

    func test_validRegex_clearsError_synchronously() {
        let m = makeModel()
        m.crossSearchUseRegex = true
        m.crossSearchQuery = "(a+)+"
        m.runCrossSearch(scope: tmpDir)
        XCTAssertNotNil(m.crossSearchRegexError)
        // Switch to a valid pattern — the error clears before dispatch.
        m.crossSearchQuery = #"\bplain\b"#
        m.runCrossSearch(scope: tmpDir)
        XCTAssertNil(m.crossSearchRegexError)
    }

    // MARK: Mode routing (asynchronous)

    func test_textMode_vs_filenameMode_route_toDifferentEngines() async throws {
        let m = makeModel()
        m.crossSearchQuery = "zzunique_name"

        // Text mode: the content is "plain content" — no content hit.
        m.crossSearchFilenameMode = false
        m.runCrossSearch(scope: tmpDir)
        try await awaitSearch(m)
        XCTAssertTrue(m.crossSearchResults.isEmpty,
                      "text mode searches CONTENT — the needle is only in the file NAME")

        // Filename mode: the file name contains the needle → one hit.
        m.crossSearchFilenameMode = true
        m.runCrossSearch(scope: tmpDir)
        try await awaitSearch(m)
        XCTAssertEqual(m.crossSearchResults.map { $0.url.lastPathComponent },
                       ["zzunique_name.txt"],
                       "filename mode matches the NAME")
        XCTAssertTrue(m.crossSearchResults.first?.matches.isEmpty ?? false,
                      "a filename hit carries no line matches")
    }
}
