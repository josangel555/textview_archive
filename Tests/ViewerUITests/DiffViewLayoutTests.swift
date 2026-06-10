import AppKit
import SwiftUI
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-593: a two-axis ScrollView centers content smaller than its viewport,
/// so a short diff floated mid-pane instead of pinning top-left like every
/// other panel.
///
/// Oracle: `ImageRenderer` over the pure-SwiftUI tree. CLAUDE.md bans
/// ImageRenderer as proof of ON-SCREEN VISIBILITY (it draws placeholders for
/// representables, so compositor occlusion can't be seen) — but this view has
/// no representable and the claim under test is SwiftUI LAYOUT GEOMETRY
/// (where does the content land inside the proposed viewport), which
/// ImageRenderer computes with the real layout engine. A window-free
/// NSHostingView frame-walk was tried first and is blind here: SwiftUI-drawn
/// rows never realize as NSViews.
@MainActor
final class DiffViewLayoutTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffViewLayout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DiffViewLayout-\(UUID().uuidString)"
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

    /// One file, one hunk, three lines — far smaller than the 640×480
    /// viewport, so the broken (centering) layout floats it mid-pane.
    private let shortDiff = """
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

    /// Render the scroll CONTENT (files seeded via the test seam, no
    /// .onAppear dependency; ScrollView itself is opaque to ImageRenderer)
    /// and return the bounding box of non-transparent pixels — i.e. where
    /// the layout actually put the content within the viewport-sized frame.
    private func contentBounds() throws -> CGRect {
        let view = DiffView(
            text: shortDiff, doc: makeDoc(), reviewSession: nil,
            initialFiles: DiffParser.parse(shortDiff)
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

        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 16 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return .null }
        // Drawing a CGImage into a CGBitmapContext lands image row 0 in the
        // FIRST buffer row — the buffer is already top-origin, so minY is
        // the distance from the viewport's top edge as-is.
        return CGRect(x: minX, y: minY,
                      width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func test_shortDiff_pinsTopLeft_notCentered() throws {
        let bounds = try contentBounds()
        XCTAssertFalse(bounds.isNull, "diff content must render some pixels")

        // Fixed layout: content starts within the stack's own padding
        // (~8-16pt). Broken (centered) layout: a ~150pt-tall diff in a
        // 480pt viewport floats ~150pt+ down; its block also centers
        // horizontally well off the left edge.
        XCTAssertLessThan(bounds.minY, 80,
            "short diff must pin to the top, not float centered (top=\(bounds.minY))")
        XCTAssertLessThan(bounds.minX, 80,
            "short diff must pin to the leading edge (left=\(bounds.minX))")
    }

    func test_shortDiff_rendersHunkContent_notEmptyState() throws {
        // Guard that the assertion above exercised the REAL content branch:
        // the parsed-diff block (header + line-number gutters + code rows)
        // is far wider than anything the empty state draws.
        let bounds = try contentBounds()
        XCTAssertGreaterThan(bounds.width, 200,
            "expected the parsed diff block to render (got \(bounds))")
        XCTAssertGreaterThan(bounds.height, 80,
            "expected header + hunk rows to render (got \(bounds))")
    }
}
