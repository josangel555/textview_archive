import XCTest
@testable import ViewerKit

final class FileTypeDetectorTests: XCTestCase {
    private func category(_ path: String) -> FileCategory {
        FileTypeDetector.category(for: URL(fileURLWithPath: path))
    }

    func test_detectsMarkdown() {
        XCTAssertEqual(category("/tmp/README.md"), .markdown)
        XCTAssertEqual(category("/tmp/notes.markdown"), .markdown)
        XCTAssertEqual(category("/tmp/foo.mkd"), .markdown)
    }

    func test_detectsCode() {
        XCTAssertEqual(category("/tmp/main.swift"), .code)
        XCTAssertEqual(category("/tmp/script.py"), .code)
        XCTAssertEqual(category("/tmp/config.yaml"), .code)
    }

    func test_detectsHTML() {
        XCTAssertEqual(category("/tmp/page.html"), .html)
        XCTAssertEqual(category("/tmp/page.htm"), .html)
    }

    func test_detectsPlainText() {
        XCTAssertEqual(category("/tmp/notes.txt"), .plainText)
        XCTAssertEqual(category("/tmp/server.log"), .plainText)
    }

    func test_extensionlessFilesAreTreatedAsText() {
        XCTAssertEqual(category("/tmp/LICENSE"), .plainText)
        // Build files are now upgraded to .code (known-basename map, 2026-06-04)
        // — still a cheap text-shaped category, just syntax-highlightable.
        XCTAssertEqual(category("/tmp/Makefile"), .code)
        // A generic extensionless file still falls through to plain text.
        XCTAssertEqual(category("/tmp/scratchfile"), .plainText)
    }

    func test_caseInsensitive() {
        XCTAssertEqual(category("/tmp/README.MD"), .markdown)
        XCTAssertEqual(category("/tmp/MAIN.SWIFT"), .code)
    }

    func test_unknownExtensionFallsBackToUnknown() {
        XCTAssertEqual(category("/tmp/file.weirdext"), .unknown)
    }
}
