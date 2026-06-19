import XCTest
@testable import ViewerCore

/// TSK-910 — host tests for the per-hunk `AttributedString` builder and the
/// find-run mapper that together enable multi-line selection in the diff
/// viewer (one selectable `Text` per hunk instead of one per line).
///
/// These pin the DATA layer: line classification per run, char-precise line
/// spans, and that find matches map to the correct char ranges with the
/// current-match flag. The render swap to a single `Text` is VM-validated.
final class DiffHunkAttributedStringTests: XCTestCase {

    private typealias K = UnifiedDiff.Line.Kind

    /// A hunk with one context, one removed, one added line.
    private func sampleHunk() -> UnifiedDiff.Hunk {
        UnifiedDiff.Hunk(
            oldStart: 1, oldCount: 2, newStart: 1, newCount: 2,
            header: "func foo()",
            lines: [
                UnifiedDiff.Line(kind: .context, oldLineNo: 1, newLineNo: 1,
                                 content: "let keep = 1"),
                UnifiedDiff.Line(kind: .removed, oldLineNo: 2, newLineNo: nil,
                                 content: "let needle = 2"),
                UnifiedDiff.Line(kind: .added, oldLineNo: nil, newLineNo: 2,
                                 content: "let needle = 3"),
            ])
    }

    // MARK: - Builder: text shape + per-line kind runs

    func test_textShape_prefixesAndNewlineJoin_noTrailingNewline() {
        let built = DiffHunkAttributedString.build(hunk: sampleHunk())
        let s = String(built.attributed.characters)
        XCTAssertEqual(s, " let keep = 1\n-let needle = 2\n+let needle = 3")
        XCTAssertFalse(s.hasSuffix("\n"), "no dangling blank row in the Text")
    }

    func test_textShape_withoutPrefix_dropsGutterChar() {
        let built = DiffHunkAttributedString.build(hunk: sampleHunk(),
                                                   includePrefix: false)
        XCTAssertEqual(String(built.attributed.characters),
                       "let keep = 1\nlet needle = 2\nlet needle = 3")
    }

    func test_eachLineRunCarriesItsKind() {
        let built = DiffHunkAttributedString.build(hunk: sampleHunk())
        var seen: [(String, K)] = []
        for run in built.attributed.runs {
            guard let kind = run[DiffHunkAttributedString.DiffLineKindAttribute.self]
            else { continue }
            let text = String(built.attributed[run.range].characters)
            seen.append((text, kind))
        }
        XCTAssertEqual(seen.map(\.1), [.context, .removed, .added])
        XCTAssertEqual(seen.map(\.0),
                       [" let keep = 1", "-let needle = 2", "+let needle = 3"])
    }

    func test_newlineSeparatorHasNoKindAttribute() {
        let built = DiffHunkAttributedString.build(hunk: sampleHunk())
        // Find a run that is exactly "\n" — it must NOT carry a kind.
        let nlRuns = built.attributed.runs.filter {
            String(built.attributed[$0.range].characters) == "\n"
        }
        XCTAssertFalse(nlRuns.isEmpty)
        for r in nlRuns {
            XCTAssertNil(r[DiffHunkAttributedString.DiffLineKindAttribute.self])
        }
    }

    // MARK: - Builder: line spans (char geometry)

    func test_lineSpans_charOffsetsMatchJoinedString() {
        let built = DiffHunkAttributedString.build(hunk: sampleHunk())
        let spans = built.lineSpans
        XCTAssertEqual(spans.count, 3)

        // " let keep = 1" is 13 chars at offset 0.
        XCTAssertEqual(spans[0], .init(lineIndex: 0, start: 0, length: 13))
        // "\n" separator at 13 → "-let needle = 2" (15 chars) starts at 14.
        XCTAssertEqual(spans[1], .init(lineIndex: 1, start: 14, length: 15))
        // next "\n" at 29 → "+let needle = 3" (15) starts at 30.
        XCTAssertEqual(spans[2], .init(lineIndex: 2, start: 30, length: 15))

        // Each span must slice the joined string back to its line text.
        let chars = Array(built.attributed.characters)
        for s in spans {
            let slice = String(chars[s.start..<s.end])
            XCTAssertFalse(slice.contains("\n"), "span must not include separator")
        }
    }

