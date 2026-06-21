import XCTest
@testable import ViewerCore

/// TSK-1204 — teeth for the read-only-extracted-document plumbing. A TextFile
/// flagged `isExtractedReadOnly` (a synthesized view of a binary source —
/// docx/rtf/ods/xlsx) must produce a read-only EditorBuffer so the save path can
/// refuse to overwrite the source. Default stays editable.
final class ExtractedReadOnlyBufferTests: XCTestCase {

    func test_extractedReadOnlyFile_makesReadOnlyBuffer() {
        let f = TextFile(url: URL(fileURLWithPath: "/tmp/x.rtf"),
                         contents: "extracted text", encoding: .utf8,
                         byteCount: 14, isExtractedReadOnly: true)
        XCTAssertTrue(EditorBuffer(from: f).isReadOnly,
                      "an extracted-read-only file must yield a read-only buffer")
    }

    func test_normalFile_makesEditableBuffer() {
        let f = TextFile(url: URL(fileURLWithPath: "/tmp/x.txt"),
                         contents: "hi", encoding: .utf8, byteCount: 2)
        XCTAssertFalse(EditorBuffer(from: f).isReadOnly,
                       "a normal text file stays editable (default)")
    }

    func test_explicitBufferInit_defaultsEditable() {
        XCTAssertFalse(EditorBuffer(url: URL(fileURLWithPath: "/tmp/x"),
                                    original: "a").isReadOnly)
    }
}
