import CoreGraphics
import Foundation

// Semantic rotate/flip verbs for the image editor UI, plus the orientation
// algebra that keeps the op list bounded.
//
// The engine already expresses every rotate/flip/flop through the 8-case
// `EditOp.orient(EXIFOrientation)` (the renderer bakes each into pixels via a
// lossless remap). What the UI needs on top is:
//   • verbs — "rotate clockwise", "flip horizontal" — instead of raw EXIF cases;
//   • coalescing — N rotate gestures must NOT append N ops (and N redraws on
//     every render). Two adjacent orientations compose into one.
//
// The composition is the dihedral group D4. We use the normal form
// `(quarterTurnsCW: 0...3, mirrored: Bool)`: an orientation displays the stored
// raster by first (optionally) horizontal-mirroring it, then rotating it
// clockwise by `quarterTurnsCW × 90°`. The group law (with the reflection
// relation `mirror ∘ rot = rot⁻¹ ∘ mirror`) gives a closed-form compose. The
// EXIF↔normal-form mapping and the whole compose are pinned against the actual
// `Renderer` by an exhaustive 8×8 render-equivalence test, so a convention slip
// can't ship silently.

extension EXIFOrientation {
    /// Normal form: clockwise quarter-turns (0...3) and whether a horizontal
    /// mirror precedes the rotation. `display = rotCW^q ∘ (mirror ? hflip : id)`.
    var normalForm: (q: Int, mirrored: Bool) {
        switch self {
        case .up:            return (0, false)
        case .right90:       return (1, false)
        case .down:          return (2, false)
        case .left90:        return (3, false)
        case .upMirrored:    return (0, true)
        case .leftMirrored:  return (1, true)
        case .downMirrored:  return (2, true)
        case .rightMirrored: return (3, true)
        }
    }

    /// Inverse of `normalForm`. `q` is taken mod 4.
    static func from(q: Int, mirrored: Bool) -> EXIFOrientation {
        switch (((q % 4) + 4) % 4, mirrored) {
        case (0, false): return .up
        case (1, false): return .right90
        case (2, false): return .down
        case (3, false): return .left90
        case (0, true):  return .upMirrored
        case (1, true):  return .leftMirrored
        case (2, true):  return .downMirrored
        default:         return .rightMirrored  // (3, true)
        }
    }

    /// Compose two orientations: the orientation equivalent to applying `self`,
    /// then `next`. Mirrors the renderer's sequential `orient(orient(img,self),next)`.
    ///
    /// Derivation (g = rot^q ∘ mir^m as a group element; reflection relation
    /// `mir ∘ rot = rot⁻¹ ∘ mir`):
    ///   g_next ∘ g_self
    ///     = rot^{qn} mir^{mn} rot^{qs} mir^{ms}
    ///     = rot^{qn + (mn ? −qs : qs)} · mir^{ms ⊕ mn}
    func then(_ next: EXIFOrientation) -> EXIFOrientation {
        let s = normalForm
        let n = next.normalForm
        let q = n.q + (n.mirrored ? -s.q : s.q)
        return .from(q: q, mirrored: s.mirrored != n.mirrored)
    }
}

extension ImageDocument {
    /// Append an orientation, coalescing with a trailing `orient` op so a run of
    /// rotate/flip gestures stays a single op (and a single redraw). Coalescing
    /// is only valid against an *adjacent trailing* orient — an intervening
    /// crop/resize changes the coordinate frame, so we append a fresh op there.
    /// If the coalesced result is `.up` (identity), the trailing op is dropped,
    /// so e.g. four clockwise rotations return the document to that prior state.
    func applyingOrientation(_ o: EXIFOrientation) -> ImageDocument {
        if case .orient(let last)? = ops.last {
            let combined = last.then(o)
            var copy = self
            copy.ops.removeLast()
            if combined != .up { copy.ops.append(.orient(combined)) }
            return copy
        }
        return appending(.orient(o))
    }

    /// Rotate the displayed image 90° clockwise.
    public func rotatedClockwise() -> ImageDocument { applyingOrientation(.right90) }
    /// Rotate the displayed image 90° counter-clockwise.
    public func rotatedCounterClockwise() -> ImageDocument { applyingOrientation(.left90) }
    /// Rotate the displayed image 180°.
    public func rotated180() -> ImageDocument { applyingOrientation(.down) }
    /// Mirror the displayed image left↔right.
    public func flippedHorizontally() -> ImageDocument { applyingOrientation(.upMirrored) }
    /// Mirror the displayed image top↔bottom.
    public func flippedVertically() -> ImageDocument { applyingOrientation(.downMirrored) }
}
