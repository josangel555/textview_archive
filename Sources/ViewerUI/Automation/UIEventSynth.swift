import AppKit
import ViewerCore

/// REAL-event click synthesis for the `--script` harness (the keystone
/// interaction layer the testing mandate requires: "at least one test
/// must INTERACT with the element").
///
/// Events are built with `NSEvent.mouseEvent` and POSTED to the app's
/// event queue (`NSApp.postEvent`) — the same channel real input arrives
/// on — so they traverse the genuine AppKit pipeline: hit-testing, the
/// responder chain, SwiftUI's gesture recognizers, AND control tracking
/// loops (an `NSButton.mouseDown` pulls its mouse-up from the QUEUE via
/// `nextEvent`; a direct `sendEvent` pair can never satisfy it — found
/// empirically by this layer's own headless test). No Accessibility TCC
/// grant needed (unlike `CGEvent` posting — the asuser-bridge app on the
/// VM has none), and in-process delivery is deterministic: no
/// WindowServer races, no focus stealing. In the live app the run loop
/// dispatches the queue within the script step's settle; headless tests
/// call `pumpQueuedEvents()`.
///
/// Targets are located by accessibility identifier on the realized
/// NSView tree — the same `view.accessibilityIdentifier()` surface
/// `DiagnosticDump` already relies on (SwiftUI ids land on hosting
/// NSViews).
@MainActor
public enum UIEventSynth {

    /// Depth-first search for the first view whose accessibility
    /// identifier equals `identifier`.
    public static func findView(identifier: String, under root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for sub in root.subviews {
            if let hit = findView(identifier: identifier, under: sub) {
                return hit
            }
        }
        return nil
    }

    /// Build the event sequence for `spec` against `window`'s view tree,
    /// or `nil` when the target id is not in the realized tree. Split
    /// from delivery so the lookup + coordinate + sequence logic is
    /// host-testable: an UN-ordered window has no window device
    /// (`windowNumber <= 0`), so queued events cannot route back to it —
    /// end-to-end delivery is only observable in the live app (the VM T4
    /// suite), but everything up to the queue is pinned headlessly.
    public static func events(spec: UIClickSpec, in window: NSWindow) -> [NSEvent]? {
        guard let root = window.contentView,
              let target = findView(identifier: spec.identifier, under: root)
        else { return nil }

        let b = target.bounds
        let local = NSPoint(x: b.minX + b.width * spec.fx,
                            y: b.minY + b.height * spec.fy)
        let inWindow = target.convert(local, to: nil)

        var flags: NSEvent.ModifierFlags = []
        if spec.command { flags.insert(.command) }
        if spec.shift { flags.insert(.shift) }

        // A double-click is a click-count-1 pair followed by a
        // click-count-2 pair — the sequence AppKit produces for a real
        // double-click and what SwiftUI's `onTapGesture(count: 2)` keys on.
        var out: [NSEvent] = []
        for clickNumber in 1...max(1, spec.clickCount) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type,
                    location: inWindow,
                    modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: clickNumber,
                    pressure: type == .leftMouseDown ? 1 : 0)
                else { return nil }
                out.append(event)
            }
        }
        return out
    }

    /// Trace of the most recent `click` — embedded in the step dump by
    /// `captureStepArtifacts` so a failing VM scenario shows WHAT was
    /// resolved and WHERE the events went instead of a silent no-op.
    public private(set) static var lastTrace: String = ""

    /// Synthesize the click described by `spec`: deliver its event
    /// sequence through `window.sendEvent` — the call that drives
    /// NSWindow-level routing INCLUDING gesture recognizers, which is
    /// what SwiftUI taps/double-taps hang off. (Queue posting was tried
    /// first: it satisfies AppKit control tracking loops, but queue
    /// dispatch order/routing in the harness context proved unreliable
    /// for SwiftUI targets; direct sendEvent is synchronous and
    /// deterministic.) Returns `false` when the target id is not in the
    /// realized tree — callers surface that loudly so a test never
    /// "passes" by clicking nothing.
    @discardableResult
    public static func click(spec: UIClickSpec, in window: NSWindow) -> Bool {
        guard let root = window.contentView,
              let target = findView(identifier: spec.identifier, under: root),
              let sequence = events(spec: spec, in: window)
        else {
            lastTrace = "click(\(spec.identifier)): target NOT FOUND"
            return false
        }
        for event in sequence {
            window.sendEvent(event)
        }
        lastTrace = "click(\(spec.identifier)): view=\(type(of: target)) "
            + "frame=\(target.frame) point=\(sequence[0].locationInWindow) "
            + "count=\(spec.clickCount) key=\(window.isKeyWindow)"
        return true
    }

}
