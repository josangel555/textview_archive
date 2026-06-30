import SwiftUI
import ViewerCore

/// TSK-1325 (slice 2) — the Image Convert panel: pick a target format + quality and convert the
/// active image into a new tab. Drives `ConvertImageViewModel` (off-main convert). The
/// console-template sheet: format picker · quality slider (lossy formats only) · Convert / Cancel ·
/// error line.
struct ConvertImageView: View {
    @ObservedObject var vm: ConvertImageViewModel
    let onConverted: (URL) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Convert Image").font(.headline)
            Text(vm.sourceURL.lastPathComponent)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            HStack {
                Text("Format")
                Picker("", selection: $vm.format) {
                    ForEach(vm.availableFormats, id: \.self) { fmt in
                        Text(Self.label(for: fmt)).tag(fmt)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                .accessibilityIdentifier("mdv.convertImage.format")
            }

            if vm.isQualityMeaningful {
                HStack {
                    Text("Quality")
                    Slider(value: $vm.quality, in: 0.1...1.0)
                    Text(String(format: "%.0f%%", vm.quality * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
            }

            if let err = vm.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mdv.convertImage.error")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Convert") {
                    Task {
                        if let out = await vm.convert() { onConverted(out) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.isConverting)
                .accessibilityIdentifier("mdv.convertImage.convert")
            }
        }
        .padding(20)
        .frame(width: 380)
        .accessibilityIdentifier("mdv.convertImage.panel")
    }

    private static func label(for f: ExportSpec.Format) -> String {
        switch f {
        case .png:  return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .bmp:  return "BMP"
        case .gif:  return "GIF"
        case .tiff: return "TIFF"
        }
    }
}
