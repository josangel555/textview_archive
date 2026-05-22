import XCTest
import Foundation

/// Page Object for the source/rendered/hex mode picker
/// (`mdv.modebar`) — wraps the in-dump assertions every
/// `toggle-view` / `setCurrentViewMode` test does today.
///
/// We assert on `model.currentViewMode` rather than the visual subtree
/// because (a) it's authoritative and (b) the pure-SwiftUI source view
/// no longer surfaces an NSTextView for the JSON dumper to pick up.
struct ModeBarPage: DumpPage {
    let dump: [String: Any]

    init(dump: [String: Any]) { self.dump = dump }

    /// Subtree rooted at `mdv.modebar`, or `nil` when the mode bar
    /// is hidden for the current document type.
    var subtree: [String: Any]? { subtree(withIdentifier: "mdv.modebar") }

    /// Convenience — `dump.model.currentViewMode`.
    var mode: String? { currentViewMode }

    /// `true` iff a `WKWebView` appears in the dump. Rendered markdown
    /// is the only mode that embeds one, so it doubles as a check that
    /// the view layer caught up to the model.
    var hasWebView: Bool { !nodes(ofClass: "WKWebView").isEmpty }

    // MARK: - Assertions

    func assertMode(
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(mode, expected,
            "Expected currentViewMode '\(expected)', got '\(mode ?? "nil")'",
            file: file, line: line)
    }

    func assertHasWebView(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(hasWebView,
            "Expected a WKWebView in rendered mode, none found",
            file: file, line: line)
    }

    func assertNoWebView(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(hasWebView,
            "Expected no WKWebView in source/hex mode, one was present",
            file: file, line: line)
    }
}
