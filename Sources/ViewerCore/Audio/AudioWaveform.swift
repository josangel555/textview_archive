import Foundation

/// Host-testable model layer for the audio visualization UI (TSK-529): the
/// decoded mono overview plus the pure zoom/scroll/playhead geometry a waveform
/// view needs. AVFoundation-free at the math layer — `load` is the only part
/// that touches the decoder, and everything the SwiftUI `AudioEditorView` binds
/// to routes back through here so the render-gated view carries real host teeth
/// (mirrors how `ImageEditorViewModel` keeps the heavy lifting testable).
public struct AudioWaveform: Sendable {
    /// Deinterleaved-then-averaged mono samples (roughly −1…1). Held in full so
    /// the view can re-reduce cheaply for any zoom window via `WaveformReducer`
    /// rather than re-decoding the file on every zoom.
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var frameCount: Int { samples.count }

    /// Total duration in seconds (0 when the sample rate is unknown/0).
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// Decode `url` to a mono overview through the headless-safe `AudioDecoder`
    /// (capped at `AudioDecoder.defaultMaxFrames`). Throws `AudioDecodeError`.
    public static func load(contentsOf url: URL) throws -> AudioWaveform {
        let buffer = try AudioDecoder.decode(contentsOf: url)
        return AudioWaveform(samples: buffer.monoSamples(), sampleRate: buffer.sampleRate)
    }

    /// Reduce to exactly `columns` (min,max) peaks over `visible` (defaults to
    /// the whole buffer). Thin wrapper over `WaveformReducer` so the view and
    /// the tests agree on the windowing.
    public func peaks(columns: Int, visible: Range<Int>? = nil) -> [WaveformPeak] {
        let window = visible ?? 0..<frameCount
        return WaveformReducer.reduce(
            samples, width: columns,
            startFrame: window.lowerBound, frameCount: window.count)
    }

    /// Seconds for an absolute sample frame (for transport time readouts).
    public func time(ofFrame frame: Int) -> Double {
        sampleRate > 0 ? Double(frame) / sampleRate : 0
    }

    /// Absolute sample frame for a playback time in seconds (clamped to the
    /// buffer). Maps `AVAudioPlayer.currentTime` to a playhead frame.
    public func frame(atTime seconds: Double) -> Int {
        guard sampleRate > 0, frameCount > 0 else { return 0 }
        let f = Int((seconds * sampleRate).rounded())
        return Swift.min(Swift.max(f, 0), frameCount)
    }
}

/// Pure, host-testable mapping between the zoom/scroll state of a waveform view
/// and the sample-frame window it shows — and between the playhead frame and its
/// x position. No SwiftUI, no AVFoundation: the `AudioEditorView` delegates all
/// of its coordinate math here so a logic regression fails on the host gate even
/// though the on-screen drawing is VM-only.
public enum AudioWaveformGeometry {

    /// Minimum and maximum horizontal zoom. `1` shows the whole file; `maxZoom`
    /// shows `1/maxZoom` of it. Bounded so a zoomed-in window never collapses
    /// below one frame and the slider has a sane range.
    public static let minZoom: Double = 1
    public static let maxZoom: Double = 200

    /// The visible sample-frame window for a given zoom (`>= 1`) and scroll
    /// fraction (`0…1`, where 0 is the start and 1 is fully scrolled right).
    ///
    /// - `zoom` is clamped to `[minZoom, maxZoom]`.
    /// - The window length is `totalFrames / zoom`, never below 1 frame (for a
    ///   non-empty buffer) so a fully-zoomed-in view still has something to draw.
    /// - `scrollFraction` positions the window between `0` and `totalFrames −
    ///   windowLen`; out-of-range values clamp rather than trap.
    /// - An empty buffer yields `0..<0`.
    public static func visibleRange(
        totalFrames: Int, zoom: Double, scrollFraction: Double
    ) -> Range<Int> {
        guard totalFrames > 0 else { return 0..<0 }
        let z = clampZoom(zoom)
        let windowLen = Swift.max(1, Int((Double(totalFrames) / z).rounded()))
        if windowLen >= totalFrames { return 0..<totalFrames }
        let maxStart = totalFrames - windowLen
        let frac = Swift.min(Swift.max(scrollFraction, 0), 1)
        let start = Int((Double(maxStart) * frac).rounded())
        let clampedStart = Swift.min(Swift.max(start, 0), maxStart)
        return clampedStart..<(clampedStart + windowLen)
    }

    /// The playhead's horizontal position as a `0…1` fraction of the visible
    /// window, or `nil` when the playhead frame lies outside the window (so the
    /// view can hide the indicator when the user has scrolled away from it).
    public static func playheadFraction(frame: Int, visible: Range<Int>) -> Double? {
        guard !visible.isEmpty, frame >= visible.lowerBound, frame < visible.upperBound
        else { return nil }
        return Double(frame - visible.lowerBound) / Double(visible.count)
    }

    /// The absolute sample frame for a click/scrub at `fraction` (`0…1`) across
    /// the visible window — the inverse of `playheadFraction`. Clamps into the
    /// window so a drag past the edges seeks to the first/last visible frame.
    public static func frame(atFraction fraction: Double, visible: Range<Int>) -> Int {
        guard !visible.isEmpty else { return 0 }
        let frac = Swift.min(Swift.max(fraction, 0), 1)
        let f = visible.lowerBound + Int((Double(visible.count) * frac).rounded())
        return Swift.min(Swift.max(f, visible.lowerBound), visible.upperBound - 1)
    }

    /// The scroll fraction that centres `frame` in a window of the given zoom —
    /// used to keep a playing playhead in view ("follow"). Clamps to `0…1`.
    public static func scrollFraction(toCenter frame: Int, totalFrames: Int, zoom: Double) -> Double {
        guard totalFrames > 0 else { return 0 }
        let z = clampZoom(zoom)
        let windowLen = Swift.max(1, Int((Double(totalFrames) / z).rounded()))
        let maxStart = totalFrames - windowLen
        guard maxStart > 0 else { return 0 }
        let desiredStart = Double(frame) - Double(windowLen) / 2
        return Swift.min(Swift.max(desiredStart / Double(maxStart), 0), 1)
    }

    public static func clampZoom(_ zoom: Double) -> Double {
        Swift.min(Swift.max(zoom, minZoom), maxZoom)
    }
}
