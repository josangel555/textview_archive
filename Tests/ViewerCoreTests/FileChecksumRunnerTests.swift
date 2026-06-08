import XCTest
@testable import ViewerCore

/// Pins the surface-agnostic "Copy SHA-256 of Current File" runner (TSK-505).
/// Uses an injected fake pasteboard so the suite never touches
/// `NSPasteboard.general` (which would clobber the developer's real clipboard).
final class FileChecksumRunnerTests: XCTestCase {

    private final class FakePasteboard: PasteboardIO {
        private(set) var stored: String?
        private(set) var writeCount = 0
        init(_ initial: String? = nil) { stored = initial }
        func readString() -> String? { stored }
        func writeString(_ s: String) { stored = s; writeCount += 1 }
    }

    func test_copiesCorrectHash_forRealFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-csum-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let pb = FakePasteboard("PRE-EXISTING")
        let status = FileChecksumRunner.copyChecksum(ofFileAt: url, pasteboard: pb)

        XCTAssertEqual(pb.stored,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(status.contains("copied to clipboard"), "status: \(status)")
        XCTAssertEqual(pb.writeCount, 1)
    }

    func test_noFileOpen_leavesPasteboardUntouched() {
        let pb = FakePasteboard("PRE-EXISTING")
        let status = FileChecksumRunner.copyChecksum(ofFileAt: nil, pasteboard: pb)
        XCTAssertEqual(pb.stored, "PRE-EXISTING")   // not clobbered
        XCTAssertEqual(pb.writeCount, 0)
        XCTAssertTrue(status.contains("no file open"), "status: \(status)")
    }

    func test_unreadableFile_leavesPasteboardUntouched() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-csum-missing-\(UUID().uuidString)")
        let pb = FakePasteboard("PRE-EXISTING")
        let status = FileChecksumRunner.copyChecksum(ofFileAt: missing, pasteboard: pb)
        XCTAssertEqual(pb.stored, "PRE-EXISTING")   // not clobbered on read failure
        XCTAssertEqual(pb.writeCount, 0)
        XCTAssertTrue(status.contains("couldn’t read"), "status: \(status)")
    }
}
