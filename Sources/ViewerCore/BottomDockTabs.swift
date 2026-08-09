import Foundation
import CoreGraphics

/// Pure selection model for the TABBED bottom dock (owner rework
/// 2026-08-09): bottom-docked tool windows render as tabs with ONE panel
/// visible at a time (the old side-by-side columns split the band into
/// unusable slivers). The container persists the user's last explicit
/// tab choice; this type resolves what actually shows for the current
/// visible set — so hiding the selected panel falls back gracefully
/// instead of rendering an empty band.
///
/// Pure-logic, host-testable (`BottomDockTabsTests`). No SwiftUI.
public enum BottomDockTabs {
    /// `UserDefaults` key for the persisted selected tab (a
    /// `SidebarPanelKind` raw value). Pinned by test.
    public static let selectionKey = "MarkdownViewer.dock.bottom.selectedPanel"

    /// `UserDefaults` key for the SHARED band height (one height for the
    /// whole tabbed dock — panels no longer size the band individually).
    /// Pinned by test.
    public static let bandHeightKey = "MarkdownViewer.dock.bottom.bandHeight"

    /// Resolve which panel the tabbed dock shows.
    ///
    ///   * the stored selection, when it is still in the visible set;
    ///   * else the FIRST visible panel (the stored value is left alone —
    ///     it self-heals if its panel returns);
    ///   * nil when nothing is bottom-docked + visible (dock renders
    ///     nothing).
    public static func resolve(
        selection: SidebarPanelKind?,
        visible: [SidebarPanelKind]
    ) -> SidebarPanelKind? {
        if let selection, visible.contains(selection) { return selection }
        return visible.first
    }
}
