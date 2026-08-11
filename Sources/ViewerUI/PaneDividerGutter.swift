import AppKit
import SwiftUI

/// I-21 S4d — the visible drag gutter between two editor panes: the
/// sidebar/dock divider idiom (owner 2026-08-09 — the bar you see IS the
/// click target, centred grabber pill). The gutter only reports the
/// drag's axis translation; the weight math lives in `PaneResize`
/// (host-tested) and the drag-start snapshot in `ContentView` (drags
/// operate in RENDERED space, snapshotted at origin — LESSONS).
struct PaneDividerGutter: View {
    static let thickness: CGFloat = 8

    /// True when the pane RUN stacks vertically (split down) — the
    /// gutter is then a horizontal bar resizing up/down.
    let verticalRun: Bool
    /// Axis translation since drag start (+ = right/down).
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    @State private var pushedCursor = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Palette.underPageBackground)
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: verticalRun ? 26 : 3,
                       height: verticalRun ? 3 : 26)
        }
        .frame(width: verticalRun ? nil : Self.thickness,
               height: verticalRun ? Self.thickness : nil)
        .contentShape(Rectangle())
        .onHover { updateCursor(hovering: $0) }
        .onDisappear { updateCursor(hovering: false) }
        .gesture(
            // .global — the gutter itself moves while dragging; local-
            // space translation oscillates + half-tracks (DraggableSidebar
            // lesson, same as the dock band gutter).
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    onDrag(verticalRun ? value.translation.height
                                       : value.translation.width)
                }
                .onEnded { _ in onEnd() }
        )
        // A shapes-only view NEVER materializes an out-of-process AX element:
        // bare id, `.accessibilityElement()`, `children: .contain`, AND
        // label+trait were each proven absent by the AX tooth + scene gate
        // (three VM rounds, 2026-08-11). The declarations stay for IN-process
        // assistive tech; the out-of-process rung is covered by
        // `PaneResizeTests` + the weighted-render pixel check, and the AX
        // drag tooth self-skips on its not-materialized guard (BACKLOG
        // "gutter AX materialization" has the candidate fixes).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane resize handle")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("mdv.pane.resize")
    }

    /// Balanced push/pop (UIRESP-10 — AppKit can re-fire onHover(true)).
    private func updateCursor(hovering: Bool) {
        if hovering {
            if !pushedCursor {
                (verticalRun ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
                pushedCursor = true
            }
        } else if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
    }
}
