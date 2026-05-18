import XCTest
@testable import ViewerCore

/// Unit tests for the sweep-line `paintOver` overlap resolution.
/// Validates "later run wins" semantic, contiguous-same-kind coalescing,
/// and clipping against `textCount`. Pinned in a separate file from
/// the engine smoke tests because the algorithm is correctness-critical
/// (silently wrong coloring = bug class that doesn't show in goldens).
final class TreeSitterPaintOverTests: XCTestCase {

    private func run(_ loc: Int, _ len: Int, _ kind: TokenKind) -> HighlightRun {
        HighlightRun(range: NSRange(location: loc, length: len), kind: kind)
    }

    func test_disjointRuns_passThrough() {
        let input = [run(0, 5, .keyword), run(10, 3, .string)]
        let out = TreeSitterEngine.paintOver(runs: input, textCount: 100)
        XCTAssertEqual(out, input)
    }

    func test_zeroLengthInput_returnsEmpty() {
        XCTAssertEqual(TreeSitterEngine.paintOver(runs: [], textCount: 10), [])
    }

    func test_zeroTextCount_returnsEmpty() {
        let input = [run(0, 5, .keyword)]
        XCTAssertEqual(TreeSitterEngine.paintOver(runs: input, textCount: 0), [])
    }

    func test_laterRunOverridesEarlier_fullCover() {
        // Two runs, identical range — second (later index) wins.
        let input = [run(0, 5, .keyword), run(0, 5, .string)]
        let out = TreeSitterEngine.paintOver(runs: input, textCount: 100)
        XCTAssertEqual(out, [run(0, 5, .string)])
    }

    func test_laterRun_nestedInsideEarlier_splitsAroundIt() {
        // Earlier: [0,10) function. Later: [3,7) keyword.
        // Expected: [0,3) function, [3,7) keyword, [7,10) function.
        let input = [run(0, 10, .function), run(3, 4, .keyword)]
        let out = TreeSitterEngine.paintOver(runs: input, textCount: 100)
        XCTAssertEqual(out, [
            run(0, 3, .function),
            run(3, 4, .keyword),
            run(7, 3, .function)
        ])
    }

    func test_partialOverlap_laterWinsOnOverlapRegion() {
        // Earlier: [0,5) keyword. Later: [3,8) string.
        // Expected: [0,3) keyword, [3,8) string.
        let input = [run(0, 5, .keyword), run(3, 5, .string)]
        let out = TreeSitterEngine.paintOver(runs: input, textCount: 100)
        XCTAssertEqual(out, [
            run(0, 3, .keyword),
            run(3, 5, .string)
        ])
    }

    func test_adjacentSameKindRuns_coalesce() {
        // [0,5) keyword + [5,10) keyword should emit ONE run [0,10).
        let input = [run(0, 5, .keyword), run(5, 5, .keyword)]
        let out = TreeSitterEngine.paintOver(runs: input, textCount: 100)
        XCTAssertEqual(out, [run(0, 10, .keyword)])
    }

    func test_adjacentDifferentKindRuns_doNotCoalesce() {
        let input = [run(0, 5, .keyword), run(5, 5, .string)]
        let out = TreeSitterEngine.paintOver(runs: input, textCount: 100)
        XCTAssertEqual(out, [run(0, 5, .keyword), run(5, 5, .string)])
    }

    func test_runExceedingTextCount_isClipped() {
        // textCount=8, run spans [5,15). Clip to [5,8).
        let input = [run(5, 10, .number)]
        let out = TreeSitterEngine.paintOver(runs: input, textCount: 8)
        XCTAssertEqual(out, [run(5, 3, .number)])
    }

    func test_negativeLocation_isClampedToZero() {
        let input = [HighlightRun(range: NSRange(location: -2, length: 5), kind: .number)]
        let out = TreeSitterEngine.paintOver(runs: input, textCount: 100)
        XCTAssertEqual(out, [run(0, 3, .number)])
    }

    func test_threeNestedLayers_lastWinsAtEachPosition() {
        // [0,20) base, [5,15) middle, [8,12) top
        // 0-5: base, 5-8: middle, 8-12: top, 12-15: middle, 15-20: base
        let input = [
            run(0, 20, .function),
            run(5, 10, .type),
            run(8,  4, .keyword)
        ]
        let out = TreeSitterEngine.paintOver(runs: input, textCount: 100)
        XCTAssertEqual(out, [
            run(0,  5, .function),
            run(5,  3, .type),
            run(8,  4, .keyword),
            run(12, 3, .type),
            run(15, 5, .function)
        ])
    }

    /// Differential check: handcrafted overlap-heavy input should give
    /// the same result as the obvious-but-slow per-character canvas
    /// implementation. Pins behavioral parity with the original
    /// algorithm we replaced.
    func test_matchesReferenceCanvasImplementation_onRandomOverlap() {
        var rng = SystemRandomNumberGenerator()
        let kinds: [TokenKind] = [.keyword, .string, .comment, .number, .function]
        for _ in 0..<25 {
            let textCount = 200
            var runs: [HighlightRun] = []
            for _ in 0..<30 {
                let loc = Int.random(in: 0..<textCount, using: &rng)
                let len = Int.random(in: 1...30, using: &rng)
                let kind = kinds.randomElement(using: &rng)!
                runs.append(HighlightRun(range: NSRange(location: loc, length: len), kind: kind))
            }
            let sweep = TreeSitterEngine.paintOver(runs: runs, textCount: textCount)
            let canvas = referenceCanvas(runs: runs, textCount: textCount)
            XCTAssertEqual(sweep, canvas, "sweep diverged from canvas reference on input \(runs)")
        }
    }

    /// Reference implementation — the per-character canvas we deleted.
    /// Inlined here as the test oracle.
    private func referenceCanvas(runs: [HighlightRun], textCount: Int) -> [HighlightRun] {
        guard !runs.isEmpty, textCount > 0 else { return [] }
        var canvas = [TokenKind?](repeating: nil, count: textCount)
        for r in runs {
            let lo = max(0, r.range.location)
            let hi = min(textCount, r.range.location + r.range.length)
            guard lo < hi else { continue }
            for i in lo..<hi { canvas[i] = r.kind }
        }
        var out: [HighlightRun] = []
        var i = 0
        while i < textCount {
            guard let kind = canvas[i] else { i += 1; continue }
            var j = i + 1
            while j < textCount, canvas[j] == kind { j += 1 }
            out.append(HighlightRun(range: NSRange(location: i, length: j - i), kind: kind))
            i = j
        }
        return out
    }
}
