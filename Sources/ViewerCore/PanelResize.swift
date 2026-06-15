import Foundation

/// Width clamp for a horizontally-resizable side panel (TSK-918). The owner
/// wants no arbitrary cap on panel width — only the sane constraint that the
/// panel can't starve the content area. So a panel grows freely up to
/// `available - minContent`, never below `minPanel`. Pure — host-testable; the
/// drag gesture that feeds it `available` (the live window width) is the VM tail.
public enum PanelResize {

    public static func clampWidth(_ proposed: Double, available: Double,
                                  minContent: Double, minPanel: Double) -> Double {
        // If the window is too small to honor both minima, the panel floor wins
        // (content gets squeezed) — never shrink the panel below usable.
        let upper = max(minPanel, available - minContent)
        return min(max(proposed, minPanel), upper)
    }
}
