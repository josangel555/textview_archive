import XCTest

/// TSK-617 — the dead-pipe read contract AppLauncher.runShell relies on.
/// `readDataToEndOfFile()` raises an UNCATCHABLE ObjC
/// `NSFileHandleOperationException` ("Bad file descriptor") when the fd is
/// dead — under fd exhaustion in the big VM suite that crashed the whole
/// xctest process at AppLauncher.swift:209 instead of letting the test
/// self-skip. The harness now uses `readToEnd()`, which surfaces the same
/// condition as a catchable Swift error.
///
/// TEETH: this test calls `readToEnd()` on a deliberately-killed fd. Swap
/// the call back to `readDataToEndOfFile()` and the process CRASHES here —
/// the exact failure mode the fix removes.
final class AppLauncherPipeSafetyTests: XCTestCase {

    func test_readToEnd_onDeadFD_returnsErrorNotCrash() {
        let pipe = Pipe()
        // Kill the read end out from under the FileHandle — the dead-fd
        // state the VM suite produced via fd exhaustion / reaped children.
        close(pipe.fileHandleForReading.fileDescriptor)

        let data = try? pipe.fileHandleForReading.readToEnd()
        XCTAssertNil(data, "a dead fd must surface as a catchable error (nil), not data")
    }

    func test_readToEnd_onHealthyPipe_roundTrips() {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("ok".utf8))
        try? pipe.fileHandleForWriting.close()

        let data = try? pipe.fileHandleForReading.readToEnd()
        XCTAssertEqual(data.flatMap { String(data: $0, encoding: .utf8) }, "ok",
            "the safe API must still read normal pipe output")
    }
}
