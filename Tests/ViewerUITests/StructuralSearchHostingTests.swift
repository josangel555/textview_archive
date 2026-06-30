import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1161 — VM render-validation of the Structural Search panel. Hosts
/// `StructuralSearchView` in a real `NSHostingView`/`NSWindow`, forces layout, and walks
/// the NSView hierarchy to prove the panel renders its controls + results (not blank /
/// collapsed). In-process → sidesteps the spawned-app framebuffer bug (TSK-1247). The
/// query/parse/search BEHAVIOR is host-tested in StructuralSearchViewModelTests; this is the
/// pixels-side complement (same pattern as ScriptConsoleHostingTests, TSK-698).
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM/nightly lane).
@MainActor
final class StructuralSearchHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
    }

    func test_panel_runsSearch_andRendersControls() async throws {
        let vm = StructuralSearchViewModel(
            inputText: "func greet() { }\nfunc add() { }", language: .swift)
        vm.query = "function_declaration"
        vm.run()
        XCTAssertEqual(vm.matches.count, 2, "the structural search must run (2 funcs)")

        let host = NSHostingView(rootView: StructuralSearchView(vm: vm, onJump: nil, onClose: {}))
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.frame.width, 0)
        // Assert on control STRUCTURE (SwiftUI Button.title is empty — see
        // ScriptConsoleHostingTests). A blank/collapsed panel would have none.
        let descendants = Self.descendants(of: host)
        XCTAssertGreaterThanOrEqual(descendants.compactMap { $0 as? NSButton }.count, 1,
            "the panel must render its Search/Close buttons (+ result rows)")
        XCTAssertTrue(descendants.contains { $0 is NSTextField },
            "the panel must render its query field")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
