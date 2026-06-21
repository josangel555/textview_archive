import XCTest
import ViewerKit
@testable import ViewerCore

/// TSK-1036 (RTF slice) — teeth for routing .rtf into the viewer as a READ-ONLY
/// extracted-text view. The category sends it to the source view; the loader
/// substitutes RtfTextExtractor output (not raw `{\rtf1...}`) and flags it
/// read-only (TSK-1204) so a save can't overwrite the source.
final class RtfViewerRoutingTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RtfRoute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_rtf_categorizedAsPlainText() {
        XCTAssertEqual(
            FileTypeDetector.category(for: tmp.appendingPathComponent("doc.rtf")),
            .plainText, "an .rtf routes to the source/plainText view")
    }

    func test_rtf_load_extractsPlainText_andIsReadOnly() throws {
        let url = tmp.appendingPathComponent("doc.rtf")
        try "{\\rtf1\\ansi\\deff0 Hello \\b World\\b0 !}".write(
            to: url, atomically: true, encoding: .utf8)

        let tf = try TextFileLoader(maxBytes: 10_000_000).load(url: url)

        XCTAssertTrue(tf.isExtractedReadOnly,
                      "an .rtf loads as a READ-ONLY extracted view (no save-corruption)")
        XCTAssertTrue(tf.contents.contains("Hello"), "extracted body text shows")
        XCTAssertTrue(tf.contents.contains("World"))
        XCTAssertFalse(tf.contents.contains("\\rtf1"),
                       "raw RTF control words must NOT appear in the view")
        XCTAssertFalse(tf.contents.contains("deff0"))
    }
}
