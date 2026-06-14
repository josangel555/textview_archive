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
