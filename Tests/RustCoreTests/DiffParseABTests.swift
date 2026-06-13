import XCTest
@testable import RustCore
import ViewerCore

/// GOLDEN suite for the Rust core's `mdvcore_diff_parse` (via `mdvCoreParseDiff`,
/// mapped to the `UnifiedDiff` model). Was an A/B parity suite against the Swift
/// `DiffParser`; that twin was DELETED in TSK-649 Stage B #4, so the expected
/// outputs are now FROZEN snapshots of the (already parity-proven) Rust output.
/// Exercises the whole pipeline incl. MessagePack encode/decode + the nested-frame
/// decode + FFI, over the documented path-split / coord / no-newline hazards.
final class DiffParseABTests: XCTestCase {

    /// Compact single-line snapshot of the parsed structure (paths, flags, hunk
    /// coords, header, per-line kind + line numbers + content).
    private func snap(_ files: [UnifiedDiff.File]) -> String {
        func kc(_ k: UnifiedDiff.Line.Kind) -> String {
            switch k {
            case .context: return "c"; case .added: return "+"
            case .removed: return "-"; case .noNewline: return "\\"
            }
        }
        return files.map { f in
            let flags = "\(f.isNew ? "N" : "")\(f.isDeleted ? "D" : "")"
                + "\(f.isBinary ? "B" : "")\(f.isRename ? "R" : "")"
            let hunks = f.hunks.map { h -> String in
                let lines = h.lines.map { l in
                    "\(kc(l.kind))\(l.oldLineNo.map(String.init) ?? "_")"
                    + "/\(l.newLineNo.map(String.init) ?? "_"):\(l.content)"
                }.joined(separator: ";")
                return "@-\(h.oldStart),\(h.oldCount)+\(h.newStart),\(h.newCount)[\(h.header)]{\(lines)}"
            }.joined(separator: " ")
            return "\(f.oldPath)>\(f.newPath)|\(flags)|\(hunks)"
        }.joined(separator: " ## ")
    }

    /// The diff corpus — kept in lock-step with the prior A/B suite so the
    /// frozen goldens still cover the path-split / coord / no-newline hazards.
    private func corpus() -> [String] {
        [
            "",
            "diff --git a/foo.txt b/foo.txt\nindex abc..def 100644\n--- a/foo.txt\n+++ b/foo.txt\n@@ -1,3 +1,3 @@\n line one\n-old line\n+new line",
            "diff --git a/new.txt b/new.txt\nnew file mode 100644\nindex 0000000..abc1234\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+first\n+second",
            "diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\nindex abc1234..0000000\n--- a/gone.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-was here\n-now gone",
            "diff --git a/old.txt b/new.txt\nsimilarity index 95%\nrename from old.txt\nrename to new.txt\nindex abc..def 100644",
            "diff --git a/img.png b/img.png\nindex abc..def 100644\nBinary files a/img.png and b/img.png differ",
            "diff --git a/a.txt b/a.txt\nindex 1..2 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-x\n+y\ndiff --git a/b.txt b/b.txt\nindex 3..4 100644\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-p\n+q",
            "commit abc123\nAuthor: Someone <s@example.com>\nDate:   Fri May 16 10:00:00 2026\n\n    My commit message\n\ndiff --git a/foo.txt b/foo.txt\nindex 1..2 100644\n--- a/foo.txt\n+++ b/foo.txt\n@@ -1 +1 @@\n-a\n+b",
            "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -10 +20 @@\n only context",
            "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new",
            "diff --git a/foo bar.txt b/foo bar.txt\n--- a/foo bar.txt\n+++ b/foo bar.txt\n@@ -1 +1 @@\n-old\n+new",
            "diff --git a/x b/y.txt b/x b/y.txt\n--- a/x b/y.txt\n+++ b/x b/y.txt\n@@ -1 +1 @@\n-old\n+new",
            "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@ func someFunction()\n a\n+b",
            "diff --git a/big b/big\n--- a/big\n+++ b/big\n@@ -99999999999999999999 +-5 @@\n ctx",
        ]
    }

    /// Frozen snapshots — captured from the parity-proven Rust output.
    private static let goldens: [String] = [
        "",
        "foo.txt>foo.txt||@-1,3+1,3[]{c1/1:line one;-2/_:old line;+_/2:new line}",
        "new.txt>new.txt|N|@-0,0+1,2[]{+_/1:first;+_/2:second}",
        "gone.txt>gone.txt|D|@-1,2+0,0[]{-1/_:was here;-2/_:now gone}",
        "old.txt>new.txt|R|",
        "img.png>img.png|B|",
        "a.txt>a.txt||@-1,1+1,1[]{-1/_:x;+_/1:y} ## b.txt>b.txt||@-1,1+1,1[]{-1/_:p;+_/1:q}",
        "foo.txt>foo.txt||@-1,1+1,1[]{-1/_:a;+_/1:b}",
        "x>x||@-10,1+20,1[]{c10/20:only context}",
        "x>x||@-1,1+1,1[]{-1/_:old;\\_/_: No newline at end of file;+_/1:new}",
        "foo bar.txt>foo bar.txt||@-1,1+1,1[]{-1/_:old;+_/1:new}",
        "x b/y.txt>x b/y.txt||@-1,1+1,1[]{-1/_:old;+_/1:new}",
        "x>x||@-1,2+1,2[func someFunction()]{c1/1:a;+_/2:b}",
        "big>big||@-0,1+0,1[]{c0/0:ctx}",
    ]

    func test_rust_matches_frozen_goldens() throws {
        var captured: [String] = []
        for text in corpus() {
            captured.append(snap(try RustDiffAdapter.toUnified(mdvCoreParseDiff(text: text))))
        }
        XCTAssertEqual(captured, Self.goldens)
    }
}
