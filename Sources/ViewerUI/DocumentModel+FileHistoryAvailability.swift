import Foundation
import ViewerCore

// File-history / extensions availability helpers (TSK-1110 SRP slice) — the
// Settings extensions inventory, the Local-History menu gate, and the pure
// repo-relative path helper. The `fileHistoryAvailability` cache stays on
// DocumentModel. Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// TSK-1112: merged extensions inventory for the Settings ▸ Extensions list.
    /// Plugins now (from the shared registry); walkthroughs (need an off-main
    /// catalog scan → snapshots) are a tracked follow-on.
    public var extensionsInventory: ExtensionsInventory { ExtensionsInventory.live() }

    /// Whether Local History can be shown for `url` — it has saved versions.
    /// (Always offer the menu; the viewer shows a friendly "no versions yet"
    /// empty state when there are none, so this returns true for any file URL.)
    public func canShowLocalHistory(for url: URL) -> Bool {
        url.isFileURL
    }

    /// Path of `url` relative to `root` (slash-joined, no leading slash),
    /// or `nil` when `url` isn't under `root`. Standardizes + resolves
    /// symlinks on both sides so a repo under `/var` (symlink to
    /// `/private/var`, the macOS scratch space) still matches.
    /// `nonisolated` so it's a pure helper testable off the main actor.
    nonisolated static func repoRelativePath(of url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        if filePath == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }
}
