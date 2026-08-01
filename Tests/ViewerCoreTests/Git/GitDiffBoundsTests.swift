import Testing
import Foundation
@testable import ViewerCore

/// I-02 (owner intake 2026-08-01) — `GitDiffBounds`: commit/cumulative/status
/// diff bodies are bounded before they reach the `.diff` file and the web
/// renderer. Truncation is whole-line, explicit (notice line), and never fires
/// under the caps.
struct GitDiffBoundsTests {

    @Test func underBothCaps_passesThroughUntouched() {
        let body = "diff --git a/f b/f\n+one\n+two\n"
        let r = GitDiffBounds.bound(body, maxBytes: 1024, maxLines: 100)
        #expect(r.text == body)
        #expect(!r.truncated)
        #expect(r.originalBytes == body.utf8.count)
    }

    @Test func byteCap_cutsAtALineBoundary_withNotice() {
        // 30 lines of 10 bytes each; cap at 105 bytes → whole-line prefix.
        let body = (1...30).map { String(format: "line-%04d", $0) }.joined(separator: "\n")
        let r = GitDiffBounds.bound(body, maxBytes: 105, maxLines: 1000)
        #expect(r.truncated)
        #expect(r.text.hasPrefix("⚠ DIFF TRUNCATED"))
        // Every retained content line is COMPLETE (no mid-line cut).
        let content = r.text.split(separator: "\n").dropFirst().filter { !$0.isEmpty }
        for line in content {
            #expect(line.hasPrefix("line-"), "unexpected fragment: \(line)")
            #expect(line.count == 9, "cut mid-line: \(line)")
        }
        #expect(r.originalBytes == body.utf8.count)
    }

    @Test func lineCap_firesEvenWhenBytesFit() {
        let body = (1...50).map { "l\($0)" }.joined(separator: "\n") + "\n"
        let r = GitDiffBounds.bound(body, maxBytes: 1_000_000, maxLines: 10)
        #expect(r.truncated)
        // 10 content lines survive (plus the notice + blank separator).
        let content = r.text.split(separator: "\n").dropFirst().filter { !$0.isEmpty }
        #expect(content.count == 10)
    }

    @Test func commandHint_landsInTheNotice() {
        let body = (1...50).map { _ in "x" }.joined(separator: "\n")
        let r = GitDiffBounds.bound(
            body, maxBytes: 10, maxLines: 5, commandHint: "git show abc1234")
        #expect(r.truncated)
        #expect(r.text.contains("git show abc1234"))
    }

    @Test func oneGiantLine_stillCutsUnderTheByteCap() {
        let body = String(repeating: "a", count: 100_000)   // no newline at all
        let r = GitDiffBounds.bound(body, maxBytes: 1024, maxLines: 1000)
        #expect(r.truncated)
        #expect(r.text.utf8.count < 2048, "cut must land near the cap")
        #expect(r.originalBytes == 100_000)
    }

    @Test func exactlyAtTheByteCap_isNotTruncated() {
        let body = "abcd\nefgh\n"   // 10 bytes
        let r = GitDiffBounds.bound(body, maxBytes: 10, maxLines: 100)
        #expect(!r.truncated)
        #expect(r.text == body)
    }
}