    func test_singleLineHunk_noSeparator() {
        let hunk = UnifiedDiff.Hunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, header: "",
            lines: [UnifiedDiff.Line(kind: .added, oldLineNo: nil,
                                     newLineNo: 1, content: "only")])
        let built = DiffHunkAttributedString.build(hunk: hunk)
        XCTAssertEqual(String(built.attributed.characters), "+only")
        XCTAssertEqual(built.lineSpans, [.init(lineIndex: 0, start: 0, length: 5)])
    }

    func test_emptyHunk_emptyString() {
        let hunk = UnifiedDiff.Hunk(
            oldStart: 0, oldCount: 0, newStart: 0, newCount: 0,
            header: "", lines: [])
        let built = DiffHunkAttributedString.build(hunk: hunk)
        XCTAssertTrue(built.attributed.characters.isEmpty)
        XCTAssertTrue(built.lineSpans.isEmpty)
    }

    // MARK: - Find-run mapper: char-precise ranges + current flag

    func test_findRuns_mapToMatchedSubstringRanges() {
        let hunk = sampleHunk()
        let built = DiffHunkAttributedString.build(hunk: hunk)
        // "needle" appears on the removed line (1) and the added line (2).
        let matches = [
            DiffFind.Match(file: 0, hunk: 0, line: 1),
            DiffFind.Match(file: 0, hunk: 0, line: 2),
        ]
        let runs = DiffFindRuns.map(
            matches: matches, query: "needle", hunk: hunk,
            fileIndex: 0, hunkIndex: 0, spans: built.lineSpans,
            current: matches[1])

        XCTAssertEqual(runs.count, 2)
        // Verify each run's char range actually slices to "needle"
        // (case-preserving) in the joined string.
        let chars = Array(built.attributed.characters)
        for run in runs {
            let slice = String(chars[run.start..<run.end]).lowercased()
            XCTAssertEqual(slice, "needle")
            XCTAssertEqual(run.length, 6)
        }
        // The current match is line 2; line 1 is not current.
        XCTAssertEqual(runs[0].lineIndex, 1)
        XCTAssertFalse(runs[0].isCurrent)
        XCTAssertEqual(runs[1].lineIndex, 2)
        XCTAssertTrue(runs[1].isCurrent)
    }

    func test_findRuns_accountForPrefixChar() {
        let hunk = sampleHunk()
        let built = DiffHunkAttributedString.build(hunk: hunk)
        // On the removed line "-let needle = 2": with the '-' prefix the
        // word "needle" starts at content offset 4 → +1 for the prefix → 5.
        let m = DiffFind.Match(file: 0, hunk: 0, line: 1)
        let withPrefix = DiffFindRuns.map(
            matches: [m], query: "needle", hunk: hunk,
            fileIndex: 0, hunkIndex: 0, spans: built.lineSpans, current: nil)
        // span[1].start == 14, prefix 1, content offset of "needle" == 4 → 19.
        XCTAssertEqual(withPrefix.first?.start, 14 + 1 + 4)

        let noPrefixBuilt = DiffHunkAttributedString.build(
            hunk: hunk, includePrefix: false)
        let noPrefix = DiffFindRuns.map(
            matches: [m], query: "needle", hunk: hunk,
            fileIndex: 0, hunkIndex: 0, spans: noPrefixBuilt.lineSpans,
            current: nil, includePrefix: false)
        // span[1].start without prefix == 13, content offset 4 → 17.
        XCTAssertEqual(noPrefix.first?.start, 13 + 4)
    }

    func test_findRuns_multipleOccurrencesPerLine() {
        let hunk = UnifiedDiff.Hunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, header: "",
            lines: [UnifiedDiff.Line(kind: .added, oldLineNo: nil,
                                     newLineNo: 1, content: "ab ab ab")])
        let built = DiffHunkAttributedString.build(hunk: hunk)
        let runs = DiffFindRuns.map(
            matches: [DiffFind.Match(file: 0, hunk: 0, line: 0)],
            query: "ab", hunk: hunk, fileIndex: 0, hunkIndex: 0,
            spans: built.lineSpans, current: nil)
        XCTAssertEqual(runs.count, 3, "all three occurrences become runs")
        let chars = Array(built.attributed.characters)
        // "+ab ab ab": prefix '+' at 0, occurrences at 1, 4, 7.
        XCTAssertEqual(runs.map(\.start), [1, 4, 7])
        for run in runs {
            XCTAssertEqual(String(chars[run.start..<run.end]), "ab")
        }
    }

    func test_findRuns_onlyMapsMatchesForThisHunk() {
        let hunk = sampleHunk()
        let built = DiffHunkAttributedString.build(hunk: hunk)
        // A match addressed to a DIFFERENT file/hunk must be ignored.
        let foreign = [
            DiffFind.Match(file: 9, hunk: 9, line: 1),
            DiffFind.Match(file: 0, hunk: 0, line: 1),
        ]
        let runs = DiffFindRuns.map(
            matches: foreign, query: "needle", hunk: hunk,
            fileIndex: 0, hunkIndex: 0, spans: built.lineSpans, current: nil)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.lineIndex, 1)
    }

    func test_findRuns_emptyQuery_noRuns() {
        let hunk = sampleHunk()
        let built = DiffHunkAttributedString.build(hunk: hunk)
        XCTAssertTrue(DiffFindRuns.map(
            matches: [DiffFind.Match(file: 0, hunk: 0, line: 1)],
            query: "  ", hunk: hunk, fileIndex: 0, hunkIndex: 0,
            spans: built.lineSpans, current: nil).isEmpty)
    }

    // MARK: - whole-line fallback

    func test_wholeLineRuns_spanEntireLine() {
        let hunk = sampleHunk()
        let built = DiffHunkAttributedString.build(hunk: hunk)
        let m = DiffFind.Match(file: 0, hunk: 0, line: 1)
        let runs = DiffFindRuns.wholeLineRuns(
            matches: [m], fileIndex: 0, hunkIndex: 0,
            spans: built.lineSpans, current: m)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].start, built.lineSpans[1].start)
        XCTAssertEqual(runs[0].length, built.lineSpans[1].length)
        XCTAssertTrue(runs[0].isCurrent)
    }

    // MARK: - parity with the real parser

    func test_parsedHunk_buildsSelectableStringAndFindRuns() {
        let files = RustDiffAdapter.parse("""
        diff --git a/alpha.swift b/alpha.swift
        --- a/alpha.swift
        +++ b/alpha.swift
        @@ -1,3 +1,3 @@
         let keep = 1
        -let needle = 2
        +let needle = 3
        """)
        guard let hunk = files.first?.hunks.first else {
            return XCTFail("parser produced no hunk")
        }
        let built = DiffHunkAttributedString.build(hunk: hunk)
        // Selection-capable text spans all three lines in one string.
        XCTAssertEqual(String(built.attributed.characters).split(separator: "\n").count, 3)

        let matches = DiffFind.matches(in: files, query: "needle")
        let runs = DiffFindRuns.map(
            matches: matches, query: "needle", hunk: hunk,
            fileIndex: 0, hunkIndex: 0, spans: built.lineSpans,
            current: matches.first)
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs.first?.isCurrent ?? false)
    }
}
