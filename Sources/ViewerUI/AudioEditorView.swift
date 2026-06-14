import AppKit
import SwiftUI
import ViewerCore

/// Audio visualization + transport UI (TSK-529 v1) — binds to the host-tested
/// `AudioEditorViewModel`. A `Canvas` waveform with horizontal zoom, amplitude
/// scale and scroll, plus a play/pause/scrub transport driven by `AVAudioPlayer`.
///
/// Deliberately contains NO `NSViewRepresentable`: the waveform is SwiftUI-native
/// `Canvas` drawing and the transport is `AVAudioPlayer` (not a view), so there
/// is no opaque AppKit layer to occlude the SwiftUI content — the recurring
/// sibling-blank pathology can't apply here (LESSONS.md / CLAUDE.md). An
/// optional frequency-spectrum panel (TSK-533) drops in below the waveform, fed
/// by the host-tested `SpectrumAnalyzer`. A trim/fade edit bar (TSK-534) selects
/// a trim range (Set Start/End at the playhead) + fade-in/out and exports the
/// result via the host-tested `AudioTrimFade` → `AudioDocument` → `AudioExporter`
/// pipeline ("Save a Copy…"); draggable handles on the waveform itself are the
/// render-tail polish. Pixel/interaction validation is the VM lane
/// (no-UI-on-host); the `mdv.audioEditor.*` identifiers let that test find the
/// waveform + controls.
struct AudioEditorView: View {
    @StateObject private var vm: AudioEditorViewModel
    /// Called when the user dismisses the editor (returns to the plain player).
    let onClose: () -> Void

