import XCTest
import CoreGraphics
@testable import ViewerCore

/// TSK-358 — pure window-geometry model: clamp a requested frame to the
/// screen-visible bounds with sane min/max, and decide restore-vs-default
/// when there's no usable saved geometry. (Applying the resolved frame to a
/// live `NSWindow` + the on-screen result are the VM tail.)
final class WindowGeometryTests: XCTestCase {

    // A single 1440×900 visible screen at the origin (menu-bar/Dock excluded
    // area is the same rect for these tests).
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: Restore-vs-default decision

    func test_noSavedFrame_centersDefault() {
        let res = WindowGeometry.resolve(requested: nil, visibleFrames: [screen])
        XCTAssertEqual(res, .centerDefault(WindowGeometry.defaultContentSize))

        // …and the concrete frame is the default size centered on the screen.
        let frame = res.frame(primaryVisible: screen)
        XCTAssertEqual(frame.size, WindowGeometry.defaultContentSize)
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, screen.midY, accuracy: 0.5)
    }

    func test_usableSavedFrame_restoredAsIs() {
        let saved = WindowGeometry.Frame(x: 100, y: 80, width: 1000, height: 700)
        let res = WindowGeometry.resolve(requested: saved, visibleFrames: [screen])
        XCTAssertEqual(res, .restore(saved.cgRect))
    }

    // MARK: NaN / zero / negative → default

    func test_nanFrame_treatedAsUnusable_centersDefault() {
        let nan = WindowGeometry.Frame(x: .nan, y: 0, width: 1000, height: 700)
        XCTAssertFalse(nan.isUsable)
        let res = WindowGeometry.resolve(requested: nan, visibleFrames: [screen])
        XCTAssertEqual(res, .centerDefault(WindowGeometry.defaultContentSize))
    }

    func test_zeroSizeFrame_centersDefault() {
        let zero = WindowGeometry.Frame(x: 50, y: 50, width: 0, height: 0)
        XCTAssertFalse(zero.isUsable)
        let res = WindowGeometry.resolve(requested: zero, visibleFrames: [screen])
        XCTAssertEqual(res, .centerDefault(WindowGeometry.defaultContentSize))
    }

    func test_negativeSize_centersDefault() {
        let neg = WindowGeometry.Frame(x: 0, y: 0, width: -800, height: 600)
        XCTAssertFalse(neg.isUsable)
        let res = WindowGeometry.resolve(requested: neg, visibleFrames: [screen])
        XCTAssertEqual(res, .centerDefault(WindowGeometry.defaultContentSize))
    }

    func test_infiniteFrame_centersDefault() {
        let inf = WindowGeometry.Frame(x: 0, y: 0, width: .infinity, height: 600)
        XCTAssertFalse(inf.isUsable)
        let res = WindowGeometry.resolve(requested: inf, visibleFrames: [screen])
        XCTAssertEqual(res, .centerDefault(WindowGeometry.defaultContentSize))
    }

    // MARK: Below-min → grown to min

    func test_belowMinSize_grownToMin() {
        let tiny = WindowGeometry.Frame(x: 200, y: 200, width: 100, height: 80)
        let res = WindowGeometry.resolve(requested: tiny, visibleFrames: [screen])
        guard case let .clamped(rect) = res else {
            return XCTFail("expected clamped, got \(res)")
        }
        XCTAssertEqual(rect.size.width, WindowGeometry.minContentSize.width)
        XCTAssertEqual(rect.size.height, WindowGeometry.minContentSize.height)
        // Anchor preserved (still fully on-screen).
        XCTAssertEqual(rect.origin.x, 200)
        XCTAssertEqual(rect.origin.y, 200)
    }

    func test_belowMinOnOneAxisOnly_grownOnThatAxis() {
        let narrow = WindowGeometry.Frame(x: 0, y: 0, width: 200, height: 700)
        let res = WindowGeometry.resolve(requested: narrow, visibleFrames: [screen])
        guard case let .clamped(rect) = res else {
            return XCTFail("expected clamped, got \(res)")
        }
        XCTAssertEqual(rect.size.width, WindowGeometry.minContentSize.width)
        XCTAssertEqual(rect.size.height, 700, "height was already above min")
    }

    // MARK: Oversize → clamped to the screen it lives on

    func test_oversizeFrame_clampedToScreen() {
        // Saved from a 4K external, restored on the 1440×900 built-in.
        let big = WindowGeometry.Frame(x: 0, y: 0, width: 3840, height: 2160)
        let res = WindowGeometry.resolve(requested: big, visibleFrames: [screen])
        guard case let .clamped(rect) = res else {
            return XCTFail("expected clamped, got \(res)")
        }
        XCTAssertEqual(rect.size.width, screen.size.width)
        XCTAssertEqual(rect.size.height, screen.size.height)
    }

    // MARK: Off-screen / disconnected display → recover with centered default

    func test_fullyOffScreen_centersDefault() {
        // Frame entirely to the right of the only screen (external monitor
        // that was disconnected since last launch).
        let gone = WindowGeometry.Frame(x: 5000, y: 100, width: 1000, height: 700)
        let res = WindowGeometry.resolve(requested: gone, visibleFrames: [screen])
        XCTAssertEqual(res, .centerDefault(WindowGeometry.defaultContentSize))
    }

    func test_partiallyOffScreen_nudgedBackOn() {
        // Title bar runs off the right edge; origin should be pulled in so the
        // whole window is reachable.
        let partial = WindowGeometry.Frame(x: 1300, y: 100, width: 1000, height: 700)
        let res = WindowGeometry.resolve(requested: partial, visibleFrames: [screen])
        guard case let .clamped(rect) = res else {
            return XCTFail("expected clamped, got \(res)")
        }
        XCTAssertLessThanOrEqual(rect.maxX, screen.maxX + 0.01)
        XCTAssertGreaterThanOrEqual(rect.origin.x, screen.origin.x - 0.01)
        XCTAssertEqual(rect.size.width, 1000, "size unchanged, only nudged")
    }

    // MARK: Multi-screen — window stays on the display it overlaps most

    func test_multiScreen_clampedToTheOwningScreen() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        // A window mostly on the second (larger) screen, slightly oversize for
        // it but fits — should be clamped to the second screen, not the first.
        let onSecond = WindowGeometry.Frame(x: 1500, y: 50, width: 2000, height: 900)
        let res = WindowGeometry.resolve(requested: onSecond,
                                         visibleFrames: [screen, second])
        guard case let .clamped(rect) = res else {
            return XCTFail("expected clamped, got \(res)")
        }
        XCTAssertEqual(rect.size.width, second.size.width,
                       "clamped to the second screen's width, not the first's")
    }

    // MARK: screen(for:) ownership

    func test_screenFor_picksLargestOverlap() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let b = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        // Mostly in `b`.
        let rect = CGRect(x: 900, y: 100, width: 600, height: 600)
        XCTAssertEqual(WindowGeometry.screen(for: rect, in: [a, b]), b)
    }

    func test_screenFor_noOverlap_returnsNil() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let rect = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        XCTAssertNil(WindowGeometry.screen(for: rect, in: [a]))
    }

    // MARK: clampOrigin

    func test_clampOrigin_pullsRectFullyInside() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let rect = CGRect(x: 800, y: 800, width: 400, height: 400)
        let clamped = WindowGeometry.clampOrigin(rect, into: bounds)
        XCTAssertEqual(clamped, CGRect(x: 600, y: 600, width: 400, height: 400))
    }

    func test_clampOrigin_oversizeRect_pinnedToOrigin() {
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 500)
        let rect = CGRect(x: -50, y: -50, width: 800, height: 800)
        let clamped = WindowGeometry.clampOrigin(rect, into: bounds)
        XCTAssertEqual(clamped.origin.x, bounds.origin.x)
        XCTAssertEqual(clamped.origin.y, bounds.origin.y)
    }

    // MARK: empty screen list (defensive — no NSScreen attached)

    func test_emptyVisibleFrames_usesNotionalPrimary_andRestores() {
        let saved = WindowGeometry.Frame(x: 0, y: 0, width: 1000, height: 700)
        let res = WindowGeometry.resolve(requested: saved, visibleFrames: [])
        // With no screens, the notional primary is the default-sized origin
        // rect; a 1000×700 frame fits and is kept.
        XCTAssertEqual(res, .restore(saved.cgRect))
    }

    // MARK: Frame round-trips through Codable

    func test_frame_codableRoundTrip() throws {
        let frame = WindowGeometry.Frame(x: 12, y: 34, width: 1000, height: 700)
        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(WindowGeometry.Frame.self, from: data)
        XCTAssertEqual(decoded, frame)
    }
}
