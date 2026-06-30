import XCTest
import AppKit
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-1141 — VM render-validation of the multi-sheet sheet-tab strip. Hosts
/// `SpreadsheetView` (a 2-sheet file) in a real `NSHostingView`/`NSWindow`, forces
/// layout, and walks the NSView hierarchy to prove the view renders a non-blank
/// hierarchy with a scroll container (the horizontal sheet-tab strip + the grid are
/// both ScrollViews) — i.e. the wrapper isn't blank/collapsed/crashed. The sheet
/// SWITCH logic is host-tested in TextFileMultiSheetTests (withActiveSheet); this is
/// the pixels-side complement (mirrors TerminalCommandPaletteHostingTests). The view
/// is pure SwiftUI (no opaque representable), so the hosted render is faithful.
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM/nightly lane).
@MainActor
final class SpreadsheetViewHostingTests: WebViewTestCase {

    private var hosted: [NSView] = []
    private var tmp: URL!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetHost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
        // On host, setUp's skipUnlessEnabled() throws BEFORE tmp is set, so guard it.
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: UserDefaults(
                suiteName: "Sheet-\(UUID().uuidString)")!))
    }

    func test_spreadsheetView_rendersNonBlankWithTabStrip() async throws {
        let file = TextFile(
            url: tmp.appendingPathComponent("wb.xlsx"),
            contents: "a\tb\nc\td", encoding: .utf8, byteCount: 0,
            isExtractedReadOnly: true,
            xlsxSheets: [XLSXSheet(name: "Alpha", rows: [["a", "b"], ["c", "d"]]),
                         XLSXSheet(name: "Beta", rows: [["x", "y"]])])

        let host = NSHostingView(rootView:
            SpreadsheetView(file: file, model: makeModel(), tabID: UUID()))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        hosted.append(host)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.frame.width, 0)
        let descendants = Self.descendants(of: host)
        XCTAssertFalse(descendants.isEmpty,
            "SpreadsheetView must render a non-empty hierarchy (not blank / collapsed)")
        XCTAssertTrue(descendants.contains { $0 is NSScrollView },
            "a scroll container (the horizontal sheet-tab strip + the grid) must render")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
