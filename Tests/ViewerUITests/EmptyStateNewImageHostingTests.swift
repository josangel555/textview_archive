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
        // The "New Image" Button bridges to an NSButton — find it by title OR its AX id (either
        // surfacing is sufficient proof it rendered).
        let hasNewImage = buttons.contains {
            $0.title == "New Image" || $0.accessibilityIdentifier() == "mdv.emptyState.newImage"
        }
        XCTAssertTrue(hasNewImage,
            "the New-Tab landing must render a 'New Image' button (TSK-1306); found: "
            + "\(buttons.map { ($0.title, $0.accessibilityIdentifier()) })")
        // Sanity: the pre-existing "New File" button is still there too (the action row rendered).
        let hasNewFile = buttons.contains {
            $0.title == "New File" || $0.accessibilityIdentifier() == "mdv.emptyState.newFile"
        }
        XCTAssertTrue(hasNewFile, "the New File button must still render alongside New Image")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
