import Foundation

/// Pure decision for renaming a session (TSK-931) — shared by the inline
/// session-tab editor and the menu-bar "Rename Session…" command.
public enum SessionRename {

    /// The name to apply when renaming from `current` to `proposed`, or nil to
    /// leave it unchanged. Trims surrounding whitespace; rejects an empty name
    /// and a no-op (already == current, after trimming) so a stray Enter on the
    /// inline editor never clobbers the existing name.
    public static func sanitize(_ proposed: String, current: String) -> String? {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current else { return nil }
        return trimmed
    }
}
