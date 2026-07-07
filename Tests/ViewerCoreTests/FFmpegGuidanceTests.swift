import XCTest
@testable import ViewerCore

/// TSK-1442 — the consolidated ffmpeg install-guidance source.
final class FFmpegGuidanceTests: XCTestCase {

    func test_unavailableMessage_namesTheActionAndTheInstallHint() {
        let m = FFmpegGuidance.unavailableMessage(action: "convert audio")
        XCTAssertTrue(m.contains("ffmpeg isn't available"))
        XCTAssertTrue(m.contains("convert audio"))
        XCTAssertTrue(m.contains("brew install ffmpeg"), "carries the install hint")
    }

    func test_disabledOptionTitle() {
        XCTAssertEqual(FFmpegGuidance.disabledOptionTitle("MP3"), "MP3 (ffmpeg not found)")
    }

    func test_shouldGuide_reflectsAvailability() {
        // A bogus override path → not available → guide.
        XCTAssertTrue(FFmpegGuidance.shouldGuide(override: "/no/such/ffmpeg", environment: [:]))
        // The real system may or may not have ffmpeg; assert the pass-through
        // agrees with the locator either way (no divergence).
        let env = ProcessInfo.processInfo.environment
        XCTAssertEqual(FFmpegGuidance.shouldGuide(environment: env),
                       !FFmpegLocator.isAvailable(environment: env))
    }

    func test_installHint_isSharedPhrasing() {
        // The one hint string flows into the action message (single source).
        XCTAssertTrue(FFmpegGuidance.unavailableMessage(action: "x")
            .contains(FFmpegGuidance.installHint))
    }
}
