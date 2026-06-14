import Foundation

/// Pure, host-testable policy that turns the audio editor's trim/fade SELECTION
/// (a trim range on the original timeline + fade-in/out durations in seconds)
/// into the ordered `AudioEditOp` list the already-tested `AudioDocument` replays
/// on export (TSK-534). SwiftUI-free: the draggable handles that set the
/// selection are the VM render tail, but the selection→ops mapping carries the
/// host teeth, so a logic regression fails the host gate.
///
/// Ops compose in order: `trim` runs first (yielding a shorter buffer), so the
/// fades address the **trimmed** buffer's frame space — `[0, fadeIn)` from its
/// new start and `[len − fadeOut, len)` at its new end. That matches
/// `AudioEditOp`'s "each op applies to the current buffer" replay semantics.
public enum AudioTrimFade {

    /// Build the edit ops for a selection over a `totalFrames`-frame source.
    /// - `trimStart`/`trimEnd` are clamped (`0 ≤ start ≤ end ≤ totalFrames`); a
    ///   trim op is emitted ONLY when the range is a true subrange (so an
    ///   untouched selection exports a byte-faithful copy, no needless op).
    /// - `fadeInSeconds`/`fadeOutSeconds` convert to frames via `sampleRate`,
    ///   each capped to the trimmed length; a non-positive duration emits no fade.
    public static func ops(
        trimStart: Int,
        trimEnd: Int,
        totalFrames: Int,
        fadeInSeconds: Double,
        fadeOutSeconds: Double,
        sampleRate: Double,
        shape: AudioEditOp.FadeShape
    ) -> [AudioEditOp] {
        var ops: [AudioEditOp] = []
        let start = Swift.min(Swift.max(trimStart, 0), Swift.max(totalFrames, 0))
        let end = Swift.min(Swift.max(trimEnd, start), Swift.max(totalFrames, 0))

        if start > 0 || end < totalFrames {
            ops.append(.trim(startFrame: start, endFrame: end))
        }

        let len = end - start   // frames in the trimmed buffer the fades address
        guard len > 0, sampleRate > 0 else { return ops }

        let inFrames = Swift.min(framesFor(seconds: fadeInSeconds, sampleRate: sampleRate), len)
        if inFrames > 0 {
            ops.append(.fade(startFrame: 0, endFrame: inFrames, direction: .in, shape: shape))
        }

        let outFrames = Swift.min(framesFor(seconds: fadeOutSeconds, sampleRate: sampleRate), len)
        if outFrames > 0 {
            ops.append(.fade(startFrame: len - outFrames, endFrame: len, direction: .out, shape: shape))
        }
        return ops
    }

    /// True when the selection would change the audio at all (a real trim or any
    /// fade) — drives whether "Save a Copy" produces an edited file vs a copy.
    public static func hasEdits(
        trimStart: Int, trimEnd: Int, totalFrames: Int,
        fadeInSeconds: Double, fadeOutSeconds: Double,
        sampleRate: Double, shape: AudioEditOp.FadeShape
    ) -> Bool {
        !ops(trimStart: trimStart, trimEnd: trimEnd, totalFrames: totalFrames,
             fadeInSeconds: fadeInSeconds, fadeOutSeconds: fadeOutSeconds,
             sampleRate: sampleRate, shape: shape).isEmpty
    }

    private static func framesFor(seconds: Double, sampleRate: Double) -> Int {
        guard seconds > 0 else { return 0 }
        return Swift.max(0, Int((seconds * sampleRate).rounded()))
    }
}
