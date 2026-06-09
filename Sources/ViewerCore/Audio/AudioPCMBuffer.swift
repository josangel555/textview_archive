import Foundation

/// Decoded audio as deinterleaved per-channel 32-bit float PCM — the in-memory
/// shape every audio feature (waveform, spectrum, trim/fade, encode) operates
/// on. Pure value type: no AVFoundation, no SwiftUI. Decoding a file into one
/// lives in `AudioDecoder`; the display reduction in `WaveformReducer`.
///
/// Samples are normalised float in the usual `[-1, 1]` range (what
/// `AVAudioFile.processingFormat` yields); values may exceed that for
/// inter-sample peaks but the waveform math doesn't assume a hard clamp.
public struct AudioPCMBuffer: Equatable, Sendable {

    /// Sample rate in Hz (e.g. 44100). 0 only for an empty/invalid buffer.
    public let sampleRate: Double

    /// One `[Float]` per channel, each `frameCount` long. Mono = 1 element,
    /// stereo = 2, etc. All channels are the same length (enforced by `init`).
    public let channels: [[Float]]

    /// Frames per channel.
    public var frameCount: Int { channels.first?.count ?? 0 }

    public var channelCount: Int { channels.count }

    /// Duration in seconds (0 when the buffer is empty or the rate is unset).
    public var duration: Double {
        sampleRate > 0 ? Double(frameCount) / sampleRate : 0
    }

    /// `channels` are truncated to the shortest channel's length so the
    /// invariant "every channel is `frameCount` long" holds — a decoder
    /// should never hand back ragged channels, but we don't trap on it.
    public init(sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        if channels.count > 1 {
            let n = channels.map(\.count).min() ?? 0
            self.channels = channels.map { $0.count == n ? $0 : Array($0.prefix(n)) }
        } else {
            self.channels = channels
        }
    }

    /// A single mono lane: the per-frame average across all channels. Mono
    /// input is returned as-is; an empty buffer yields `[]`. This is what a
    /// single-lane waveform overview draws.
    public func monoSamples() -> [Float] {
        switch channels.count {
        case 0: return []
        case 1: return channels[0]
        default:
            let n = frameCount
            let c = Float(channels.count)
            var out = [Float](repeating: 0, count: n)
            for ch in channels {
                for i in 0..<n { out[i] += ch[i] }
            }
            for i in 0..<n { out[i] /= c }
            return out
        }
    }

    /// The largest absolute sample value across all channels (0 for silence /
    /// empty). The headroom reference for a level meter or normalize op.
    public func peakAmplitude() -> Float {
        var peak: Float = 0
        for ch in channels {
            for s in ch {
                let a = abs(s)
                if a > peak { peak = a }
            }
        }
        return peak
    }

    /// Root-mean-square amplitude across all channels (0 for silence / empty) —
    /// the loudness reference a VU/RMS meter draws.
    public func rmsAmplitude() -> Float {
        var sumSquares: Double = 0
        var count = 0
        for ch in channels {
            for s in ch {
                sumSquares += Double(s) * Double(s)
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return Float((sumSquares / Double(count)).squareRoot())
    }
}
