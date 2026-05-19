import XCTest
import SwiftUI
import ViewerCore
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

    // MARK: - Integration: positioning math (Self.popoverPosition)

    /// Sanity: a normal sidebar rect places the popover to its right,
    /// vertically centered.
    func test_popoverPosition_anchorsToRightOfRect() {
        let rect = CGRect(x: 0, y: 0, width: 240, height: 800)
        let pos = WalkthroughOverlay.popoverPosition(forSurfaceRect: rect)
        XCTAssertNotNil(pos)
        // 240 (maxX) + 12 (gap) + 180 (half popover width) = 432
        XCTAssertEqual(pos?.x, 432)
        // midY of 800-tall rect at y=0 = 400
        XCTAssertEqual(pos?.y, 400)
    }

    func test_popoverPosition_rectOffsetByContainer() {
        // Sidebar lives at x=20 (some padding), 200 wide, vertically
        // offset by a top bar. Position should track the maxX edge.
        let rect = CGRect(x: 20, y: 40, width: 200, height: 600)
        let pos = WalkthroughOverlay.popoverPosition(forSurfaceRect: rect)
        XCTAssertEqual(pos?.x, 20 + 200 + 12 + 180)   // 412
        XCTAssertEqual(pos?.y, 40 + 300)              // 340
    }

    func test_popoverPosition_zeroSize_returnsNil() {
        // Pre-layout: GeometryReader publishes a .zero rect before the
        // first measure pass. We must NOT position a popover at (0,0) in
        // that interval — the caller falls back to alignment.
        XCTAssertNil(
            WalkthroughOverlay.popoverPosition(forSurfaceRect: .zero))
        XCTAssertNil(
            WalkthroughOverlay.popoverPosition(
                forSurfaceRect: CGRect(x: 100, y: 100, width: 0, height: 50)))
        XCTAssertNil(
            WalkthroughOverlay.popoverPosition(
                forSurfaceRect: CGRect(x: 100, y: 100, width: 50, height: 0)))
    }

    func test_popoverPosition_customGapAndHalfWidth() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pos = WalkthroughOverlay.popoverPosition(
            forSurfaceRect: rect, gap: 20, popoverHalfWidth: 200)
        XCTAssertEqual(pos?.x, 100 + 20 + 200)        // 320
        XCTAssertEqual(pos?.y, 50)
    }

    // MARK: - Integration: surfaceKey routing

    func test_surfaceKey_routesAnchoredOnly() {
        XCTAssertEqual(
            WalkthroughOverlay.surfaceKey(for: .sidebar(section: .files)),
            WalkthroughAnchorSurface.sidebar.id)
        XCTAssertEqual(
            WalkthroughOverlay.surfaceKey(for: .gitTab(tab: .status)),
            WalkthroughAnchorSurface.gitTab.id)
        XCTAssertEqual(WalkthroughOverlay.surfaceKey(for: .editor),
                       WalkthroughAnchorSurface.editor.id)
    }

    func test_surfaceKey_indifferent_toAssociatedValues() {
        // The surfaceKey routes purely on case; associated values
        // (sidebar section, git tab) don't affect the published id.
        // Otherwise re-using the same sidebar rect for a different
        // section would miss the lookup.
        XCTAssertEqual(
            WalkthroughOverlay.surfaceKey(for: .sidebar(section: .files)),
            WalkthroughOverlay.surfaceKey(for: .sidebar(section: .git)))
        XCTAssertEqual(
            WalkthroughOverlay.surfaceKey(for: .gitTab(tab: .status)),
            WalkthroughOverlay.surfaceKey(for: .gitTab(tab: .log)))
    }

    func test_surfaceKey_returnsNil_forNonRegisteredAnchors() {
        // .line is positioned by gutter math (lineAnchoredPopover) and
        // .window centers itself in the overlay — neither registers a
        // surface frame, so the surfaceKey lookup must return nil so
        // the overlay falls through to those paths.
        XCTAssertNil(WalkthroughOverlay.surfaceKey(for: .window))
        XCTAssertNil(WalkthroughOverlay.surfaceKey(
            for: .line(path: "/tmp/x.swift", line: 10)))
    }
}
