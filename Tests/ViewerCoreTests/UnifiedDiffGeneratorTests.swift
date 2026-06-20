import XCTest
@testable import ViewerCore

/// Teeth for `UnifiedDiffGenerator` (TSK-1103) — the string→unified-diff-text
/// generator that lets the Local-History side feed the SAME renderer git does.
///
/// The load-bearing guarantee is the ROUND-TRIP: text we generate must parse
/// back (via the real `RustDiffAdapter`/rust-core parser the renderer uses) into
/// a structure that reconstructs the new file. If the dialect drifts, the
/// renderer would show garbage — so these assert against the actual parser, not
/// a re-implementation.
final class UnifiedDiffGeneratorTests: XCTestCase {

    // MARK: - Round-trip: generate → parse → reconstruct

    /// Reconstruct the NEW file from a parsed unified diff: walk every hunk and
    /// apply added/context lines (in new-line order). For a diff with full
    /// context this reproduces the whole file; for a context-trimmed diff it
    /// reproduces the changed regions — so we test with a large context so the
    /// whole file is covered, making the reconstruction exact.
    private func reconstructNew(from files: [UnifiedDiff.File]) -> [String] {
        var out: [String] = []
        for file in files {
            for hunk in file.hunks {
                for line in hunk.lines {
                    switch line.kind {
                    case .added, .context:
                        out.append(line.content)
                    case .removed, .noNewline:
                        break
                    }
                }
            }
        }
        // The unified-diff parser (shared with git output) splits on "\n" keeping
        // the empty subsequence after the final newline, which surfaces as a
        // trailing empty CONTEXT line. That's the parser's faithful encoding of
        // "the diff text ended in \n", NOT a phantom line of the file — drop one
        // trailing "" so the reconstruction equals the file's logical lines.
        if out.last == "" { out.removeLast() }
        return out
    }

    /// With context large enough to cover the file, generate→parse→reconstruct
    /// must reproduce the new file's lines exactly.
    private func assertRoundTrip(old: String, new: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = UnifiedDiffGenerator.generate(old: old, new: new, path: "f.txt", context: 100_000)
        if old == new {
            XCTAssertEqual(text, "", "identical inputs must yield empty diff", file: file, line: line)
            return
        }
        let parsed = RustDiffAdapter.parse(text)
        XCTAssertFalse(parsed.isEmpty, "generated diff must parse to ≥1 file", file: file, line: line)
        let expected = UnifiedDiffGenerator.splitLines(new).lines
        XCTAssertEqual(reconstructNew(from: parsed), expected,
                       "reconstructed new file must equal the input new file", file: file, line: line)
    }

    func test_roundTrip_pureAdd() {
        assertRoundTrip(old: "a\nb\n", new: "a\nb\nc\nd\n")
    }

    func test_roundTrip_pureDelete() {
        assertRoundTrip(old: "a\nb\nc\nd\n", new: "a\nd\n")
    }

    func test_roundTrip_modify() {
        assertRoundTrip(old: "one\ntwo\nthree\n", new: "one\nTWO\nthree\n")
    }

    func test_roundTrip_fromEmpty() {
        assertRoundTrip(old: "", new: "hello\nworld\n")
    }

    func test_roundTrip_toEmpty() {
        assertRoundTrip(old: "hello\nworld\n", new: "")
    }

    func test_roundTrip_noTrailingNewline() {
        assertRoundTrip(old: "a\nb", new: "a\nB")
    }

    func test_roundTrip_interleavedChanges() {
        let old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"
        let new = "1\n2\nXXX\n4\n5\n6\nYYY\n8\n9\nZZZ\n"
        assertRoundTrip(old: old, new: new)
    }

    // MARK: - Identity / empty

    func test_identical_yieldsEmpty() {
        XCTAssertEqual(UnifiedDiffGenerator.generate(old: "same\n", new: "same\n", path: "x"), "")
    }

    func test_bothEmpty_yieldsEmpty() {
        XCTAssertEqual(UnifiedDiffGenerator.generate(old: "", new: "", path: "x"), "")
    }

    // MARK: - Dialect specifics (the renderer relies on these)

    func test_emitsGitFileHeaderAndPaths() {
        let text = UnifiedDiffGenerator.generate(old: "a\n", new: "b\n", path: "notes.md")
        XCTAssertTrue(text.contains("diff --git a/notes.md b/notes.md"), text)
        XCTAssertTrue(text.contains("--- a/notes.md"), text)
        XCTAssertTrue(text.contains("+++ b/notes.md"), text)
    }

    func test_addedAndRemovedLinesHaveCorrectPrefixes() {
        let text = UnifiedDiffGenerator.generate(old: "keep\nold\n", new: "keep\nnew\n", path: "x", context: 100)
        XCTAssertTrue(text.contains("\n-old"), text)
        XCTAssertTrue(text.contains("\n+new"), text)
        XCTAssertTrue(text.contains("\n keep"), text)   // context line, space prefix
    }

    func test_noNewlineMarkerEmittedForNoTrailingNewline() {
        // old ends WITHOUT newline → the removed line gets the marker.
        let text = UnifiedDiffGenerator.generate(old: "a\nb", new: "a\nc\n", path: "x", context: 100)
        XCTAssertTrue(text.contains("\\ No newline at end of file"), text)
    }

    // MARK: - Hunk grouping

    func test_separateChanges_yieldSeparateHunks_whenFarApart() {
        // Two changes 20 lines apart with context 3 → two hunks.
        var oldLines: [String] = (1...40).map { "line\($0)" }
        var newLines = oldLines
        newLines[2] = "CHANGED_A"
        newLines[30] = "CHANGED_B"
        let old = oldLines.joined(separator: "\n") + "\n"
        let new = newLines.joined(separator: "\n") + "\n"
        let text = UnifiedDiffGenerator.generate(old: old, new: new, path: "x", context: 3)
        let hunkHeaders = text.split(separator: "\n").filter { $0.hasPrefix("@@") }
        XCTAssertEqual(hunkHeaders.count, 2, "two far-apart changes → two hunks:\n\(text)")
        _ = (oldLines, newLines)
    }

    func test_adjacentChanges_mergeIntoOneHunk() {
        var oldLines: [String] = (1...20).map { "line\($0)" }
        var newLines = oldLines
        newLines[5] = "A"
        newLines[6] = "B"   // adjacent → one hunk
        let old = oldLines.joined(separator: "\n") + "\n"
        let new = newLines.joined(separator: "\n") + "\n"
        let text = UnifiedDiffGenerator.generate(old: old, new: new, path: "x", context: 3)
        let hunkHeaders = text.split(separator: "\n").filter { $0.hasPrefix("@@") }
        XCTAssertEqual(hunkHeaders.count, 1, "adjacent changes → one hunk:\n\(text)")
        _ = (oldLines, newLines)
    }

    // MARK: - splitLines semantics

    func test_splitLines_trailingNewlineDoesNotAddPhantomLine() {
        let r = UnifiedDiffGenerator.splitLines("a\nb\n")
        XCTAssertEqual(r.lines, ["a", "b"])
        XCTAssertFalse(r.lastLineHasNoNewline)
    }

    func test_splitLines_noTrailingNewlineFlagged() {
        let r = UnifiedDiffGenerator.splitLines("a\nb")
        XCTAssertEqual(r.lines, ["a", "b"])
        XCTAssertTrue(r.lastLineHasNoNewline)
    }

    func test_splitLines_emptyString() {
        let r = UnifiedDiffGenerator.splitLines("")
        XCTAssertEqual(r.lines, [])
        XCTAssertFalse(r.lastLineHasNoNewline)
    }
}
