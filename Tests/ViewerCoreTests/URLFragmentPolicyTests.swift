import XCTest
@testable import ViewerCore

/// Pure coverage for the shared same-document-fragment check (was a private
/// `isSameDocumentFragment` triplicated in HTMLDocumentPolicy +
/// MarkdownRenderedView + CodeMirrorEditorView).
final class URLFragmentPolicyTests: XCTestCase {
    private func u(_ s: String) -> URL { URL(string: s)! }

    func test_noFragment_isFalse() {
        XCTAssertFalse(URLFragmentPolicy.isSameDocument(u("https://x/p"), as: u("https://x/p")))
    }

    func test_emptyFragment_isFalse() {
        XCTAssertFalse(URLFragmentPolicy.isSameDocument(u("https://x/p#"), as: u("https://x/p")))
    }

    func test_sameDocAnchor_isTrue() {
        XCTAssertTrue(URLFragmentPolicy.isSameDocument(u("https://x/p#sec"), as: u("https://x/p")))
        XCTAssertTrue(URLFragmentPolicy.isSameDocument(u("https://x/p?q=1#sec"), as: u("https://x/p?q=1")))
    }

    func test_differentPathOrQuery_isFalse() {
        XCTAssertFalse(URLFragmentPolicy.isSameDocument(u("https://x/other#sec"), as: u("https://x/p")))
        XCTAssertFalse(URLFragmentPolicy.isSameDocument(u("https://x/p?q=2#sec"), as: u("https://x/p?q=1")))
        XCTAssertFalse(URLFragmentPolicy.isSameDocument(u("https://y/p#sec"), as: u("https://x/p")))
    }

    func test_noCurrentDocument_schemelessFragmentIsTrue_schemedIsFalse() {
        XCTAssertTrue(URLFragmentPolicy.isSameDocument(u("#sec"), as: nil))
        XCTAssertFalse(URLFragmentPolicy.isSameDocument(u("https://x/p#sec"), as: nil))
    }
}
