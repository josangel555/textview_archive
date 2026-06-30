import XCTest
import AppKit
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-1176 — VM render-validation of the Terminal Command Palette panel. Hosts
/// `TerminalCommandPaletteView` in a real `NSHostingView`/`NSWindow`, forces layout, and
/// walks the NSView hierarchy to prove the panel renders its query field + result list (not
/// blank / collapsed). In-process → sidesteps the spawned-app framebuffer bug (TSK-1247). The
/// query/filter/selection BEHAVIOR is host-tested in TerminalCommandPaletteViewModelTests;
/// this is the pixels-side complement (ScriptConsoleHostingTests pattern).
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM/nightly lane).
@MainActor
final class TerminalCommandPaletteHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
    }

    func test_panel_rendersQueryFieldAndResults() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermPaletteHost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fav = TerminalFavoritesStore(storeURL: tmp.appendingPathComponent("fav.json"))
        let hist = TerminalCommandHistory(storeURL: tmp.appendingPathComponent("hist.json"))
        _ = hist.record("npm test")
        _ = hist.record("git status")
        let vm = TerminalCommandPaletteViewModel(favorites: fav, history: hist)
        XCTAssertFalse(vm.results.isEmpty, "seed the result list")

        let host = NSHostingView(rootView:
            TerminalCommandPaletteView(vm: vm, onInsert: { _ in }, onClose: {}))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.frame.width, 0)
        let descendants = Self.descendants(of: host)
        XCTAssertTrue(descendants.contains { $0 is NSTextField },
            "the palette must render its query field")
        XCTAssertTrue(descendants.contains { $0 is NSScrollView },
            "the palette must render its results list")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
