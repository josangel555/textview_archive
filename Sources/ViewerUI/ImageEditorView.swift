import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ViewerCore

/// Minimal image-editor PoC view (TSK-342) — binds to the host-tested
/// `ImageEditorViewModel`. Left: the live WYSIWYG preview of the edited
/// document. Right: the controls (tonal sliders + geometry + history + save).
///
/// All the heavy lifting (decode → ops → CGImage, export) is in the engine /
/// view-model, both host-tested; this view is the thin, render-gated binding
/// layer whose on-screen behaviour is validated on the VM pixel/AX lane.
/// a11y identifiers (`mdv.imageEditor.*`) exist so that VM UI test can find the
/// preview + a slider + the Done button.
struct ImageEditorView: View {
    @StateObject private var vm: ImageEditorViewModel
    /// TSK-1101 — last canvas pixel painted this drag, for continuous brush strokes.
    @State private var lastPaintPixel: (x: Int, y: Int)?
    /// Called when the user dismisses the editor (returns to the plain viewer).
    let onClose: () -> Void

    init(url: URL, onClose: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: ImageEditorViewModel(ImageDocument(contentsOf: url)))
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            preview
                // The floor matters: in a panel-crowded narrow window the
                // flexible preview otherwise collapses to ~0pt while the
                // fixed-width controls survive — an "editor with no image"
                // (TSK-618). Better to overflow/clip the controls edge than
                // to silently hide the document being edited.
                .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.windowBackground)
            Divider()
            controls
                .frame(width: 260)
                .background(.regularMaterial)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("mdv.imageEditor")
    }

    // MARK: - preview

    @ViewBuilder private var preview: some View {
        if let cg = vm.rendered {
            GeometryReader { geo in
                let displayed = Self.aspectFitRect(
                    imageSize: CGSize(width: cg.width, height: cg.height),
                    in: geo.frame(in: .local))
                ZStack {
                    Image(cg, scale: 1, label: Text("Edited image preview"))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .accessibilityIdentifier("mdv.imageEditor.preview")
                    // Vector annotations (TSK-287) draw OVER the raster, in the
                    // exact rect the fitted image occupies — a pure SwiftUI
                    // sibling (Canvas), so no opaque-representable occlusion.
                    VectorOverlayView(overlay: vm.overlay, imageRect: displayed)
                }
                .contentShape(Rectangle())
                // TSK-1101: map drag/tap → canvas pixel → apply the current paint
                // tool. Brush sweeps a continuous stroke; eyedropper/bucket act on
                // release. Off-image points map to nil and paint nothing.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard vm.tool == .brush,
                                  let px = PaintCoordinateMapping.canvasPixel(
                                      value.location, in: displayed,
                                      imageWidth: cg.width, imageHeight: cg.height)
                            else { return }
                            if let last = lastPaintPixel {
                                vm.brushStroke(fromX: last.x, y0: last.y, toX: px.x, y1: px.y)
                            } else {
                                vm.applyTool(atX: px.x, y: px.y)
                            }
                            lastPaintPixel = px
                        }
                        .onEnded { value in
                            defer { lastPaintPixel = nil }
                            guard vm.tool != .none,
                                  let px = PaintCoordinateMapping.canvasPixel(
                                      value.location, in: displayed,
                                      imageWidth: cg.width, imageHeight: cg.height)
                            else { return }
                            if vm.tool != .brush {
                                vm.applyTool(atX: px.x, y: px.y)
                            }
                        }
                )
            }
            .padding(16)
        } else {
            ContentUnavailableView(
                "Couldn't render image", systemImage: "exclamationmark.triangle",
                description: Text(vm.lastError ?? "Unknown error"))
                .accessibilityIdentifier("mdv.imageEditor.error")
        }
    }

    // MARK: - controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Edit Image").font(.headline)
                    Spacer()
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("mdv.imageEditor.done")
                }

                groupLabel("Tone")
                slider("Brightness", \.brightness, -1, 1, id: "brightness")
                slider("Contrast", \.contrast, 0, 2, id: "contrast")
                slider("Saturation", \.saturation, 0, 2, id: "saturation")
                slider("Exposure", \.exposureEV, -2, 2, id: "exposure")
                slider("Shadows", \.shadow, 0, 1, id: "shadow")
                slider("Highlights", \.highlight, 0, 1, id: "highlight")
                slider("Sharpen", \.sharpness, 0, 2, id: "sharpen")

                groupLabel("Geometry")
                HStack {
                    Button { vm.commitGeometry(.orient(.right90)) } label: {
                        Label("Rotate", systemImage: "rotate.right")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.rotate")
                    Button { vm.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!vm.canUndo)
                    .accessibilityIdentifier("mdv.imageEditor.undo")
                    Button { vm.redo() } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!vm.canRedo)
                    .accessibilityIdentifier("mdv.imageEditor.redo")
                }

                // Minimal draw-tool affordance (TSK-749): commits a shape / text
                // op to the undo history. Each draw is undoable via the buttons
                // above. A full marquee/drag tool is the render-gated remainder.
                groupLabel("Draw")
                HStack {
                    Button { commitCenteredShape() } label: {
                        Label("Box", systemImage: "rectangle")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.drawBox")
                    Button { commitSampleText() } label: {
                        Label("Text", systemImage: "textformat")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.drawText")
                }

                groupLabel("Paint")
                paintControls

                groupLabel("Annotations")
                HStack {
                    Button { vm.addShape(Self.centeredShape(.rect)) } label: {
                        Image(systemName: "rectangle")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.addRect")
                    Button { vm.addShape(Self.centeredShape(.ellipse)) } label: {
                        Image(systemName: "circle")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.addEllipse")
                    Button { vm.addShape(Self.centeredShape(.line)) } label: {
                        Image(systemName: "line.diagonal")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.addLine")
                    Button { vm.addShape(Self.centeredShape(.arrow)) } label: {
                        Image(systemName: "arrow.up.right")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.addArrow")
                    Button { vm.clearShapes() } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.clearShapes")
                    .disabled(vm.overlay.isEmpty)
                }

                groupLabel("Document")
                HStack {
                    Button("Reset Tone") { vm.resetTonal() }
                    Button("Revert All") { vm.revertAll() }
                }
                Button {
                    saveCopy()
                } label: {
                    Label("Save a Copy…", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("mdv.imageEditor.save")

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    /// Commit a centered, half-size stroked box onto the current render. Sized
    /// from the rendered raster's dimensions so it lands sensibly on any image;
    /// the precise placement/drag tool is the render-gated remainder (TSK-749).
    private func commitCenteredShape() {
        guard let image = vm.rendered else { return }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = CGRect(x: w * 0.25, y: h * 0.25, width: w * 0.5, height: h * 0.5)
        vm.commitDraw(.strokeRect(rect, .red, lineWidth: max(2, w / 100)))
    }

    /// Commit a sample text label near the top-left of the current render. A
    /// placeholder for the (render-gated) text-entry tool; proves the wiring.
    private func commitSampleText() {
        guard let image = vm.rendered else { return }
        let h = CGFloat(image.height)
        vm.commitDraw(.drawText("Text", origin: CGPoint(x: 12, y: 12),
                                .black, fontSize: Double(max(16, h / 12))))
    }

    // MARK: - paint tools (TSK-285)

    /// Raster paint affordance: tool picker (eyedropper / brush / bucket), color
    /// swatch, brush size, fill tolerance, and a discard. The tap-to-paint surface
    /// is the preview itself, wired on the VM via `applyTool(atX:y:)` — that
    /// gesture mapping (image point → canvas pixel) is the render-gated remainder
    /// validated on the VM; the model behaviour each control drives is host-tested.
    @ViewBuilder private var paintControls: some View {
        Picker("Tool", selection: $vm.tool) {
            Text("Off").tag(ImageEditorViewModel.RasterTool.none)
            Image(systemName: "eyedropper").tag(ImageEditorViewModel.RasterTool.colorPicker)
            Image(systemName: "paintbrush.pointed").tag(ImageEditorViewModel.RasterTool.brush)
            Image(systemName: "drop").tag(ImageEditorViewModel.RasterTool.floodFill)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("mdv.imageEditor.paintTool")

        ColorPicker("Color", selection: paintColorBinding, supportsOpacity: true)
            .accessibilityIdentifier("mdv.imageEditor.paintColor")

        VStack(alignment: .leading, spacing: 2) {
            Text("Brush Size: \(vm.brushRadius)").font(.caption)
            Slider(
                value: Binding(
                    get: { Double(vm.brushRadius) },
                    set: { vm.brushRadius = Int($0.rounded()) }),
                in: 0...32)
                .accessibilityIdentifier("mdv.imageEditor.brushSize")
        }

        VStack(alignment: .leading, spacing: 2) {
            Text("Fill Tolerance: \(vm.fillTolerance)").font(.caption)
            Slider(
                value: Binding(
                    get: { Double(vm.fillTolerance) },
                    set: { vm.fillTolerance = UInt8(max(0, min(255, $0.rounded()))) }),
                in: 0...255)
                .accessibilityIdentifier("mdv.imageEditor.fillTolerance")
        }

        if vm.hasPaint {
            Button("Discard Paint") { vm.discardPaint() }
                .accessibilityIdentifier("mdv.imageEditor.discardPaint")
        }
    }

    /// Bridge the VM's straight-RGBA8 `paintColor` to SwiftUI's `Color` for the
    /// `ColorPicker`. The setter resolves the picked `Color` into 8-bit sRGB
    /// components via `NSColor`.
    private var paintColorBinding: Binding<Color> {
        Binding(
            get: {
                let c = vm.paintColor
                return Color(.sRGB,
                             red: Double(c.r) / 255, green: Double(c.g) / 255,
                             blue: Double(c.b) / 255, opacity: Double(c.a) / 255)
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
                vm.paintColor = RGBAColor(
                    r: byte(ns.redComponent), g: byte(ns.greenComponent),
                    b: byte(ns.blueComponent), a: byte(ns.alphaComponent))
            })
    }

    private func slider(
        _ label: String,
        _ keyPath: ReferenceWritableKeyPath<ImageEditorViewModel, Double>,
        _ lo: Double, _ hi: Double, id: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption)
            Slider(
                value: Binding(
                    get: { vm[keyPath: keyPath] },
                    // TSK-1050: debounce — a drag fires many deltas/sec; coalesce
                    // them into one render instead of running CoreImage per tick.
                    set: { vm[keyPath: keyPath] = $0; vm.scheduleRender() }),
                in: lo...hi)
                .accessibilityIdentifier("mdv.imageEditor.\(id)")
        }
    }

    /// A new shape of `kind` placed in the centre of the image (normalized
    /// `0...1` space): a 40% box for closed shapes, a diagonal across the middle
    /// 40% for open shapes (line / arrow), styled with the default red stroke so
    /// it reads as an annotation against most photos.
    static func centeredShape(_ kind: VectorShape.Kind) -> VectorShape {
        let style = ShapeStyle(stroke: .red, lineWidth: 3)
        switch kind {
        case .rect, .ellipse:
            return VectorShape(
                kind: kind, frame: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
                style: style)
        case .line, .arrow:
            let frame = VectorShape.openFrame(
                from: CGPoint(x: 0.3, y: 0.3), to: CGPoint(x: 0.7, y: 0.7))
            return VectorShape(kind: kind, frame: frame, style: style)
        }
    }

    /// Compute the rect a `imageSize` raster occupies when aspect-fit-centered
    /// into `bounds` — the same fit `Image(...).aspectRatio(contentMode: .fit)`
    /// applies — so the vector overlay maps its normalized `0...1` coordinates
    /// into the exact pixels the image covers. Returns `.zero` for a degenerate
    /// image (so the overlay simply draws nothing).
    static func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(
            x: bounds.minX + (bounds.width - w) / 2,
            y: bounds.minY + (bounds.height - h) / 2,
            width: w, height: h)
    }

    /// Present an `NSSavePanel` and write the edited document via the
    /// host-tested `ImageEditorViewModel.export`. Format follows the chosen
    /// extension (defaults to PNG).
    private func saveCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "edited.png"
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format: ExportSpec.Format
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": format = .jpeg
        case "heic": format = .heic
        default: format = .png
        }
        // Route through the view-model so a write/encoder failure (disk
        // full, dir not writable, HEIC encode failure) is captured in
        // `lastError` and surfaced — the old `try? vm.export(...)` discarded
        // EVERY failure, so a failed save looked exactly like a successful
        // one (silent data loss). Mirror AudioEditorView.saveCopy().
        if !vm.saveCopy(format: format, to: url) {
            let alert = NSAlert()
            alert.messageText = "Couldn't save a copy"
            alert.informativeText = vm.lastError ?? "The image couldn't be saved."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
