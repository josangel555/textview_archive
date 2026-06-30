import XCTest
import AppKit
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-1323/1324 (slice 2) — render-validation of the Audio Extract/Convert panel: the format
/// picker renders as an NSPopUpButton carrying the encodable audio formats (WAV/AIFF/CAF/AAC/MP3).
/// In-process NSHostingView — the SettingsView / image-convert picker pattern.
///
/// `#192`-gated (VM GUI lane — SwiftUI realizes its controls there).
@MainActor
final class AudioConvertHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
    }

    func test_audioPanel_rendersFormatPicker_withEncodableFormats() async throws {
        let vm = AudioConvertViewModel(sourceURL: URL(fileURLWithPath: "/tmp/clip.mp4"), dropVideo: true)
        let host = NSHostingView(rootView: AudioConvertView(
            vm: vm, onConverted: { _ in }, onClose: {}))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        // Two NSPopUpButtons render (format + bit rate for the lossy default); the FORMAT picker is
        // the one carrying the format labels.
        let popups = Self.descendants(of: host).compactMap { $0 as? NSPopUpButton }
        let hasFormatPicker = popups.contains { pb in
            let titles = pb.itemTitles
            return titles.contains("WAV") && titles.contains("MP3")
                && titles.contains(where: { $0.contains("AAC") })
        }
        XCTAssertTrue(hasFormatPicker,
            "the audio panel must render a format picker with the encodable formats "
            + "(WAV/AIFF/CAF/AAC/MP3). Popups found: \(popups.map(\.itemTitles))")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
