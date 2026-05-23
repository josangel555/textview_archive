import XCTest
@testable import ViewerCore

/// Extended coverage for the cross-file text search engine.
///
/// Existing `CrossFileSearchTests` covers happy paths + canonical
/// skipped dirs. This file adds defensive scenarios that matter at
/// the boundary of pathological inputs:
///   - Empty root directory
///   - Symlink loops are bounded by `maxEntriesScanned`
///   - Hidden files are skipped by `skipsHiddenFiles`
///   - File at exactly the size cap is read; size+1 is rejected
///   - Unicode query / haystack via case-insensitive folding
///   - maxResults stops mid-file
final class SearchEngineExtendedTests: XCTestCase {

    private var tmpRoot: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmpRoot = fm.temporaryDirectory
            .appendingPathComponent("search-ext-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmpRoot)
    }

    private func writeFile(_ relPath: String, _ contents: String) throws -> URL {
        let url = tmpRoot.appendingPathComponent(relPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Edge cases

    func test_emptyRoot_returnsEmpty() {
        let results = CrossFileSearch.search(root: tmpRoot, query: "foo")
        XCTAssertEqual(results, [])
    }

    func test_emptyQuery_returnsEmpty_evenWithMatchableContent() throws {
        _ = try writeFile("a.txt", "foo bar")
        XCTAssertEqual(CrossFileSearch.search(root: tmpRoot, query: ""), [])
    }

    func test_singleFile_match_excludesNonMatches() throws {
        _ = try writeFile("hit.txt", "the needle is here\nso is needle again\n")
        _ = try writeFile("miss.txt", "nothing matching\n")
        let res = CrossFileSearch.search(root: tmpRoot, query: "needle")
        XCTAssertEqual(res.count, 1)
        XCTAssertEqual(res[0].url.lastPathComponent, "hit.txt")
        XCTAssertEqual(res[0].matches.count, 2)
    }

    // MARK: - Size cap

    func test_fileAtExactCap_isRead() throws {
        // Cap at 32 bytes. Content == 32 bytes — must still be searched.
        let payload = String(repeating: "a", count: 32)
        _ = try writeFile("cap.txt", payload)
        let opts = CrossFileSearch.Options(maxFileBytes: 32)
        let res = CrossFileSearch.search(root: tmpRoot, query: "a", options: opts)
        XCTAssertEqual(res.count, 1)
    }

    func test_fileOverCap_isSkipped() throws {
        let payload = String(repeating: "a", count: 100)
        _ = try writeFile("over.txt", payload)
        let opts = CrossFileSearch.Options(maxFileBytes: 50)
        let res = CrossFileSearch.search(root: tmpRoot, query: "a", options: opts)
        XCTAssertEqual(res, [])
    }

    // MARK: - maxResults stops mid-file

    func test_maxResults_stopsScanningWithinFile() throws {
        let payload = (0..<10).map { _ in "needle here" }.joined(separator: "\n")
        _ = try writeFile("many.txt", payload)
        let opts = CrossFileSearch.Options(maxResults: 3)
        let res = CrossFileSearch.search(root: tmpRoot, query: "needle", options: opts)
        let total = res.reduce(0) { $0 + $1.matches.count }
        XCTAssertLessThanOrEqual(total, 3,
            "totalMatches should cap at maxResults across files")
    }

    // MARK: - Symlink loop safety

    func test_symlinkLoop_bounded_doesNotHang() throws {
        // proj/loop → proj  (back-edge that would re-enter forever)
        let proj = tmpRoot.appendingPathComponent("proj")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        _ = try writeFile("proj/a.txt", "find me")
        let loopLink = proj.appendingPathComponent("loop")
        try fm.createSymbolicLink(at: loopLink, withDestinationURL: proj)

        // Tight scan cap — the loop guard must prevent runaway descent.
        let opts = CrossFileSearch.Options(maxEntriesScanned: 200)
        let res = CrossFileSearch.search(root: proj, query: "find", options: opts)
        XCTAssertGreaterThan(res.count, 0, "the real file should still be found once")
    }

    // MARK: - Hidden files skipped

    func test_hiddenFiles_areSkipped() throws {
        _ = try writeFile(".hidden", "secret needle")
        _ = try writeFile("visible.txt", "visible needle")
        let res = CrossFileSearch.search(root: tmpRoot, query: "needle")
        XCTAssertEqual(res.count, 1)
        XCTAssertEqual(res[0].url.lastPathComponent, "visible.txt")
    }

    // MARK: - Skipped dir names

    func test_buildDirs_skipped_byDefault() throws {
        _ = try writeFile("node_modules/lib.js", "matching content here")
        _ = try writeFile(".git/config", "matching content here")
        _ = try writeFile("src/main.swift", "matching content here")
        let res = CrossFileSearch.search(root: tmpRoot, query: "matching")
        // Only src/main.swift should match.
        XCTAssertEqual(res.count, 1)
        XCTAssertEqual(res[0].url.lastPathComponent, "main.swift")
    }

    // MARK: - Case sensitivity

    func test_caseInsensitive_default_matches_unicode_case() throws {
        _ = try writeFile("uni.txt", "RÉSUMÉ keyword\n")
        // Unicode case folding via NSString.lowercased — RÉSUMÉ ↔ résumé.
        let res = CrossFileSearch.search(root: tmpRoot, query: "résumé")
        XCTAssertEqual(res.count, 1)
    }

    func test_caseSensitive_distinguishesCases() throws {
        _ = try writeFile("c.txt", "FoO bar\n")
        let opts = CrossFileSearch.Options(caseSensitive: true)
        XCTAssertEqual(
            CrossFileSearch.search(root: tmpRoot, query: "foo", options: opts), [])
        let res = CrossFileSearch.search(root: tmpRoot, query: "FoO", options: opts)
        XCTAssertEqual(res.count, 1)
    }

    // MARK: - Binary file skip

    func test_binaryFile_isSkipped_doesNotCrash() throws {
        let url = tmpRoot.appendingPathComponent("data.bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD, 0x00, 0xAA]).write(to: url)
        let res = CrossFileSearch.search(root: tmpRoot, query: "anything")
        XCTAssertEqual(res, [])
    }
}
