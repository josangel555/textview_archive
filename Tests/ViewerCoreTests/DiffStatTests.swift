import XCTest
@testable import ViewerCore

/// Coverage for DiffStat / UnifiedDiff.File.lineStats (TSK-514). Feeds real
/// unified-diff text through DiffParser so the stat is exercised end-to-end.
final class DiffStatTests: XCTestCase {

    func test_perFile_lineStats_addedAndRemoved() {
        let diff = """
        diff --git a/foo.txt b/foo.txt
        index abc..def 100644
        --- a/foo.txt
        +++ b/foo.txt
        @@ -1,3 +1,4 @@
         context
        -old line
        +new line
        +another new
         trailing
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        let s = files[0].lineStats
        XCTAssertEqual(s.added, 2)
        XCTAssertEqual(s.removed, 1)   // context/trailing don't count
    }

    func test_aggregate_multiFile() {
        let diff = """
        diff --git a/a.txt b/a.txt
        index 1..2 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -x
        +y
        diff --git a/b.txt b/b.txt
        new file mode 100644
        --- /dev/null
        +++ b/b.txt
        @@ -0,0 +1,2 @@
        +p
        +q
        """
        let stat = DiffStat(DiffParser.parse(diff))
        XCTAssertEqual(stat.filesChanged, 2)
        XCTAssertEqual(stat.additions, 3)   // a:+1, b:+2
        XCTAssertEqual(stat.deletions, 1)   // a:-1
        XCTAssertEqual(stat.shortStat, "2 files changed, 3 insertions(+), 1 deletion(-)")
    }

    func test_singular_pluralization() {
        let one = """
        diff --git a/a.txt b/a.txt
        new file mode 100644
        --- /dev/null
        +++ b/a.txt
        @@ -0,0 +1 @@
        +only
        """
        let stat = DiffStat(DiffParser.parse(one))
        XCTAssertEqual(stat.shortStat, "1 file changed, 1 insertion(+)")
    }

    func test_deletionsOnly() {
        let diff = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -was here
        -now gone
        """
        let stat = DiffStat(DiffParser.parse(diff))
        XCTAssertEqual(stat.additions, 0)
        XCTAssertEqual(stat.deletions, 2)
        XCTAssertEqual(stat.shortStat, "1 file changed, 2 deletions(-)")
    }

    func test_binaryFile_zeroLines_butCountsAsChanged() {
        let diff = """
        diff --git a/img.png b/img.png
        index abc..def 100644
        Binary files a/img.png and b/img.png differ
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.first?.lineStats.added, 0)
        XCTAssertEqual(files.first?.lineStats.removed, 0)
        let stat = DiffStat(files)
        XCTAssertEqual(stat.filesChanged, 1)        // listed even with no line changes
        XCTAssertEqual(stat.shortStat, "1 file changed")
    }

    func test_emptyDiff_noChanges() {
        let stat = DiffStat(DiffParser.parse(""))
        XCTAssertEqual(stat, DiffStat(filesChanged: 0, additions: 0, deletions: 0))
        XCTAssertEqual(stat.shortStat, "no changes")
    }
}
