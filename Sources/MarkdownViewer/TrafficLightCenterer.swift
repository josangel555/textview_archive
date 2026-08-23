import AppKit

/// Owner 2026-08-09 ("center the traffic lights in the session band") —
/// re-implemented 2026-08-22 WITHOUT the empty-unified-toolbar spacer.
///
/// The spacer trick made AppKit lay out a 66pt titlebar container (probed)
/// whose invisible toolbar region swallowed clicks up to ~20px INTO the
/// tab strip below the 46pt session band — the owner's "dead spots right
/// above the text". With no toolbar the titlebar container is the standard
/// ~28pt (entirely within the band); this helper vertically centers the
/// three standard window buttons in the band by shifting their frames.
///
/// AppKit re-lays the buttons out on resize / fullscreen / appearance
/// changes, so the shift re-applies on the relevant notifications. The
/// shift keeps each button inside its (28pt) container minus ~a pixel —
/// hit-testing outside a superview's bounds fails, so we clamp the shift
/// to keep the buttons' clickable area intact.
@MainActor
enum TrafficLightCenterer {
    private static var observers: [NSObjectProtocol] = []

    static func install(on window: NSWindow, bandHeight: CGFloat) {
        apply(to: window, bandHeight: bandHeight)
        // Re-apply after AppKit re-layouts. Coalescing via async is fine —
        // the shift is idempotent.
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated {
                    apply(to: window, bandHeight: bandHeight)
                }
            })
        }
    }

    private static func apply(to window: NSWindow, bandHeight: CGFloat) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttons {
            guard let button = window.standardWindowButton(type),
                  let container = button.superview else { continue }
            // Container coords are non-flipped (origin bottom-left, at the
            // window's top strip). Center the button on the BAND's midline:
            // band midline measured from the window top = bandHeight/2;
            // in container coords that is containerHeight - bandHeight/2
            // ... clamped so the button never leaves the container (its
            // area outside the superview would not hit-test).
            let ch = container.bounds.height
            guard ch > 0 else { continue }
            // Container top == window top; band midline = bandHeight/2 from
            // the top ⇒ in container coords: ch − bandHeight/2. Clamped so
            // the button stays inside the container (area outside a
            // superview's bounds doesn't hit-test) — with a 28pt container
            // this lands ~3px above true center: close, and clickable.
            let targetMidY = ch - bandHeight / 2
            let clampedMidY = min(max(targetMidY, button.frame.height / 2),
                                  ch - button.frame.height / 2)
            var f = button.frame
            f.origin.y = (clampedMidY - f.height / 2).rounded()
            button.frame = f
        }
    }
}
