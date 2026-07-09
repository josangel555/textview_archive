import Foundation

/// TSK-1572 — the PURE keyboard-nav state for the new-tab launchpad: a selection
/// that moves across the omni FIELD (the top) and the section ROWS below it with
/// ↑/↓, clamped at both ends. `nil` = the omni field is focused (so Enter runs the
/// typed query); an index selects a row (Enter activates it). Host-testable; the
/// view mirrors `selectedRow` into its highlight + routes Enter accordingly.
public struct LaunchpadSelection: Equatable, Sendable {

    /// Number of selectable rows below the omni field.
    public let rowCount: Int
    /// nil = the omni field (top); else a 0-based row index into the rows below.
    public private(set) var selectedRow: Int?

    public init(rowCount: Int, selectedRow: Int? = nil) {
        self.rowCount = max(0, rowCount)
        // Clamp any provided row into range (nil stays nil = omni).
        if let r = selectedRow { self.selectedRow = min(max(0, r), max(0, self.rowCount - 1)) }
        else { self.selectedRow = nil }
    }

    /// True while the omni field holds the selection (Enter runs the typed query).
    public var isOmniFocused: Bool { selectedRow == nil }

    /// Move the selection DOWN: omni → row 0 → row 1 → … clamped at the last row.
    /// A no-op when there are no rows (stays on the omni field).
    public mutating func moveDown() {
        guard rowCount > 0 else { return }
        switch selectedRow {
        case nil: selectedRow = 0
        case let r?: selectedRow = min(r + 1, rowCount - 1)
        }
    }

    /// Move the selection UP: row → previous row, and row 0 → the omni field
    /// (which then stays put on further up-presses).
    public mutating func moveUp() {
        switch selectedRow {
        case nil: return                     // already at the top (omni)
        case 0: selectedRow = nil            // row 0 → omni field
        case let r?: selectedRow = r - 1
        }
    }

    /// Re-clamp after the row list changes (a filter shrank/grew it). Keeps the
    /// omni focus if it was focused; otherwise clamps the row into the new range
    /// (or back to the omni field when the list emptied).
    public func reclamped(toRowCount newCount: Int) -> LaunchpadSelection {
        LaunchpadSelection(rowCount: newCount,
                           selectedRow: newCount == 0 ? nil : selectedRow)
    }
}
