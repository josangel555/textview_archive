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

/// Which window edge the terminal PANE itself docks to (TSK-491) — distinct
/// from `TerminalTabPosition`, which only places the tab strip *inside* the
/// pane. `bottom` is the default (the classic fixed-height band under the
/// content); `left`/`right` make the pane a fixed-WIDTH side column. Raw-
/// string-backed so an unknown persisted value degrades to `.bottom`.
public enum TerminalPaneEdge: String, Sendable, Equatable, CaseIterable, Codable {
    case bottom
    case left
    case right

    /// The default placement (unchanged behaviour: a bottom band).
    public static let `default`: TerminalPaneEdge = .bottom

    /// `left`/`right` dock the pane as a side column sized by WIDTH; `bottom`
    /// is a band sized by HEIGHT. Drives which axis the resize handle controls.
    public var isSide: Bool { self == .left || self == .right }

    /// Human-readable name for the Settings picker.
    public var displayName: String {
        switch self {
        case .bottom: return "Bottom"
        case .left:   return "Left"
        case .right:  return "Right"
        }
    }

    /// SF Symbol cue matching the macOS dock iconography.
    public var systemImage: String {
        switch self {
        case .bottom: return "rectangle.bottomthird.inset.filled"
        case .left:   return "sidebar.left"
        case .right:  return "sidebar.right"
        }
    }
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
    /// Pane dock edge (raw `TerminalPaneEdge`). Pinned by test. (TSK-491)
    public static let paneEdgeKey = "MarkdownViewer.terminal.paneEdge"
    /// Pane width in points when docked left/right. Pinned by test. (TSK-491)
    public static let sideWidthKey = "MarkdownViewer.terminal.sideWidth"

    /// Sensible bounds so a corrupted / hostile default can't make the
    /// pane swallow the window or collapse to nothing.
    public static let minHeight: CGFloat = 80
    public static let maxHeight: CGFloat = 800
    public static let defaultHeight: CGFloat = 220
    /// Width bounds for the side-docked pane (left/right column).
    public static let minWidth: CGFloat = 160
    public static let maxWidth: CGFloat = 900
    public static let defaultWidth: CGFloat = 360

    public var isOpen: Bool
    public private(set) var height: CGFloat
    /// Tab-strip placement (default `.left`, TSK-488).
    public var tabPosition: TerminalTabPosition
    /// Pane dock edge (default `.bottom`, TSK-491).
    public var paneEdge: TerminalPaneEdge
    /// Side-column width when `paneEdge` is `.left`/`.right` (TSK-491).
    public private(set) var sideWidth: CGFloat

    public init(
        isOpen: Bool = false,
        height: CGFloat = TerminalPaneLayout.defaultHeight,
        tabPosition: TerminalTabPosition = .left,
        paneEdge: TerminalPaneEdge = .bottom,
        sideWidth: CGFloat = TerminalPaneLayout.defaultWidth
    ) {
        self.isOpen = isOpen
        self.height = TerminalPaneLayout.clampHeight(height)
        self.tabPosition = tabPosition
        self.paneEdge = paneEdge
        self.sideWidth = TerminalPaneLayout.clampWidth(sideWidth)
    }

    /// Clamp a height into `[minHeight, maxHeight]`. NaN (garbage) falls back
    /// to the default; ±infinity clamps to the bounds (+inf→max, -inf→min).
    public static func clampHeight(_ h: CGFloat) -> CGFloat {
        guard !h.isNaN else { return defaultHeight }
        return min(max(h, minHeight), maxHeight)
    }

    /// Clamp a width into `[minWidth, maxWidth]`; NaN → defaultWidth.
    public static func clampWidth(_ w: CGFloat) -> CGFloat {
        guard !w.isNaN else { return defaultWidth }
        return min(max(w, minWidth), maxWidth)
    }

    public mutating func setHeight(_ h: CGFloat) {
        height = TerminalPaneLayout.clampHeight(h)
    }

    public mutating func setWidth(_ w: CGFloat) {
        sideWidth = TerminalPaneLayout.clampWidth(w)
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
        // Unknown / unset raw → default `.bottom` (TSK-491).
        let edge = defaults.string(forKey: paneEdgeKey)
            .flatMap(TerminalPaneEdge.init(rawValue:)) ?? .bottom
        let storedWidth: CGFloat
        if defaults.object(forKey: sideWidthKey) != nil {
            storedWidth = CGFloat(defaults.double(forKey: sideWidthKey))
        } else {
            storedWidth = defaultWidth
        }
        return TerminalPaneLayout(
            isOpen: open, height: storedHeight, tabPosition: pos,
            paneEdge: edge, sideWidth: storedWidth)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isOpen, forKey: TerminalPaneLayout.openKey)
        defaults.set(Double(height), forKey: TerminalPaneLayout.heightKey)
        defaults.set(tabPosition.rawValue, forKey: TerminalPaneLayout.tabPositionKey)
        defaults.set(paneEdge.rawValue, forKey: TerminalPaneLayout.paneEdgeKey)
        defaults.set(Double(sideWidth), forKey: TerminalPaneLayout.sideWidthKey)
    }
}
