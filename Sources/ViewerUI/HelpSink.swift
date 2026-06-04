import SwiftUI
import ViewerKit

/// Holds the `HelpInfo` for the element the pointer is currently hovering,
/// so the status bar can show its longer `description`.
///
/// Deliberately a SEPARATE `ObservableObject` from `DocumentModel` (not a
/// `@Published` on the god-object): `.onHover` fires on the render thread on
/// every hover enter/leave across the whole UI, and routing that through
/// `DocumentModel` would republish unrelated views on every pointer move —
/// the exact republish-amplification trap LESSONS.md warns against. As its
/// own small observable, only views that observe `HelpSink` re-render.
///
/// The setter dedupes on equal value (`HelpInfo: Equatable`) so a hover that
/// doesn't change the displayed info is a no-op (no `objectWillChange`).
@MainActor
public final class HelpSink: ObservableObject {
    @Published public private(set) var hovered: HelpInfo?

    /// `nonisolated` so the process-wide `shared` instance (and thus the
    /// `EnvironmentKey.defaultValue`) can be created without main-actor
    /// isolation. Initializing the `@Published` to `nil` touches no
    /// main-actor state.
    public nonisolated init() {}

    /// Process-wide default. Used as the environment default so the
    /// `.helpInfo(_:)` modifier and the status-bar consumer share one
    /// instance WITHOUT requiring an explicit injection at the (out-of-scope)
    /// ContentView root. A host that wants per-window isolation can override
    /// `\.helpSink` in the environment.
    ///
    /// `nonisolated(unsafe)` so it can seed the `EnvironmentKey.defaultValue`
    /// (which Swift 6 requires be non-isolated). The instance is only ever
    /// touched on the main actor in practice (`.onHover` and the StatusBar
    /// read both run there), so the "unsafe" escape is sound here.
    nonisolated(unsafe) public static let shared = HelpSink()

    /// Push the hovered element's help info (or `nil` on hover-exit).
    /// No-op when the value is unchanged.
    public func set(_ info: HelpInfo?) {
        guard hovered != info else { return }
        hovered = info
    }
}

/// Environment slot for the active `HelpSink`. Defaults to `HelpSink.shared`
/// so producers (`.helpInfo`) and the consumer (StatusBar) line up with zero
/// wiring at the root.
private struct HelpSinkKey: EnvironmentKey {
    static let defaultValue: HelpSink = HelpSink.shared
}

public extension EnvironmentValues {
    var helpSink: HelpSink {
        get { self[HelpSinkKey.self] }
        set { self[HelpSinkKey.self] = newValue }
    }
}

// NOTE (UX-H, #230): the `.helpInfo(...)` View modifier now lives in
// `FloatingTooltip.swift`. It still feeds this `HelpSink` (the status-bar
// description slot) and sets the native `.help` + a11y label/hint, but it
// ALSO drives the custom floating tooltip overlay. `HelpSink` itself is
// unchanged — it remains the narrow observable for the status-bar feed.
