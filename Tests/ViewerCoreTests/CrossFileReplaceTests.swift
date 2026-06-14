import XCTest
@testable import ViewerCore

/// TSK-726 — host coverage for project-wide find-and-replace. Splits into the
/// PURE core (`replacedText` — no I/O, exhaustively tested) and the
/// side-effecting `apply` (temp files only; never touches ~/Documents). The
/// engine reuses `EditorWriter.save` so it inherits atomic-rename, symlink
/// refusal, and metadata preservation; the relevant cases are pinned here too.
final class CrossFileReplaceTests: XCTestCase {

    private var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossFileReplace-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func write(_ name: String, _ contents: String,
                       encoding: String.Encoding = .utf8) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.data(using: encoding)!.write(to: url)
        return url
    }

    private func read(_ url: URL, encoding: String.Encoding = .utf8) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return String(data: d, encoding: encoding)
    }

    // MARK: - replacedText (pure)

    func test_literal_replacesAllOccurrences_caseSensitiveDefault() {
        let (out, n) = CrossFileReplace.replacedText(
            in: "foo Foo foo", query: "foo", replacement: "bar",
            caseSensitive: true, useRegex: false)!
        XCTAssertEqual(out, "bar Foo bar")   // "Foo" untouched (case-sensitive)
        XCTAssertEqual(n, 2)
    }

    func test_literal_caseInsensitive_replacesMixedCase() {
        let (out, n) = CrossFileReplace.replacedText(
            in: "foo Foo FOO", query: "foo", replacement: "x",
            caseSensitive: false, useRegex: false)!
        XCTAssertEqual(out, "x x x")
        XCTAssertEqual(n, 3)
    }

    func test_literal_noMatch_returnsZeroCount_sameText() {
        let (out, n) = CrossFileReplace.replacedText(
            in: "hello world", query: "zzz", replacement: "x",
            caseSensitive: false, useRegex: false)!
        XCTAssertEqual(out, "hello world")
        XCTAssertEqual(n, 0)
    }

    func test_emptyQuery_returnsNil() {
        XCTAssertNil(CrossFileReplace.replacedText(
            in: "abc", query: "", replacement: "x",
            caseSensitive: false, useRegex: false))
    }

    func test_regex_captureGroupTemplate() {
        // Swap `key=value` → `value=key` via capture groups.
        let (out, n) = CrossFileReplace.replacedText(
            in: "a=1\nb=2", query: #"(\w+)=(\w+)"#, replacement: "$2=$1",
            caseSensitive: true, useRegex: true)!
        XCTAssertEqual(out, "1=a\n2=b")
        XCTAssertEqual(n, 2)
    }

    func test_regex_anchorsMatchLines_perLineCarets() {
        // `^foo` with .anchorsMatchLines must hit the start of EACH line, the
        // same per-line semantics CrossFileSearch uses — not just the first.
        let (out, n) = CrossFileReplace.replacedText(
            in: "foo\nfoo\nxfoo", query: "^foo", replacement: "BAR",
            caseSensitive: true, useRegex: true)!
        XCTAssertEqual(out, "BAR\nBAR\nxfoo")  // line 3 not anchored
        XCTAssertEqual(n, 2)
    }

    func test_regex_invalidPattern_returnsNil() {
        XCTAssertNil(CrossFileReplace.replacedText(
            in: "abc", query: "(", replacement: "x",
            caseSensitive: false, useRegex: true),
            "an uncompilable regex yields nil (no replacement possible)")
    }

    func test_countOccurrences_nonOverlapping() {
        XCTAssertEqual(
            CrossFileReplace.countOccurrences(of: "aa", in: "aaaa", caseSensitive: true),
            2, "non-overlapping, matching what replacingOccurrences replaces")
    }

    // MARK: - apply (disk)

    func test_apply_replacesAcrossMultipleFiles_andCounts() throws {
        let a = try write("a.txt", "foo and foo")
        let b = try write("b.txt", "foo once")
        let c = try write("c.txt", "no match here")
        let outcomes = CrossFileReplace.apply(
            toFiles: [a, b, c], query: "foo", replacement: "bar",
            caseSensitive: true, useRegex: false)
        XCTAssertEqual(read(a), "bar and bar")
        XCTAssertEqual(read(b), "bar once")
        XCTAssertEqual(read(c), "no match here", "untouched file stays byte-identical")

        let summary = CrossFileReplace.Summary(outcomes: outcomes)
        XCTAssertEqual(summary.totalReplacements, 3)
        XCTAssertEqual(summary.filesChanged, 2, "the no-match file isn't counted/rewritten")
        XCTAssertTrue(summary.failures.isEmpty)
    }

    func test_apply_skipsNoMatchFile_noRewrite() throws {
        let c = try write("c.txt", "untouched")
        let mtimeBefore = try FileManager.default
            .attributesOfItem(atPath: c.path)[.modificationDate] as? Date
        let outcomes = CrossFileReplace.apply(
            toFiles: [c], query: "absent", replacement: "x",
            caseSensitive: false, useRegex: false)
        XCTAssertTrue(outcomes.isEmpty, "a file with no matches yields no outcome (skipped)")
        let mtimeAfter = try FileManager.default
            .attributesOfItem(atPath: c.path)[.modificationDate] as? Date
        XCTAssertEqual(mtimeBefore, mtimeAfter, "no rewrite ⇒ mtime unchanged")
    }

    func test_apply_preservesLatin1Encoding() throws {
        // A CP1252/Latin-1 file with a non-ASCII byte must stay decodable in
        // its original encoding after the replace (not get mangled to UTF-8).
        let url = try write("latin.txt", "café foo café", encoding: .isoLatin1)
        let outcomes = CrossFileReplace.apply(
            toFiles: [url], query: "foo", replacement: "bar",
            caseSensitive: true, useRegex: false)
        XCTAssertEqual(outcomes.first?.replacements, 1)
        XCTAssertEqual(read(url, encoding: .isoLatin1), "café bar café",
                       "the file stays Latin-1; the é byte is preserved")
        // And it must NOT accidentally be valid UTF-8 (0xE9 alone is invalid UTF-8).
        let raw = try Data(contentsOf: url)
        XCTAssertNil(String(data: raw, encoding: .utf8),
                     "a Latin-1 é (0xE9) is not valid UTF-8 — encoding was preserved")
    }

    func test_apply_skipsBinaryFile_reportsFailure() throws {
        let bin = dir.appendingPathComponent("b.bin")
        try Data([0x00, 0x01, 0x66, 0x6F, 0x6F, 0x00]).write(to: bin)  // NUL-laden
        let outcomes = CrossFileReplace.apply(
            toFiles: [bin], query: "foo", replacement: "bar",
            caseSensitive: true, useRegex: false)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].succeeded)
        XCTAssertEqual(outcomes[0].error, "binary or undecodable")
    }

    func test_apply_skipsOversizedFile() throws {
        let big = try write("big.txt", "foo")
        let outcomes = CrossFileReplace.apply(
            toFiles: [big], query: "foo", replacement: "bar",
            caseSensitive: true, useRegex: false, maxFileBytes: 1)  // cap below size
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].succeeded)
        XCTAssertEqual(read(big), "foo", "an oversized file is left untouched")
    }

    func test_apply_refusesToWriteThroughSymlink() throws {
        let target = try write("real.txt", "foo")
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let outcomes = CrossFileReplace.apply(
            toFiles: [link], query: "foo", replacement: "bar",
            caseSensitive: true, useRegex: false)  // allowSymlink defaults false
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].succeeded, "must refuse to de-symlink")
        XCTAssertEqual(read(target), "foo", "the symlink target is untouched")
    }

    func test_apply_unreadableMissingFile_reportsFailure() {
        let missing = dir.appendingPathComponent("nope.txt")
        let outcomes = CrossFileReplace.apply(
            toFiles: [missing], query: "foo", replacement: "bar",
            caseSensitive: false, useRegex: false)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].succeeded)
    }

    func test_apply_regexAcrossFiles_withGroups() throws {
        let a = try write("a.swift", "let x = 1")
        let outcomes = CrossFileReplace.apply(
            toFiles: [a], query: #"let (\w+) = (\d+)"#, replacement: "var $1 = $2",
            caseSensitive: true, useRegex: true)
        XCTAssertEqual(outcomes.first?.replacements, 1)
        XCTAssertEqual(read(a), "var x = 1")
    }

    // MARK: - Summary

    func test_summary_aggregatesAndSeparatesFailures() {
        let ok1 = CrossFileReplace.FileOutcome(url: dir.appendingPathComponent("a"),
                                               replacements: 3, error: nil)
        let ok2 = CrossFileReplace.FileOutcome(url: dir.appendingPathComponent("b"),
                                               replacements: 2, error: nil)
        let fail = CrossFileReplace.FileOutcome(url: dir.appendingPathComponent("c"),
                                                replacements: 0, error: "boom")
        let s = CrossFileReplace.Summary(outcomes: [ok1, ok2, fail])
        XCTAssertEqual(s.totalReplacements, 5)
        XCTAssertEqual(s.filesChanged, 2)
        XCTAssertEqual(s.failures.count, 1)
    }
}
