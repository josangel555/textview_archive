import Foundation
import CoreGraphics

/// Where the terminal's tab strip sits relative to the terminal surface
/// (TSK-488). `left` is the default; `top`/`right` are user choices. A
/// vertical chip column is drawn for `left`/`right`, a horizontal strip
/// for `top`. Raw-string-backed so an unknown persisted value degrades to
/// `.left` rather than crashing.
public enum TerminalTabPosition: String, Sendable, Equatable, CaseIterable, Codable {
    case left
    case top
    case right

    /// The strip runs vertically (a column of chips) for left/right.
    public var isVertical: Bool { self == .left || self == .right }
}

/// Persisted layout for the bottom terminal pane: whether it's open and
/// how tall it is. Mirrors the `PanelEdgeAssignment` / `PanelVisibility`
/// persistence idiom — a value type that owns its own `UserDefaults`
/// keys + load/save round-trip, host-testable with a throwaway suite.
///
/// Pure-logic (no SwiftUI / no AppKit). The observable wrapper
/// (`TerminalPaneStore`, ViewerUI) holds one of these and writes through
/// on user-paced toggles/drags.
public struct TerminalPaneLayout: Sendable, Equatable {
    /// Whether the terminal pane is open. Pinned by test.
    public static let openKey   = "MarkdownViewer.terminal.isOpen"
    /// Pane height in points. Pinned by test.
    public static let heightKey = "MarkdownViewer.terminal.height"
    /// Tab-strip position (raw `TerminalTabPosition`). Pinned by test.
    public static let tabPositionKey = "MarkdownViewer.terminal.tabPosition"

    /// Sensible bounds so a corrupted / hostile default can't make the
    /// pane swallow the window or collapse to nothing.
    public static let minHeight: CGFloat = 80
    public static let maxHeight: CGFloat = 800
    public static let defaultHeight: CGFloat = 220

    public var isOpen: Bool
    public private(set) var height: CGFloat
    /// Tab-strip placement (default `.left`, TSK-488).
    public var tabPosition: TerminalTabPosition

    public init(
        isOpen: Bool = false,
        height: CGFloat = TerminalPaneLayout.defaultHeight,
        tabPosition: TerminalTabPosition = .left
    ) {
        self.isOpen = isOpen
        self.height = TerminalPaneLayout.clampHeight(height)
        self.tabPosition = tabPosition
    }

    /// Clamp a height into `[minHeight, maxHeight]`. NaN (garbage) falls back
    /// to the default; ±infinity clamps to the bounds (+inf→max, -inf→min).
    public static func clampHeight(_ h: CGFloat) -> CGFloat {
        guard !h.isNaN else { return defaultHeight }
        return min(max(h, minHeight), maxHeight)
    }

    public mutating func setHeight(_ h: CGFloat) {
        height = TerminalPaneLayout.clampHeight(h)
    }

    // MARK: - Persistence

    public static func load(from defaults: UserDefaults) -> TerminalPaneLayout {
        let open = defaults.bool(forKey: openKey)
        // `object(forKey:)` distinguishes "unset" (→ default) from a
        // stored 0 (→ clamped to minHeight).
        let storedHeight: CGFloat
        if defaults.object(forKey: heightKey) != nil {
            storedHeight = CGFloat(defaults.double(forKey: heightKey))
        } else {
            storedHeight = defaultHeight
        }
        // Unknown / unset raw → default `.left`.
        let pos = defaults.string(forKey: tabPositionKey)
            .flatMap(TerminalTabPosition.init(rawValue:)) ?? .left
        return TerminalPaneLayout(isOpen: open, height: storedHeight, tabPosition: pos)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isOpen, forKey: TerminalPaneLayout.openKey)
        defaults.set(Double(height), forKey: TerminalPaneLayout.heightKey)
        defaults.set(tabPosition.rawValue, forKey: TerminalPaneLayout.tabPositionKey)
    }
}
