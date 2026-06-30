import XCTest
import AppKit
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-1312 — render-validation of the terminal colour-scheme picker (the user-facing surface of
/// the "colors look off running claude code" fix). The theme LOGIC + pref wiring are host-tested
/// (AnsiTheme.named → theme-aware TerminalPalette; DocumentModel.terminalColorThemeName didSet);
/// this proves the Settings ▸ Terminal ▸ Colour scheme Picker actually RENDERS with the AnsiTheme
/// options (incl. "Classic (xterm)", the vivid-ANSI fix). In-process NSHostingView (SettingsView is
/// a flat single page) — the panel-hosting pattern.
///
/// `#192`-gated (VM GUI lane — SwiftUI realizes its controls there, per the other hosting suites).
@MainActor
final class SettingsTerminalColorSchemeHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []
    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsColorSchemeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SettingsColorSchemeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
    }

    @MainActor
    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    func test_settings_rendersTerminalColorSchemePicker_withThemeOptions() async throws {
        let model = makeModel()
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 1200)  // tall: all sections realize
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.frame.width, 0)
        // The colour-scheme Picker (.menu style) bridges to an NSPopUpButton whose item titles
        // are the AnsiTheme.builtIns names — assert one carries "Classic" (the vivid-ANSI fix).
        let popups = Self.descendants(of: host).compactMap { $0 as? NSPopUpButton }
        let hasColorScheme = popups.contains { pb in
            pb.itemTitles.contains { $0.localizedCaseInsensitiveContains("classic") }
        }
        XCTAssertTrue(hasColorScheme,
            "Settings ▸ Terminal ▸ Colour scheme must render a picker with the AnsiTheme options "
            + "(incl. Classic xterm). Popups found: \(popups.map(\.itemTitles))")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
