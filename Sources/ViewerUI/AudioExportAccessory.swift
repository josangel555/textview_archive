import AppKit
import ViewerCore

/// AppKit `accessoryView` for the audio editor's "Save a Copy…" `NSSavePanel`,
/// letting the user pick the export format and its quality knob (PCM bit depth
/// for lossless containers, bit rate for AAC/MP3) before saving. The chosen
/// `AudioExportSettings` is read back by the caller and mapped to an
/// `AudioExportSpec` for `AudioExporter` (TSK-535).
///
/// Kept as a thin AppKit controller (not a SwiftUI `NSViewRepresentable`)
/// because `NSSavePanel.accessoryView` wants a plain `NSView` and the panel is
/// already an AppKit modal — so there's no SwiftUI hosting layer to occlude or
/// to fight over focus. The *logic* (which control applies, format→spec) lives
/// in the host-tested `AudioExportSettings`; this class is the wiring only.
@MainActor
final class AudioExportAccessory: NSObject {

    /// The current user selection — read by the caller after the panel returns.
    private(set) var settings: AudioExportSettings

    /// Fired when the format menu changes, so the caller can re-suggest the
    /// filename (correct extension) and relax the panel's type filter.
    var onFormatChange: ((AudioExportSettings) -> Void)?

    /// Whether MP3 is selectable (a host `ffmpeg` was resolved). When false the
    /// MP3 menu item is disabled so the user can't pick a format that will fail.
    private let mp3Available: Bool

    let view: NSView

    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityLabel = NSTextField(labelWithString: "Quality:")

    init(initial: AudioExportSettings, mp3Available: Bool) {
        self.settings = initial
        self.mp3Available = mp3Available
        self.view = NSView()
        super.init()
        buildUI()
        syncQualityControl()
    }

    // MARK: - Build

    private func buildUI() {
        let formatLabel = NSTextField(labelWithString: "Format:")

        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        for fmt in AudioExportSpec.Format.allCases {
            let item = NSMenuItem(title: Self.title(for: fmt), action: nil, keyEquivalent: "")
            item.representedObject = fmt.rawValue
            if fmt == .mp3 && !mp3Available {
                item.isEnabled = false
                item.title = FFmpegGuidance.disabledOptionTitle("MP3")
            }
            formatPopup.menu?.addItem(item)
        }
        selectFormat(settings.format)

        qualityPopup.target = self
        qualityPopup.action = #selector(qualityChanged)

        let grid = NSGridView(views: [
            [formatLabel, formatPopup],
            [qualityLabel, qualityPopup],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 8

        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    /// Display name for a format in the menu.
    static func title(for format: AudioExportSpec.Format) -> String {
        switch format {
        case .wav:  return "WAV (lossless)"
        case .aiff: return "AIFF (lossless)"
        case .caf:  return "CAF (lossless)"
        case .aac:  return "AAC / M4A"
        case .mp3:  return "MP3"
        }
    }

    /// Display name for a PCM sample format.
    static func title(for sampleFormat: AudioExportSpec.SampleFormat) -> String {
        switch sampleFormat {
        case .int16:   return "16-bit integer"
        case .int24:   return "24-bit integer"
        case .int32:   return "32-bit integer"
        case .float32: return "32-bit float"
        }
    }

    /// Display name for a lossy bit rate.
    static func title(forBitRate bitRate: Int) -> String { "\(bitRate / 1000) kbps" }

    // MARK: - Quality control population

    /// Repopulate the quality popup to match the current format: PCM depths for
    /// lossless containers, bit rates for lossy, and disable it where neither
    /// applies (it never is — both arms populate — but the guard keeps it honest).
    private func syncQualityControl() {
        qualityPopup.removeAllItems()
        if settings.sampleFormatApplies {
            qualityLabel.stringValue = "Bit depth:"
            for sf in AudioExportSettings.pcmSampleFormats {
                let item = NSMenuItem(title: Self.title(for: sf), action: nil, keyEquivalent: "")
                item.representedObject = sf.rawValue
                qualityPopup.menu?.addItem(item)
            }
            selectSampleFormat(settings.sampleFormat)
        } else {
            qualityLabel.stringValue = "Bit rate:"
            for br in AudioExportSettings.lossyBitRates {
                let item = NSMenuItem(title: Self.title(forBitRate: br), action: nil, keyEquivalent: "")
                item.representedObject = br
                qualityPopup.menu?.addItem(item)
            }
            selectBitRate(AudioExportSettings.snapBitRate(settings.bitRate))
        }
    }

    // MARK: - Selection helpers

    private func selectFormat(_ format: AudioExportSpec.Format) {
        let idx = AudioExportSpec.Format.allCases.firstIndex(of: format) ?? 0
        formatPopup.selectItem(at: idx)
    }
    private func selectSampleFormat(_ sf: AudioExportSpec.SampleFormat) {
        if let idx = AudioExportSettings.pcmSampleFormats.firstIndex(of: sf) {
            qualityPopup.selectItem(at: idx)
        }
    }
    private func selectBitRate(_ br: Int) {
        if let idx = AudioExportSettings.lossyBitRates.firstIndex(of: br) {
            qualityPopup.selectItem(at: idx)
        }
    }

    // MARK: - Actions

    @objc private func formatChanged() {
        guard let raw = formatPopup.selectedItem?.representedObject as? String,
              let fmt = AudioExportSpec.Format(rawValue: raw) else { return }
        settings.format = fmt
        syncQualityControl()
        onFormatChange?(settings)
    }

    @objc private func qualityChanged() {
        guard let obj = qualityPopup.selectedItem?.representedObject else { return }
        if let raw = obj as? String, let sf = AudioExportSpec.SampleFormat(rawValue: raw) {
            settings.sampleFormat = sf
        } else if let br = obj as? Int {
            settings.bitRate = br
        }
    }
}
