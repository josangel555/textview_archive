import Foundation

/// A single, lossless, replayable audio edit (TSK-527). Mirrors `EditOp` in the
/// image engine: the whole edit history of an `AudioDocument` is just an ordered
/// array of these — there is no separate "baked" buffer kept around, so undo is
/// dropping the last element and the decoded source is never mutated.
///
/// Frame indices are interpreted in the **current** buffer's frame space at the
/// point the op runs during replay (a `fade` after a `trim` addresses the
/// trimmed buffer), matching the image engine's "each op applies to the current
/// raster" replay semantics.
public enum AudioEditOp: Sendable, Equatable, Codable {

    /// Keep only frames `[startFrame, endFrame)` (half-open). Both bounds are
    /// clamped to the buffer and `endFrame` is clamped to `>= startFrame`, so an
    /// out-of-range or inverted range yields a clamped (possibly empty) result
    /// rather than a trap.
    case trim(startFrame: Int, endFrame: Int)

    /// Apply a gain envelope over `[startFrame, endFrame)` — a fade in or out,
    /// linear or equal-power. Clamped like `trim`. Multiplies the existing
    /// samples, so silence stays silent and the op composes with others.
    case fade(startFrame: Int, endFrame: Int, direction: FadeDirection, shape: FadeShape)

    /// Scale every sample by a constant gain of `decibels` dB (×10^(dB/20)) —
    /// the audio amplitude "scale". 0 dB is identity; +6 dB ≈ ×2, −6 dB ≈ ×0.5.
    case gain(decibels: Double)

    /// Peak-normalize: scale the whole buffer so its loudest sample sits at
    /// `targetPeakDB` dBFS (0 dBFS = full scale). A no-op on silence (nothing to
    /// scale). Composes after trim/fade like any other op.
    case normalize(targetPeakDB: Double)

    public enum FadeDirection: String, Sendable, Equatable, Codable, CaseIterable {
        case `in`, out
    }
    public enum FadeShape: String, Sendable, Equatable, Codable, CaseIterable {
        /// Amplitude-linear ramp (midpoint gain 0.5).
        case linear
        /// Constant-power crossfade curve (midpoint gain ≈ 0.707 = -3 dB) —
        /// preserves perceived loudness through the fade.
        case equalPower
    }

    /// Gain at normalised position `p ∈ [0, 1]` across the fade range.
    static func fadeGain(at p: Double, direction: FadeDirection, shape: FadeShape) -> Float {
        let clamped = Swift.min(Swift.max(p, 0), 1)
        switch (direction, shape) {
        case (.in,  .linear):     return Float(clamped)
        case (.out, .linear):     return Float(1 - clamped)
        case (.in,  .equalPower): return Float(sin(clamped * .pi / 2))
        case (.out, .equalPower): return Float(cos(clamped * .pi / 2))
        }
    }

    /// Apply this op to `buffer`, returning a new buffer (never mutates input).
    public func apply(to buffer: AudioPCMBuffer) -> AudioPCMBuffer {
        let n = buffer.frameCount
        switch self {
        case let .trim(startFrame, endFrame):
            let start = Swift.min(Swift.max(startFrame, 0), n)
            let end = Swift.min(Swift.max(endFrame, start), n)
            guard end > start else {
                return AudioPCMBuffer(sampleRate: buffer.sampleRate,
                                      channels: buffer.channels.map { _ in [] })
            }
            return AudioPCMBuffer(
                sampleRate: buffer.sampleRate,
                channels: buffer.channels.map { Array($0[start..<end]) }
            )

        case let .fade(startFrame, endFrame, direction, shape):
            let start = Swift.min(Swift.max(startFrame, 0), n)
            let end = Swift.min(Swift.max(endFrame, start), n)
            let len = end - start
            guard len > 0 else { return buffer }

            // Precompute the envelope once; reuse across channels.
            var env = [Float](repeating: 0, count: len)
            for i in 0..<len {
                let p = len > 1 ? Double(i) / Double(len - 1) : 1.0
                env[i] = AudioEditOp.fadeGain(at: p, direction: direction, shape: shape)
            }

            let faded = buffer.channels.map { channel -> [Float] in
                var out = channel
                for i in 0..<len { out[start + i] *= env[i] }
                return out
            }
            return AudioPCMBuffer(sampleRate: buffer.sampleRate, channels: faded)

        case let .gain(decibels):
            return AudioEditOp.scaled(buffer, by: Float(pow(10.0, decibels / 20.0)))

        case let .normalize(targetPeakDB):
            let peak = buffer.peakAmplitude()
            guard peak > 0 else { return buffer }   // silence: nothing to normalise
            let targetLinear = Float(pow(10.0, targetPeakDB / 20.0))
            return AudioEditOp.scaled(buffer, by: targetLinear / peak)
        }
    }

    /// Multiply every sample of every channel by `factor`.
    private static func scaled(_ buffer: AudioPCMBuffer, by factor: Float) -> AudioPCMBuffer {
        AudioPCMBuffer(
            sampleRate: buffer.sampleRate,
            channels: buffer.channels.map { $0.map { $0 * factor } }
        )
    }
}

/// A non-destructive audio edit session: an immutable decoded `source` plus an
/// ordered list of `ops`. The working buffer is always `source` folded through
/// `ops`, so undo/revert is free (drop ops) and replay is deterministic.
/// Mirrors `ImageDocument`.
public struct AudioDocument: Equatable, Sendable {

    /// The decoded source — never mutated by edits.
    public let source: AudioPCMBuffer

    /// Ordered edit history; `rendered()` replays these over `source`.
    public var ops: [AudioEditOp]

    public init(source: AudioPCMBuffer, ops: [AudioEditOp] = []) {
        self.source = source
        self.ops = ops
    }

    /// The working buffer = `source` with every op applied in order.
    public func rendered() -> AudioPCMBuffer {
        ops.reduce(source) { $1.apply(to: $0) }
    }

    /// Append an edit.
    public mutating func append(_ op: AudioEditOp) {
        ops.append(op)
    }

    /// Drop the most recent edit (no-op when empty). Undo for free.
    @discardableResult
    public mutating func undo() -> AudioEditOp? {
        ops.isEmpty ? nil : ops.removeLast()
    }

    /// Drop all edits, returning to the source.
    public mutating func revert() {
        ops.removeAll()
    }
}
