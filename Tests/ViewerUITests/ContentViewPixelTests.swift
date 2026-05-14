import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Tier 1m+ pixel-sample tests. Hosts `ContentView` in `NSHostingView`,
/// renders into an `NSBitmapImageRep` via `cacheDisplay(in:to:)`, then
/// asserts that **non-background pixels exist** in regions where TabBar,
/// ModeBar, and the content area should be rendering.
///
/// Catches the class of bug where the view tree is structurally present
/// but visually empty — i.e. "the user sees only line numbers". Unlike
/// `ContentViewHostingTests` (which verifies NSView frames), this layer
/// verifies that something is actually drawn into those frames.
@MainActor
final class ContentViewPixelTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentViewPixelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ContentViewPixelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpDir.appendingPathComponent("history.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Renders a SwiftUI view to an `NSBitmapImageRep` via `ImageRenderer`
    /// (the modern macOS 13+ SwiftUI snapshot API). `cacheDisplay`-based
    /// capture returns a transparent bitmap for layer-backed SwiftUI
    /// content; `ImageRenderer` walks the SwiftUI hierarchy directly.
    private func render<V: View>(_ view: V, size: NSSize) -> NSBitmapImageRep? {
        _ = NSApplication.shared
        let renderer = ImageRenderer(
            content: view.frame(width: size.width, height: size.height)
        )
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = 1.0
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    /// Counts pixels within `region` (in the rep's own pixel coordinates)
    /// whose color is *not* one of the system background colors. Stride of
    /// 5 px keeps the sample cheap.
    private func nonBackgroundPixels(in rep: NSBitmapImageRep, region: NSRect) -> Int {
        let xMin = max(0, Int(region.minX))
        let xMax = min(rep.pixelsWide, Int(region.maxX))
        let yMin = max(0, Int(region.minY))
        let yMax = min(rep.pixelsHigh, Int(region.maxY))
        var count = 0
        for y in stride(from: yMin, to: yMax, by: 5) {
            for x in stride(from: xMin, to: xMax, by: 5) {
                if let color = rep.colorAt(x: x, y: y),
                   !ContentViewPixelTests.isBackground(color) {
                    count += 1
                }
            }
        }
        return count
    }

    /// True when the color is close to one of the system background colors
    /// (window / control / text background, light or dark variant) or
    /// transparent. Tolerance covers anti-aliasing fringe.
    private static func isBackground(_ color: NSColor) -> Bool {
        guard let srgb = color.usingColorSpace(.sRGB) else { return false }
        // Effectively-transparent pixels read as background to us.
        if srgb.alphaComponent < 0.05 { return true }
        // Very light (light-mode bg) or very dark (dark-mode bg) flat color.
        let r = srgb.redComponent, g = srgb.greenComponent, b = srgb.blueComponent
        let nearWhite = r > 0.92 && g > 0.92 && b > 0.92
        let nearBlack = r < 0.18 && g < 0.18 && b < 0.18
        let nearGray = abs(r - g) < 0.04 && abs(g - b) < 0.04 && (r > 0.85 || r < 0.25)
        return nearWhite || nearBlack || nearGray
    }

    // MARK: Per-region assertions

    func test_openXML_rendersInkInTabBarAndContentRegions() throws {
        let model = makeModel()
        // Wide-ish XML content so the source view has text to draw.
        let xml = (0..<12)
            .map { "  <line index=\"\($0)\"/>" }
            .joined(separator: "\n")
        let url = try writeFile("ink.xml", "<root>\n\(xml)\n</root>\n")
        model.open(url: url)

        let size = NSSize(width: 1000, height: 700)
        guard let rep = render(ContentView(model: model), size: size) else {
            return XCTFail("Failed to render ContentView into bitmap")
        }

        // The bitmap is in pixel coordinates; on Retina it's 2× the points.
        let scaleY = CGFloat(rep.pixelsHigh) / size.height
        let scaleX = CGFloat(rep.pixelsWide) / size.width
        func region(_ pts: NSRect) -> NSRect {
            NSRect(x: pts.minX * scaleX, y: pts.minY * scaleY,
                   width: pts.width * scaleX, height: pts.height * scaleY)
        }

        // NSView coordinates flip Y depending on isFlipped. NSHostingView
        // is flipped (top-left origin), but bitmapImageRepForCachingDisplay
        // captures using NSView geometry — sample positions cover the top
        // ~30pt strip (TabBar) and a middle band (source content).
        let tabBarRegionPts = NSRect(x: 0, y: 0, width: size.width, height: 30)
        let contentRegionPts = NSRect(
            x: 80, y: size.height * 0.4,
            width: 400, height: size.height * 0.3
        )

        let tabInk = nonBackgroundPixels(in: rep, region: region(tabBarRegionPts))
        let contentInk = nonBackgroundPixels(in: rep, region: region(contentRegionPts))

        XCTAssertGreaterThan(
            tabInk + contentInk, 20,
            "Rendered ContentView should contain non-background pixels in TabBar+content. Got tab=\(tabInk), content=\(contentInk)"
        )
    }

    func test_emptyState_rendersAtLeastTheEmptyStateMessage() throws {
        let model = makeModel()
        // No file open — should render EmptyStateView with the doc.text icon
        // and the "No file open" label. Either contributes ink pixels.
        let size = NSSize(width: 800, height: 600)
        guard let rep = render(ContentView(model: model), size: size) else {
            return XCTFail("Failed to render")
        }
        let scaleX = CGFloat(rep.pixelsWide) / size.width
        let scaleY = CGFloat(rep.pixelsHigh) / size.height
        let centerRegionPts = NSRect(
            x: size.width * 0.25, y: size.height * 0.25,
            width: size.width * 0.5, height: size.height * 0.5
        )
        let centerRegion = NSRect(
            x: centerRegionPts.minX * scaleX, y: centerRegionPts.minY * scaleY,
            width: centerRegionPts.width * scaleX,
            height: centerRegionPts.height * scaleY
        )
        let ink = nonBackgroundPixels(in: rep, region: centerRegion)
        XCTAssertGreaterThan(ink, 10, "EmptyStateView should draw ink in the center region")
    }
}
