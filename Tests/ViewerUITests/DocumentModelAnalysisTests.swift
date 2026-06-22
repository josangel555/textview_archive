import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host coverage for the active-document ANALYSIS model wiring (TSK-1227,
/// continuing the TSK-1113/1224/1225/1226 built-but-under-tested drain):
/// `activeDocumentStats` (word/char/line counts) and `checkLinksInActiveMarkdown`
/// (broken local-link report). The DocumentStats / MarkdownLinks engines have
/// their own tests, but the DocumentModel wiring — the gates, active-file
/// routing, and (for links) base-dir-relative existence resolution — had NO host
/// coverage. These pin that wiring with teeth: stats route through the engine for
/// the active file; the link checker resolves links relative to the FILE's own
/// directory (a real existing file is OK, a missing one is broken) and is gated
/// to Markdown files only.
@MainActor
final class DocumentModelAnalysisTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelAnalysisTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelAnalysisTests-\(UUID().uuidString)"
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
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Document stats

    func test_activeDocumentStats_routesActiveFileThroughEngine() throws {
        let model = makeModel()
        let text = "hello world\nfoo bar baz\n"
        let url = try writeFile("a.txt", text)
        model.open(url: url)
        XCTAssertEqual(model.activeDocumentStats, DocumentStats.compute(text),
            "stats must be DocumentStats.compute of the active file's text")
        XCTAssertTrue((model.activeDocumentStats?.words ?? 0) >= 1, "non-empty file has words")
    }

    func test_activeDocumentStats_isNil_whenNoActiveFile() {
        let model = makeModel()
        XCTAssertNil(model.activeDocumentStats)
    }

    // MARK: - Markdown link check

    func test_checkLinksInActiveMarkdown_resolvesLocalLinksRelativeToFileDir() throws {
        let model = makeModel()
        // A real sibling the link can resolve to, and one that's absent.
        try writeFile("present.txt", "x")
        let url = try writeFile("doc.md", "[ok](present.txt)\n[bad](missing.txt)\n")
        model.open(url: url)
        let report = model.checkLinksInActiveMarkdown()
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.total, 2, "both local links count toward total")
        XCTAssertEqual(report?.broken.count, 1, "only the missing target is broken")
        XCTAssertTrue(report?.broken.first?.target.contains("missing") == true,
            "the broken entry points at the absent target")
    }

    func test_checkLinksInActiveMarkdown_allResolve_noBroken() throws {
        let model = makeModel()
        try writeFile("a.txt", "x")
        try writeFile("b.txt", "y")
        let url = try writeFile("doc.md", "[a](a.txt) and [b](b.txt)\n")
        model.open(url: url)
        let report = model.checkLinksInActiveMarkdown()
        XCTAssertEqual(report?.total, 2)
        XCTAssertEqual(report?.broken.count, 0, "all local links resolve → none broken")
    }

    func test_checkLinksInActiveMarkdown_isNil_forNonMarkdownFile() throws {
        let model = makeModel()
        let url = try writeFile("notes.txt", "[bad](missing.txt)\n")
        model.open(url: url)
        XCTAssertNil(model.checkLinksInActiveMarkdown(),
            "the link checker is gated to Markdown files only")
    }

    func test_checkLinksInActiveMarkdown_isNil_whenNoActiveFile() {
        let model = makeModel()
        XCTAssertNil(model.checkLinksInActiveMarkdown())
    }
}
