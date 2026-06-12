import XCTest
@testable import RustCore
import ViewerCore

/// A/B parity: the Rust core's `mdvcore_diff_parse` (via `mdvCoreParseDiff`,
/// mapped to the `UnifiedDiff` model) vs the SHIPPING Swift `DiffParser`, over a
/// corpus mirroring `DiffParserTests` plus the documented path-split / coord /
/// no-newline hazards. Both sides must produce structurally identical files.
/// Forces the Rust path directly (no gate) — exercises the whole pipeline incl.
/// MessagePack encode/decode + the nested-frame decode + FFI.
final class DiffParseABTests: XCTestCase {

    /// The diff corpus — kept in lock-step with `DiffParserTests` so a parity
    /// gap surfaces the same inputs the Swift parser is pinned on.
    private func corpus() -> [String] {
        [
            "",
            // single file, context + removed + added
            """
            diff --git a/foo.txt b/foo.txt
            index abc..def 100644
            --- a/foo.txt
            +++ b/foo.txt
            @@ -1,3 +1,3 @@
             line one
            -old line
            +new line
            """,
            // new file (--- /dev/null must not clobber the path)
            """
            diff --git a/new.txt b/new.txt
            new file mode 100644
            index 0000000..abc1234
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1,2 @@
            +first
            +second
            """,
            // deleted file
            """
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            index abc1234..0000000
            --- a/gone.txt
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -was here
            -now gone
            """,
            // rename (rename from/to precedence over ---/+++)
            """
            diff --git a/old.txt b/new.txt
            similarity index 95%
            rename from old.txt
            rename to new.txt
            index abc..def 100644
            """,
            // binary
            """
            diff --git a/img.png b/img.png
            index abc..def 100644
            Binary files a/img.png and b/img.png differ
            """,
            // multi-file
            """
            diff --git a/a.txt b/a.txt
            index 1..2 100644
            --- a/a.txt
            +++ b/a.txt
            @@ -1 +1 @@
            -x
            +y
            diff --git a/b.txt b/b.txt
            index 3..4 100644
            --- a/b.txt
            +++ b/b.txt
            @@ -1 +1 @@
            -p
            +q
            """,
            // git-show commit header skipped
            """
            commit abc123
            Author: Someone <s@example.com>
            Date:   Fri May 16 10:00:00 2026

                My commit message

            diff --git a/foo.txt b/foo.txt
            index 1..2 100644
            --- a/foo.txt
            +++ b/foo.txt
            @@ -1 +1 @@
            -a
            +b
            """,
            // omitted hunk count (defaults to 1)
            """
            diff --git a/x b/x
            --- a/x
            +++ b/x
            @@ -10 +20 @@
             only context
            """,
            // \ No newline at end of file marker
            """
            diff --git a/x b/x
            --- a/x
            +++ b/x
            @@ -1 +1 @@
            -old
            \\ No newline at end of file
            +new
            """,
            // path with spaces (strategy 2: equal-prefix)
            """
            diff --git a/foo bar.txt b/foo bar.txt
            --- a/foo bar.txt
            +++ b/foo bar.txt
            @@ -1 +1 @@
            -old
            +new
            """,
            // filename containing " b/" substring
            """
            diff --git a/x b/y.txt b/x b/y.txt
            --- a/x b/y.txt
            +++ b/x b/y.txt
            @@ -1 +1 @@
            -old
            +new
            """,
            // hunk header context tail preserved
            """
            diff --git a/x b/x
            --- a/x
            +++ b/x
            @@ -1,2 +1,2 @@ func someFunction()
             a
            +b
            """,
            // adversarial coords clamp to a sane range
            """
            diff --git a/big b/big
            --- a/big
            +++ b/big
            @@ -99999999999999999999 +-5 @@
             ctx
            """,
        ]
    }

    func test_rust_matches_swift_across_corpus() throws {
        for text in corpus() {
            let swift = DiffParser.parse(text)
            let rust = try RustDiffAdapter.toUnified(mdvCoreParseDiff(text: text))
            XCTAssertEqual(rust, swift, "parity mismatch for diff:\n\(text)")
        }
    }

    func test_gate_off_uses_swift_and_matches() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1 +1 @@
        -a
        +b
        """
        let o = RustDiffAdapter.outcome(text, environment: ["MDV_RUST_DIFF": "0"])
        XCTAssertEqual(o.source, .swiftBecauseGateOff)
        XCTAssertEqual(o.value, DiffParser.parse(text))
    }
}
