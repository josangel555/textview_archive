import XCTest
@testable import ViewerCore

/// Teeth for the "Open in Browser" temp-filename derivation.
final class BrowserPreviewTests: XCTestCase {

    func test_plainStem() {
        XCTAssertEqual(BrowserPreview.tempFileName(stem: "README"), "README.html")
    }

    func test_sanitizesUnsafeChars() {
        XCTAssertEqual(BrowserPreview.tempFileName(stem: "my notes"), "my-notes.html")
        XCTAssertEqual(BrowserPreview.tempFileName(stem: "a/b:c*d"), "a-b-c-d.html")
    }

    func test_keepsSafePunctuation() {
        XCTAssertEqual(BrowserPreview.tempFileName(stem: "v1.2_final-draft"), "v1.2_final-draft.html")
    }

    func test_trimsLeadingTrailingDashesAndDots() {
        XCTAssertEqual(BrowserPreview.tempFileName(stem: ".hidden."), "hidden.html")
        XCTAssertEqual(BrowserPreview.tempFileName(stem: "  spaced  "), "spaced.html")
    }

    func test_emptyOrAllUnsafe_fallsBackToPreview() {
        XCTAssertEqual(BrowserPreview.tempFileName(stem: ""), "preview.html")
        XCTAssertEqual(BrowserPreview.tempFileName(stem: "///"), "preview.html")
    }
}