    init(url: URL, onClose: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: AudioEditorViewModel(url: url))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            waveform
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if vm.showSpectrum {
                Divider()
                spectrumPanel
                    .frame(height: 130)
            }
            Divider()
            editBar
            Divider()
            transport
        }
        .background(Palette.windowBackground)
        .ignoresSafeArea()
        .accessibilityIdentifier("mdv.audioEditor")
        .task { await vm.load() }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
            Text(vm.url.lastPathComponent)
                .font(.headline)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Done", action: onClose)
                .accessibilityIdentifier("mdv.audioEditor.done")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - waveform

    @ViewBuilder private var waveform: some View {
        if vm.isLoading {
            ProgressView("Reading audio…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("mdv.audioEditor.loading")
        } else if let err = vm.loadError {
            ContentUnavailableView(
                "Couldn't visualize audio", systemImage: "exclamationmark.triangle",
                description: Text(err))
                .accessibilityIdentifier("mdv.audioEditor.error")
        } else {
            GeometryReader { geo in
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    // Centre baseline.
                    Rectangle()
                        .fill(Palette.separator)
                        .frame(height: 1)
                    waveformCanvas
                    trimOverlay
                    playheadCanvas
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let frac = value.location.x / max(geo.size.width, 1)
                            vm.scrub(toFraction: Double(frac))
                        }
                )
                .onAppear { vm.rebuild(columns: columns(for: geo.size.width)) }
                .onChange(of: geo.size.width) { _, w in vm.rebuild(columns: columns(for: w)) }
                .onChange(of: vm.isLoading) { _, _ in vm.rebuild(columns: columns(for: geo.size.width)) }
            }
            .accessibilityIdentifier("mdv.audioEditor.waveform")
        }
    }

    /// One peak column per ~1 logical point keeps the overview crisp without
    /// over-reducing; bounded so a very wide window stays cheap.
    private func columns(for width: CGFloat) -> Int {
        Swift.min(Swift.max(Int(width), 1), 4000)
    }

    private var waveformCanvas: some View {
        Canvas { ctx, size in
            let peaks = vm.displayPeaks
            guard !peaks.isEmpty else { return }
            let mid = size.height / 2
            let half = size.height / 2
            let colW = size.width / CGFloat(peaks.count)
            var path = Path()
            for (i, peak) in peaks.enumerated() {
                let x = (CGFloat(i) + 0.5) * colW
                let top = mid - CGFloat(clampUnit(Double(peak.max) * vm.amplitudeScale)) * half
                let bottom = mid - CGFloat(clampUnit(Double(peak.min) * vm.amplitudeScale)) * half
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: Swift.max(bottom, top + 0.5)))
            }
            ctx.stroke(path, with: .color(.accentColor), lineWidth: Swift.max(1, colW * 0.9))
        }
    }

    private var playheadCanvas: some View {
        Canvas { ctx, size in
            guard let frac = vm.playheadFraction else { return }
            let x = CGFloat(frac) * size.width
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(path, with: .color(.red), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    private func clampUnit(_ v: Double) -> Double { Swift.min(Swift.max(v, -1), 1) }

    // MARK: - spectrum (TSK-533)

    private var spectrumPanel: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if vm.spectrum == nil {
                Text("Spectrum appears while playing or after scrubbing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                spectrumCanvas
            }
        }
        .accessibilityIdentifier("mdv.audioEditor.spectrum")
    }

    /// Linear-frequency magnitude bars: each bin's dB (floored at
    /// `bins.floorDB`) maps to a bar height. Drawn as a single filled `Path`
    /// (one rect per bin) so a 1024-bin column stays cheap at the playback tick.
    private var spectrumCanvas: some View {
        Canvas { ctx, size in
            guard let bins = vm.spectrum, !bins.magnitudesDB.isEmpty else { return }
            let mags = bins.magnitudesDB
            let floor = Double(bins.floorDB)
            let span = max(0 - floor, 1)   // dB range, guarded against a 0 floor
            let colW = size.width / CGFloat(mags.count)
            var path = Path()
            for (i, db) in mags.enumerated() {
                let norm = Swift.min(Swift.max((Double(db) - floor) / span, 0), 1)
                let h = CGFloat(norm) * size.height
                let x = CGFloat(i) * colW
                path.addRect(CGRect(x: x, y: size.height - h,
                                    width: Swift.max(colW, 0.5), height: h))
            }
            ctx.fill(path, with: .color(.accentColor))
        }
    }

    // MARK: - trim / fade / export (TSK-534)

    /// Shades the trimmed-away regions and draws the trim boundary lines, mapped
    /// into the currently-visible window (so it stays correct when zoomed). The
    /// handles are set via the playhead buttons; draggable handles are the VM
    /// render-tail polish.
    private var trimOverlay: some View {
        Canvas { ctx, size in
            let vis = vm.visibleRange
            guard !vis.isEmpty else { return }
            let s = clampUnit01(Double(vm.trimStartFrame - vis.lowerBound) / Double(vis.count))
            let e = clampUnit01(Double(vm.trimEndFrame - vis.lowerBound) / Double(vis.count))
            let dim = GraphicsContext.Shading.color(.black.opacity(0.35))
            if s > 0 {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: CGFloat(s) * size.width, height: size.height)), with: dim)
            }
            if e < 1 {
                ctx.fill(Path(CGRect(x: CGFloat(e) * size.width, y: 0,
                                     width: CGFloat(1 - e) * size.width, height: size.height)), with: dim)
            }
            var line = Path()
            if s > 0 {
                line.move(to: CGPoint(x: CGFloat(s) * size.width, y: 0))
                line.addLine(to: CGPoint(x: CGFloat(s) * size.width, y: size.height))
            }
            if e < 1 {
                line.move(to: CGPoint(x: CGFloat(e) * size.width, y: 0))
                line.addLine(to: CGPoint(x: CGFloat(e) * size.width, y: size.height))
            }
            ctx.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    private func clampUnit01(_ v: Double) -> Double { Swift.min(Swift.max(v, 0), 1) }

    @ViewBuilder private var editBar: some View {
        if !vm.isLoading && vm.loadError == nil {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("Trim")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Button("Set Start") { vm.setTrimStartToPlayhead() }
                        .accessibilityIdentifier("mdv.audioEditor.trimStart")
                    Button("Set End") { vm.setTrimEndToPlayhead() }
                        .accessibilityIdentifier("mdv.audioEditor.trimEnd")
                    Button("Reset") { vm.resetTrim() }
                        .disabled(vm.trimStartFraction == 0 && vm.trimEndFraction == 1)
                    Text(trimSelectionLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { saveCopy() } label: {
                        Label("Save a Copy…", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("mdv.audioEditor.saveCopy")
                }
                HStack(spacing: 10) {
                    labelled("Fade In") {
                        Slider(value: $vm.fadeInSeconds, in: 0...5)
                            .accessibilityIdentifier("mdv.audioEditor.fadeIn")
                    }
                    labelled("Fade Out") {
                        Slider(value: $vm.fadeOutSeconds, in: 0...5)
                            .accessibilityIdentifier("mdv.audioEditor.fadeOut")
                    }
                    Picker("", selection: $vm.fadeShape) {
                        Text("Equal-power").tag(AudioEditOp.FadeShape.equalPower)
                        Text("Linear").tag(AudioEditOp.FadeShape.linear)
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("mdv.audioEditor.fadeShape")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var trimSelectionLabel: String {
        guard let src = vm.sourceBuffer, src.sampleRate > 0 else { return "" }
        let startT = Double(vm.trimStartFrame) / src.sampleRate
        let endT = Double(vm.trimEndFrame) / src.sampleRate
        return "\(timeString(startT))–\(timeString(endT))"
    }

    private func saveCopy() {
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        panel.canCreateDirectories = true
        let base = vm.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base)-edited.wav"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let format = Self.exportFormat(for: dest.pathExtension)
        do {
            try vm.exportCopy(spec: AudioExportSpec(format: format), to: dest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save a copy"
            alert.informativeText = Self.describeExport(error)
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func exportFormat(for ext: String) -> AudioExportSpec.Format {
        switch ext.lowercased() {
        case "aiff", "aif": return .aiff
        case "caf": return .caf
        case "m4a", "aac": return .aac
        case "mp3": return .mp3
        default: return .wav
        }
    }

    private static func describeExport(_ error: Error) -> String {
        switch error {
        case AudioExportError.mp3FFmpegNotFound:
            return "MP3 export needs ffmpeg, which wasn't found. Choose WAV, AIFF, CAF, or M4A (AAC)."
        case AudioExportError.ffmpegFailed(let code):
            return "ffmpeg failed (exit \(code))."
        case AudioExportError.emptyBuffer:
            return "There's no audio to export."
        default:
            return String(describing: error)
        }
    }

    // MARK: - transport

    private var transport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: { vm.togglePlay() }) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .disabled(vm.isLoading || vm.loadError != nil)
                .accessibilityIdentifier("mdv.audioEditor.playPause")

                Text("\(timeString(vm.currentTime)) / \(timeString(vm.duration))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button(action: { vm.toggleSpectrum() }) {
                    Image(systemName: "waveform.path.ecg")
                        .frame(width: 18)
                        .foregroundStyle(vm.showSpectrum ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(vm.isLoading || vm.loadError != nil)
                .help(vm.showSpectrum ? "Hide frequency spectrum" : "Show frequency spectrum")
                .accessibilityIdentifier("mdv.audioEditor.spectrumToggle")
            }

            HStack(spacing: 10) {
                labelled("Zoom") {
                    Slider(
                        value: Binding(get: { vm.zoom }, set: { vm.setZoom($0) }),
                        in: AudioWaveformGeometry.minZoom...AudioWaveformGeometry.maxZoom)
                        .accessibilityIdentifier("mdv.audioEditor.zoom")
                }
                labelled("Scale") {
                    Slider(value: $vm.amplitudeScale, in: 1...8)
                        .accessibilityIdentifier("mdv.audioEditor.scale")
                }
            }

            if vm.zoom > AudioWaveformGeometry.minZoom {
                labelled("Scroll") {
                    Slider(
                        value: Binding(get: { vm.scrollFraction }, set: { vm.setScroll($0) }),
                        in: 0...1)
                        .accessibilityIdentifier("mdv.audioEditor.scroll")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func labelled<Content: View>(
        _ label: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            content()
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
