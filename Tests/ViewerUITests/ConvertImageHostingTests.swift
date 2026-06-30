import XCTest
import AppKit
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-1325 (slice 2) — render-validation of the Image Convert panel: the format picker renders as
/// an NSPopUpButton carrying the encodable formats (PNG/JPEG/HEIC/BMP/GIF/TIFF). In-process
/// NSHostingView (the panel is a standalone view) — the SettingsView picker pattern.
///
/// `#192`-gated (VM GUI lane — SwiftUI realizes its controls there).
@MainActor
final class ConvertImageHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
    }

    func test_convertPanel_rendersFormatPicker_withEncodableFormats() async throws {
        let vm = ConvertImageViewModel(sourceURL: URL(fileURLWithPath: "/tmp/example.png"))
        let host = NSHostingView(rootView: ConvertImageView(
            vm: vm, onConverted: { _ in }, onClose: {}))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        // The `.menu` Picker bridges to an NSPopUpButton whose item titles are the format labels.
        let popups = Self.descendants(of: host).compactMap { $0 as? NSPopUpButton }
        let hasFormatPicker = popups.contains { pb in
            let titles = pb.itemTitles
            return titles.contains("PNG") && titles.contains("JPEG") && titles.contains("TIFF")
        }
        XCTAssertTrue(hasFormatPicker,
            "the Convert panel must render a format picker with the encodable formats "
            + "(PNG/JPEG/HEIC/BMP/GIF/TIFF). Popups found: \(popups.map(\.itemTitles))")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
