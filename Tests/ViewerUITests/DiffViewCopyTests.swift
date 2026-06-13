import AppKit
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-594: the Copy Hunk / Copy File Diff context-menu items call
/// `DiffView.copyToPasteboard` with the model's `clipboardText`. A real
/// right-click can't be synthesized headlessly, so per the testing
/// directive this exercises the EXACT function the menu buttons invoke,
/// against a private named pasteboard (never the user's general one).
@MainActor
final class DiffViewCopyTests: HeadlessUITestCase {

    func test_copyToPasteboard_writesStringType() {
        let pb = NSPasteboard(name: NSPasteboard.Name("mdv-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        DiffView.copyToPasteboard("@@ -1,1 +1,1 @@\n-old\n+new\n", pasteboard: pb)
        XCTAssertEqual(pb.string(forType: .string), "@@ -1,1 +1,1 @@\n-old\n+new\n")
    }

    func test_copyToPasteboard_replacesPriorContents() {
        let pb = NSPasteboard(name: NSPasteboard.Name("mdv-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        DiffView.copyToPasteboard("first", pasteboard: pb)
        DiffView.copyToPasteboard("second", pasteboard: pb)
        XCTAssertEqual(pb.string(forType: .string), "second",
                       "each copy must replace, not append")
    }

    func test_menuPayloads_areTheModelClipboardText() throws {
        // The menu buttons pass `hunk.clipboardText` / `file.clipboardText`
        // verbatim — pin that the parsed sample produces the same payload a
        // copy would deliver end-to-end.
        let sample = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,1 +1,2 @@
         let a = 1
        +let b = 2
        """
        let file = try XCTUnwrap(RustDiffAdapter.parse(sample).first)
        let hunk = try XCTUnwrap(file.hunks.first)

        let pb = NSPasteboard(name: NSPasteboard.Name("mdv-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        DiffView.copyToPasteboard(hunk.clipboardText, pasteboard: pb)
        XCTAssertEqual(pb.string(forType: .string), """
        @@ -1,1 +1,2 @@
         let a = 1
        +let b = 2

        """)
    }
}
