import XCTest
import Foundation

/// Page Object for the main content area (`mdv.content`) — anything
/// that's NOT the sidebar, tab bar, or status bar.
///
/// Mostly used for invariant checks across long flows ("WKWebView
/// must be present at every step that opens a markdown file" — see
/// `LongFlowTests`).
struct RenderedContentPage: DumpPage {
    let dump: [String: Any]

    init(dump: [String: Any]) { self.dump = dump }

    var subtree: [String: Any]? { subtree(withIdentifier: "mdv.content") }

    /// `true` when the rendered markdown WKWebView is in the tree.
    var hasWebView: Bool { !nodes(ofClass: "WKWebView").isEmpty }

    /// `true` when the HEX-mode view is present.
    var hasHexView: Bool { subtree(withIdentifier: "mdv.hexView") != nil }

    /// `true` when the image preview view is present.
    var hasImagePreview: Bool { subtree(withIdentifier: "mdv.imagePreview") != nil }

    // MARK: - Assertions

    func assertHasWebView(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(hasWebView,
            "Expected rendered markdown WKWebView, none found",
            file: file, line: line)
    }

    func assertContentNonEmpty(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let count = totalNodeCount
        XCTAssertGreaterThan(count, 1,
            "Content view tree looks empty (totalNodeCount=\(count))",
            file: file, line: line)
    }
}
