import SwiftUI
import ViewerCore

// MARK: - Resizable section divider
//
// 1-px hairline that looks identical to a SwiftUI `Divider()` at rest
// but exposes a 4-px hit zone above + below it. Hovering swaps the
// system cursor to `resizeUpDown`; vertical drag adjusts a height
// binding the parent owns (the section ABOVE this divider).
//
// Interactive drag + cursor hover is not unit-tested on the host —
// AppKit cursor / mouse-tracking events require a live NSApplication
// and a real window. Exercised by the VM-only UI test bundles
// (`Tests/ViewerUITests/...`) and the manual checklist. The clamp
// logic (min-height floor, defaults read-back) lives in
// `SidebarPanelHeights` and IS host-testable.
//
// Layout note: the divider is meant to sit BETWEEN two sections in
// the sidebar `VStack`. It does not own the height of the section
// above; it only mutates the binding the parent passes in. That keeps
// the divider stateless and lets the parent persist via
// `@AppStorage`.
struct ResizableSectionDivider: View {
    /// Binding for the height of the section directly above this
    /// divider. Drag deltas are added to it and re-clamped.
    @Binding var heightAbove: CGFloat
    /// True when the section above is collapsed (header-only). The
    /// drag handle is still drawn (so the visual divider is uniform)
    /// but interaction is disabled — there's nothing meaningful to
    /// resize when only a header is showing.
    var isAboveCollapsed: Bool = false

    @State private var dragStartHeight: CGFloat? = nil

    var body: some View {
        ZStack {
            // The hairline. Matches a stock `Divider()` in colour
            // and weight; rendered as the literal Divider so the
            // appearance tracks the system style automatically (dark
            // mode / increased-contrast).
            Divider()
        }
        // 4-px hit zone — wider than the 1-px hairline so the user
        // doesn't have to be pixel-perfect. The Divider itself stays
        // centred inside.
        .frame(height: 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            // Only swap the cursor when the section above can
            // actually be resized — i.e. it's expanded.
            guard !isAboveCollapsed else {
                if !hovering { NSCursor.arrow.set() }
                return
            }
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(dragGesture)
        .accessibilityIdentifier("mdv.sidebar.resizeHandle")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isAboveCollapsed else { return }
                if dragStartHeight == nil {
                    dragStartHeight = heightAbove
                }
                let base = dragStartHeight ?? heightAbove
                heightAbove = SidebarPanelHeights.clamp(
                    base + value.translation.height
                )
            }
            .onEnded { _ in
                dragStartHeight = nil
            }
    }
}
