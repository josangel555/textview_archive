import XCTest
@testable import ViewerKit

/// TSK-948: the Fold / Unfold / Fold All / Unfold All menu actions are
/// meaningful only in the FOLDABLE text lenses (Source / Editor) — both carry
/// a fold model (TreeSitter `FoldRegion` / CM6 folds). Every other lens —
/// Rendered (WKWebView), Preview, Hex, Formatted, Table, Diff — has no fold
/// model and the actions must grey out. `DocumentModel.canFoldActiveDocument`
/// gates the menu on `ViewMode.supportsFolding`; these pin the classification
/// so a new mode can't silently default to "Fold enabled".
final class ViewModeFoldingTests: XCTestCase {
    func test_foldableModes_supportFolding() {
        XCTAssertTrue(ViewMode.source.supportsFolding)
        XCTAssertTrue(ViewMode.editor.supportsFolding)
    }

    func test_nonFoldableModes_doNotSupportFolding() {
        XCTAssertFalse(ViewMode.rendered.supportsFolding,
                       "rendered markdown (WKWebView) has no fold model")
        XCTAssertFalse(ViewMode.formatted.supportsFolding)
        XCTAssertFalse(ViewMode.table.supportsFolding)
        XCTAssertFalse(ViewMode.diff.supportsFolding)
        XCTAssertFalse(ViewMode.preview.supportsFolding)
        XCTAssertFalse(ViewMode.hex.supportsFolding)
    }

    /// Total switch — adding a `ViewMode` forces an explicit foldable decision
    /// (and trips this exhaustiveness check if the set drifts).
    func test_everyMode_isClassified() {
        let foldable = ViewMode.allCases.filter(\.supportsFolding)
        XCTAssertEqual(Set(foldable), [.source, .editor],
                       "exactly Source + Editor are foldable; got \(foldable)")
    }
}
