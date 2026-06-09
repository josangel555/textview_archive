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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Button { vm.undoGeometry() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.undo")
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
