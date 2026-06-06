import XCTest
@testable import ViewerCore

/// Headless coverage for the clipboard Tools surface. Uses a FAKE pasteboard
/// so the suite never touches `NSPasteboard.general` (which would clobber the
/// dev's real clipboard).
final class TextToolRunnerTests: XCTestCase {

    private final class FakePasteboard: PasteboardIO {
        var contents: String?
        init(_ initial: String? = nil) { contents = initial }
        func readString() -> String? { contents }
        func writeString(_ s: String) { contents = s }
    }

    func testGenerateUUID_writesFreshUUID_ignoringInput() {
        let pb = FakePasteboard("pre-existing")
        let status = TextToolRunner.run(.generateUUID, pasteboard: pb)
        XCTAssertNotNil(pb.contents)
        XCTAssertNotEqual(pb.contents, "pre-existing")
        XCTAssertNotNil(pb.contents?.range(of:
            "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            options: .regularExpression))
        XCTAssertTrue(status.contains("copied"))
    }

    func testSHA256_transformsClipboard() {
        let pb = FakePasteboard("abc")
        _ = TextToolRunner.run(.sha256, pasteboard: pb)
        XCTAssertEqual(pb.contents,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testBase64Encode_thenDecode_roundTripsViaClipboard() {
        let pb = FakePasteboard("hello")
        _ = TextToolRunner.run(.base64Encode, pasteboard: pb)
        XCTAssertEqual(pb.contents, "aGVsbG8=")
        _ = TextToolRunner.run(.base64Decode, pasteboard: pb)
        XCTAssertEqual(pb.contents, "hello")
    }

    func testBase64Decode_invalid_leavesClipboardUnchanged() {
        let pb = FakePasteboard("!!! not base64 !!!")
        let status = TextToolRunner.run(.base64Decode, pasteboard: pb)
        XCTAssertEqual(pb.contents, "!!! not base64 !!!", "failed transform must not overwrite")
        XCTAssertTrue(status.lowercased().contains("isn’t valid")
            || status.lowercased().contains("valid"))
    }

    func testTransform_emptyClipboard_isNoOpWithStatus() {
        let pb = FakePasteboard(nil)
        let status = TextToolRunner.run(.base64Encode, pasteboard: pb)
        XCTAssertNil(pb.contents, "empty clipboard must stay empty")
        XCTAssertTrue(status.lowercased().contains("empty"))
    }
}
