import XCTest
import AppKit
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-1160 — VM render-validation of the Task Runner panel. Hosts `TaskRunnerView` in a real
/// `NSHostingView`/`NSWindow`, forces layout, and walks the NSView hierarchy to prove the
/// panel renders its controls + task list (not blank / collapsed). In-process → sidesteps the
/// spawned-app framebuffer bug (TSK-1247). The discover/run BEHAVIOR is host-tested in
/// TaskRunnerViewModelTests; this is the pixels-side complement (ScriptConsoleHostingTests pattern).
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM/nightly lane).
@MainActor
final class TaskRunnerHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
    }

    func test_panel_rendersControlsAndTaskList() async throws {
        let vm = TaskRunnerViewModel()
        // Seed a discovered task so the list (not the empty placeholder) renders.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskRunnerHost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try #"{"scripts":{"test":"echo hi"}}"#
            .write(to: tmp.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        vm.discover(at: tmp)
        XCTAssertFalse(vm.tasks.isEmpty, "discovery must seed the list")

        let host = NSHostingView(rootView: TaskRunnerView(vm: vm, onClose: {}))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 440)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.frame.width, 0)
        // Assert on control STRUCTURE (SwiftUI Button.title is empty — see
        // ScriptConsoleHostingTests). A blank/collapsed panel would have neither.
        let descendants = Self.descendants(of: host)
        XCTAssertGreaterThanOrEqual(descendants.compactMap { $0 as? NSButton }.count, 1,
            "the panel must render its Run/Close buttons")
        XCTAssertTrue(descendants.contains { $0 is NSScrollView },
            "the panel must render its task list / output scroll view")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
