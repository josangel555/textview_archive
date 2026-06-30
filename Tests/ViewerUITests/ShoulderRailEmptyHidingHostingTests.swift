import XCTest
import AppKit
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-1316 — render-validation that an EMPTY shoulder bar is hidden unless a drag is active (user
/// bug: empty shoulder bars always showed a bare strip). ShoulderRailView now drops its content
/// (the `if hasContent || isDraggingPanel` gate) for an empty, non-dragging rail. Proven by the
/// rendered NSView count: an empty rail (the right edge — v1 docks all panels left) renders nothing
/// when not dragging and reveals its strip when dragging; the left rail always renders (it carries
/// the terminal toggle).
///
/// `#192`-gated (VM GUI lane — SwiftUI realizes its views there, per the other hosting suites).
@MainActor
final class ShoulderRailEmptyHidingHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []
    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoulderRailEmptyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ShoulderRailEmptyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history-\(UUID().uuidString).json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    private func railViewCount(_ model: DocumentModel, edge: PanelEdge, dragging: Bool) -> Int {
        let host = NSHostingView(rootView: ShoulderRailView(
            edge: edge, panelLayout: model.panelLayout, sidebar: model.sidebar,
            model: model, terminalPane: model.terminalPane, isDraggingPanel: dragging))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()
        return Self.descendants(of: host).count
    }

    func test_emptyShoulder_hiddenUnlessDragging_TSK1316() async throws {
        let model = makeModel()
        // The right rail has no docked panels in v1 → empty.
        let hidden = railViewCount(model, edge: .right, dragging: false)
        let shown = railViewCount(model, edge: .right, dragging: true)
        XCTAssertGreaterThan(shown, hidden,
            "an empty shoulder must be HIDDEN when idle and REVEAL while dragging (TSK-1316); "
            + "idle=\(hidden) dragging=\(shown)")
    }

    func test_leftShoulder_alwaysRenders_evenWithoutDrag() async throws {
        let model = makeModel()
        // The left rail always carries the terminal toggle → never hidden.
        let left = railViewCount(model, edge: .left, dragging: false)
        XCTAssertGreaterThan(left, 0,
            "the left rail must always render (it carries the terminal toggle), even with no panels")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
