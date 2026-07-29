import XCTest
import UniformTypeIdentifiers
@testable import ViewerUI

/// TSK-284 (owner choice (a)) — drag files OUT of the app. The physical
/// drag session is the live glance; these pin the data layer (what the
/// provider REGISTERS — the part that decides whether Finder copies a
/// file or drops a dead link) and the wiring (source pins).
@MainActor
final class FileDragProviderTests: HeadlessUITestCase {

    private func tempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDragProviderTests-\(UUID().uuidString).txt")
        try Data("drag me".utf8).write(to: url)
        return url
    }

    func test_make_registersTheFileURLRepresentation() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = FileDragProvider.make(for: url)
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            "Finder needs public.file-url to COPY a file — got: "
            + "\(provider.registeredTypeIdentifiers)")
    }

    func test_make_missingFile_stillCarriesTheURL_neverCrashes() {
        let gone = URL(fileURLWithPath: "/tmp/FileDragProviderTests-no-such-\(UUID()).txt")
        let provider = FileDragProvider.make(for: gone)
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            "the fallback registration must still carry the file reference")
    }

    /// Wiring pins (the TSK-561 dead-channel idiom): the drag-out sources
    /// actually attach the provider — and the tab strips actually reorder.
    func test_dragSources_areWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ rel: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
        }
        let sidebar = try source("Sources/ViewerUI/SidebarView.swift")
        XCTAssertEqual(
            sidebar.components(separatedBy: "FileDragProvider.make(for:").count - 1, 2,
            "both the tree row and the filter row must be drag-out sources")

        // Both strips reorder by DRAG GESTURE.
        for rel in ["Sources/ViewerUI/TabBar.swift",
                    "Sources/ViewerUI/Sessions/SessionTabBar.swift"] {
            let strip = try source(rel)
            XCTAssertTrue(strip.contains(".stripReorderable("),
                          "\(rel) must wire drag-to-reorder")
            XCTAssertTrue(strip.contains("StripInsertionCaret"),
                          "\(rel) must show WHERE the drag will land — an "
                          + "invisible reorder reads as 'not supported'")
        }
    }

    /// REGRESSION GUARD for the 2026-07-27 symptom ("dragging a tab acts
    /// like dragging a file; the window tries to open it"). An `.onDrag`
    /// on a tab registers `public.file-url`, so the drag reads as a FILE
    /// drag and the window-level `.onDrop(of: [.fileURL])` in ContentView
    /// catches it — which also means the reorder never happens. The strips
    /// must own their pointer via the gesture instead.
    func test_tabStrips_doNotReintroduceAFileDrag() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for rel in ["Sources/ViewerUI/TabBar.swift",
                    "Sources/ViewerUI/Sessions/SessionTabBar.swift"] {
            let strip = try String(contentsOf: root.appendingPathComponent(rel),
                                   encoding: .utf8)
            XCTAssertFalse(strip.contains(".onDrag {"),
                           "\(rel): an .onDrag on a tab turns a reorder into a "
                           + "file drag the window opens — reorder via the "
                           + "gesture, and add tear-off deliberately if wanted")
            XCTAssertFalse(strip.contains("NSItemProvider"),
                           "\(rel): the pasteboard round-trip was removed; "
                           + "reorder geometry lives in StripReorder")
        }
    }
}
