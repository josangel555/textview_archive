import XCTest
@testable import RustCore
import ViewerCore

/// GOLDEN suite for the Rust core's `mdvcore_diff_hunk_marks` (via
/// `mdvCoreDiffHunkMarks`, mapped to the `DiffMark` model). Was an A/B parity
/// suite against the Swift `DiffHunkParser`; that twin was DELETED in TSK-649
/// Stage B #4, so the expected `line → mark` maps are now FROZEN snapshots of the
/// (already parity-proven) Rust output — covering add / modify (`-`then`+`) /
/// delete-tick placement, the `+++` metadata trap, and multi-hunk offset tracking.
final class DiffHunkMarksABTests: XCTestCase {

    private func toDM(_ d: [Int: DiffHunkMark]) -> [Int: DiffMark] {
        d.mapValues {
            switch $0 {
            case .added: return .added
            case .modified: return .modified
            case .deleted: return .deleted
            }
        }
    }

    /// Compact single-line snapshot: `line:mark` pairs, sorted by line.
    private func snap(_ m: [Int: DiffMark]) -> String {
        m.keys.sorted().map { k -> String in
            let v: String
            switch m[k]! { case .added: v = "+"; case .modified: v = "~"; case .deleted: v = "-" }
            return "\(k):\(v)"
        }.joined(separator: ",")
    }

    private func corpus() -> [String] {
        [
            "",
            "diff --git a/f b/f\n@@ -1,3 +1,4 @@\n ctx\n-old\n+new\n+fresh\n-gone\n",
            "diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n",
            "diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1,2 @@\n+x\n+y\n",
            "diff --git a/g b/g\ndeleted file mode 100644\n--- a/g\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n",
            "diff --git a/f b/f\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n@@ -10,2 +10,3 @@\n j\n+k\n l\n",
            "diff --git a/a b/a\n@@ -1 +1 @@\n-x\n+y\ndiff --git a/b b/b\n@@ -5 +5,2 @@\n m\n+n\n",
            "diff --git a/f b/f\n@@ -1,2 +1,2 @@\n one\n two\n",
            "diff --git a/f b/f\n@@ -1,1 +1,4 @@\n keep\n+a\n+b\n+c\n",
        ]
    }

    /// Frozen snapshots — captured from the parity-proven Rust output.
    private static let goldens: [String] = [
        "",
        "2:~,3:+,4:-",
        "1:~",
        "1:+,2:+",
        "1:-",
        "2:~,11:+",
        "1:~,6:+",
        "",
        "2:+,3:+,4:+",
    ]

    func test_rust_matches_frozen_goldens() throws {
        var captured: [String] = []
        for diff in corpus() {
            captured.append(snap(toDM(try mdvCoreDiffHunkMarks(text: diff))))
        }
        XCTAssertEqual(captured, Self.goldens)
    }
}
