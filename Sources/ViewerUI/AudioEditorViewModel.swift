import AVFoundation
import Foundation
import ViewerCore

/// Host-friendly model layer for the audio visualization UI (TSK-529). Owns the
/// decoded `AudioWaveform`, the zoom/scroll/amplitude view state, and an
/// `AVAudioPlayer` transport. All coordinate math is delegated to the pure,
/// host-tested `AudioWaveformGeometry`; this layer adds the async decode, the
/// memoised display peaks, and the playback clock — the AV/render-gated parts.
///
/// Peaks are recomputed only when the *window* changes (zoom / scroll / width),
/// never on a playhead tick, so playback redraws are cheap (the moving playhead
/// is a separate Canvas layer in the view).
@MainActor
public final class AudioEditorViewModel: ObservableObject {

    public let url: URL

    @Published public private(set) var waveform: AudioWaveform?
    @Published public private(set) var isLoading = true
    @Published public private(set) var loadError: String?

    /// Horizontal zoom (`1` = whole file). Clamped via `AudioWaveformGeometry`.
    @Published public var zoom: Double = 1
    /// Window position, `0…1`, left→right.
    @Published public var scrollFraction: Double = 0
    /// Vertical amplitude exaggeration applied at draw time (`1` = true scale).
    @Published public var amplitudeScale: Double = 1

    /// Memoised peaks for the current window + column count (drawn by the view).
    @Published public private(set) var displayPeaks: [WaveformPeak] = []

    /// Playhead position in absolute sample frames.
    @Published public private(set) var playheadFrame: Int = 0
    @Published public private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var lastColumns = 600

    public init(url: URL) {
        self.url = url
    }

    // The playback clock captures `[weak self]`, so it ends on its own once the
    // view-model deallocates — no deinit cancellation needed (and a @MainActor
    // deinit touching the non-Sendable task would fight strict concurrency).

    // MARK: - Loading

    /// Decode the file off the main actor, then publish the overview + initial
    /// peaks. Safe to call once on appear.
    public func load() async {
        let target = url
        do {
            let wf = try await Task.detached(priority: .userInitiated) {
                try AudioWaveform.load(contentsOf: target)
            }.value
            waveform = wf
            loadError = nil
            isLoading = false
            rebuild(columns: lastColumns)
        } catch {
            loadError = (error as? AudioDecodeError).map(Self.describe) ?? String(describing: error)
            isLoading = false
        }
    }

    private static func describe(_ e: AudioDecodeError) -> String {
        switch e {
        case .unreadable: return "This file couldn't be read as audio."
        case .unsupportedFormat: return "Unsupported audio format."
        case .empty: return "The audio file is empty."
        case .tooLarge: return "The audio file is too large to visualize."
        }
    }

    // MARK: - Windowing

    public var totalFrames: Int { waveform?.frameCount ?? 0 }
    public var duration: Double { waveform?.duration ?? 0 }
    public var currentTime: Double { waveform?.time(ofFrame: playheadFrame) ?? 0 }

    public var visibleRange: Range<Int> {
        AudioWaveformGeometry.visibleRange(
            totalFrames: totalFrames, zoom: zoom, scrollFraction: scrollFraction)
    }

    /// `0…1` position of the playhead within the visible window, or `nil` when
    /// it's scrolled off-screen.
    public var playheadFraction: Double? {
        AudioWaveformGeometry.playheadFraction(frame: playheadFrame, visible: visibleRange)
    }

    /// Recompute the display peaks for `columns` over the current window. Called
    /// by the view on width/zoom/scroll changes — NOT on playhead ticks.
    public func rebuild(columns: Int) {
        guard columns > 0 else { return }
        lastColumns = columns
        guard let wf = waveform else { displayPeaks = []; return }
        displayPeaks = wf.peaks(columns: columns, visible: visibleRange)
    }

    public func setZoom(_ z: Double) {
        zoom = AudioWaveformGeometry.clampZoom(z)
        rebuild(columns: lastColumns)
    }

    public func setScroll(_ f: Double) {
        scrollFraction = Swift.min(Swift.max(f, 0), 1)
        rebuild(columns: lastColumns)
    }

    // MARK: - Transport

    public func togglePlay() { isPlaying ? pause() : play() }

    public func play() {
        guard waveform != nil else { return }
        let p: AVAudioPlayer
        if let existing = player {
            p = existing
        } else {
            guard let made = try? AVAudioPlayer(contentsOf: url) else {
                loadError = "Couldn't open the audio for playback."
                return
            }
            made.prepareToPlay()
            player = made
            p = made
        }
        p.play()
        isPlaying = true
        startClock()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    /// Seek to `fraction` (`0…1`) across the *visible* window.
    public func scrub(toFraction fraction: Double) {
        guard let wf = waveform else { return }
        let frame = AudioWaveformGeometry.frame(atFraction: fraction, visible: visibleRange)
        playheadFrame = frame
        player?.currentTime = wf.time(ofFrame: frame)
    }

    private func startClock() {
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, let p = self.player, p.isPlaying {
                self.playheadFrame = self.waveform?.frame(atTime: p.currentTime) ?? 0
                try? await Task.sleep(for: .milliseconds(33))
            }
            // Playback reached the end (isPlaying went false on its own).
            if let self, let p = self.player, !p.isPlaying, self.isPlaying {
                self.isPlaying = false
                self.playheadFrame = self.totalFrames
            }
        }
    }
}
