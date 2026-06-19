import Foundation

/// Pure decision for renaming a session (TSK-931) — shared by the inline
/// session-tab editor and the menu-bar "Rename Session…" command. Also home to
/// the auto-relabel decision (TSK-1016): a session tab name tracks its current
/// root folder UNLESS the user manually renamed it.
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

    /// Best-effort display name from a folder URL (TSK-1016). The last path
    /// component is the natural pick; falls back to "Untitled" when the URL is
    /// the root (`/`) or empty. `URL.lastPathComponent` returns "/" for the
    /// root, not the empty string — handle both. Single source of truth for the
    /// derivation: `SessionState.defaultDisplayName` and the value-level
    /// `SessionsCoordinator.openFolder` both flow through here so the new-session
    /// title and a later root-change relabel can never diverge.
    public static func defaultDisplayName(forRoot url: URL) -> String {
        defaultDisplayName(forRootPath: url.lastPathComponent)
    }

    /// Path-component variant — lets the value layer derive a title from a bare
    /// `sidebarRootPath` string without round-tripping through `URL`.
    public static func defaultDisplayName(forRootPath lastComponentOrPath: String) -> String {
        // Accept either a full path or just the last component. Strip any
        // trailing slash, then take the final path segment.
        let trimmed = lastComponentOrPath.hasSuffix("/") && lastComponentOrPath.count > 1
            ? String(lastComponentOrPath.dropLast())
            : lastComponentOrPath
        let last = (trimmed as NSString).lastPathComponent
        if last.isEmpty || last == "/" { return "Untitled" }
        return last
    }

    /// TSK-1016 auto-relabel decision. When a session's root folder changes,
    /// the tab label should follow the new folder name — UNLESS the user has
    /// manually renamed the session (a manual rename wins and is never
    /// clobbered by a later root change).
    ///
    /// Returns the display name to apply, or `nil` to leave the existing name
    /// untouched. `nil` is returned when:
    ///   - `displayNameIsUserSet` is true (manual rename always wins), or
    ///   - the derived folder name equals the current name (no-op — avoids a
    ///     spurious republish / autosave write).
    ///
    /// Pure + host-testable: the live wiring (`SessionState.makeSnapshot`)
    /// calls this with the current sidebar root and the persisted user-set flag.
    public static func relabelForRootChange(
        newRoot: URL,
        currentDisplayName: String,
        displayNameIsUserSet: Bool
    ) -> String? {
        guard !displayNameIsUserSet else { return nil }
        let derived = defaultDisplayName(forRoot: newRoot)
        return derived == currentDisplayName ? nil : derived
    }
}
