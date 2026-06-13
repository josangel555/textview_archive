import XCTest
@testable import ViewerCore

/// TSK-594: golden tests for the unified-diff plain-text reconstruction
/// behind the diff view's Copy Hunk / Copy File Diff actions. The output
/// must round-trip the unified-diff line shape (prefix char per line,
/// `@@` banner, `---`/`+++` header) so a paste reads as a normal diff.
final class UnifiedDiffClipboardTextTests: XCTestCase {

    private let sample = """
    diff --git a/a.swift b/a.swift
    index 0000000..1111111 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -1,2 +1,3 @@ func foo()
     let a = 1
    +let b = 2
     let c = 3
    """

    func test_hunkClipboardText_roundTripsPrefixesAndBanner() throws {
        let file = try XCTUnwrap(RustDiffAdapter.parse(sample).first)
        let hunk = try XCTUnwrap(file.hunks.first)
        XCTAssertEqual(hunk.clipboardText, """
        @@ -1,2 +1,3 @@ func foo()
         let a = 1
        +let b = 2
         let c = 3

        """)
    }

    func test_fileClipboardText_includesHeaderAndHunks() throws {
        let file = try XCTUnwrap(RustDiffAdapter.parse(sample).first)
        XCTAssertEqual(file.clipboardText, """
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,3 @@ func foo()
         let a = 1
        +let b = 2
         let c = 3

        """)
    }

    func test_fileClipboardText_newFile_usesDevNullOldSide() throws {
        let newFile = """
        diff --git a/fresh.txt b/fresh.txt
        new file mode 100644
        index 0000000..1111111
        --- /dev/null
        +++ b/fresh.txt
        @@ -0,0 +1,1 @@
        +hello
        """
        let file = try XCTUnwrap(RustDiffAdapter.parse(newFile).first)
        XCTAssertTrue(file.clipboardText.hasPrefix("--- /dev/null\n+++ b/fresh.txt\n"),
                      "new file must show /dev/null on the old side: \(file.clipboardText)")
    }

    func test_fileClipboardText_binary_reproducesGitOneLiner() throws {
        let binary = """
        diff --git a/img.png b/img.png
        index 0000000..1111111 100644
        Binary files a/img.png and b/img.png differ
        """
        let file = try XCTUnwrap(RustDiffAdapter.parse(binary).first)
        XCTAssertEqual(file.clipboardText, "Binary files a/img.png and b/img.png differ\n")
    }

    func test_noNewlineMarker_keepsBackslashPrefix() throws {
        let noNL = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1,1 +1,1 @@
        -old
        +new
        \\ No newline at end of file
        """
        let file = try XCTUnwrap(RustDiffAdapter.parse(noNL).first)
        let hunk = try XCTUnwrap(file.hunks.first)
        XCTAssertTrue(hunk.clipboardText.contains("\\ No newline at end of file"),
                      "the no-newline marker must keep its backslash prefix")
    }
}
