import Foundation

/// One pixel column of a waveform: the minimum and maximum sample value over
/// the frames that column covers. A waveform view draws a vertical line from
/// `min` to `max` per column.
public struct WaveformPeak: Equatable, Sendable {
    public let min: Float
    public let max: Float
    public init(min: Float, max: Float) {
        self.min = min
        self.max = max
    }
    /// Silence / no-data column.
    public static let zero = WaveformPeak(min: 0, max: 0)
}

/// Pure, host-testable downsampler: turns a channel's `N` float samples into
/// `width` (min,max) peak columns over a zoom window — the exact data a
/// waveform view needs and nothing more (no AVFoundation, no drawing).
///
/// The zoom window is `[startFrame, startFrame+frameCount)` in sample frames,
/// clamped to the buffer. `frameCount == nil` means "to the end". Each column
/// covers `windowLength/width` frames using a fractional stride (so columns
/// don't drift on non-divisible sizes); when zoomed in past 1 frame/column
/// every column still covers at least one frame (a flat point).
public enum WaveformReducer {

    /// Reduce `samples` to exactly `width` peak columns over the (clamped) zoom
    /// window. Returns `[]` for `width <= 0`. An empty window (or empty buffer)
    /// yields `width` zero columns so the view can still lay out a flat line.
    public static func reduce(
        _ samples: [Float],
        width: Int,
        startFrame: Int = 0,
        frameCount: Int? = nil
    ) -> [WaveformPeak] {
        guard width > 0 else { return [] }

        let total = samples.count
        // Clamp the requested window to the buffer bounds.
        let lo = Swift.min(Swift.max(startFrame, 0), total)
        let requestedEnd = frameCount.map { startFrame + Swift.max($0, 0) } ?? total
        let hi = Swift.min(Swift.max(requestedEnd, lo), total)
        let windowLen = hi - lo

        guard windowLen > 0 else {
            return Array(repeating: .zero, count: width)
        }

        let stride = Double(windowLen) / Double(width)
        var out = [WaveformPeak]()
        out.reserveCapacity(width)

        for col in 0..<width {
            // Fractional span → integer indices, clamped to [lo, hi).
            var colStart = lo + Int((Double(col) * stride).rounded(.down))
            var colEnd = lo + Int((Double(col + 1) * stride).rounded(.down))
            colStart = Swift.min(colStart, hi - 1)            // never past the last frame
            if colEnd <= colStart { colEnd = colStart + 1 }   // zoomed-in: ≥1 frame
            colEnd = Swift.min(colEnd, hi)

            var lowest = samples[colStart]
            var highest = samples[colStart]
            var i = colStart + 1
            while i < colEnd {
                let v = samples[i]
                if v < lowest { lowest = v }
                if v > highest { highest = v }
                i += 1
            }
            out.append(WaveformPeak(min: lowest, max: highest))
        }
        return out
    }
}
