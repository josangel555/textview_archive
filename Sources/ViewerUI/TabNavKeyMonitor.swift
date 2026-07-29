import AppKit
import SwiftUI

/// App-wide monitor for the extra **tab-navigation** shortcuts (TSK-1591):
/// `⌃Tab` / `⌃⇧Tab` (cycle forward / back — the browser convention) and
/// `⌘]` / `⌘[` (next / previous — the Safari/Terminal convention). Mirrors
/// `DoubleShiftMonitor` / `EscFocusMonitor`: an otherwise-empty
/// `NSViewRepresentable` that installs a local `NSEvent` monitor and routes the
/// decision through a pure, host-testable classifier (``TabNavKeyMonitor/classify``).
///
/// These live in a monitor rather than menu key-equivalents because `⌃Tab`
/// isn't a clean menu shortcut, and because the monitor sees the event before
/// the CM6 WebView so tab-switching works even while the editor has focus. The
/// existing `⌘⇧]` / `⌘⇧[` menu items are unaffected (this only claims the four
/// NEW combos).
///
/// `⌘[` / `⌘]` are DEFERRED to an active walkthrough (whose player binds the
/// same combo to step nav): while a walkthrough runs, the classifier returns
/// `.none` for that pair so the event passes through to the overlay. `⌃Tab`
/// has no such conflict and always switches tabs.
struct TabNavKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    /// True while a walkthrough is playing — suppresses the `⌘[`/`⌘]` capture
    /// so the player keeps those keys for step navigation.
    let walkthroughActive: Bool
    let onNext: () -> Void
    let onPrev: () -> Void

    enum Action: Equatable { case next, prev, none }

    /// Pure key → action mapping (host-testable, no live window).
    /// `keyCode 48` is Tab; `chars` is `charactersIgnoringModifiers`.
    /// `modifiers` must already be masked to `deviceIndependentFlagsMask`.
    static func classify(
        keyCode: UInt16,
        chars: String,
        modifiers: NSEvent.ModifierFlags,
        walkthroughActive: Bool
    ) -> Action {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
        // ⌃Tab / ⌃⇧Tab — exact modifier match so ⌘⌃Tab etc. don't fire.
        if keyCode == 48 {
            if mods == [.control, .shift] { return .prev }
            if mods == [.control] { return .next }
            return .none
        }
        // ⌘] / ⌘[ — command ONLY (⌘⇧] is the existing menu item; ⌥⌘[ is Fold
        // All), and never while a walkthrough owns the combo.
        if mods == [.command], !walkthroughActive {
            if chars == "]" { return .next }
            if chars == "[" { return .prev }
        }
        return .none
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.update(onNext: onNext, onPrev: onPrev, walkthroughActive: walkthroughActive)
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(onNext: onNext, onPrev: onPrev, walkthroughActive: walkthroughActive)
        context.coordinator.setActive(isActive)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var monitor: Any?
        private var onNext: (() -> Void)?
        private var onPrev: (() -> Void)?
        private var walkthroughActive = false

        func update(onNext: @escaping () -> Void, onPrev: @escaping () -> Void, walkthroughActive: Bool) {
            self.onNext = onNext
            self.onPrev = onPrev
            self.walkthroughActive = walkthroughActive
        }

        func setActive(_ active: Bool) {
            if active && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // Pull primitives out of the (non-Sendable) NSEvent before
                    // the isolation scope — same pattern as DoubleShiftMonitor.
                    let keyCode = event.keyCode
                    let chars = event.charactersIgnoringModifiers ?? ""
                    let mods = event.modifierFlags
                    let result: Action = MainActor.assumeIsolated {
                        guard let self else { return .none }
                        return TabNavKeyMonitor.classify(
                            keyCode: keyCode, chars: chars, modifiers: mods,
                            walkthroughActive: self.walkthroughActive)
                    }
                    switch result {
                    case .next:
                        MainActor.assumeIsolated { self?.onNext?() }
                        return nil   // consume
                    case .prev:
                        MainActor.assumeIsolated { self?.onPrev?() }
                        return nil   // consume
                    case .none:
                        return event
                    }
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            MainActor.assumeIsolated {
                if let m = monitor { NSEvent.removeMonitor(m) }
            }
        }
    }
}
