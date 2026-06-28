import Foundation
import Testing
@testable import ViewerCore

/// Coverage for `FileQuarantine.isQuarantined` — the security boundary that
/// gates raw-HTML JavaScript trust: a quarantined (downloaded / received-from-
/// outside) file must NOT be trust-eligible, so `HTMLTrustPolicy` only relaxes
/// sanitize/CSP/JS for a LOCAL, non-quarantined file. The HTMLTrustPolicy tests
/// inject `isQuarantined` as a bool; this exercises the REAL `getxattr` detection
/// against the `com.apple.quarantine` extended attribute. An IO test (temp file
/// in the per-user temporary directory, ± the xattr), not pure logic.
struct FileQuarantineTests {

    private func tempFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-quarantine-\(UUID().uuidString).txt")
        try? "payload".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func plainFileIsNotQuarantined() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileQuarantine.isQuarantined(path: url.path) == false)
    }

    @Test func fileWithQuarantineXattrIsDetected() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // isQuarantined only checks PRESENCE (getxattr length ≥ 0), so the value's
        // real flags;ts;agent;uuid format is irrelevant — any bytes suffice.
        let value = Array("0081;00000000;test;".utf8)
        let rc = value.withUnsafeBufferPointer {
            setxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }
        #expect(rc == 0, "setxattr should succeed on a writable temp file")
        #expect(FileQuarantine.isQuarantined(path: url.path) == true)
    }

    @Test func removingTheXattrClearsQuarantine() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let value = Array("q".utf8)
        _ = value.withUnsafeBufferPointer {
            setxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }
        #expect(FileQuarantine.isQuarantined(path: url.path) == true)
        #expect(removexattr(url.path, "com.apple.quarantine", 0) == 0)
        #expect(FileQuarantine.isQuarantined(path: url.path) == false)
    }

    @Test func nonexistentPathIsNotQuarantined() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-absent-\(UUID().uuidString)").path
        #expect(FileQuarantine.isQuarantined(path: path) == false)
    }

    /// A DIFFERENT xattr must not be mistaken for quarantine (the check keys on
    /// the exact `com.apple.quarantine` name).
    @Test func anUnrelatedXattrIsNotQuarantine() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let value = Array("x".utf8)
        _ = value.withUnsafeBufferPointer {
            setxattr(url.path, "com.example.other", $0.baseAddress, $0.count, 0, 0)
        }
        #expect(FileQuarantine.isQuarantined(path: url.path) == false)
    }
}
