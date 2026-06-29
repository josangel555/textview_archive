import XCTest
@testable import ViewerCore

/// Guards the ffmpeg-spawn robustness: `AudioExporter.runFFmpeg` routes through
/// `ProcessRunner` with a wall-clock timeout, so a wedged ffmpeg can't block the
/// export thread forever (the prior raw `waitUntilExit()` had no bail; this
/// mirrors GitClient's ProcessRunner-timeout). Uses system binaries as stand-ins
/// for ffmpeg — no real ffmpeg needed, host-safe.
final class AudioExporterFFmpegTests: XCTestCase {

    /// A wedged process (`/bin/sleep 60`) must be bailed by the timeout
    /// (SIGTERM→SIGKILL) and surfaced as a throw — NOT block for 60s. Reaching
    /// the assert quickly is the teeth: the prior raw `waitUntilExit()` would
    /// have blocked the whole 60s.
    func test_runFFmpeg_timesOut_onWedgedProcess() {
        let t0 = Date()
        XCTAssertThrowsError(
            try AudioExporter.runFFmpeg(URL(fileURLWithPath: "/bin/sleep"), ["60"], timeout: 1)
        ) { error in
            XCTAssertEqual(error as? AudioExportError, .ffmpegFailed(-1),
                           "a timed-out ffmpeg should surface as ffmpegFailed(-1)")
        }
        // Generous bound (timeout 1s + 2s kill-grace ≈ 3s); 15s tolerates CI load
        // while still proving we didn't wait the full 60s.
        XCTAssertLessThan(Date().timeIntervalSince(t0), 15,
                          "must bail on the timeout, not block for the child's full 60s")
    }

    /// Happy path: a clean zero-exit child returns without throwing.
    func test_runFFmpeg_succeeds_onCleanZeroExit() throws {
        let status = try AudioExporter.runFFmpeg(URL(fileURLWithPath: "/usr/bin/true"), [], timeout: 5)
        XCTAssertEqual(status, 0)
    }

    /// A non-zero exit surfaces as `ffmpegFailed(status)`.
    func test_runFFmpeg_throwsOnNonZeroExit() {
        XCTAssertThrowsError(
            try AudioExporter.runFFmpeg(URL(fileURLWithPath: "/usr/bin/false"), [], timeout: 5)
        ) { error in
            // /usr/bin/false exits 1.
            XCTAssertEqual(error as? AudioExportError, .ffmpegFailed(1))
        }
    }
}
