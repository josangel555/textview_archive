import Combine
import Foundation
import Testing
@testable import ViewerUI

/// I-21 S4c — the cross-pane geometry channel: strip drop-target
/// hit-testing (source pane excluded, dead panes pruned, hover deduped)
/// and content click-focus targeting (focused pane excluded), plus the
/// window→SwiftUI-global point conversion the click monitor rides.
@MainActor
@Suite struct PaneDropChannelTests {

    let p0 = UUID(), p1 = UUID(), gone = UUID()

    func channel() -> PaneDropChannel {
        let ch = PaneDropChannel()
        ch.recordStrip(id: p0, rect: CGRect(x: 0, y: 0, width: 400, height: 30))
        ch.recordStrip(id: p1, rect: CGRect(x: 400, y: 0, width: 400, height: 30))
        ch.recordContent(id: p0, rect: CGRect(x: 0, y: 30, width: 400, height: 570))
        ch.recordContent(id: p1, rect: CGRect(x: 400, y: 30, width: 400, height: 570))
        return ch
    }

    // MARK: strip drop targets

    @Test func paneID_hitsTheStripUnderThePoint_excludingTheSource() {
        let ch = channel()
        let live: Set<UUID> = [p0, p1]
        #expect(ch.paneID(at: CGPoint(x: 500, y: 10), live: live, excluding: p0) == p1)
        #expect(ch.paneID(at: CGPoint(x: 100, y: 10), live: live, excluding: p0) == nil,
                "a drop on your own strip is a reorder, never an external target")
        #expect(ch.paneID(at: CGPoint(x: 500, y: 200), live: live, excluding: p0) == nil,
                "content regions are not strip drop targets")
    }

    @Test func paneID_prunesDeadPanes() {
        let ch = channel()
        ch.recordStrip(id: gone, rect: CGRect(x: 800, y: 0, width: 400, height: 30))
        // `gone`'s pane closed: not live ⇒ never a target, entry pruned.
        #expect(ch.paneID(at: CGPoint(x: 900, y: 10), live: [p0, p1], excluding: p0) == nil)
    }

    @Test func hover_isDeduped_andClearsWhenItsStripLeaves() {
        let ch = channel()
        var publishes = 0
        let sub = ch.objectWillChange.sink { publishes += 1 }
        defer { sub.cancel() }
        ch.setHovered(p1)
        ch.setHovered(p1)                  // same value — no republish
        #expect(publishes == 1)
        ch.removeStrip(id: p1)             // the hovered pane closed mid-drag
        #expect(ch.hoveredPaneID == nil, "a closed pane can't stay lit")
    }

    // MARK: content click-focus targets

    @Test func focusTarget_hitsUnfocusedContent_skipsFocusedAndOutside() {
        let ch = channel()
        let live: Set<UUID> = [p0, p1]
        #expect(ch.focusTarget(at: CGPoint(x: 500, y: 300), live: live, focused: p0) == p1)
        #expect(ch.focusTarget(at: CGPoint(x: 100, y: 300), live: live, focused: p0) == nil,
                "clicking the focused pane changes nothing")
        #expect(ch.focusTarget(at: CGPoint(x: 500, y: 10), live: live, focused: p0) == nil,
                "strip clicks focus via their own actions, not the monitor")
    }

    // MARK: window → SwiftUI-global conversion (the monitor's math)

    @Test func globalPoint_flipsOnlyForUnflippedHosts() {
        // NSHostingView is flipped: window coords ARE top-left coords.
        #expect(PaneFocusClickMonitor.globalPoint(
            locationInWindow: CGPoint(x: 10, y: 20),
            hostIsFlipped: true, hostHeight: 600) == CGPoint(x: 10, y: 20))
        // An unflipped host measures y from the bottom: flip it.
        #expect(PaneFocusClickMonitor.globalPoint(
            locationInWindow: CGPoint(x: 10, y: 20),
            hostIsFlipped: false, hostHeight: 600) == CGPoint(x: 10, y: 580))
    }
}
