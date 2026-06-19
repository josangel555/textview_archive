import CoreGraphics

/// Font sizing for the git-diff body (TSK-766). The unified-diff view's
/// per-hunk rows are *source code* — a diff line is the same line you see in the
/// Editor / Source view. So its body text must track the SAME font-size source
/// the editor/source surfaces bind to (`ContentFontSizing.effective` =
/// `contentFontSize × zoom`), not the chrome `uiSize` scale (`base × zoom`).
///
/// Before TSK-766 the diff body hard-coded `doc.uiSize(11)` for content and
/// `doc.uiSize(10)` for the line-number gutter — that scaled with zoom but
/// ignored the user's editor content font-size preference and started from a
/// different base point size, so a hunk line drifted off the Source view's
/// typography. Routing every diff body size through this helper means a line in
/// the diff reads identically to the same line in the Source view at every
/// zoom + content-font-size setting.
///
/// Pure + host-testable (no SwiftUI) so the contract has teeth: a regression
/// that re-hardcodes a size, or decouples the body from the content font-size
/// source, fails the host gate. The actual `.font(...)` application lives in
/// `DiffView`; the live look is the VM render tail.
public enum DiffTextStyle {

    /// The diff body CONTENT point size — the +/- line text. Equals the
    /// editor/source content size exactly, so a diff line and the same line in
    /// the Source view render at identical size. `contentFontSize` / `zoom` are
    /// the already-clamped `PreferencesStore` values (same inputs the editor
    /// reads via `DocumentModel.effectiveContentFontSize`).
    public static func bodyFontSize(contentFontSize: Double, zoom: Double) -> CGFloat {
        ContentFontSizing.effective(baseSize: contentFontSize, zoom: zoom)
    }

    /// The +/- gutter prefix column size. Historically the same size as the
    /// content (both were `uiSize(11)`), so it tracks the body 1:1.
    public static func prefixFontSize(contentFontSize: Double, zoom: Double) -> CGFloat {
        bodyFontSize(contentFontSize: contentFontSize, zoom: zoom)
    }

    /// The old/new line-number cell size. Historically a notch smaller than the
    /// content (`uiSize(10)` vs `uiSize(11)`); preserve that 10/11 visual
    /// hierarchy by scaling the body size by the same ratio, so the gutter stays
    /// proportional to the content at every setting rather than drifting onto a
    /// fixed point size.
    public static func lineNumberFontSize(contentFontSize: Double, zoom: Double) -> CGFloat {
        bodyFontSize(contentFontSize: contentFontSize, zoom: zoom) * (10.0 / 11.0)
    }
}
