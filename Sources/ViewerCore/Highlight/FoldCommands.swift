import Foundation

/// Pure-logic implementations of the fold keyboard commands. Lives in
/// ViewerCore so it's testable on the host without spinning up the
/// SwiftUI / NSResponder chain. The UI layer wires these into
/// `NSResponder` selectors or `Commands` blocks.
///
/// Idempotence:
/// - `collapseAtCaret` is idempotent if the smallest enclosing fold is
///   already collapsed (returns input).
/// - `expandAtCaret` mirrors: if no fold is collapsed at the caret line,
///   returns input.
/// - `collapseAll` / `expandAll` are trivially idempotent.
public enum FoldCommands {

    /// Collapse the smallest enclosing fold for the given 1-based
    /// caret line in the *original* buffer. No-op if no fold contains
    /// that line, or it's already collapsed.
    public static func collapseAtCaret(
        in state: FoldState, originalLine: Int
    ) -> FoldState {
        guard let r = state.smallestRegion(containing: originalLine) else {
            return state
        }
        if state.collapsed.contains(r) { return state }
        var copy = state
        copy.collapsed.insert(r)
        return copy
    }

    /// Expand the smallest enclosing collapsed fold for `originalLine`.
    /// No-op if nothing collapsed covers the line.
    public static func expandAtCaret(
        in state: FoldState, originalLine: Int
    ) -> FoldState {
        // Pick the smallest *collapsed* region that contains the line.
        // We deliberately don't expand a non-collapsed enclosing fold;
        // that would be a no-op semantically and confuse "what just
        // happened?" feedback.
        var best: FoldRegion?
        var bestSpan = Int.max
        for r in state.collapsed
            where r.startLine <= originalLine && originalLine <= r.endLine {
            if r.lineCount < bestSpan {
                best = r
                bestSpan = r.lineCount
            }
        }
        guard let target = best else { return state }
        var copy = state
        copy.collapsed.remove(target)
        return copy
    }

    /// Collapse every region. Idempotent on the (post-call) state.
    public static func collapseAll(in state: FoldState) -> FoldState {
        var copy = state
        copy.collapsed = Set(state.regions)
        return copy
    }

    /// Expand every region. Idempotent.
    public static func expandAll(in state: FoldState) -> FoldState {
        var copy = state
        copy.collapsed.removeAll()
        return copy
    }

    /// Toggle the fold whose `startLine` exactly matches the given
    /// line. Used by the gutter chevron click. If multiple folds start
    /// on the same line (rare — e.g. `func f() { return [` on one
    /// line), the largest one wins on collapse, matching the "click
    /// to hide the visible block" intuition. Returns nil if no fold
    /// starts on that line.
    public static func toggle(
        in state: FoldState, foldStartingAt line: Int
    ) -> FoldState? {
        let starts = state.regionsStarting(at: line)
        guard !starts.isEmpty else { return nil }
        // Largest span first — typical user intent on a click.
        let target = starts.max(by: { $0.lineCount < $1.lineCount }) ?? starts[0]
        var copy = state
        if copy.collapsed.contains(target) {
            copy.collapsed.remove(target)
        } else {
            copy.collapsed.insert(target)
        }
        return copy
    }
}
