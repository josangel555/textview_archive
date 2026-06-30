import Foundation
import ViewerCore

/// Zoom-control commands (TSK-1110 SRP extraction). The `zoom` multiplier itself
/// is a stored `@Published` on DocumentModel (it must live with the other stored
/// state); these are the three control actions that mutate it, grouped here and
/// clamped to the PreferencesStore bounds so a user can't zoom past the limits.
extension DocumentModel {

    public func zoomIn() {
        zoom = min(zoom + PreferencesStore.zoomStep, PreferencesStore.maxZoom)
    }

    public func zoomOut() {
        zoom = max(zoom - PreferencesStore.zoomStep, PreferencesStore.minZoom)
    }

    public func zoomReset() {
        zoom = 1.0
    }
}
