import XCTest
@testable import ViewerCore
import ViewerKit

/// Ensures DocumentController routes media files to the .preview
/// state instead of trying to text-load them (which would fail or
/// silently produce a hex view).
final class DocumentControllerMediaTests: XCTestCase {

    private var controller: DocumentController!
    private var tmpDir: URL!

    override func setUpWithError() throws {
        controller = DocumentController()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-media-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeBlob(_ name: String, _ bytes: [UInt8] = [0, 1, 2, 3]) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testImageOpensAsPreview() throws {
        let url = try writeBlob("a.png")
        let state = controller.open(url: url)
        guard case let .preview(u, cat) = state else {
            return XCTFail("expected .preview, got \(state)")
        }
        XCTAssertEqual(u, url)
        XCTAssertEqual(cat, .image)
    }

    func testAudioOpensAsPreview() throws {
        let url = try writeBlob("song.mp3")
        let state = controller.open(url: url)
        guard case .preview(_, let cat) = state else {
            return XCTFail("expected .preview, got \(state)")
        }
        XCTAssertEqual(cat, .audio)
    }

    func testVideoOpensAsPreview() throws {
        let url = try writeBlob("clip.mp4")
        let state = controller.open(url: url)
        guard case .preview(_, let cat) = state else {
            return XCTFail("expected .preview, got \(state)")
        }
        XCTAssertEqual(cat, .video)
    }

    func testPDFOpensAsPreview() throws {
        let url = try writeBlob("doc.pdf")
        let state = controller.open(url: url)
        guard case .preview(_, let cat) = state else {
            return XCTFail("expected .preview, got \(state)")
        }
        XCTAssertEqual(cat, .pdf)
    }

    func testSQLiteOpensAsPreview() throws {
        let url = try writeBlob("data.sqlite")
        let state = controller.open(url: url)
        guard case .preview(_, let cat) = state else {
            return XCTFail("expected .preview, got \(state)")
        }
        XCTAssertEqual(cat, .sqlite)
    }

    func testMissingImageStillRoutesToError() throws {
        // Don't write the file.
        let url = tmpDir.appendingPathComponent("missing.png")
        let state = controller.open(url: url)
        if case .error = state {
            return  // expected
        }
        XCTFail("expected .error for missing file; got \(state)")
    }

    func testTextFileNotMisidentifiedAsPreview() throws {
        let url = try writeBlob("note.txt",
            Array("hello world".utf8))
        let state = controller.open(url: url)
        if case .loaded = state {
            return  // expected
        }
        XCTFail("expected .loaded for text file; got \(state)")
    }
}
