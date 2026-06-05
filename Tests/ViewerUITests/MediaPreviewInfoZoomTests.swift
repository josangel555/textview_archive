import XCTest
@testable import ViewerUI

/// TSK-271: the media preview info chrome — image dimensions / sibling counter /
/// zoom %, and the unsupported-file metadata card — must scale with the unified
/// UI zoom instead of staying hard-wired at 11pt. All of that sizing routes
/// through `MediaPreviewView.infoFontSize(uiScale:)`, so this asserts the scaling
/// contract directly (the views just multiply through it). Pure value math —
/// host-headless, no view hosting.
final class MediaPreviewInfoZoomTests: XCTestCase {
    func test_infoFontSize_isBase11AtUnityZoom() {
        XCTAssertEqual(MediaPreviewView.infoFontSize(uiScale: 1.0), 11, accuracy: 0.0001)
    }

    func test_infoFontSize_scalesLinearlyWithZoom() {
        XCTAssertEqual(MediaPreviewView.infoFontSize(uiScale: 2.0), 22, accuracy: 0.0001)
        XCTAssertEqual(MediaPreviewView.infoFontSize(uiScale: 0.5), 5.5, accuracy: 0.0001)
        XCTAssertEqual(MediaPreviewView.infoFontSize(uiScale: 1.5), 16.5, accuracy: 0.0001)
    }
}
