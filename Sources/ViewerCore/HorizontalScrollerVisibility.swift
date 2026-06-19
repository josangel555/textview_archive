// Horizontal-scroller visibility state machine for the CM6 editor.
//
// TSK-895: the CM6 editor's horizontal scrollbar flickered visible/hidden
// on every keystroke. Root cause is the classic `overflow: auto` boundary
// flap — when a long line's content width hovers right at the viewport
// edge, a single inserted/deleted character nudges the measured content
// width back and forth across the threshold. The browser shows the
// scrollbar (which itself consumes layout height/width), the next layout
// pass re-measures, the condition flips, the scrollbar hides — a 1-frame
// oscillation that reads as visible flicker while typing.
//
// The decision of WHETHER the horizontal scroller is shown must be a pure
// function of **content overflow only** — never of the transient typing /
// interaction state — and it must be HYSTERETIC so a content width that
// sits exactly on the boundary cannot toggle the output on consecutive
// same-overflow keystrokes.
//
// This is the host-testable kernel of that policy. No AppKit / WebKit
// imports: the JS host (`Resources/codemirror/codemirror.html`) feeds it
// `(contentWidth, viewportWidth, typing)` ticks and applies the returned
// `shouldShow` by toggling an explicit `overflow-x` class on `.cm-scroller`
// instead of leaning on `overflow: auto`. The Swift side owns the policy so
// it is regression-guarded on the host gate; the render application of the
// class is VM-validated.

import Foundation

/// Tuning for the hysteresis band around the viewport boundary.
///
/// Two margins (in the same unit as the widths fed to the state machine —
/// CSS px in practice) form a dead-band so the visibility output is stable
/// across keystrokes that don't materially change overflow:
///
/// - `showMargin`: content must exceed the viewport by MORE than this before
///   a hidden scroller is shown. Soaks up sub-pixel / single-glyph growth at
///   the exact boundary.
/// - `hideMargin`: a shown scroller stays shown until content shrinks to MORE
///   than this *below* the viewport. A wider hide band than show band means
///   the scroller, once shown, is "sticky" and won't blink off on the very
///   next backspace that momentarily fits.
///
/// `showMargin <= hideMargin` is the configuration that yields true
/// hysteresis (the show threshold sits ABOVE the hide threshold, so there is
/// a band of content widths in which the output simply holds its prior
/// value). The defaults are deliberately asymmetric and sized to comfortably
/// exceed one monospace glyph advance at typical editor font sizes, which is
/// the per-keystroke width delta that drove the original flap.
public struct HorizontalScrollerHysteresis: Equatable, Sendable {
    public let showMargin: Double
    public let hideMargin: Double

    public init(showMargin: Double = 2.0, hideMargin: Double = 8.0) {
        // Negative margins would invert the dead-band into an unstable
        // overlap; clamp to a sane floor so a misconfiguration can't
        // reintroduce the flap this type exists to kill.
        self.showMargin = max(0, showMargin)
        self.hideMargin = max(0, hideMargin)
    }

    /// No dead-band — visibility flips exactly at the boundary. Provided for
    /// tests that want to assert the raw overflow predicate without
    /// hysteresis; NOT recommended for the live editor (it reintroduces the
    /// boundary flap).
    public static let none = HorizontalScrollerHysteresis(showMargin: 0, hideMargin: 0)

    public static let `default` = HorizontalScrollerHysteresis()
}

/// Pure state machine deciding whether the CM6 horizontal scroller should be
/// visible. Feed it a stream of `(contentWidth, viewportWidth, typing)` ticks
/// via `update`; it returns the stable `shouldShow` decision.
///
/// Invariants enforced by the design (and pinned by `ViewerCoreTests`):
///
/// 1. The output is a function of content-vs-viewport overflow ONLY. The
///    `typing` flag is accepted (so the call site can pass it without
///    branching) but DOES NOT influence the decision — typing never shows or
///    hides the scroller.
/// 2. Consecutive ticks at the SAME overflow state never toggle the output:
///    no flap on repeated same-width keystrokes.
/// 3. The output only flips when content overflow truly crosses the viewport
///    boundary *and* clears the hysteresis margin in that direction.
///
/// `struct` + `mutating func`: the live editor owns a single instance per
/// editor view; the value semantics keep it trivially testable (snapshot the
/// state, replay a tick sequence, assert the output trace).
public struct HorizontalScrollerVisibility: Equatable, Sendable {
    public let hysteresis: HorizontalScrollerHysteresis

    /// Current decision. Starts hidden — an editor with no content (or a
    /// not-yet-measured viewport) shows no horizontal scroller.
    public private(set) var isVisible: Bool

    public init(
        hysteresis: HorizontalScrollerHysteresis = .default,
        initiallyVisible: Bool = false
    ) {
        self.hysteresis = hysteresis
        self.isVisible = initiallyVisible
    }

    /// Feed one measurement tick. Returns the (possibly unchanged) decision.
    ///
    /// - Parameters:
    ///   - contentWidth: measured width of the editor content (longest line),
    ///     in the same unit as `viewportWidth`. Negative values are clamped
    ///     to 0 (a degenerate measurement must not invert the comparison).
    ///   - viewportWidth: visible width of the scroller's viewport. A
    ///     non-positive viewport (editor not yet laid out / zero-sized) is
    ///     treated as "cannot overflow" and forces the scroller hidden —
    ///     showing a scrollbar in a zero-width viewport is never correct.
    ///   - typing: whether a keystroke/interaction is in flight. Accepted for
    ///     call-site convenience and IGNORED by the decision (invariant 1).
    /// - Returns: the stable `shouldShow` decision after applying hysteresis.
    @discardableResult
    public mutating func update(
        contentWidth: Double,
        viewportWidth: Double,
        typing: Bool = false
    ) -> Bool {
        _ = typing  // intentionally not part of the decision (invariant 1)

        guard viewportWidth > 0 else {
            isVisible = false
            return isVisible
        }

        let content = max(0, contentWidth)
        let overflow = content - viewportWidth

        if isVisible {
            // Sticky-shown: only hide once content clears the (wider) hide
            // band below the viewport. Holds through the dead-band.
            if overflow <= -hysteresis.hideMargin {
                isVisible = false
            }
        } else {
            // Hidden: only show once content exceeds the viewport by more
            // than the (narrower) show band. Holds through the dead-band.
            if overflow > hysteresis.showMargin {
                isVisible = true
            }
        }
        return isVisible
    }

    /// Replay a sequence of ticks from the current state and return the trace
    /// of decisions (one per tick). Convenience for tests / batch evaluation;
    /// mutates `self` to the final state.
    @discardableResult
    public mutating func updateAll(
        _ ticks: [(contentWidth: Double, viewportWidth: Double, typing: Bool)]
    ) -> [Bool] {
        ticks.map { update(contentWidth: $0.contentWidth, viewportWidth: $0.viewportWidth, typing: $0.typing) }
    }
}
