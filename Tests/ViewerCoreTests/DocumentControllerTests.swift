import XCTest
@testable import ViewerCore

final class DocumentControllerTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocCtrlTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_openExistingFile_returnsLoaded() throws {
        let url = tmpDir.appendingPathComponent("hi.txt")
        try "hi".write(to: url, atomically: true, encoding: .utf8)
        let state = DocumentController().open(url: url)
        guard case .loaded(let file) = state else {
            return XCTFail("expected .loaded, got \(state)")
        }
        XCTAssertEqual(file.contents, "hi")
        XCTAssertEqual(file.url, url)
    }

    func test_openMissingFile_returnsErrorWithUserMessage() {
        let url = tmpDir.appendingPathComponent("nope.txt")
        let state = DocumentController().open(url: url)
        guard case .error(let failure) = state else {
            return XCTFail("expected .error, got \(state)")
        }
        XCTAssertEqual(failure.url, url)
        XCTAssertEqual(failure.message, "File not found.")
    }

    func test_oversizedFile_reportsSizeInMB() throws {
        let url = tmpDir.appendingPathComponent("big.txt")
        try String(repeating: "x", count: 2_000_000)
            .write(to: url, atomically: true, encoding: .utf8)
        let controller = DocumentController(loader: TextFileLoader(maxBytes: 1024))
        let state = controller.open(url: url)
        guard case .error(let failure) = state else {
            return XCTFail("expected .error, got \(state)")
        }
        XCTAssertTrue(failure.message.contains("too large"),
                      "got message: \(failure.message)")
        XCTAssertTrue(failure.message.contains("MB"),
                      "expected size in MB; got: \(failure.message)")
    }

    func test_messageMapping() {
        XCTAssertEqual(DocumentController.message(for: .fileNotFound),
                       "File not found.")
        XCTAssertEqual(DocumentController.message(for: .notReadable),
                       "File could not be read.")
        XCTAssertEqual(DocumentController.message(for: .decodingFailed),
                       "File is not valid UTF-8 or Latin-1 text.")
        XCTAssertTrue(DocumentController.message(for: .tooLarge(bytes: 5_242_880))
                      .contains("5.0 MB"))
    }

    // MARK: - .loading(URL) state

    /// `.loading(URL)` was added so `materializeIfNeeded` can flip a tab
    /// to a placeholder state while the file read runs on a detached
    /// Task. Equality must discriminate by URL — otherwise SwiftUI's
    /// view diffing collapses two distinct in-flight loads into "no
    /// change" and the placeholder gets stuck.
    func test_loadingState_equatableByURL() {
        let a = URL(fileURLWithPath: "/tmp/A.md")
        let b = URL(fileURLWithPath: "/tmp/B.md")
        XCTAssertEqual(DocumentState.loading(a), DocumentState.loading(a))
        XCTAssertNotEqual(DocumentState.loading(a), DocumentState.loading(b))
        XCTAssertNotEqual(DocumentState.loading(a), DocumentState.empty)
    }

    /// Cross-case inequality: `.loading(url)` must never equal any
    /// non-loading variant of the state enum at the same URL.
    func test_loadingState_neverEqualsOtherCases() {
        let url = URL(fileURLWithPath: "/tmp/x.md")
        let failure = DocumentState.LoadFailure(url: url, message: "x")
        XCTAssertNotEqual(DocumentState.loading(url), DocumentState.empty)
        XCTAssertNotEqual(DocumentState.loading(url), DocumentState.error(failure))
        XCTAssertNotEqual(DocumentState.loading(url),
                          DocumentState.preview(url, .image))
    }
}
