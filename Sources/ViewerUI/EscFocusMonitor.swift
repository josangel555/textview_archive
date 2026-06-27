import AppKit
import SwiftUI
import WebKit

/// App-wide monitor for **Esc → return focus to the active document tab**
/// (TSK-938). Mirrors `DoubleShiftMonitor` / `SidebarKeyMonitor`: an
/// otherwise-empty `NSViewRepresentable` that installs a local `NSEvent`
/// monitor and routes the firing decision through a pure, host-testable core
/// (the model's `returnFocusToActiveDocument` + the
/// ``EscFocusMonitor/firstResponderIsDocument(_:editorView:)`` classifier here).
///
/// When the keyboard is parked in a tool surface (file-nav / search / git /
/// terminal / any non-document field) and the user hits Esc, the active
/// document re-takes first responder by bumping the SAME focus-request nonce
/// TSK-905/906 already drive — no new focus path. If Esc is pressed while focus
/// is ALREADY on the document, this is a no-op (the over-grab guard) and the
/// event passes through so other Esc handlers (palette dismiss, find-bar close)
/// still see it.
///
/// The command palette owns its own Esc dismiss, so when the palette is
/// presented we never intercept — its overlay is the first responder and the
/// model's `returnFocusToActiveDocument` doesn't fire there.
struct EscFocusMonitor: NSViewRepresentable {
    /// Whether the gesture is armed (mounted-but-inactive removes the monitor).
    let isActive: Bool
    /// Resolve "is focus already on the document?" then hand control to the
    /// model. Returns `true` iff the model bumped a focus nonce (handled the
    /// Esc) — the monitor then CONSUMES the event so it doesn't also drive a
    /// downstream Esc handler; otherwise the event passes through unchanged.
    let onEscape: (_ currentFocusIsDocument: Bool) -> Bool

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onEscape = onEscape
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.setActive(isActive)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Pure classifier (host-testable, no live window): is `firstResponder` a
    /// DOCUMENT surface rather than a tool surface? A document surface is:
    ///   - the CM6 editor webview (or a descendant of it) — passed in as a
    ///     plain `NSView` (a `WKWebView` is one), the same shape
    ///     `SidebarKeyMonitor.shouldYield` uses so the test needs no live
    ///     WebView;
    ///   - any `WKWebView` first-responder — the rendered-markdown preview is a
    ///     `WKWebView`, and so is the editor, so "focus is on SOME document
    ///     webview" collapses to one check (the model's over-grab guard handles
    ///     the editor-vs-preview distinction);
    ///   - an `NSText` (NSTextView / field editor) ONLY when it lives inside the
    ///     content pane (`contentRoot`) — the Source/Formatted/Diff document
    ///     panes are NSTextViews, but so are the search field, rename prompt, and
    ///     terminal-adjacent fields, which are NOT document surfaces. Without a
    ///     content root we can't tell them apart, so a bare `NSText` is treated
    ///     as NON-document (conservative: Esc returns focus to the document
    ///     rather than risk a no-op when the user is in a tool field).
    @MainActor
    static func firstResponderIsDocument(
        _ firstResponder: NSResponder?,
        editorViews: [NSView],
        contentRoot: NSView? = nil
    ) -> Bool {
        guard let fr = firstResponder else { return false }
        // Check EVERY mounted editor pane, not just one: with MountedPanesLRU the
        // key window hosts several editor webviews and the focused one may not be
        // `current()`, so the focused pane's Esc would be mis-classified as a
        // tool surface — the same multi-pane leak class as SidebarKeyMonitor
        // (TSK-1280). The caller passes registry.liveWebViews.
        if let v = fr as? NSView,
           editorViews.contains(where: { v === $0 || v.isDescendant(of: $0) }) {
            return true
        }
        if fr is WKWebView { return true }
        if fr is NSText, let v = fr as? NSView, let root = contentRoot {
            return v === root || v.isDescendant(of: root)
        }
        return false
    }

    @MainActor
    final class Coordinator {
        var monitor: Any?
        var onEscape: ((Bool) -> Bool)?

        func setActive(_ active: Bool) {
            if active && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // Esc only (keyCode 53). Pull primitives out of the
                    // (non-Sendable) NSEvent before the isolation scope — same
                    // pattern as SidebarKeyMonitor / DoubleShiftMonitor.
                    guard event.keyCode == 53,
                          event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
                    else { return event }
                    let consume: Bool = MainActor.assumeIsolated {
                        guard let self, let onEscape = self.onEscape else { return false }
                        let fr = NSApp.keyWindow?.firstResponder
                        // ALL mounted editor panes, not just current() — current()
                        // can be an inactive pane under MountedPanesLRU (TSK-1280).
                        let editors = CodeMirrorEditorRegistry.shared.liveWebViews
                        let onDoc = EscFocusMonitor.firstResponderIsDocument(fr, editorViews: editors)
                        return onEscape(onDoc)
                    }
                    // Consume only when the model handled it; otherwise let
                    // other Esc handlers (palette dismiss, find-bar close) see it.
                    return consume ? nil : event
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
