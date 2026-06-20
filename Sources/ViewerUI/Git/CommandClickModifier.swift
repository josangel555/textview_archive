import AppKit
import SwiftUI

/// AppKit-backed modifier that distinguishes a plain click from a Cmd-click
/// (SwiftUI's `List` selection alone can't tell us the modifier). We layer a
/// transparent click-catcher that reports the `command` flag; the underlying
/// `List` row still handles plain selection so keyboard / VoiceOver navigation
/// is unaffected.
///
/// Shared by the git `FileHistoryView` and the unified `UnifiedHistoryView`
/// (TSK-1103) — both need Cmd-click-arms-a-range row behavior, so the one
/// implementation lives here.
struct CommandClickModifier: ViewModifier {
    let onClick: (_ command: Bool) -> Void

    func body(content: Content) -> some View {
        content.overlay(
            CommandClickCatcher(onClick: onClick)
        )
    }
}

private struct CommandClickCatcher: NSViewRepresentable {
    let onClick: (_ command: Bool) -> Void

    func makeNSView(context: Context) -> ClickView {
        let v = ClickView()
        v.onClick = onClick
        return v
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onClick = onClick
    }

    final class ClickView: NSView {
        var onClick: ((_ command: Bool) -> Void)?

        // Only intercept Cmd-clicks; let plain clicks fall through to the
        // List row beneath so normal selection / hover still works.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            if event.type == .leftMouseDown,
               event.modifierFlags.contains(.command) {
                return super.hitTest(point)
            }
            return nil
        }

        override func mouseDown(with event: NSEvent) {
            onClick?(event.modifierFlags.contains(.command))
        }
    }
}
