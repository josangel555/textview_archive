import XCTest
import SwiftUI
@testable import ViewerUI

/// Unit tests for the `WalkthroughAnchorKey` preference key and its
/// reducer. The reducer is the load-bearing piece — SwiftUI calls it
/// repeatedly as the tree settles, and we need per-surface last-write-
/// wins semantics so a re-layout updates rather than appends.
final class WalkthroughAnchorKeyTests: XCTestCase {

    func test_defaultValue_isEmpty() {
        XCTAssertEqual(WalkthroughAnchorKey.defaultValue, [:])
    }

    func test_reduce_addsNewSurface() {
        var value: [String: CGRect] = [:]
        WalkthroughAnchorKey.reduce(value: &value) {
            ["sidebar": CGRect(x: 0, y: 0, width: 240, height: 800)]
        }
        XCTAssertEqual(value.count, 1)
        XCTAssertEqual(value["sidebar"], CGRect(x: 0, y: 0, width: 240, height: 800))
    }

    func test_reduce_overwritesSameSurface() {
        var value: [String: CGRect] = [
            "sidebar": CGRect(x: 0, y: 0, width: 240, height: 800)
        ]
        WalkthroughAnchorKey.reduce(value: &value) {
            ["sidebar": CGRect(x: 0, y: 0, width: 260, height: 820)]
        }
        XCTAssertEqual(value["sidebar"]?.width, 260,
            "re-registering same surface must replace the rect, not duplicate")
    }

    func test_reduce_preservesOtherSurfaces() {
        var value: [String: CGRect] = [
            "sidebar": CGRect(x: 0, y: 0, width: 240, height: 800)
        ]
        WalkthroughAnchorKey.reduce(value: &value) {
            ["gitTab": CGRect(x: 240, y: 0, width: 360, height: 800)]
        }
        XCTAssertEqual(value.count, 2)
        XCTAssertNotNil(value["sidebar"])
        XCTAssertNotNil(value["gitTab"])
    }

    func test_surface_idStableAcrossInstances() {
        XCTAssertEqual(WalkthroughAnchorSurface.sidebar.id, "sidebar")
        XCTAssertEqual(WalkthroughAnchorSurface.gitTab.id, "gitTab")
        XCTAssertEqual(WalkthroughAnchorSurface.editor.id, "editor")
    }
}
