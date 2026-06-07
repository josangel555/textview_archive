import XCTest
import SwiftUI
import AppKit
@testable import ViewerUI
@testable import ViewerCore
import ViewerKit

/// Headless RENDER coverage for the terminal tab strip (TSK-488 / owner
/// "I see no tabs"). The model layer (`TerminalPaneStoreTests`) proves the
/// store always has ≥1 tab when open — but that says nothing about whether
/// the STRIP actually renders beside the terminal surface. This mounts the
/// real `TerminalPaneView` inside a ContentView-faithful column (a greedy
/// body over a fixed-height, `.clipped()` terminal pane, framed by rails)
/// and walks the realized AppKit tree to assert the strip's tab-chip
/// scrollview sits on the correct EDGE relative to the live terminal
/// surface (`TerminalNSView`).
///
/// HEADLESS, host-safe: an in-process `NSHostingController` + an unshown,
/// explicitly-sized `NSWindow` (never `orderFront`) — same pattern as
/// `TabBarIntrinsicSizeTests`. Sizing the window is load-bearing: an
/// unsized host is 0×0 and every realized frame comes back centered around
/// the origin (garbage negative coords).
///
/// CAVEAT (LESSONS): an in-process frame walk pins the SwiftUI LAYOUT, not
/// the WindowServer compositor — it proves the strip occupies its band and
/// the opaque surface does not overlap it. A live compositor-only hide
/// stays VM/T5-owed.
@MainActor
final class TerminalTabStripRenderTests: HeadlessUITestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "TermStripRender-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// LEFT strip (default): the tab-chip scrollview sits entirely to the
    /// LEFT of the terminal surface, and the surface starts to its right.
    func test_leftStrip_sitsLeftOfSurface() throws {
        let (strip, surface) = mountAndLocate(.left)
        XCTAssertNotNil(strip, "tab-strip scrollview not found — strip didn't render")
        XCTAssertNotNil(surface, "terminal surface (TerminalNSView) not found")
        XCTAssertLessThanOrEqual(strip!.maxX, surface!.minX + 1,
            "strip (maxX=\(strip!.maxX)) must sit left of the surface (minX=\(surface!.minX))")
        XCTAssertGreaterThan(strip!.width, 0, "strip collapsed to zero width")
    }

    /// RIGHT strip: scrollview sits entirely to the RIGHT of the surface.
    func test_rightStrip_sitsRightOfSurface() throws {
        let (strip, surface) = mountAndLocate(.right)
        XCTAssertNotNil(strip, "tab-strip scrollview not found")
        XCTAssertNotNil(surface, "terminal surface not found")
        XCTAssertGreaterThanOrEqual(strip!.minX, surface!.maxX - 1,
            "strip (minX=\(strip!.minX)) must sit right of the surface (maxX=\(surface!.maxX))")
    }

    /// TOP strip: the horizontal strip sits ABOVE the surface.
    func test_topStrip_sitsAboveSurface() throws {
        let (strip, surface) = mountAndLocate(.top)
        XCTAssertNotNil(strip, "tab-strip scrollview not found")
        XCTAssertNotNil(surface, "terminal surface not found")
        XCTAssertLessThanOrEqual(strip!.maxY, surface!.minY + 1,
            "strip (maxY=\(strip!.maxY)) must sit above the surface (minY=\(surface!.minY))")
    }

    // MARK: - Harness

    /// Mount the pane for a tab position and return (stripFrame, surfaceFrame)
    /// in the root's coordinate space.
    private func mountAndLocate(_ pos: TerminalTabPosition)
        -> (NSRect?, NSRect?) {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)
        store.setTabPosition(pos)
        XCTAssertEqual(store.tabs.count, 1)
        let root = mountInColumn(store: store)
        defer { store.shutdown() }
        return (frame(in: root, classContains: "HostingScrollView"),
                frame(in: root, classContains: "TerminalNSView"))
    }

    /// Reproduce ContentView's center column: a greedy body over a fixed-
    /// height, `.clipped()` terminal pane, inside an outer HStack with rails
    /// — the context the live pane lives in.
    private func mountInColumn(store: TerminalPaneStore) -> NSView {
        let rootView = HStack(spacing: 0) {
            Color.clear.frame(width: 44)                 // left rail stand-in
            Divider()
            VStack(spacing: 0) {                          // center column
                Color.gray
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .layoutPriority(1)
                TerminalResizeHandle(store: store)
                TerminalPaneView(store: store, fontSize: 12)
                    .frame(height: 160)
                    .clipped()
                    .layoutPriority(0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.clear.frame(width: 44)                 // right rail stand-in
        }
        let hc = NSHostingController(rootView: rootView)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentViewController = hc
        win.setContentSize(NSSize(width: 1000, height: 600))   // else host is 0×0
        let root = win.contentView ?? hc.view
        hc.view.layoutSubtreeIfNeeded()
        win.layoutIfNeeded()
        hc.view.layoutSubtreeIfNeeded()
        return root
    }

    /// First realized NSView whose class name contains `needle`, as a frame
    /// in `root`'s coordinate space.
    private func frame(in root: NSView, classContains needle: String) -> NSRect? {
        var found: NSRect?
        func rec(_ v: NSView) {
            if found == nil, String(describing: type(of: v)).contains(needle) {
                found = v.convert(v.bounds, to: root)
            }
            for s in v.subviews where found == nil { rec(s) }
        }
        rec(root)
        return found
    }
}
