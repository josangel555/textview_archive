import XCTest
@testable import RustCore
import ViewerCore

/// A/B parity: the Rust core's `mdvcore_diff_hunk_marks` (via
/// `mdvCoreDiffHunkMarks`) vs the SHIPPING Swift `DiffHunkParser.parse`, over a
/// corpus exercising add / modify (`-`then`+`) / delete-tick placement, the
/// `+++` metadata trap, multi-hunk offset tracking, and empty input. The
/// `line → mark` maps must be identical. Forces the Rust path directly (no gate).
final class DiffHunkMarksABTests: XCTestCase {

    /// Map the RustCore wire enum to the ViewerCore model for comparison.
    private func toDM(_ d: [Int: DiffHunkMark]) -> [Int: DiffMark] {
        d.mapValues {
            switch $0 {
            case .added: return .added
            case .modified: return .modified
            case .deleted: return .deleted
            }
        }
    }

    private func corpus() -> [String] {
        [
            "",
            // modify (─then+), pure add, delete-at-end
            "diff --git a/f b/f\n@@ -1,3 +1,4 @@\n ctx\n-old\n+new\n+fresh\n-gone\n",
            // metadata incl. +++ (must not be read as an added line)
            "diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n",
            // new file — all additions
            "diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1,2 @@\n+x\n+y\n",
            // deleted file — deletions land as a tick
            "diff --git a/g b/g\ndeleted file mode 100644\n--- a/g\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n",
            // multi-hunk: offsets tracked across both
            "diff --git a/f b/f\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n@@ -10,2 +10,3 @@\n j\n+k\n l\n",
            // multi-file
            "diff --git a/a b/a\n@@ -1 +1 @@\n-x\n+y\ndiff --git a/b b/b\n@@ -5 +5,2 @@\n m\n+n\n",
            // context-only hunk → no marks
            "diff --git a/f b/f\n@@ -1,2 +1,2 @@\n one\n two\n",
            // pure insertion block
            "diff --git a/f b/f\n@@ -1,1 +1,4 @@\n keep\n+a\n+b\n+c\n",
        ]
    }

    func test_rust_matches_swift_across_corpus() throws {
        for diff in corpus() {
            let swift = DiffHunkParser.parse(diff)
            let rust = toDM(try mdvCoreDiffHunkMarks(text: diff))
            XCTAssertEqual(rust, swift, "parity mismatch for diff:\n\(diff)")
        }
    }

    func test_gate_off_uses_swift_and_matches() {
        let diff = "diff --git a/f b/f\n@@ -1 +1 @@\n-a\n+b\n"
        let o = RustDiffAdapter.hunkMarksOutcome(diff)
        XCTAssertEqual(o.source, .swiftBecauseGateOff)
        XCTAssertEqual(o.value, DiffHunkParser.parse(diff))
    }
}
