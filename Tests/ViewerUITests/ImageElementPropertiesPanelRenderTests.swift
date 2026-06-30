import AppKit
import XCTest
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ViewerCore
@testable import ViewerUI

/// TSK-1321 — non-T5 render guard for the element-properties inspector. When an overlay shape is
/// selected, ImageElementPropertiesPanel must render its edit controls (the stroke ColorPicker
/// bridges to a concrete NSColorWell); with nothing selected it must render NOTHING (so composing it
/// unconditionally into the editor's controls column is safe). This is the in-process proof that the
/// non-AX edit-after-placement path renders + is selection-gated; the on-canvas drag is the AX tier.
/// `#192`-gated (in-process NSHostingView needs the GUI session); webview lane.
@MainActor
final class ImageElementPropertiesPanelRenderTests: WebViewTestCase {

    private var hosted: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hosted)
        hosted.removeAll()
    }

    private func solidPNG(width: Int, height: Int) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func host(_ vm: ImageEditorViewModel) -> NSView {
        let h = NSHostingView(rootView: ImageElementPropertiesPanel(vm: vm))
        h.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        let window = NSWindow(contentRect: h.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = h
        hosted.append(h)
        h.layoutSubtreeIfNeeded()
        return h
    }

    private func containsColorWell(_ v: NSView) -> Bool {
        if v is NSColorWell { return true }
        return v.subviews.contains { containsColorWell($0) }
    }

    private func containsEditableField(_ v: NSView) -> Bool {
        if let tf = v as? NSTextField, tf.isEditable { return true }
        return v.subviews.contains { containsEditableField($0) }
    }

    func test_textShape_rendersEditableTextField_TSK1310() async throws {
        let vm = ImageEditorViewModel(ImageDocument(data: try solidPNG(width: 20, height: 16)))
        _ = vm.addShape(VectorShape(
            kind: .text, frame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.12),
            style: ShapeStyle(stroke: .red, lineWidth: 1), text: "Hi", fontSize: 0.06))
        vm.selectLatestShape()
        XCTAssertEqual(vm.selectedShape?.kind, .text, "precondition: a .text shape is selected")
        XCTAssertTrue(containsEditableField(host(vm)),
            "the inspector must render an editable text field for a selected .text shape (TSK-1310)")
    }

    func test_inspector_rendersForSelectedShape_hiddenOtherwise_TSK1321() async throws {
        // With a selected shape → the edit controls (stroke ColorPicker → NSColorWell) render.
        let selected = ImageEditorViewModel(ImageDocument(data: try solidPNG(width: 20, height: 16)))
        _ = selected.drawShape(.rect, normalizedFrame: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.5))
        selected.selectLatestShape()
        XCTAssertNotNil(selected.selectedShape, "precondition: a shape is selected")
        XCTAssertTrue(containsColorWell(host(selected)),
            "the inspector must render its edit controls (stroke ColorPicker) for a selected shape")

        // With nothing selected → the inspector renders nothing.
        let empty = ImageEditorViewModel(ImageDocument(data: try solidPNG(width: 20, height: 16)))
        XCTAssertNil(empty.selectedShape, "precondition: no selection")
        XCTAssertFalse(containsColorWell(host(empty)),
            "the inspector must be selection-gated — no controls when nothing is selected")
    }
}
