import AppKit
import SwiftUI

// MARK: - Balanced pointing-hand cursor on hover (TSK-892)
//
// File-tree hover felt laggy/janky. The cause was NOT the row body
// (`FileRowView` is already `.equatable()` over a snapshot — TSK-613 — so
// a hover re-bodies only the hovered row). The cause was the cursor side
// effect on EVERY `onHover` callback:
//
//     .onHover { hovering in
//         isHovering = hovering
//         if hovering { NSCursor.pointingHand.push() }   // <- unguarded
//         else { NSCursor.pop() }                        // <- unguarded
//     }
//
// `NSCursor.push()`/`pop()` mutate a PROCESS-GLOBAL cursor stack and poke
// the WindowServer's cursor-rectangle machinery. AppKit can — and on a
// fast drag across many rows does — emit back-to-back `onHover(true)`
// callbacks for the same view, and can deliver a spurious `onHover(false)`
// without a matching prior `true`. With the unguarded code above:
//   * each repeated `onHover(true)` pushes AGAIN → the global stack grows
//     without bound for the duration of a hover session,
//   * a stray `onHover(false)` pops a cursor that THIS view never pushed →
//     it strands an unrelated cursor (the resize cursor over a column
//     edge, say) and the pointing-hand flickers.
// The net effect during sustained mousing is a storm of redundant
// push/pop calls into the global cursor stack — exactly the per-hover
// churn that reads as "the file tree hover is slow / janky".
//
// `RowHoverButtonStyle` / `IconHoverButtonStyle` already solved this with
// a per-view `pushedCursor` bool guard, but the open-coded sidebar hover
// sites (the FILES section header and `FileRowView`) never adopted it.
// This file factors the GUARD into one small, host-testable value type so
// every open-coded `onHover` site can share it (and so a regression of
// the balance rule fails a host test, not just a live drag).

/// Pure decision core for a balanced `NSCursor` push/pop driven by
/// `onHover` callbacks. Holds whether THIS view currently owns a push on
/// the global cursor stack, and maps an `onHover(hovering:)` callback to
/// the at-most-one cursor action that keeps the stack balanced.
///
/// Host-testable: it performs no AppKit side effect itself — it returns
/// the action to take. The view layer (`hoverCursor` modifier below)
/// translates `.push` / `.pop` into the real `NSCursor` calls. This lets
/// a host test assert the balance invariants (idempotent enter, no
/// over-pop) without a live window.
struct HoverCursorBalance {
    /// The cursor action a callback resolves to. `.none` is the fast path
    /// taken on every redundant repeat callback — no global-stack mutation.
    enum Action: Equatable {
        case push
        case pop
        case none
    }

    /// True iff this instance currently owns exactly one push on the
    /// global cursor stack that it is responsible for popping.
    private(set) var isPushed = false

    /// Resolve an `onHover(hovering:)` callback to the single cursor
    /// action that preserves balance, mutating `isPushed` to match.
    ///
    /// Invariants (the whole point):
    ///   * `update(hovering: true)` pushes only on the FIRST true after a
    ///     false — repeated `true` is a `.none` no-op (idempotent enter).
    ///   * `update(hovering: false)` pops only if we actually own a push —
    ///     a `false` with no outstanding push is a `.none` no-op (never an
    ///     over-pop that strands a foreign cursor).
    mutating func update(hovering: Bool) -> Action {
        if hovering {
            guard !isPushed else { return .none }
            isPushed = true
            return .push
        } else {
            guard isPushed else { return .none }
            isPushed = false
            return .pop
        }
    }

    /// Resolve a teardown (view `onDisappear`) to a balancing `.pop` if —
    /// and only if — we still own an outstanding push. A view torn down
    /// while hovered would otherwise leak an unbalanced push.
    mutating func teardown() -> Action {
        guard isPushed else { return .none }
        isPushed = false
        return .pop
    }
}

/// Applies a balanced pointing-hand cursor on hover, and (optionally)
/// mirrors the hover flag back to a binding for a hover tint. This is the
/// drop-in replacement for the open-coded
/// `if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }`
/// sites — it never double-pushes or over-pops, eliminating the per-hover
/// global-cursor-stack churn (TSK-892).
private struct HoverCursorModifier: ViewModifier {
    /// Mirrors hover state out so the host view can drive a tint. Optional
    /// because some call sites only want the cursor, not a tint.
    let isHovering: Binding<Bool>?
    /// The region pointer style (macOS 15 `.pointerStyle` — see the
    /// owner-flicker note on `resizePointer`).
    let style: PointerStyle

    func body(content: Content) -> some View {
        content
            .pointerStyle(style)
            .onHover { hovering in
                isHovering?.wrappedValue = hovering
            }
    }
}

extension View {
    /// Attach a pointing-hand pointer on hover, optionally mirroring the
    /// hover flag into `isHovering` for a hover tint.
    ///
    /// 2026-08-22 (owner: "pointer rapidly switches over CM6 text"): the
    /// NSCursor push/pop implementation — even BALANCED (TSK-892) — leaks
    /// by MISSED EXIT: a fast pointer transit can skip `onHover(false)`,
    /// leaving a pushed cursor that then fights WKWebView's per-mousemove
    /// I-beam — the rapid arrow↔I-beam flicker. `.pointerStyle` is
    /// region-based and SwiftUI-managed: no global stack, nothing to leak.
    /// (`HoverCursorBalance` remains for any residual NSCursor site.)
    func hoverCursor(
        isHovering: Binding<Bool>? = nil,
        cursor: NSCursor = .pointingHand
    ) -> some View {
        modifier(HoverCursorModifier(
            isHovering: isHovering,
            style: cursor == .pointingHand ? .link : .default))
    }

    /// Region-based resize pointer for dividers/gutters — the
    /// `.pointerStyle` replacement for the leaky NSCursor stack (same
    /// rationale as `hoverCursor`; the I-07 phase-2 migration).
    func resizePointer(vertical: Bool) -> some View {
        pointerStyle(vertical ? .rowResize : .columnResize)
    }
}
