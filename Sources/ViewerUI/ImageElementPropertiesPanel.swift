import SwiftUI
import AppKit
import ViewerCore

/// TSK-1321 — the element-properties inspector for the image editor. When an overlay shape is
/// selected (`ImageEditorViewModel.selectedShape`), shows an EDIT-AFTER-PLACEMENT form bound to the
/// host-tested selection-edit API (`restyleSelectedShape`): the shape kind, stroke colour, and line
/// width. This is the NON-AX render path for "change a placed element's colour/style" (the owner's
/// TSK-1310/1321 ask) — a form, not an on-canvas drag (the drag-handle interaction is the AX tier,
/// off-limits, see TSK-1188). Selection-gated: renders nothing when no shape is selected, so it is
/// safe to compose unconditionally into the editor's controls column.
struct ImageElementPropertiesPanel: View {
    @ObservedObject var vm: ImageEditorViewModel

    var body: some View {
        if let shape = vm.selectedShape {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Selected Element")
                        .font(.caption).bold().foregroundStyle(.secondary)
                    Spacer()
                    Button("Deselect") { vm.deselectShape() }
                        .controlSize(.small)
                        .accessibilityIdentifier("mdv.imageEditor.element.deselect")
                }
                Text(shape.kind.rawValue.capitalized)
                    .font(.callout)

                ColorPicker("Stroke", selection: Binding(
                    get: { shape.style.stroke.swiftUIColor },
                    set: { newColor in
                        var style = shape.style
                        style.stroke = OverlayColor(newColor)
                        _ = vm.restyleSelectedShape(style)
                    }))
                    .accessibilityIdentifier("mdv.imageEditor.element.stroke")

                HStack {
                    Text("Width").frame(width: 56, alignment: .leading)
                    Slider(value: Binding(
                        get: { shape.style.lineWidth },
                        set: { newWidth in
                            var style = shape.style
                            style.lineWidth = newWidth
                            _ = vm.restyleSelectedShape(style)
                        }), in: 0...20)
                }
                .accessibilityIdentifier("mdv.imageEditor.element.width")
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("mdv.imageEditor.elementProperties")
        }
    }
}

private extension OverlayColor {
    /// The overlay colour as a SwiftUI `Color` (sRGB, alpha-preserving).
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// Build an `OverlayColor` from a SwiftUI `Color`, normalising into sRGB so the stored
    /// components are stable regardless of the picker's working colour space.
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB)
            ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                  b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}
