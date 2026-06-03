import XCTest
@testable import ViewerKit

/// VM-01: the status bar's "Ln X, Col Y" readout is meaningful only in the
/// caret-backed text lenses (Source / Editor). Every other lens — Rendered
/// (WKWebView, no caret), Preview, Hex, Formatted, Table, Diff — must hide it.
/// `StatusBar` gates the chip on `ViewMode.hasTextCaret`; these pin the
/// classification so a new mode can't silently default to "shows Ln/Col".
final class ViewModeCaretTests: XCTestCase {
    func test_caretModes_haveTextCaret() {
        XCTAssertTrue(ViewMode.source.hasTextCaret)
        XCTAssertTrue(ViewMode.editor.hasTextCaret)
    }

    func test_caretlessModes_haveNoTextCaret() {
        // The VM-01 case: rendered markdown has no caret in the WKWebView.
        XCTAssertFalse(ViewMode.rendered.hasTextCaret)
        XCTAssertFalse(ViewMode.formatted.hasTextCaret)
        XCTAssertFalse(ViewMode.table.hasTextCaret)
        XCTAssertFalse(ViewMode.diff.hasTextCaret)
        XCTAssertFalse(ViewMode.preview.hasTextCaret)
        XCTAssertFalse(ViewMode.hex.hasTextCaret)
    }

    /// Every case is classified — `hasTextCaret` is a total switch, so adding
    /// a new `ViewMode` forces an explicit caret/caretless decision (and trips
    /// this exhaustiveness check if the count drifts).
    func test_everyMode_isClassified() {
        let caret = ViewMode.allCases.filter(\.hasTextCaret)
        XCTAssertEqual(Set(caret), [.source, .editor],
                       "exactly Source + Editor are caret-backed; got \(caret)")
    }
}
