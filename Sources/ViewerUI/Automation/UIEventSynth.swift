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

    /// Walk the ACCESSIBILITY element tree for `identifier` and return
    /// its frame in SCREEN coordinates. This is how SwiftUI controls are
    /// found: a whole SwiftUI hierarchy lives inside ONE NSHostingView —
    /// its buttons/strips are NOT NSViews, so their
    /// `.accessibilityIdentifier(_:)` exists ONLY as AX elements
    /// (discovered live on the VM: `mdv.sessionTab.new` is unfindable by
    /// the NSView walk).
    public static func findAXFrame(identifier: String, element: Any) -> NSRect? {
        guard let obj = element as? any NSAccessibilityProtocol else { return nil }
        if obj.accessibilityIdentifier() == identifier {
            return obj.accessibilityFrame()
        }
        for child in obj.accessibilityChildren() ?? [] {
            if let hit = findAXFrame(identifier: identifier, element: child) {
                return hit
            }
        }
        return nil
    }

    /// Collect a bounded sample of the accessibility identifiers visible
    /// from `element` — failure-trace fodder.
    public static func collectAXIdentifiers(element: Any,
                                            into out: inout [String],
                                            limit: Int) {
        guard out.count < limit,
              let obj = element as? any NSAccessibilityProtocol else { return }
        if let id = obj.accessibilityIdentifier(), !id.isEmpty { out.append(id) }
        for child in obj.accessibilityChildren() ?? [] {
            collectAXIdentifiers(element: child, into: &out, limit: limit)
        }
    }

    /// Resolve the target's rect in WINDOW coordinates: the
    /// ClickTargetRegistry first (SwiftUI controls publish their own
    /// frames — the ONLY in-process channel that can see them; LESSONS
    /// "the five constraints"), then the NSView walk (hosted AppKit
    /// views carry the id directly), then the AX tree (dead in-process,
    /// kept for external-client parity).
    public static func resolveTargetRect(identifier: String,
                                         in window: NSWindow) -> NSRect? {
        guard let root = window.contentView else { return nil }
        if let global = ClickTargetRegistry.shared.frame(for: identifier) {
            return ClickTargetRegistry.windowRect(fromSwiftUIGlobal: global,
                                                  contentView: root)
        }
        if let view = findView(identifier: identifier, under: root) {
            return view.convert(view.bounds, to: nil)
        }
        if let screenRect = findAXFrame(identifier: identifier, element: root) {
            return window.convertFromScreen(screenRect)
        }
        return nil
    }

    /// Build the event sequence for `spec` against `window`'s view tree,
    /// or `nil` when the target id is not in the realized tree. Split
    /// from delivery so the lookup + coordinate + sequence logic is
    /// host-testable: an UN-ordered window has no window device
    /// (`windowNumber <= 0`), so queued events cannot route back to it —
    /// end-to-end delivery is only observable in the live app (the VM T4
    /// suite), but everything up to delivery is pinned headlessly.
    public static func events(spec: UIClickSpec, in window: NSWindow) -> [NSEvent]? {
        guard let rect = resolveTargetRect(identifier: spec.identifier, in: window)
        else { return nil }

        let inWindow = NSPoint(x: rect.minX + rect.width * spec.fx,
                               y: rect.minY + rect.height * spec.fy)

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

    /// Drive `window` to KEY status for real-event delivery, escalating as
    /// needed. `NSApp.activate` is ASYNCHRONOUS — key status lands on a
    /// later run-loop turn, so each rung pumps the loop until it sticks or
    /// times out. The `.accessory` policy (MDV_BACKGROUND) can deny key
    /// outright, so the second rung escalates to `.regular` — acceptable
    /// in the script harness, which only runs on the VM GUI lane.
    /// Best-effort: callers check `isKeyWindow` afterwards and fall back
    /// to direct responder dispatch when key never landed.
    public static func makeWindowKey(_ window: NSWindow,
                                     timeoutPerRung: TimeInterval = 1.5) {
        func pump(until deadline: Date) -> Bool {
            while !window.isKeyWindow, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return window.isKeyWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if pump(until: Date().addingTimeInterval(timeoutPerRung)) { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        _ = pump(until: Date().addingTimeInterval(timeoutPerRung))
    }

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
        guard let rect = resolveTargetRect(identifier: spec.identifier, in: window),
              let sequence = events(spec: spec, in: window)
        else {
            // Self-describing failure: WHICH resolver version ran and what
            // the AX walk could actually see — distinguishes "stale binary"
            // from "AX tree empty" from "ids elsewhere" in one trace.
            var seen: [String] = []
            if let root = window.contentView {
                collectAXIdentifiers(element: root, into: &seen, limit: 15)
            }
            let rootKids = (window.contentView?.accessibilityChildren() ?? []).count
            lastTrace = "click[v6](\(spec.identifier)): NOT FOUND; "
                + "registryIds=\(ClickTargetRegistry.shared.identifiers) "
                + "axRootChildren=\(rootKids) axIdsSample=\(seen)"
            return false
        }
        // Delivery: `window.sendEvent` is the full pipeline (hit-testing +
        // gesture recognizers + responder chain) — but it ALSO runs
        // NSWindow's click-through suppression, which eats a mouseDown on
        // a NON-key window (acceptsFirstMouse == false for SwiftUI
        // content). When the harness couldn't get key status (root app in
        // a user GUI session; accessory policy), fall back to dispatching
        // straight to the hit-tested view's responder methods — bypassing
        // the window-level suppression. One path or the other, never both
        // (both working would double-fire the action).
        let via: String
        if window.isKeyWindow {
            via = "sendEvent"
            for event in sequence {
                window.sendEvent(event)
            }
        } else {
            via = "responder"
            let target = window.contentView?.hitTest(sequence[0].locationInWindow)
            for event in sequence {
                switch event.type {
                case .leftMouseDown: target?.mouseDown(with: event)
                case .leftMouseUp: target?.mouseUp(with: event)
                default: break
                }
            }
        }
        lastTrace = "click[v6](\(spec.identifier)): rect=\(rect) "
            + "point=\(sequence[0].locationInWindow) "
            + "count=\(spec.clickCount) via=\(via) key=\(window.isKeyWindow) "
            + "active=\(NSApp.isActive)"
        return true
    }

}
