import XCTest
import AppKit
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-1306 — render-validation that the New-Tab landing offers a "New Image" entry point (the
/// owner-reported gap: the action + BlankImageCreator existed + were host-tested, but the landing
/// empty-state had no Image button). The button's wired closure (newBlankImageForLanding -> valid
/// blank PNG) is host-tested; this proves the BUTTON actually renders in EmptyStateView.
///
/// `#192`-gated (VM GUI lane — SwiftUI realizes its controls there, per the other hosting suites).
@MainActor
final class EmptyStateNewImageHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []
    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyStateNewImageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "EmptyStateNewImageTests-\(UUID().uuidString)"
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

    func test_emptyState_rendersNewImageButton_TSK1306() async throws {
        let model = makeModel()
        let host = NSHostingView(rootView: EmptyStateView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        let buttons = Self.descendants(of: host).compactMap { $0 as? NSButton }
        // SwiftUI Buttons bridge to NSButtons but expose neither their title nor their
        // .accessibilityIdentifier in the hosted NSView tree (verified on the VM: 4 × ("","")) —
        // only a `.menu` Picker carries identity (NSPopUpButton). So match by COUNT: the landing
        // action row is New File · New Image · Open File · Open Folder = 4; before TSK-1306 it was 3
        // (no New Image). With no recents (→ no recent-row buttons), 4 proves New Image was added.
        XCTAssertEqual(buttons.count, 4,
            "the New-Tab landing action row must render 4 buttons incl. the new 'New Image' "
            + "(TSK-1306; was 3 before the fix). Count: \(buttons.count)")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
