import CoreGraphics
import Foundation

/// TSK-1254 slice 3 — the CGEvent acting mechanism for the AX tier.
///
/// Settled by measurement on the VM (2026-07-31, five rounds — see
/// LESSONS):
///   - SwiftUI's macOS AX bridge ACCEPTS `kAXPressAction` on plain-style
///     buttons (`.success`, action advertised) without ever dispatching
///     the action — the same "looks driveable, isn't" shape that
///     disqualified System Events.
///   - `CGEvent.postToPid` delivery is NOT hit-tested by AppKit — the
///     click lands in the app's queue but no control fires.
///   - The GLOBAL HID-tap post is what works, even from the VM lane's
///     asuser/root context: real event routing, exactly what a mouse does.
///
/// So the tier's division of labor: AX supplies FIND + GEOMETRY
/// (`AXDriverCore` + `AXUIElementNode`), HID supplies the EVENT. Needs
/// the Accessibility TCC grant (same one the AX reads need) and the
/// target window frontmost — both properties of the VM GUI lane the tier
/// already gates on (`AXInteractionTestCase`).
public enum AXClickExecutor {

    /// Post a real left-click (down + settle + up) at a GLOBAL screen
    /// point (top-left origin — the same space AX frames report).
    public static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            return
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        // A same-instant up can be coalesced away; 30ms reads as a click.
        usleep(30_000)
        up.post(tap: .cghidEventTap)
    }

    /// Click the center of `frame` (an AX element's reported frame).
    public static func click(centerOf frame: CGRect) {
        click(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Post a real drag: down at `from`, `steps` interpolated
    /// `leftMouseDragged` moves, up at `to` — the shape a
    /// `DragGesture(minimumDistance:)` recognizes. Steps are paced ~12ms
    /// apart: a teleporting two-event drag can be coalesced into a click,
    /// and gesture recognizers sample velocity between events.
    public static func drag(from: CGPoint, to: CGPoint, steps: Int = 16) {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type,
                    mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        post(.leftMouseDown, from)
        usleep(30_000)
        let n = max(2, steps)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            post(.leftMouseDragged,
                 CGPoint(x: from.x + (to.x - from.x) * t,
                         y: from.y + (to.y - from.y) * t))
            usleep(12_000)
        }
        usleep(30_000)
        post(.leftMouseUp, to)
    }
}
