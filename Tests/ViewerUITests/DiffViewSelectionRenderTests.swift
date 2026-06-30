import AppKit
import SwiftUI
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-910: the multi-line commit-diff selection HIGHLIGHT actually renders.
/// DiffView tints a selected row with `Color.accentColor.opacity(0.20)`
/// (DiffView.swift, gated by `isRowSelected` → `DiffLineSelection.contains`).
///
/// This host test renders `scrollBody` WITH vs WITHOUT a seeded row selection
/// via `ImageRenderer` and asserts the two differ over a non-trivial region —
/// i.e. the selection visibly tints the selected rows. The view is pure SwiftUI
/// (no representable), so ImageRenderer is a faithful oracle for the tint (same
/// rationale as DiffViewLayoutTests). TEETH: if the highlight stopped rendering
/// (isRowSelected mis-wired, the `.background` dropped, the seam not honored),
/// the two renders would be identical and `differing` collapses to 0.
///
/// The selection/copy MODEL is host-tested in DiffLineSelectionTests; the only
/// untestable tail is the real pointer shift-click that drives the selection
/// (the AX tier).
@MainActor
final class DiffViewSelectionRenderTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffViewSel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DiffViewSel-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func makeDoc() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    /// One file, one hunk, three rows (flat indices 0,1,2).
    private let diff = """
    diff --git a/a.swift b/a.swift
    index 0000000..1111111 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -1,2 +1,3 @@
     let a = 1
    +let b = 2
     let c = 3
    """
    private let viewport = CGSize(width: 640, height: 480)

    /// Render scrollBody (files seeded via the test seam, optional row selection)
    /// to a top-origin RGBA8 pixel buffer.
    private func pixels(selection: DiffView.RowSelection?) throws -> [UInt8] {
        let files = RustDiffAdapter.parse(diff)
        let view = DiffView(
            text: diff, doc: makeDoc(), reviewSession: nil,
            initialFiles: files, initialSelection: selection
        ).scrollBody(viewport: viewport)
        let renderer = ImageRenderer(content: view.frame(
            width: viewport.width, height: viewport.height))
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.cgImage, "ImageRenderer must produce an image")
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    func test_selectionHighlight_rendersOverSelectedRows() throws {
        let none = try pixels(selection: nil)
        let sel = try pixels(selection: DiffView.RowSelection(
            fileIndex: 0, selection: DiffLineSelection(anchor: 0, focus: 2)))
        XCTAssertEqual(none.count, sel.count, "same canvas size")

        var differing = 0
        var i = 0
        while i < none.count {
            if none[i] != sel[i] { differing += 1 }
            i += 4   // one channel per pixel is enough to detect the tint
        }
        // The 3 selected rows tinted accentColor@0.20 ⇒ a substantial delta.
        XCTAssertGreaterThan(differing, 200,
            "a row selection must visibly tint the selected rows (got \(differing) changed pixels)")
    }
}
