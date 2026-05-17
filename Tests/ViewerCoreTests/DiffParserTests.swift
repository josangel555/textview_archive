import XCTest
@testable import ViewerCore

final class DiffParserTests: XCTestCase {

    func test_empty_input_returns_empty() {
        XCTAssertEqual(DiffParser.parse(""), [])
    }

    func test_single_file_single_hunk_added_and_removed() {
        let diff = """
        diff --git a/foo.txt b/foo.txt
        index abc..def 100644
        --- a/foo.txt
        +++ b/foo.txt
        @@ -1,3 +1,3 @@
         line one
        -old line
        +new line
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        let f = files[0]
        XCTAssertEqual(f.oldPath, "foo.txt")
        XCTAssertEqual(f.newPath, "foo.txt")
        XCTAssertFalse(f.isNew)
        XCTAssertFalse(f.isDeleted)
        XCTAssertFalse(f.isRename)
        XCTAssertEqual(f.hunks.count, 1)
        let h = f.hunks[0]
        XCTAssertEqual(h.oldStart, 1); XCTAssertEqual(h.oldCount, 3)
        XCTAssertEqual(h.newStart, 1); XCTAssertEqual(h.newCount, 3)
        XCTAssertEqual(h.lines.count, 3)
        XCTAssertEqual(h.lines[0].kind, .context)
        XCTAssertEqual(h.lines[0].content, "line one")
        XCTAssertEqual(h.lines[0].oldLineNo, 1)
        XCTAssertEqual(h.lines[0].newLineNo, 1)
        XCTAssertEqual(h.lines[1].kind, .removed)
        XCTAssertEqual(h.lines[1].content, "old line")
        XCTAssertEqual(h.lines[1].oldLineNo, 2)
        XCTAssertNil(h.lines[1].newLineNo)
        XCTAssertEqual(h.lines[2].kind, .added)
        XCTAssertEqual(h.lines[2].content, "new line")
        XCTAssertNil(h.lines[2].oldLineNo)
        XCTAssertEqual(h.lines[2].newLineNo, 2)
    }

    func test_new_file() {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..abc1234
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +first
        +second
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isNew)
        XCTAssertEqual(files[0].newPath, "new.txt")
        XCTAssertEqual(files[0].hunks.first?.lines.count, 2)
        XCTAssertTrue(files[0].hunks.first?.lines.allSatisfy { $0.kind == .added } ?? false)
    }

    func test_deleted_file() {
        let diff = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index abc1234..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -was here
        -now gone
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isDeleted)
        XCTAssertEqual(files[0].oldPath, "gone.txt")
    }

    func test_renamed_file() {
        let diff = """
        diff --git a/old.txt b/new.txt
        similarity index 95%
        rename from old.txt
        rename to new.txt
        index abc..def 100644
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isRename)
        XCTAssertEqual(files[0].oldPath, "old.txt")
        XCTAssertEqual(files[0].newPath, "new.txt")
    }

    func test_binary_file() {
        let diff = """
        diff --git a/img.png b/img.png
        index abc..def 100644
        Binary files a/img.png and b/img.png differ
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isBinary)
        XCTAssertTrue(files[0].hunks.isEmpty)
    }

    func test_multi_file_diff() {
        let diff = """
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
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].newPath, "a.txt")
        XCTAssertEqual(files[1].newPath, "b.txt")
    }

    func test_skips_git_show_commit_header() {
        let diff = """
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
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].hunks.first?.lines.count, 2)
    }

    func test_hunk_coords_with_omitted_count() {
        // "@@ -10 +20 @@" — count omitted means 1
        let diff = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -10 +20 @@
         only context
        """
        let files = DiffParser.parse(diff)
        let h = files[0].hunks[0]
        XCTAssertEqual(h.oldStart, 10); XCTAssertEqual(h.oldCount, 1)
        XCTAssertEqual(h.newStart, 20); XCTAssertEqual(h.newCount, 1)
        XCTAssertEqual(h.lines[0].oldLineNo, 10)
        XCTAssertEqual(h.lines[0].newLineNo, 20)
    }

    func test_no_newline_at_end_marker() {
        let diff = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        """
        let files = DiffParser.parse(diff)
        let kinds = files[0].hunks[0].lines.map(\.kind)
        XCTAssertEqual(kinds, [.removed, .noNewline, .added])
    }

    func test_hunk_header_context_tail_preserved() {
        let diff = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1,2 +1,2 @@ func someFunction()
         a
        +b
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files[0].hunks[0].header, "func someFunction()")
    }
}
