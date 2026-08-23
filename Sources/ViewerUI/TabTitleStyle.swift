import Foundation

/// Pure decision for how a tab title is emphasised — hoisted out of the
/// SwiftUI `TabBar` body so the rule is host-testable (SwiftUI font
/// modifiers aren't introspectable headlessly; the pixel is the VM tail).
///
/// Rules:
/// - **Italic** marks an ephemeral *preview* tab (VSCode convention).
/// - **Bold** (semibold) marks the active document — BUT only for a normal
///   tab. A preview tab stays "just italics, not bold" even when selected
///   (TSK-902): the italic already conveys ephemerality, and stacking bold
///   on top read as a heavy, mismatched title.
public enum TabTitleStyle {

    /// True when the title should render italic.
    public static func isItalic(isPreview: Bool) -> Bool { isPreview }

    /// True when the title should render bold (semibold).
    public static func isBold(isSelected: Bool, isPreview: Bool) -> Bool {
        isSelected && !isPreview
    }
}

/// Pure decision for which selection emphasis a tab chip wears — hoisted so
/// the rule is host-testable. Owner 2026-08-23: in a split, ONLY the focused
/// pane's selected tab carries the accent; an unfocused pane's selected tab
/// goes GREY, so "which tab is actually active" is answerable at a glance.
public enum TabChipSelectionStyle: Equatable {
    /// Selected in the focused pane — THE active tab (accent).
    case accent
    /// Selected in an unfocused pane — that pane's front tab, muted grey.
    case muted
    /// Not selected.
    case plain

    public static func emphasis(isSelected: Bool, isPaneFocused: Bool) -> TabChipSelectionStyle {
        guard isSelected else { return .plain }
        return isPaneFocused ? .accent : .muted
    }
}
