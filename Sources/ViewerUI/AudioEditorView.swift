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
/// by the host-tested `SpectrumAnalyzer`; draggable trim/fade handles and
/// Save-As remain follow-up sub-tasks. Pixel/interaction validation is the VM
/// lane (no-UI-on-host); the `mdv.audioEditor.*` identifiers let that test find
/// the waveform + controls.
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
