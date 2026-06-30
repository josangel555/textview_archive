import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1256 — the "Copy Reference (current line)" verb/command builds a line-precise
/// `mdv://file` reference from the active tab url + the current editor line. The pure
/// builder (`DocumentModel.lineReference(url:line:)`) is host-testable without standing
/// up a model; the verb (`copy-reference`) and command (`edit.copyReference`) wire it to
/// `currentURL` + `sourceView.sourceSelection.line` and copy the result to the clipboard
/// (the render/clipboard step caps at review).
@MainActor
final class DocumentModelLineReferenceTests: XCTestCase {

    func test_lineReference_buildsFileRefViaSerialize() {
        let url = URL(fileURLWithPath: "/Users/me/notes/today.md")
        let ref = DocumentModel.lineReference(url: url, line: 42)
        XCTAssertEqual(ref, ElementRef.file(path: url.path, line: 42, endLine: nil).serialized,
                       "builds the file ref via the (tested) ElementRef serialize")
        XCTAssertEqual(ref.flatMap { ElementRef(parsing: $0) }, .file(path: url.path, line: 42, endLine: nil),
                       "round-trips back to the same file+line")
    }

    func test_lineReference_nilWhenNoURL() {
        XCTAssertNil(DocumentModel.lineReference(url: nil, line: 7),
                     "no active file → no reference")
    }

    func test_lineReference_carriesTheLine_notDropped() {
        // Teeth: the copy-reference contract is LINE-PRECISE — a regression that drops
        // the line (e.g. mis-wires to a bare file ref or the tab id) fails here.
        let ref = DocumentModel.lineReference(url: URL(fileURLWithPath: "/a/b.md"), line: 5)
        XCTAssertEqual(ref.flatMap { ElementRef(parsing: $0) }, .file(path: "/a/b.md", line: 5, endLine: nil))
    }

    // TSK-942: the line-RANGE reference (a selected span) carries both line + endLine,
    // and collapses to a plain single-line reference when the range is one line.
    func test_lineRangeReference_carriesTheRange_andCollapsesSingleLine() {
        let url = URL(fileURLWithPath: "/a/b.md")
        let ranged = DocumentModel.lineRangeReference(url: url, startLine: 10, endLine: 20)
        XCTAssertEqual(ranged.flatMap { ElementRef(parsing: $0) },
                       .file(path: "/a/b.md", line: 10, endLine: 20),
                       "a multi-line selection carries both line + endLine")
        let single = DocumentModel.lineRangeReference(url: url, startLine: 7, endLine: 7)
        XCTAssertEqual(single, DocumentModel.lineReference(url: url, line: 7),
                       "a one-line range == the plain single-line reference")
        XCTAssertNil(DocumentModel.lineRangeReference(url: nil, startLine: 1, endLine: 3),
                     "no active file → no reference")
    }
}
