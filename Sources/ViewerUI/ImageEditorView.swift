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
            Image(cg, scale: 1, label: Text("Edited image preview"))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(16)
                .accessibilityIdentifier("mdv.imageEditor.preview")
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
                    set: { vm[keyPath: keyPath] = $0; vm.render() }),
                in: lo...hi)
                .accessibilityIdentifier("mdv.imageEditor.\(id)")
        }
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
        try? vm.export(format: format, to: url)
    }
}
