import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// UAT LSP-01 regression: the PROBLEMS sidebar section must not present a
/// falsely-reassuring "No problems detected." for an LSP-supported file the
/// language server was never asked about. Source view never drives the
/// `didOpen`/`didChange` that makes a server publish diagnostics, so an empty
/// diagnostics store for an open `.swift` file means "not analyzed here", not
/// "clean". `DocumentModel.activeFileUnanalyzedByLSP` is the signal the panel
/// reads to swap the all-clear copy for an honest "not analyzed" message.
///
/// Host-safe (constructs DocumentModel directly, no window, no LSP server
/// spawned — the property is pure: registry lookup + store membership).
@MainActor
final class ProblemsPanelUnanalyzedTests: XCTestCase {

    private var tmp: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProblemsUnanalyzed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        suite = "ProblemsUnanalyzed-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func file(_ rel: String, _ body: String) throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_noActiveFile_isNotFlaggedUnanalyzed() {
        let model = makeModel()
        XCTAssertFalse(model.activeFileUnanalyzedByLSP,
                       "with no open file there's nothing to analyze; the empty store is genuinely empty")
    }

    func test_lspSupportedFile_withEmptyStore_isUnanalyzed() throws {
        // A .swift file open in Source view with no diagnostics in the store:
        // the server was never told about it ⇒ honest "not analyzed", NOT a
        // green "no problems".
        let swift = try file("badType.swift", "let badType: Int = \"not an int\"\n")
        let model = makeModel()
        model.open(url: swift)
        XCTAssertEqual(model.currentURL?.standardizedFileURL.resolvingSymlinksInPath().path,
                       swift.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertTrue(model.activeFileUnanalyzedByLSP,
                      "an LSP-supported file with no store entry must read as un-analyzed")
    }

    func test_lspSupportedFile_withDiagnostics_isNotUnanalyzed() throws {
        // Once diagnostics exist for the file, it's been analyzed — the panel
        // shows rows, and even an emptied future publish is "clean", not
        // "un-analyzed" while the entry stands.
        let swift = try file("ok.swift", "let x = 1\n")
        let model = makeModel()
        model.open(url: swift)
        let url = model.currentURL!
        model.lspDiagnostics.replace(url: url, with: [
            LSPDiagnostic(
                range: .init(start: .init(line: 0, character: 0),
                             end: .init(line: 0, character: 4)),
                severity: .error, code: nil, source: "sourcekitd",
                message: "cannot convert value of type 'String' to 'Int'")
        ])
        XCTAssertFalse(model.activeFileUnanalyzedByLSP,
                       "a file with diagnostics in the store has been analyzed")
    }

    func test_nonLSPFile_isNotFlaggedUnanalyzed() throws {
        // Markdown / plain text have no registered language server, so the
        // all-clear "No problems detected." is genuinely correct for them —
        // they must NOT be flagged un-analyzed.
        let md = try file("README.md", "# hello\n")
        let model = makeModel()
        model.open(url: md)
        XCTAssertFalse(model.activeFileUnanalyzedByLSP,
                       ".md has no LSP language; the empty-store all-clear is correct")
    }
}
