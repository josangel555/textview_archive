import XCTest
import CoreGraphics
@testable import ViewerCore

/// Pins the squarified treemap layout core (TSK-334): proportional areas,
/// in-bounds, non-overlapping, area-conserving. Pure geometry → host-tested.
final class TreemapLayoutTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    private func area(_ r: CGRect) -> Double { Double(r.width) * Double(r.height) }

    func test_empty_and_nonPositiveWeights_yieldNoTiles() {
        XCTAssertTrue(TreemapLayout.squarify([(id: 1, weight: 1.0)], in: .zero).isEmpty)
        XCTAssertTrue(TreemapLayout.squarify([] as [(id: Int, weight: Double)], in: bounds).isEmpty)
        XCTAssertTrue(TreemapLayout.squarify(
            [(id: 1, weight: 0.0), (id: 2, weight: -3.0), (id: 3, weight: .nan)],
            in: bounds).isEmpty)
    }

    func test_nonPositive_droppedButPositivesKept() {
        let tiles = TreemapLayout.squarify(
            [(id: "a", weight: 0), (id: "b", weight: 2), (id: "c", weight: -1)], in: bounds)
        XCTAssertEqual(tiles.map(\.id), ["b"])           // only the positive survives
        XCTAssertEqual(area(tiles[0].rect), area(bounds), accuracy: 1.0)
    }

    func test_singleItem_fillsBounds() {
        let tiles = TreemapLayout.squarify([(id: 7, weight: 42.0)], in: bounds)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0].rect.minX, bounds.minX, accuracy: 0.001)
        XCTAssertEqual(tiles[0].rect.minY, bounds.minY, accuracy: 0.001)
        XCTAssertEqual(tiles[0].rect.width, bounds.width, accuracy: 0.001)
        XCTAssertEqual(tiles[0].rect.height, bounds.height, accuracy: 0.001)
    }

    func test_areaProportionalToWeight() {
        let items = [(id: "a", weight: 1.0), (id: "b", weight: 2.0),
                     (id: "c", weight: 3.0), (id: "d", weight: 4.0)]
        let tiles = TreemapLayout.squarify(items, in: bounds)
        XCTAssertEqual(tiles.count, 4)
        let total = items.reduce(0.0) { $0 + $1.weight }   // 10
        let byID = Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0.rect) })
        for it in items {
            let expected = (it.weight / total) * area(bounds)
            XCTAssertEqual(area(byID[it.id]!), expected, accuracy: 1.0,
                           "tile \(it.id) area not proportional")
        }
    }

    func test_tilesStayInBounds_andConserveArea() {
        let items = (1...12).map { (id: $0, weight: Double($0 * $0)) } // varied weights
        let tiles = TreemapLayout.squarify(items, in: bounds)
        XCTAssertEqual(tiles.count, 12)
        var summed = 0.0
        for t in tiles {
            XCTAssertGreaterThanOrEqual(t.rect.minX, bounds.minX - 0.001)
            XCTAssertGreaterThanOrEqual(t.rect.minY, bounds.minY - 0.001)
            XCTAssertLessThanOrEqual(t.rect.maxX, bounds.maxX + 0.001)
            XCTAssertLessThanOrEqual(t.rect.maxY, bounds.maxY + 0.001)
            XCTAssertGreaterThan(t.rect.width, 0)
            XCTAssertGreaterThan(t.rect.height, 0)
            summed += area(t.rect)
        }
        XCTAssertEqual(summed, area(bounds), accuracy: 1.0)   // exact tiling
    }

    func test_tilesDoNotOverlap() {
        let items = (1...15).map { (id: $0, weight: Double(($0 * 7) % 11 + 1)) }
        let tiles = TreemapLayout.squarify(items, in: bounds)
        for i in 0..<tiles.count {
            for j in (i + 1)..<tiles.count {
                let inter = tiles[i].rect.intersection(tiles[j].rect)
                // Shared edges are fine (zero-area intersection); true overlap is not.
                let overlap = inter.isNull ? 0 : area(inter)
                XCTAssertLessThan(overlap, 0.01,
                    "tiles \(tiles[i].id) and \(tiles[j].id) overlap by \(overlap)")
            }
        }
    }
}
