import Foundation

/// TSK-1169 — the LOCATION half of the settings ask: make the JSON settings
/// state discoverable at `~/.textview/` (the precedent `keybinding.json` /
/// repo-local `.textview/` already set) instead of buried under
/// `~/Library/Application Support/MarkdownViewer/`. This is the PURE
/// migration model — the path mapping, the one-time migration PLAN, and the
/// backward-read resolution — all host-tested with injected roots. The
/// actual FileManager move is the data-safety-sensitive live tail (moving a
/// user's prefs; do it once, atomically, VM/owner-validated).
public enum SettingsRelocation {

    /// The new discoverable settings root: `<home>/.textview`.
    public static func newRoot(home: URL) -> URL {
        home.appendingPathComponent(".textview", isDirectory: true)
    }

    /// The legacy root: `<home>/Library/Application Support/MarkdownViewer`.
    public static func legacyRoot(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support/MarkdownViewer",
                                    isDirectory: true)
    }

    /// The JSON state files eligible to relocate. UserDefaults-backed prefs
    /// (zoom/theme/window) stay in the defaults DB — only the app's own JSON
    /// state files move (the discoverable, hand-editable ones).
    public static let relocatableFiles: [String] = [
        "bookmarks.json",
        "history.json",
        "recent-paths.json",
        "view-mode-locks.json",
        "remembered-lenses.json",
        "lsp-trusted-binaries.json",
    ]

    /// One file's relocation.
    public struct Move: Equatable, Sendable {
        public let file: String
        public let from: URL
        public let to: URL
        public init(file: String, from: URL, to: URL) {
            self.file = file
            self.from = from
            self.to = to
        }
    }

    /// The one-time migration plan: for each relocatable file, move it from
    /// legacy→new ONLY when it exists in legacy AND is ABSENT in new (never
    /// clobber a file the user already has in the new location — a re-run or
    /// a partial prior migration is a no-op for that file). `existsAt` is
    /// injected so the plan is pure.
    public static func migrationPlan(
        home: URL, existsAt: (URL) -> Bool
    ) -> [Move] {
        let newDir = newRoot(home: home)
        let oldDir = legacyRoot(home: home)
        return relocatableFiles.compactMap { file in
            let from = oldDir.appendingPathComponent(file)
            let to = newDir.appendingPathComponent(file)
            guard existsAt(from), !existsAt(to) else { return nil }
            return Move(file: file, from: from, to: to)
        }
    }

    /// Which path to READ a settings file from: the new location if present,
    /// else the legacy location (backward read — a not-yet-migrated install,
    /// or a file that failed to move, still loads). The caller writes to the
    /// new location going forward.
    public static func readPath(
        for file: String, home: URL, existsAt: (URL) -> Bool
    ) -> URL {
        let newPath = newRoot(home: home).appendingPathComponent(file)
        if existsAt(newPath) { return newPath }
        let oldPath = legacyRoot(home: home).appendingPathComponent(file)
        return existsAt(oldPath) ? oldPath : newPath  // default to new for a fresh write
    }
}
