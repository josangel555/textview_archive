import SwiftUI
import ViewerCore

/// TSK-1323/1324 (slice 2) — the Audio Extract/Convert panel: pick a target format (+ bit rate for
/// lossy) and run the transcode into a new tab. One panel for both modes (the title/action label
/// follow `vm.dropVideo`: Extract from a video, Convert an audio file). Drives
/// `AudioConvertViewModel` (off-main ffmpeg). Mirrors the image-convert panel.
struct AudioConvertView: View {
    @ObservedObject var vm: AudioConvertViewModel
    let onConverted: (URL) -> Void
    let onClose: () -> Void

    private var title: String { vm.dropVideo ? "Extract Audio" : "Convert Audio" }
    private var actionLabel: String { vm.dropVideo ? "Extract" : "Convert" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(vm.sourceURL.lastPathComponent)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            HStack {
                Text("Format")
                Picker("", selection: $vm.format) {
                    ForEach(vm.availableFormats, id: \.self) { f in
                        Text(Self.label(for: f)).tag(f)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 200)
                .accessibilityIdentifier("mdv.audioConvert.format")
            }

            if vm.isBitRateMeaningful {
                HStack {
                    Text("Bit rate")
                    Picker("", selection: $vm.bitRate) {
                        ForEach([96_000, 128_000, 192_000, 256_000, 320_000], id: \.self) { br in
                            Text("\(br / 1000) kbps").tag(br)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 140)
                    .accessibilityIdentifier("mdv.audioConvert.bitrate")
                }
            }

            if let err = vm.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mdv.audioConvert.error")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button(actionLabel) {
                    Task { if let out = await vm.convert() { onConverted(out) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.isConverting)
                .accessibilityIdentifier("mdv.audioConvert.run")
            }
        }
        .padding(20)
        .frame(width: 380)
        .accessibilityIdentifier("mdv.audioConvert.panel")
    }

    private static func label(for f: AudioExportSpec.Format) -> String {
        switch f {
        case .wav:  return "WAV"
        case .aiff: return "AIFF"
        case .caf:  return "CAF"
        case .aac:  return "AAC (m4a)"
        case .mp3:  return "MP3"
        }
    }
}
