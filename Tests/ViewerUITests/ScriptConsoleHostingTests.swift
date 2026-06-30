import XCTest
import AppKit
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-698 slice 3b — VM render-validation of the Script Console panel. Hosts
/// `ScriptConsoleView` in a real `NSHostingView` inside a real `NSWindow`, forces layout,
/// and walks the resulting NSView hierarchy to prove the panel actually RENDERS its controls
/// (not blank / collapsed / occluded) — the render confirmation the host model tests can't
/// give. The run/error/timeout BEHAVIOR is host-tested in `ScriptConsoleViewModelTests`;
/// this is the pixels-side complement, in-process so it sidesteps the spawned-app
/// framebuffer bug (TSK-1247).
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM/nightly lane) — skips in the bare host sweep.
@MainActor
final class ScriptConsoleHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()   // #192: VM/nightly only
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
    }

    func test_panel_runsModel_andRendersControls() async throws {
        // Drive the model so the panel has real output to render.
        let vm = ScriptConsoleViewModel(inputContent: "[1,2,3]")
        vm.expression = "input.map(x => x * 2)"
        await vm.run()
        XCTAssertEqual(vm.output, "[\n  2,\n  4,\n  6\n]", "the console model must run the expression")

        // Host the SwiftUI panel in a real window + force layout.
        let host = NSHostingView(rootView: ScriptConsoleView(vm: vm, onApply: { _ in }, onClose: {}))
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        // The panel must occupy real space …
        XCTAssertGreaterThan(host.frame.width, 0)
        XCTAssertGreaterThan(host.frame.height, 0)

        // … and render its controls. NOTE (VM-confirmed): a SwiftUI Button bridges to an
        // NSButton whose `.title` is EMPTY (the label is a SwiftUI subview, not the cell
        // title), so assert on the control STRUCTURE, not titles. A blank / collapsed /
        // occluded panel would have none of these.
        let descendants = Self.descendants(of: host)
        let buttonCount = descendants.compactMap { $0 as? NSButton }.count
        let hasPicker = descendants.contains { $0 is NSSegmentedControl }
        let hasField = descendants.contains { $0 is NSTextField }
        XCTAssertGreaterThanOrEqual(buttonCount, 2,
            "the console panel must render its action buttons (Run / Apply / Close); got \(buttonCount)")
        XCTAssertTrue(hasPicker || hasField,
            "the console panel must render its format picker and/or expression field")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
