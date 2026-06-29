import Foundation
import ViewerKit
import ViewerCore

// Per-tab dict forwarders (TSK-1110 SRP slice) — TabCoordinator owns the storage;
// these keep external call sites unchanged for CSV filter state + HEX byte-width.
// Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// Source-compat alias — the type was previously nested on
    /// DocumentModel; CSVTableView constructs `DocumentModel.CSVFilterState()`.
    /// Keeps that call site valid without churning view code.
    public typealias CSVFilterState = TabCoordinator.CSVFilterState

    /// Forwarder. New code should call `tabCoordinator.csvFilterStates`.
    public var csvFilterStates: [UUID: CSVFilterState] {
        tabCoordinator.csvFilterStates
    }

    public func csvFilterState(forTabID id: UUID) -> CSVFilterState {
        tabCoordinator.csvFilterState(forTabID: id)
    }

    public func setCsvFilterState(_ state: CSVFilterState, forTabID id: UUID) {
        tabCoordinator.setCsvFilterState(state, forTabID: id)
    }

    /// Forwarder. New code should call `tabCoordinator.hexBytesPerRow`.
    public var hexBytesPerRow: [UUID: Int] { tabCoordinator.hexBytesPerRow }

    public func hexWidth(forTabID id: UUID) -> Int {
        tabCoordinator.hexWidth(forTabID: id, fallback: preferences.hexBytesPerRow)
    }

    public func setHexWidth(_ width: Int, forTabID id: UUID) {
        tabCoordinator.setHexWidth(width, forTabID: id)
        // Also bump the global default so the next opened binary
        // remembers what the user picked. Cheap; matches Sublime
        // "remember last setting" feel. Lives on DocumentModel
        // because PreferencesStore is a DocumentModel dependency.
        let clamped = HexLayout.clampWidth(width)
        if preferences.hexBytesPerRow != clamped {
            preferences.hexBytesPerRow = clamped
        }
    }
}
