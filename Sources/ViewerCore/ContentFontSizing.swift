import CoreGraphics

/// The content text-size model (TSK-358): the on-screen size of editor/source
/// CONTENT text is an absolute base point size (`PreferencesStore.contentFontSize`,
/// user-settable in Settings) multiplied by the unified `zoom`. Splitting the two
/// answers the long-standing "is it font-size OR zoom?" — it's *both*: the base
/// sets the un-zoomed baseline, zoom scales everything (UI chrome + content) on
/// top. Pure + host-testable so the interaction is pinned; the actual font
/// application (CM6 editor, source NSTextView, gutter) is the render tail.
public enum ContentFontSizing {

    /// On-screen content point size for a given absolute `baseSize` and `zoom`.
    /// Both are read already-clamped from `PreferencesStore`; this is just the
    /// multiplication, isolated so the contract has teeth.
    public static func effective(baseSize: Double, zoom: Double) -> CGFloat {
        CGFloat(baseSize * zoom)
    }
}
