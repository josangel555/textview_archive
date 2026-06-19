import CoreGraphics
import Foundation
import XCTest
@testable import ViewerCore

/// T1 headless tests for the multi-layer image document model (TSK-286).
/// Pure value-model logic — composite order, opacity/visibility flags, stack
/// mutation, and the own JSON format round-trip — so it carries REAL host teeth
/// (no window, no Core Image render needed for any assertion here).
final class LayeredImageDocumentTests: XCTestCase {

    // MARK: - Fixtures

    /// A trivially-distinct `ImageLayer` for stack tests; the wrapped document
    /// references a `.data` source so equality/serialization are deterministic
    /// without touching the filesystem.
    private func makeLayer(
        name: String,
        opacity: Double = 1,
        visible: Bool = true,
        blend: LayerBlendMode = .normal,
        seed: UInt8 = 0
    ) -> ImageLayer {
        let doc = ImageDocument(data: Data([seed, seed &+ 1, seed &+ 2]))
        return ImageLayer(name: name, document: doc,
                          opacity: opacity, isVisible: visible, blendMode: blend)
    }

    // MARK: - Composite order (stacking convention: [0] = bottom, [last] = top)

    func testCompositeOrderIsBottomToTop() {
        let bottom = makeLayer(name: "bottom")
        let middle = makeLayer(name: "middle")
        let top = makeLayer(name: "top")
        let doc = LayeredImageDocument(canvasSize: CGSize(width: 10, height: 10),
                                       layers: [bottom, middle, top])
        XCTAssertEqual(doc.layers.map(\.name), ["bottom", "middle", "top"])
        // compositingLayers is the painting order — bottom first, top last.
        XCTAssertEqual(doc.compositingLayers.map(\.name), ["bottom", "middle", "top"])
    }

