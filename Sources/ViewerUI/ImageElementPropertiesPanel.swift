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

                if shape.kind == .text {
                    // TSK-1310: the editable text + size for a retained .text element.
                    TextField("Text", text: Binding(
                        get: { shape.text ?? "" },
                        set: { _ = vm.setSelectedShapeText($0, fontSize: shape.fontSize) }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("mdv.imageEditor.element.text")
                    HStack {
                        Text("Size").frame(width: 56, alignment: .leading)
                        Slider(value: Binding(
                            get: { shape.fontSize ?? 0.06 },
                            set: { _ = vm.setSelectedShapeText(shape.text, fontSize: $0) }),
                            in: 0.01...0.3)
                    }
                    .accessibilityIdentifier("mdv.imageEditor.element.fontSize")
                    HStack {
                        Toggle("Bold", isOn: Binding(
                            get: { shape.bold == true },
                            set: { _ = vm.setSelectedShapeTextStyle(bold: $0, italic: shape.italic) }))
                        Toggle("Italic", isOn: Binding(
                            get: { shape.italic == true },
                            set: { _ = vm.setSelectedShapeTextStyle(bold: shape.bold, italic: $0) }))
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("mdv.imageEditor.element.fontStyle")
                }

                ColorPicker("Stroke", selection: Binding(
                    get: { shape.style.stroke.swiftUIColor },
                    set: { newColor in
                        var style = shape.style
                        style.stroke = OverlayColor(newColor)
                        _ = vm.restyleSelectedShape(style)
                    }))
                    .accessibilityIdentifier("mdv.imageEditor.element.stroke")

                // Fill — closed shapes only (rect/ellipse/roundedRect). Activates the dormant
                // style.fill capability: the draw path already fills a shape whose fill is non-nil,
                // but no UI ever set it, so every shape was unfilled. TSK-1321 editable props.
                if shape.kind == .rect || shape.kind == .ellipse || shape.kind == .roundedRect {
                    Toggle("Fill", isOn: Binding(
                        get: { shape.style.fill != nil },
                        set: { on in
                            var style = shape.style
                            style.fill = on ? (style.fill ?? shape.style.stroke) : nil
                            _ = vm.restyleSelectedShape(style)
                        }))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("mdv.imageEditor.element.fillToggle")
                    if shape.style.fill != nil {
                        ColorPicker("Fill color", selection: Binding(
                            get: { (shape.style.fill ?? shape.style.stroke).swiftUIColor },
                            set: { newColor in
                                var style = shape.style
                                style.fill = OverlayColor(newColor)
                                _ = vm.restyleSelectedShape(style)
                            }))
                            .accessibilityIdentifier("mdv.imageEditor.element.fill")
                    }
                }

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

                HStack {
                    Text("Rotation").frame(width: 56, alignment: .leading)
                    Slider(value: Binding(
                        get: { shape.rotation ?? 0 },
                        set: { _ = vm.setSelectedShapeRotation($0) }), in: -180...180)
                }
                .accessibilityIdentifier("mdv.imageEditor.element.rotation")

                // Position & size (normalized 0…1) via the form — the non-AX "move it / resize"
                // path → the host-tested resizeSelectedShape. The on-canvas drag is the AX tier.
                Text("Position & Size").font(.caption).foregroundStyle(.secondary)
                frameSlider("X", \.origin.x, shape)
                frameSlider("Y", \.origin.y, shape)
                frameSlider("W", \.size.width, shape)
                frameSlider("H", \.size.height, shape)
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("mdv.imageEditor.elementProperties")
        }
    }

    /// A normalized (0…1) slider for one component of the selected shape's frame, committed via the
    /// host-tested `resizeSelectedShape` (set the whole frame each change — the model is the source
    /// of truth and re-reads `selectedShape` on the next render).
    @ViewBuilder private func frameSlider(
        _ label: String, _ keyPath: WritableKeyPath<CGRect, CGFloat>, _ shape: VectorShape
    ) -> some View {
        HStack {
            Text(label).frame(width: 20, alignment: .leading).font(.caption)
            Slider(value: Binding(
                get: { Double(shape.frame[keyPath: keyPath]) },
                set: { newValue in
                    var frame = shape.frame
                    frame[keyPath: keyPath] = CGFloat(newValue)
                    _ = vm.resizeSelectedShape(to: frame)
                }), in: 0...1)
        }
        .accessibilityIdentifier("mdv.imageEditor.element.frame.\(label)")
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
