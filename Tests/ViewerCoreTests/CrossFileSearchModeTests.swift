import XCTest
@testable import ViewerCore

/// TSK-758 — the two new cross-file search modes: filename search and regex
/// matching (with ReDoS validation). Pure ViewerCore over a temp fixture tree;
/// host-safe.
final class CrossFileSearchModeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossSearchMode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("hello foo123 world\nsecond line\n", "alpha.txt")
        try write("# Beta\nnothing here\n", "Beta.md")
        try write("foo999\n", "gamma.log")
        try makeDir("sub")
        try write("let x = 1\n", "sub/alpha_two.swift")
        // A skip-listed dir whose file name would otherwise match "alpha"/"skip".
        try makeDir("node_modules")
        try write("alpha\n", "node_modules/skip.js")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ contents: String, _ rel: String) throws {
        try contents.write(to: root.appendingPathComponent(rel), atomically: true, encoding: .utf8)
    }
    private func makeDir(_ rel: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
    }
    private func names(_ r: [CrossFileSearch.FileMatches]) -> Set<String> {
        Set(r.map { $0.url.lastPathComponent })
    }

    // MARK: Filename search

    func test_searchFilenames_caseInsensitiveByDefault_acrossSubdirs() {
        let r = CrossFileSearch.searchFilenames(root: root, query: "alpha")
        XCTAssertEqual(names(r), ["alpha.txt", "alpha_two.swift"],
                       "matches both files whose NAME contains 'alpha', recursing into sub/")
        // Filename hits carry no line matches — the file itself is the result.
        XCTAssertTrue(r.allSatisfy { $0.matches.isEmpty })
    }

    func test_searchFilenames_skipsBuildAndVCSDirs() {
        // node_modules/skip.js must NOT surface for "skip".
        XCTAssertTrue(CrossFileSearch.searchFilenames(root: root, query: "skip").isEmpty,
                      "files inside skipDirNames dirs are not walked")
    }

    func test_searchFilenames_caseSensitiveOption() {
        var opts = CrossFileSearch.Options(); opts.caseSensitive = true
        XCTAssertTrue(CrossFileSearch.searchFilenames(root: root, query: "Alpha", options: opts).isEmpty,
                      "case-sensitive 'Alpha' matches no lowercase 'alpha*' file")
        XCTAssertEqual(names(CrossFileSearch.searchFilenames(root: root, query: "Beta", options: opts)),
                       ["Beta.md"])
    }

    func test_searchFilenames_noMatch_isEmpty() {
        XCTAssertTrue(CrossFileSearch.searchFilenames(root: root, query: "zzznope").isEmpty)
    }

    func test_searchFilenames_emptyQuery_isEmpty() {
        XCTAssertTrue(CrossFileSearch.searchFilenames(root: root, query: "").isEmpty)
    }

    // MARK: Regex content search

    func test_regexContentSearch_matchesAcrossFiles() {
        var opts = CrossFileSearch.Options(); opts.useRegex = true
        let r = CrossFileSearch.search(root: root, query: #"foo\d+"#, options: opts)
        XCTAssertEqual(names(r), ["alpha.txt", "gamma.log"],
                       "the \\d+ regex matches foo123 and foo999, not the plain Beta heading")
        // The matched line + range are populated.
        if let alpha = r.first(where: { $0.url.lastPathComponent == "alpha.txt" }) {
            XCTAssertEqual(alpha.matches.first?.lineNumber, 1)
            XCTAssertEqual(alpha.matches.first?.line, "hello foo123 world")
            XCTAssertNotNil(alpha.matches.first?.matchRange)
        } else { XCTFail("alpha.txt should match foo\\d+") }
    }

    func test_regexContentSearch_anchors() {
        var opts = CrossFileSearch.Options(); opts.useRegex = true
        let r = CrossFileSearch.search(root: root, query: #"^# Beta"#, options: opts)
        XCTAssertEqual(names(r), ["Beta.md"], "^-anchored regex matches the Beta heading line")
    }

    func test_regexContentSearch_caseSensitivity() {
        var ci = CrossFileSearch.Options(); ci.useRegex = true; ci.caseSensitive = false
        XCTAssertEqual(names(CrossFileSearch.search(root: root, query: #"FOO\d+"#, options: ci)),
                       ["alpha.txt", "gamma.log"], "case-insensitive regex matches lowercase foo")
        var cs = CrossFileSearch.Options(); cs.useRegex = true; cs.caseSensitive = true
        XCTAssertTrue(CrossFileSearch.search(root: root, query: #"FOO\d+"#, options: cs).isEmpty,
                      "case-sensitive FOO does not match lowercase foo")
    }

    func test_regexFilenameSearch() {
        var opts = CrossFileSearch.Options(); opts.useRegex = true
        let r = CrossFileSearch.searchFilenames(root: root, query: #"^alpha.*\.txt$"#, options: opts)
        XCTAssertEqual(names(r), ["alpha.txt"],
                       "anchored filename regex matches alpha.txt only (not alpha_two.swift)")
    }

    // MARK: Regex validation / rejection

    func test_validateRegex_rejectsReDoSAndInvalid_acceptsNormal() {
        XCTAssertNotNil(CrossFileSearch.validateRegex("(a+)+"), "nested quantifier is ReDoS-rejected")
        XCTAssertNotNil(CrossFileSearch.validateRegex("(unclosed"), "uncompilable pattern rejected")
        XCTAssertNil(CrossFileSearch.validateRegex(#"foo\d+"#), "an ordinary pattern is accepted")
        XCTAssertNil(CrossFileSearch.validateRegex(""), "empty is handled upstream, not an error")
    }

    func test_rejectedRegex_yieldsNoResults() {
        var opts = CrossFileSearch.Options(); opts.useRegex = true
        XCTAssertTrue(CrossFileSearch.search(root: root, query: "(a+)+", options: opts).isEmpty,
                      "a rejected regex produces no matches (matcher is nil)")
        XCTAssertTrue(CrossFileSearch.searchFilenames(root: root, query: "(a+)+", options: opts).isEmpty)
    }

    // MARK: Literal path unchanged (regression guard)

    func test_literalSearch_unchanged() {
        // Default options = literal substring, the pre-TSK-758 behavior.
        let r = CrossFileSearch.search(root: root, query: "foo123")
        XCTAssertEqual(names(r), ["alpha.txt"])
        // A regex metacharacter is treated LITERALLY when useRegex is off.
        XCTAssertTrue(CrossFileSearch.search(root: root, query: #"foo\d+"#).isEmpty,
                      "literal mode does not interpret \\d+")
    }
}