    func testAddingLayerPlacesItOnTop() {
        let a = makeLayer(name: "a")
        let b = makeLayer(name: "b")
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [a])
            .addingLayer(b)
        XCTAssertEqual(doc.layers.map(\.name), ["a", "b"])
        XCTAssertEqual(doc.layers.last?.name, "b", "added layer is the new top")
    }

    func testInsertingLayerClampsOutOfRangeIndex() {
        let a = makeLayer(name: "a")
        let b = makeLayer(name: "b")
        let base = LayeredImageDocument(canvasSize: .zero, layers: [a])
        let atBottom = base.insertingLayer(b, at: 0)
        XCTAssertEqual(atBottom.layers.map(\.name), ["b", "a"])
        let wayPastEnd = base.insertingLayer(b, at: 999)
        XCTAssertEqual(wayPastEnd.layers.map(\.name), ["a", "b"], "clamps to append")
        let negative = base.insertingLayer(b, at: -5)
        XCTAssertEqual(negative.layers.map(\.name), ["b", "a"], "clamps to bottom")
    }

    func testMoveUpDownReordersStack() {
        let a = makeLayer(name: "a")
        let b = makeLayer(name: "b")
        let c = makeLayer(name: "c")
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [a, b, c])

        let up = doc.movingLayerUp(a.id)        // a moves toward top
        XCTAssertEqual(up.layers.map(\.name), ["b", "a", "c"])

        let down = doc.movingLayerDown(c.id)    // c moves toward bottom
        XCTAssertEqual(down.layers.map(\.name), ["a", "c", "b"])
    }

    func testMoveUpAtTopAndDownAtBottomAreNoOps() {
        let a = makeLayer(name: "a")
        let b = makeLayer(name: "b")
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [a, b])
        XCTAssertEqual(doc.movingLayerUp(b.id), doc, "top layer can't move up")
        XCTAssertEqual(doc.movingLayerDown(a.id), doc, "bottom layer can't move down")
        let absent = UUID()
        XCTAssertEqual(doc.movingLayerUp(absent), doc, "absent id is a no-op")
    }

    func testMoveToExplicitIndexPreservesRelativeOrder() {
        let a = makeLayer(name: "a")
        let b = makeLayer(name: "b")
        let c = makeLayer(name: "c")
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [a, b, c])
        // Move bottom (a) to the top.
        let moved = doc.movingLayer(a.id, to: 2)
        XCTAssertEqual(moved.layers.map(\.name), ["b", "c", "a"])
        // Clamp past-end.
        let clamped = doc.movingLayer(a.id, to: 99)
        XCTAssertEqual(clamped.layers.map(\.name), ["b", "c", "a"])
    }

    func testRemovingLayer() {
        let a = makeLayer(name: "a")
        let b = makeLayer(name: "b")
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [a, b])
        XCTAssertEqual(doc.removingLayer(a.id).layers.map(\.name), ["b"])
        XCTAssertEqual(doc.removingLayer(UUID()), doc, "absent id is a no-op")
    }

    // MARK: - Opacity / visibility flags drive the composite set

    func testHiddenLayerExcludedFromComposite() {
        let visible = makeLayer(name: "v", visible: true)
        let hidden = makeLayer(name: "h", visible: false)
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [visible, hidden])
        XCTAssertEqual(doc.compositingLayers.map(\.name), ["v"])
        XCTAssertFalse(hidden.contributesToComposite)
        XCTAssertTrue(visible.contributesToComposite)
    }

    func testZeroOpacityLayerExcludedFromComposite() {
        let opaque = makeLayer(name: "o", opacity: 1)
        let transparent = makeLayer(name: "t", opacity: 0)
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [opaque, transparent])
        XCTAssertEqual(doc.compositingLayers.map(\.name), ["o"])
        XCTAssertFalse(transparent.contributesToComposite, "opacity 0 contributes nothing")
    }

    func testToggleVisibilityFlipsCompositeMembership() {
        let a = makeLayer(name: "a")
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [a])
        XCTAssertEqual(doc.compositingLayers.count, 1)
        let hidden = doc.togglingVisibility(a.id)
        XCTAssertTrue(hidden.compositingLayers.isEmpty)
        XCTAssertTrue(hidden.isEmpty)
        let shownAgain = hidden.togglingVisibility(a.id)
        XCTAssertEqual(shownAgain.compositingLayers.count, 1)
    }

    func testHidingPreservesOpacityWhileZeroOpacityDoesNotPreserveVisibility() {
        // Hiding a layer keeps its opacity, so toggling back restores the weight.
        let a = makeLayer(name: "a", opacity: 0.4, visible: true)
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [a])
        let hidden = doc.togglingVisibility(a.id)
        XCTAssertEqual(hidden.layers[0].opacity, 0.4, accuracy: 1e-9,
                       "hiding must not zero the opacity")
        let shown = hidden.togglingVisibility(a.id)
        XCTAssertEqual(shown.layers[0].opacity, 0.4, accuracy: 1e-9)
        XCTAssertTrue(shown.layers[0].isVisible)
    }

    func testOpacityClampedOnEveryMutationPath() {
        // init clamps
        let over = makeLayer(name: "x", opacity: 5)
        XCTAssertEqual(over.opacity, 1, accuracy: 1e-9)
        let under = makeLayer(name: "y", opacity: -2)
        XCTAssertEqual(under.opacity, 0, accuracy: 1e-9)
        // didSet clamps
        var m = over
        m.opacity = 2.5
        XCTAssertEqual(m.opacity, 1, accuracy: 1e-9)
        m.opacity = -0.5
        XCTAssertEqual(m.opacity, 0, accuracy: 1e-9)
        // settingOpacity routes through the clamp
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [makeLayer(name: "z")])
        let id = doc.layers[0].id
        XCTAssertEqual(doc.settingOpacity(3, of: id).layers[0].opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(doc.settingOpacity(-1, of: id).layers[0].opacity, 0, accuracy: 1e-9)
        XCTAssertEqual(doc.settingOpacity(0.5, of: id).layers[0].opacity, 0.5, accuracy: 1e-9)
    }

    func testNonFiniteOpacityCollapsesToBound() {
        XCTAssertEqual(ImageLayer.clampOpacity(.nan), 1, accuracy: 1e-9)
        XCTAssertEqual(ImageLayer.clampOpacity(.infinity), 1, accuracy: 1e-9)
        XCTAssertEqual(ImageLayer.clampOpacity(-.infinity), 0, accuracy: 1e-9)
    }

    func testReplacingLayerUpdatesMetadataById() {
        let a = makeLayer(name: "a", opacity: 1, blend: .normal)
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [a])
        var edited = a
        edited.name = "renamed"
        edited.blendMode = .multiply
        edited.opacity = 0.25
        let result = doc.replacingLayer(edited)
        XCTAssertEqual(result.layers[0].name, "renamed")
        XCTAssertEqual(result.layers[0].blendMode, .multiply)
        XCTAssertEqual(result.layers[0].opacity, 0.25, accuracy: 1e-9)
        // A replacement whose id isn't present is a no-op.
        let foreign = makeLayer(name: "foreign")
        XCTAssertEqual(doc.replacingLayer(foreign), doc)
    }

    // MARK: - Own document format: (de)serialize round-trip

    func testRoundTripPreservesEverything() throws {
        let l0 = makeLayer(name: "Background", opacity: 1, visible: true, blend: .normal, seed: 10)
        let l1 = makeLayer(name: "Overlay", opacity: 0.6, visible: false, blend: .multiply, seed: 20)
        let l2 = makeLayer(name: "Top", opacity: 0.33, visible: true, blend: .screen, seed: 30)
        let original = LayeredImageDocument(
            canvasSize: CGSize(width: 1920, height: 1080),
            layers: [l0, l1, l2])

        let data = try original.encoded()
        let restored = try LayeredImageDocument(decoding: data)

        XCTAssertEqual(restored, original, "full document equality after round-trip")
        // Spell out the load-bearing fields too, so a future Equatable change
        // can't silently weaken this guard.
        XCTAssertEqual(restored.canvasSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(restored.layers.map(\.name), ["Background", "Overlay", "Top"])
        XCTAssertEqual(restored.layers.map(\.id), [l0.id, l1.id, l2.id], "ids survive")
        XCTAssertEqual(restored.layers.map(\.isVisible), [true, false, true])
        XCTAssertEqual(restored.layers.map(\.blendMode), [.normal, .multiply, .screen])
        XCTAssertEqual(restored.layers[1].opacity, 0.6, accuracy: 1e-9)
        XCTAssertEqual(restored.formatVersion, LayeredImageDocument.currentFormatVersion)
    }

    func testEncodingIsDeterministic() throws {
        let doc = LayeredImageDocument(
            canvasSize: CGSize(width: 64, height: 64),
            layers: [makeLayer(name: "a", seed: 1), makeLayer(name: "b", seed: 2)])
        let first = try doc.encoded()
        let second = try doc.encoded()
        XCTAssertEqual(first, second, "sorted-keys encoding is byte-stable")
    }

    func testEncodedBlobCarriesMagicAndVersion() throws {
        let doc = LayeredImageDocument(canvasSize: .zero)
        let json = try doc.encoded()
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains(LayeredImageDocument.magic),
                      "own-format discriminator present in JSON")
        XCTAssertTrue(text.contains("\"formatVersion\":1"))
    }

    func testDecodeRejectsWrongMagic() {
        // A valid JSON object that isn't our format (different magic).
        let foreign = """
        {"magic":"someone.elses.format","formatVersion":1,\
        "canvasSize":{"width":0,"height":0},"layers":[]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try LayeredImageDocument(decoding: foreign)) { error in
            XCTAssertEqual(error as? LayeredImageError,
                           .wrongFormat(found: "someone.elses.format"))
        }
    }

    func testDecodeRejectsFutureVersion() {
        let future = """
        {"magic":"\(LayeredImageDocument.magic)","formatVersion":999,\
        "canvasSize":{"width":0,"height":0},"layers":[]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try LayeredImageDocument(decoding: future)) { error in
            XCTAssertEqual(error as? LayeredImageError, .unsupportedVersion(999))
        }
    }

    func testDecodeRejectsMalformedJSON() {
        let garbage = Data("not json at all".utf8)
        XCTAssertThrowsError(try LayeredImageDocument(decoding: garbage)) { error in
            XCTAssertEqual(error as? LayeredImageError, .malformedJSON)
        }
    }

    func testEmptyDocumentRoundTrips() throws {
        let empty = LayeredImageDocument(canvasSize: CGSize(width: 100, height: 200))
        let restored = try LayeredImageDocument(decoding: empty.encoded())
        XCTAssertEqual(restored, empty)
        XCTAssertTrue(restored.isEmpty)
        XCTAssertTrue(restored.layers.isEmpty)
    }

    func testBlendModeRawValuesAreStable() {
        // The own format round-trips blend modes by NAME — pin the raw strings so
        // a case rename is caught here rather than silently breaking old files.
        XCTAssertEqual(LayerBlendMode.normal.rawValue, "normal")
        XCTAssertEqual(LayerBlendMode.multiply.rawValue, "multiply")
        XCTAssertEqual(LayerBlendMode.screen.rawValue, "screen")
        XCTAssertEqual(LayerBlendMode.overlay.rawValue, "overlay")
        XCTAssertEqual(LayerBlendMode.darken.rawValue, "darken")
        XCTAssertEqual(LayerBlendMode.lighten.rawValue, "lighten")
        XCTAssertEqual(LayerBlendMode.difference.rawValue, "difference")
        XCTAssertEqual(LayerBlendMode.allCases.count, 7)
    }

    func testIndexOfFindsAndMisses() {
        let a = makeLayer(name: "a")
        let b = makeLayer(name: "b")
        let doc = LayeredImageDocument(canvasSize: .zero, layers: [a, b])
        XCTAssertEqual(doc.index(of: a.id), 0)
        XCTAssertEqual(doc.index(of: b.id), 1)
        XCTAssertNil(doc.index(of: UUID()))
    }
}
