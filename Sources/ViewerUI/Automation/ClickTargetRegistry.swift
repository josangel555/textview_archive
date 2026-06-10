import AppKit
import SwiftUI

/// TSK-620 half B: SwiftUI-side click-target registration.
///
/// The in-process accessibility tree is EMPTY (SwiftUI materializes AX
/// elements only for external AX clients, and xctest AX TCC is
/// owner-only), and SwiftUI controls inside an NSHostingView are not
/// NSViews — so neither an NSView walk nor an AX walk can locate a
/// SwiftUI control by its accessibility id (LESSONS 2026-06-10, the
/// five constraints). Instead, opted-in controls PUBLISH their own
/// frames: `.uiClickTarget("mdv.x")` streams the control's `.global`
/// frame into this registry via `onGeometryChange`, and
/// `UIEventSynth.resolveTargetRect` consults the registry FIRST. The
/// coordinates feed the existing NSEvent builder unchanged.
///
/// Frames are stored in SwiftUI GLOBAL space (the hosting view's
/// coordinate space, top-left origin, y-down). Conversion to AppKit
/// window coordinates happens at resolve time against the live
/// contentView — `windowRect(fromSwiftUIGlobal:contentView:)` — so a
/// window resize between publish and click is harmless as long as the
/// control re-published (onGeometryChange fires on any frame change).
@MainActor
public final class ClickTargetRegistry {

    public static let shared = ClickTargetRegistry()

    /// id → most recent frame in SwiftUI .global space.
    private var frames: [String: CGRect] = [:]

    /// Test seam: instances are constructible so registry semantics are
    /// unit-testable without mutating the shared one.
    public init() {}

    public func update(id: String, frame: CGRect) {
        frames[id] = frame
    }

    /// Called from `onDisappear` so an unmounted control can't be
    /// "clicked" at its stale last-known frame.
    public func remove(id: String) {
        frames.removeValue(forKey: id)
    }

    public func frame(for id: String) -> CGRect? {
        frames[id]
    }

    /// Sorted snapshot of registered ids — failure-trace fodder.
    public var identifiers: [String] {
        frames.keys.sorted()
    }

    /// Convert a SwiftUI `.global`-space rect (top-left origin within the
    /// hosting view) to AppKit WINDOW coordinates. The app's contentView
    /// IS the NSHostingView (`contentViewController` pattern in
    /// main.swift), so global space == contentView space modulo y-flip;
    /// flip only when the contentView is not already flipped, then let
    /// AppKit do the window conversion.
    public static func windowRect(fromSwiftUIGlobal rect: CGRect,
                                  contentView root: NSView) -> NSRect {
        let local: NSRect
        if root.isFlipped {
            local = rect
        } else {
            local = NSRect(x: rect.minX,
                           y: root.bounds.height - rect.maxY,
                           width: rect.width,
                           height: rect.height)
        }
        return root.convert(local, to: nil)
    }
}

public extension View {
    /// Opt this control into the `ui-click` script harness: publish its
    /// global frame (and keep it fresh across layout changes) under
    /// `id`, withdrawing it on disappear. Pair with the SAME string used
    /// for `.accessibilityIdentifier` so dump/AX tooling and the click
    /// harness agree on names.
    func uiClickTarget(_ id: String) -> some View {
        self
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                ClickTargetRegistry.shared.update(id: id, frame: frame)
            }
            .onDisappear {
                ClickTargetRegistry.shared.remove(id: id)
            }
    }
}
