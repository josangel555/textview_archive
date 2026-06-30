import XCTest
@testable import ViewerCore

/// TSK-910 — multi-line diff selection foundation: the selection range model +
/// the range→clipboard-text extraction (the per-line-Text rendering blocks
/// SwiftUI's cross-line text-selection, so copy is built from the model).
final class DiffLineSelectionTests: XCTestCase {

    private func line(_ kind: UnifiedDiff.Line.Kind, _ content: String) -> UnifiedDiff.Line {
        UnifiedDiff.Line(kind: kind, oldLineNo: nil, newLineNo: nil, content: content)
    }

    private func file(_ kinds: [(UnifiedDiff.Line.Kind, String)]) -> UnifiedDiff.File {
        UnifiedDiff.File(oldPath: "a", newPath: "a", hunks: [
            UnifiedDiff.Hunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, header: "",
                             lines: kinds.map { line($0.0, $0.1) })
        ])
    }

    func test_range_isOrderIndependent_andCounts() {
        XCTAssertEqual(DiffLineSelection(anchor: 5, focus: 2).range, 2...5, "anchor below focus")
        XCTAssertEqual(DiffLineSelection(anchor: 2, focus: 5).range, 2...5, "focus below anchor")
        XCTAssertEqual(DiffLineSelection(3).range, 3...3, "single-row click")
        XCTAssertEqual(DiffLineSelection(anchor: 2, focus: 5).count, 4)
    }

    func test_contains_marksOnlyTheSelectedRows() {
        let sel = DiffLineSelection(anchor: 2, focus: 4)
        XCTAssertFalse(sel.contains(1))
        XCTAssertTrue(sel.contains(2))
        XCTAssertTrue(sel.contains(3))
        XCTAssertTrue(sel.contains(4))
        XCTAssertFalse(sel.contains(5))
    }

    func test_selectedClipboardText_multiLine_prefixedByKind() {
        let f = file([(.context, "ctx"), (.added, "new"), (.removed, "old"), (.context, "tail")])
        XCTAssertEqual(f.selectedClipboardText(DiffLineSelection(anchor: 1, focus: 2)), "+new\n-old",
                       "a multi-line selection copies each row prefixed by its kind")
        XCTAssertEqual(f.selectedClipboardText(DiffLineSelection(0)), " ctx", "a single context row keeps its space prefix")
        XCTAssertEqual(f.selectedClipboardText(DiffLineSelection(anchor: 0, focus: 3)), " ctx\n+new\n-old\n tail")
    }

    func test_selectedClipboardText_clampsOutOfRange_andEmptyFile() {
        let f = file([(.added, "x")])
        XCTAssertEqual(f.selectedClipboardText(DiffLineSelection(anchor: 0, focus: 99)), "+x",
                       "the upper bound clamps to the last row")
        let empty = UnifiedDiff.File(oldPath: "a", newPath: "a", hunks: [])
        XCTAssertEqual(empty.selectedClipboardText(DiffLineSelection(0)), "", "empty file → empty selection text")
    }

    func test_flatLines_andSelection_spanHunks() {
        let h1 = UnifiedDiff.Hunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, header: "",
                                  lines: [line(.context, "a")])
        let h2 = UnifiedDiff.Hunk(oldStart: 5, oldCount: 1, newStart: 5, newCount: 1, header: "",
                                  lines: [line(.added, "b")])
        let f = UnifiedDiff.File(oldPath: "a", newPath: "a", hunks: [h1, h2])
        XCTAssertEqual(f.flatLines.count, 2, "flatLines concatenates across hunks")
        XCTAssertEqual(f.selectedClipboardText(DiffLineSelection(anchor: 0, focus: 1)), " a\n+b",
                       "a selection can span hunk boundaries")
    }
}
