import CoreGraphics
import SwiftUI
import ViewerCore

/// TSK-1168 — the selection outline + eight resize handles for the vector shape
/// being edited on the image canvas (the `.editShapes` tool). Pure SwiftUI
/// (`Canvas` sibling, no `NSViewRepresentable` → no occlusion trap), drawn OVER
/// `VectorOverlayView`. Handle positions come from the host-tested
/// `ShapeDragGeometry.handlePoints`; the drag that consumes them is wired in
/// `ImageEditorView` and validated on the VM/AX lane.
struct ShapeSelectionHandlesView: View {
    /// The selected shape's normalized (`0...1`, top-left origin) frame.
    let frame: CGRect
    /// The on-screen rect the normalized coordinates map into (the fitted image).
    let imageRect: CGRect

    private let handleSize: CGFloat = 8

    var body: some View {
        Canvas { ctx, _ in
            // Dashed selection outline around the shape's bounding box.
            ctx.stroke(
                Path(mapped(frame).standardized),
                with: .color(.accentColor),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            // A grab square at each of the eight handles.
            for (_, p) in ShapeDragGeometry.handlePoints(for: frame) {
                let c = map(p)
                let box = CGRect(
                    x: c.x - handleSize / 2, y: c.y - handleSize / 2,
                    width: handleSize, height: handleSize)
                ctx.fill(Path(box), with: .color(.white))
                ctx.stroke(Path(box), with: .color(.accentColor), lineWidth: 1)
            }
        }
        .accessibilityIdentifier("mdv.imageEditor.selectionHandles")
    }

    private func map(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: imageRect.minX + p.x * imageRect.width,
            y: imageRect.minY + p.y * imageRect.height)
    }

    private func mapped(_ f: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + f.minX * imageRect.width,
            y: imageRect.minY + f.minY * imageRect.height,
            width: f.width * imageRect.width,
            height: f.height * imageRect.height)
    }
}
