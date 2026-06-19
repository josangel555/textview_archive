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

    // MARK: - Key synthesis (TSK-818)

    /// Translate a `UIKeySpec.Modifiers` set to the AppKit flag family
    /// (`NSEvent.keyEvent`'s `modifierFlags`).
    public static func nsFlags(for mods: UIKeySpec.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.contains(.command) { flags.insert(.command) }
        if mods.contains(.shift)   { flags.insert(.shift) }
        if mods.contains(.control) { flags.insert(.control) }
        if mods.contains(.option)  { flags.insert(.option) }
        return flags
    }

    /// Translate a `UIKeySpec.Modifiers` set to the CoreGraphics flag family
    /// (`CGEvent.flags`) — the channel real keydown injection uses on the VM.
    public static func cgFlags(for mods: UIKeySpec.Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mods.contains(.command) { flags.insert(.maskCommand) }
        if mods.contains(.shift)   { flags.insert(.maskShift) }
        if mods.contains(.control) { flags.insert(.maskControl) }
        if mods.contains(.option)  { flags.insert(.maskAlternate) }
        return flags
    }

    /// The `characters` an `NSEvent` keyDown should report for a stroke — the
    /// glyph the field actually inserts. Letters/symbols carry their base
    /// glyph, uppercased when `.shift` is held; a stroke with a command/control
    /// modifier or no base glyph (named navigation keys) reports `""` (no
    /// insertion). This is the same rule AppKit applies before routing a key to
    /// `insertText:` vs `doCommandBySelector:`.
    public static func characters(for stroke: UIKeySpec.KeyStroke) -> String {
        guard let base = stroke.baseCharacter else { return "" }
        // Command / control chords are commands, not text — they don't insert.
        if stroke.modifiers.contains(.command) || stroke.modifiers.contains(.control) {
            return ""
        }
        if stroke.modifiers.contains(.shift) {
            return shiftedGlyph(forBase: base)
        }
        return base
    }

    /// The glyph a base key produces when ⇧ is held (US ANSI). Letters
    /// uppercase; the number row + punctuation map to their shifted symbol.
    public static func shiftedGlyph(forBase base: String) -> String {
        switch base {
        case "1": return "!"
        case "2": return "@"
        case "3": return "#"
        case "4": return "$"
        case "5": return "%"
        case "6": return "^"
        case "7": return "&"
        case "8": return "*"
        case "9": return "("
        case "0": return ")"
        case "-": return "_"
        case "=": return "+"
        case "[": return "{"
        case "]": return "}"
        case "\\": return "|"
        case ";": return ":"
        case "'": return "\""
        case ",": return "<"
        case ".": return ">"
        case "/": return "?"
        case "`": return "~"
        default:  return base.uppercased()
        }
    }

    /// Build the `NSEvent` keyDown/keyUp pair stream for `spec` against
    /// `window` — host-testable, no GUI session. Each stroke yields a keyDown
    /// then a keyUp carrying the stroke's keycode + AppKit modifier flags +
    /// reported characters. Returns `nil` if any event could not be
    /// constructed (AppKit can refuse on a malformed keycode). Split from
    /// delivery (`typeKeys`) so the keycode/modifier/characters mapping is
    /// pinned headlessly while real injection stays VM-only.
    public static func keyEvents(spec: UIKeySpec, in window: NSWindow) -> [NSEvent]? {
        var out: [NSEvent] = []
        for stroke in spec.strokes {
            let flags = nsFlags(for: stroke.modifiers)
            let chars = characters(for: stroke)
            for isDown in [true, false] {
                guard let event = NSEvent.keyEvent(
                    with: isDown ? .keyDown : .keyUp,
                    location: .zero,
                    modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: isDown ? chars : "",
                    charactersIgnoringModifiers: isDown ? (stroke.baseCharacter ?? "") : "",
                    isARepeat: false,
                    keyCode: stroke.keyCode)
                else { return nil }
                out.append(event)
            }
        }
        return out
    }

    /// Trace of the most recent `typeKeys` — embedded in the step dump so a
    /// failing VM scenario shows WHAT keystrokes were posted and via which
    /// channel instead of a silent no-op.
    public private(set) static var lastKeyTrace: String = ""

    /// VM-ONLY: post REAL keydown/keyup CGEvents for `spec` into the focused
    /// field of the spawned app. CGEvent posting requires a WindowServer + a
    /// GUI login session (and, off the asuser bridge, Accessibility TCC) — it
    /// is a no-op stub on the host headless lane (the `keyEvents` builder above
    /// is the host coverage). Drives the window key first; posts to the session
    /// event tap so the events traverse the real WindowServer → focused-field
    /// pipeline that the CM6/AppKit key-routing tail (894/896/921/730/728) bugs
    /// live on.
    @discardableResult
    public static func typeKeys(spec: UIKeySpec, in window: NSWindow) -> Bool {
        makeWindowKey(window)
        let source = CGEventSource(stateID: .hidSystemState)
        var posted = 0
        for stroke in spec.strokes {
            let flags = cgFlags(for: stroke.modifiers)
            for isDown in [true, false] {
                guard let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: stroke.keyCode,
                    keyDown: isDown)
                else { continue }
                event.flags = flags
                event.post(tap: .cgSessionEventTap)
                posted += 1
            }
        }
        lastKeyTrace = "typeKeys(\(spec.strokes.count) strokes): posted=\(posted) "
            + "key=\(window.isKeyWindow) active=\(NSApp.isActive)"
        return posted > 0
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
            lastTrace = "click[v8](\(spec.identifier)): NOT FOUND; "
                + "registryIds=\(ClickTargetRegistry.shared.identifiers) "
                + "axRootChildren=\(rootKids) axIdsSample=\(seen)"
            return false
        }
        // Delivery: `window.sendEvent` is the full pipeline (hit-testing +
        // gesture recognizers + responder chain) — but it suppresses a
        // mouseDown on a NON-key window, and the suppression is NOT keyed
        // on the overridable `isKeyWindow` (probed: a fake-key subclass
        // changed nothing, even for plain AppKit subviews). Real key
        // status requires real activation, which only a LaunchServices
        // launch can grant on macOS 14+ — AppLauncher's `open --env`
        // route. For a window that isn't key, fall back to direct
        // responder dispatch (drives AppKit views, not SwiftUI gestures —
        // best effort). One path only, never two (both working would
        // double-fire the action).
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
        lastTrace = "click[v8](\(spec.identifier)): rect=\(rect) "
            + "point=\(sequence[0].locationInWindow) "
            + "count=\(spec.clickCount) via=\(via) "
            + "active=\(NSApp.isActive)"
        return true
    }

}
