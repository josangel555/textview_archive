import XCTest
@testable import ViewerKit

/// TSK-1474 — the video fallback classification (extension → supported?).
final class VideoPlayabilityTests: XCTestCase {

    func test_nativeContainers_playInline() {
        for ext in ["mp4", "m4v", "mov", "mpg", "mpeg", "3gp", "MP4", "MoV"] {
            XCTAssertEqual(VideoPlayability.classify(extension: ext), .native,
                           "\(ext) is an AVFoundation container (case-insensitive)")
        }
    }

    func test_nonAVFoundationContainers_getTheFallbackCard() {
        // These are in FileCategory.video (they ROUTE to the media surface)
        // but AVFoundation can't play them — a black player is the bug this
        // classification prevents.
        for ext in ["mkv", "webm", "wmv", "flv", "avi"] {
            XCTAssertEqual(VideoPlayability.classify(extension: ext), .unsupported,
                           "\(ext) must show the fallback, not a black AVPlayerView")
        }
    }

    func test_unknownExtension_isGracefullyUnsupported() {
        XCTAssertEqual(VideoPlayability.classify(extension: "xyz"), .unsupported)
        XCTAssertEqual(VideoPlayability.classify(extension: ""), .unsupported)
    }

    func test_urlConvenience() {
        XCTAssertEqual(
            VideoPlayability.classify(url: URL(fileURLWithPath: "/a/clip.mov")), .native)
        XCTAssertEqual(
            VideoPlayability.classify(url: URL(fileURLWithPath: "/a/clip.mkv")), .unsupported)
    }

    /// DRIFT GUARD: every extension in FileCategory's video set must have a
    /// DELIBERATE classification here — adding a new video extension without
    /// deciding native-vs-fallback goes RED (parses the live source, same
    /// pattern as the SettingsCatalog guard).
    func test_everyFileCategoryVideoExtension_isDeliberatelyClassified() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // ViewerKitTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("Sources/ViewerKit/FileCategory.swift"),
            encoding: .utf8)
        guard let setStart = source.range(of: "videoExtensions: Set<String> = ["),
              let setEnd = source.range(of: "]", range: setStart.upperBound..<source.endIndex)
        else { return XCTFail("videoExtensions set not found in FileCategory.swift") }
        let body = source[setStart.upperBound..<setEnd.lowerBound]
        let exts = body.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\""))) }
            .filter { !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(exts.count, 11, "sanity: parsed the real set")
        // The DELIBERATE list: extensions we KNOW are native. Everything else
        // in the category must classify .unsupported — and any NEW extension
        // someone adds lands here for an explicit decision.
        let knownNative: Set<String> = ["mp4", "m4v", "mov", "mpg", "mpeg", "3gp"]
        for ext in exts {
            let expected: VideoPlayability = knownNative.contains(ext) ? .native : .unsupported
            XCTAssertEqual(VideoPlayability.classify(extension: ext), expected,
                           "extension '\(ext)' from FileCategory.video needs a deliberate "
                           + "native-vs-fallback decision in VideoPlayability")
        }
    }
}
