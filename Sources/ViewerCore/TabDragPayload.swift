import Foundation

/// The drag-and-drop payload protocol for document tabs. A drag publishes
/// the tab's STABLE id (never its index — indices go stale the moment the
/// strip reorders mid-drag); drop targets resolve the id back to a live
/// tab at drop time and bail cleanly if it has since been closed.
///
/// Shared by the tab strip's reorder delegate and the session-bar's
/// move-to-session delegate (TSK-274) so the wire format lives in one
/// place instead of two hand-rolled prefix parsers.
public enum TabDragPayload {
    public static let prefix = "mdv-tab:"

    public static func encode(_ id: UUID) -> String {
        prefix + id.uuidString
    }

    /// nil for non-tab payloads (arbitrary dropped text) or a malformed id.
    public static func tabID(from string: String) -> UUID? {
        guard string.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }
}
