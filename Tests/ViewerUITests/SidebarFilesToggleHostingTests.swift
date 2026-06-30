import XCTest
import AppKit
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-1314 — render-validation that the file-nav tree respects its `.files` shoulder toggle (the
/// user bug: the tree stayed visible with the toggle OFF). The visibility LOGIC is host-tested
/// (SidebarFilesVisibilityTests: .hidden ⇒ not visible); SidebarView gates `filesPanel` on
/// `filesPanelVisible` (line 162). This proves the VIEW actually drops the filesPanel subtree when
/// the override is `.hidden` vs `.shown` — measured by the rendered NSView count (the filesPanel
/// contributes views; SwiftUI .accessibilityIdentifier on a Text doesn't reliably surface as a
/// walkable NSView id, so a count delta is the reliable signal).
///
/// `#192`-gated (VM GUI lane — SwiftUI realizes its views there, per the other hosting suites).
@MainActor
final class SidebarFilesToggleHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []
    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarFilesToggleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SidebarFilesToggleTests-\(UUID().uuidString)"
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

    private func hostSidebarViewCount(_ model: DocumentModel) -> Int {
        let host = NSHostingView(rootView: SidebarView(
            sidebar: model.sidebar, model: model,
            trackedRepos: model.trackedRepos, panelLayout: model.panelLayout))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()
        return Self.descendants(of: host).count
    }

    func test_fileTree_respectsTheFilesShoulderToggle() async throws {
        let model = makeModel()
        model.panelLayout.setOverride(.files, .shown)
        let shownCount = hostSidebarViewCount(model)
        model.panelLayout.setOverride(.files, .hidden)
        let hiddenCount = hostSidebarViewCount(model)
        XCTAssertGreaterThan(shownCount, hiddenCount,
            "the file-nav tree must drop its views when .files=.hidden vs .shown (TSK-1314: the "
            + "tree must respect its shoulder toggle); shown=\(shownCount) hidden=\(hiddenCount)")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
