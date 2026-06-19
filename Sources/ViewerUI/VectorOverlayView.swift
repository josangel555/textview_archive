import CoreGraphics
import SwiftUI
import ViewerCore

/// Minimal SwiftUI render overlay for the image editor's vector annotations
/// (TSK-287). Draws a `ViewerCore.VectorOverlay` — rectangles, ellipses, lines,
/// arrows — above the image preview, back-to-front (`shapes[0]` first, last on
/// top), mapping each shape's normalized `0...1` frame into the displayed image
/// rect supplied by the parent.
///
/// Implemented with SwiftUI's `Canvas` (a single CoreGraphics-backed draw pass),
/// NOT an `NSViewRepresentable`: it stays a pure SwiftUI sibling so it composites
/// over the `Image` preview without the opaque-representable occlusion trap
/// (CLAUDE.md, TSK-488). The model is fully host-tested; this draw path is the
/// render-gated remainder validated on the VM pixel lane.
struct VectorOverlayView: View {
    /// The shapes to draw. Order is z-order: index 0 back, last front.
    let overlay: VectorOverlay
    /// The on-screen rect (in this view's local space) the normalized `0...1`
    /// image coordinates map into — i.e. where the fitted image actually sits.
    let imageRect: CGRect

    var body: some View {
        Canvas { ctx, _ in
            for shape in overlay.shapes {
                Self.draw(shape, in: ctx, imageRect: imageRect)
            }
        }
        .accessibilityIdentifier("mdv.imageEditor.vectorOverlay")
        .allowsHitTesting(false)
    }

    /// Map a normalized point (`0...1`, top-left origin) into the displayed rect.
    private static func map(_ p: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    /// Map a normalized frame into the displayed rect.
    private static func map(_ f: CGRect, _ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + f.minX * rect.width,
            y: rect.minY + f.minY * rect.height,
            width: f.width * rect.width,
            height: f.height * rect.height)
    }

    private static func draw(_ shape: VectorShape, in ctx: GraphicsContext, imageRect: CGRect) {
        let style = shape.style
        let stroke = Color(rgba: style.stroke)
        switch shape.kind {
        case .rect:
            let r = map(shape.frame, imageRect)
            let path = Path(r)
            if let fill = style.fill { ctx.fill(path, with: .color(Color(rgba: fill))) }
            if style.lineWidth > 0, style.stroke.a > 0 {
                ctx.stroke(path, with: .color(stroke), lineWidth: style.lineWidth)
            }
        case .ellipse:
            let r = map(shape.frame, imageRect)
            let path = Path(ellipseIn: r)
            if let fill = style.fill { ctx.fill(path, with: .color(Color(rgba: fill))) }
            if style.lineWidth > 0, style.stroke.a > 0 {
                ctx.stroke(path, with: .color(stroke), lineWidth: style.lineWidth)
            }
        case .line:
            guard style.lineWidth > 0, style.stroke.a > 0 else { return }
            let a = map(shape.start, imageRect)
            let b = map(shape.end, imageRect)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            ctx.stroke(path, with: .color(stroke), lineWidth: style.lineWidth)
        case .arrow:
            guard style.lineWidth > 0, style.stroke.a > 0 else { return }
            let a = map(shape.start, imageRect)
            let b = map(shape.end, imageRect)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            // Arrowhead: two short barbs at `b`, angled 30° off the shaft, sized
            // proportionally to the stroke so it scales with the line weight.
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(8, style.lineWidth * 4)
            let barb = CGFloat.pi / 6
            let left = CGPoint(
                x: b.x - head * cos(angle - barb), y: b.y - head * sin(angle - barb))
            let right = CGPoint(
                x: b.x - head * cos(angle + barb), y: b.y - head * sin(angle + barb))
            path.move(to: left)
            path.addLine(to: b)
            path.addLine(to: right)
            ctx.stroke(path, with: .color(stroke), lineWidth: style.lineWidth)
        }
    }
}

extension Color {
    /// Bridge the host-testable `RGBAColor` (straight-alpha sRGB `0...1`) into a
    /// SwiftUI `Color` for the draw path.
    init(rgba: RGBAColor) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}
