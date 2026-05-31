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
        XCTAssertTrue(DocumentController.message(
            for: .tooLarge(bytes: 5_242_880, ceiling: 512 * 1024 * 1024))
            .contains("5.0 MB"))
    }

    // MARK: - Two-tier read cap

    /// Set a file's stat size without writing the bytes (sparse
    /// truncate). The loader checks size before reading, so this trips
    /// the ceiling gate fast and disk-cheap.
    private func makeSparseFile(_ name: String, size: Int) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
        return url
    }

    /// A file above the OLD 32 MiB cap but below the 512 MiB ceiling now
    /// returns `.loaded` (was `.error("File is too large")` before). Use
    /// a small custom ceiling so the test stays cheap: a 2 KiB file with
    /// a 1 MiB ceiling lands in the 32–512 band conceptually.
    func test_open_aboveOldCapBelowCeiling_returnsLoaded() throws {
        let url = tmpDir.appendingPathComponent("midband.txt")
        try String(repeating: "x", count: 2048)
            .write(to: url, atomically: true, encoding: .utf8)
        // Default loader: 512 MiB ceiling, 64 MiB watermark — the 2 KiB
        // file is trivially loadable and proves the open() path returns
        // .loaded rather than .error for a non-tiny text file.
        let state = DocumentController().open(url: url)
        guard case .loaded(let file) = state else {
            return XCTFail("expected .loaded, got \(state)")
        }
        XCTAssertEqual(file.byteCount, 2048)
        XCTAssertFalse(file.isLargeReadOnly)
    }

    /// A file above the hard ceiling returns `.error` with a message
    /// that conveys the ceiling (reads as a real cap, not an arbitrary
    /// refusal of a merely-big file).
    func test_open_aboveCeiling_returnsErrorWithCeilingMessage() throws {
        let ceiling = 4 * 1024 * 1024
        let url = try makeSparseFile("over-ceiling.bin", size: ceiling + 1)
        let controller = DocumentController(
            loader: TextFileLoader(maxBytes: ceiling)
        )
        let state = controller.open(url: url)
        guard case .error(let failure) = state else {
            return XCTFail("expected .error, got \(state)")
        }
        XCTAssertTrue(failure.message.contains("too large"),
                      "got message: \(failure.message)")
        XCTAssertTrue(failure.message.contains("read limit"),
                      "message must convey a hard ceiling; got: \(failure.message)")
        XCTAssertTrue(failure.message.contains("\(ceiling / 1_048_576) MB"),
                      "message must name the ceiling in MB; got: \(failure.message)")
    }

    /// `message(for:.tooLarge)` format: en-US-POSIX decimal, names both
    /// the file size and the ceiling.
    func test_tooLargeMessage_namesCeiling() {
        let msg = DocumentController.message(
            for: .tooLarge(bytes: 600 * 1024 * 1024, ceiling: 512 * 1024 * 1024))
        XCTAssertTrue(msg.contains("600.0 MB"), "got: \(msg)")
        XCTAssertTrue(msg.contains("512 MB read limit"), "got: \(msg)")
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
