import Foundation
import ViewerKit

/// Per-session snapshot of the things a user expects to come back
/// after a relaunch. Persisted as JSON on disk; restored at startup.
/// Schema versioning is explicit so we can evolve safely.
///
/// See STATE.md for the design notes — this is the v0 slice
/// (auto-saved `_last.json`). Named workspaces, crash recovery
/// banners, and iCloud sync are subsequent layers on this base.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public let schemaVersion: Int
    public let savedAt: Date

    public let sidebarRootPath: String?
    public let openTabs: [TabSnapshot]
    public let selectedTabIndex: Int?
    public let zoom: Double?
    public let wordWrap: Bool?
    public let themeOverride: String?  // SyntaxTheme.Name.rawValue or nil

    public init(
        schemaVersion: Int = WorkspaceSnapshot.currentSchema,
        savedAt: Date = Date(),
        sidebarRootPath: String?,
        openTabs: [TabSnapshot],
        selectedTabIndex: Int?,
        zoom: Double?,
        wordWrap: Bool?,
        themeOverride: String?
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.sidebarRootPath = sidebarRootPath
        self.openTabs = openTabs
        self.selectedTabIndex = selectedTabIndex
        self.zoom = zoom
        self.wordWrap = wordWrap
        self.themeOverride = themeOverride
    }
}

public struct TabSnapshot: Codable, Equatable, Sendable {
    public let path: String
    public let viewMode: String     // ViewMode.rawValue

    public init(path: String, viewMode: String) {
        self.path = path
        self.viewMode = viewMode
    }
}

/// Reads + writes WorkspaceSnapshot files to
/// `~/Library/Application Support/MarkdownViewer/Workspaces/`.
public final class WorkspaceStore: Sendable {
    public let directory: URL

    public static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("MarkdownViewer/Workspaces")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public init(directory: URL = WorkspaceStore.defaultDirectory()) {
        self.directory = directory
    }

    /// Write the auto-save slot, atomically. Errors are swallowed —
    /// failure to persist shouldn't crash the app on quit.
    public func saveAutoSlot(_ snap: WorkspaceSnapshot) {
        let url = directory.appendingPathComponent("_last.json")
        save(snap, to: url)
    }

    public func loadAutoSlot() -> WorkspaceSnapshot? {
        let url = directory.appendingPathComponent("_last.json")
        return load(from: url)
    }

    public func save(_ snap: WorkspaceSnapshot, name: String) {
        let safe = sanitize(name)
        let url = directory.appendingPathComponent("\(safe).json")
        save(snap, to: url)
    }

    public func load(name: String) -> WorkspaceSnapshot? {
        let safe = sanitize(name)
        let url = directory.appendingPathComponent("\(safe).json")
        return load(from: url)
    }

    public func list() -> [String] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "_last.json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public func delete(name: String) {
        let safe = sanitize(name)
        let url = directory.appendingPathComponent("\(safe).json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - private

    private func save(_ snap: WorkspaceSnapshot, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(snap)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort. App-quit-time persistence shouldn't fail
            // loudly; user can't act on it.
        }
    }

    private func load(from url: URL) -> WorkspaceSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let snap = try? decoder.decode(WorkspaceSnapshot.self, from: data) else {
            return nil
        }
        return snap
    }

    /// Sanitize a user-supplied workspace name for use as a filename.
    /// Replaces /, :, NUL with underscores; trims whitespace.
    private func sanitize(_ name: String) -> String {
        let bad: Set<Character> = ["/", ":", "\0", "\\"]
        var out = name.trimmingCharacters(in: .whitespacesAndNewlines)
        out = String(out.map { bad.contains($0) ? "_" : $0 })
        if out.isEmpty { out = "untitled" }
        return out
    }
}
