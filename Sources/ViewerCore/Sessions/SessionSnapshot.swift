import Foundation

/// On-disk shape of a single tab inside a session. Lifted out of the
/// retired `WorkspaceStore` (decision G, 2026-05-25): kept its name +
/// shape so existing `Sessions/<uuid>.json` files round-trip without a
/// schema bump.
public struct TabSnapshot: Codable, Equatable, Sendable {
    public let path: String
    public let viewMode: String     // ViewMode.rawValue

    public init(path: String, viewMode: String) {
        self.path = path
        self.viewMode = viewMode
    }
}

/// On-disk shape of a single session ("a project the user has open").
///
/// Schema v2 of the workspace state — see `docs/SESSIONS_DESIGN.md`
/// §5.3. The legacy v1 `WorkspaceSnapshot` / `WorkspaceStore` files
/// were retired in decision G (2026-05-25) — `SessionStore` is the
/// only on-disk shape.
///
/// All additive fields beyond the v1 baseline are `Optional` so a
/// future v3 reader can still decode v2 files, and a v2 reader faced
/// with a partial v3 file decodes the additive fields it recognizes
/// (the design doc's "additive, optional, default-filled" rule).
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentSchema = 2
    public let schemaVersion: Int
    public let savedAt: Date

    // Identity (new in v2). In v2 the field is always present; v1
    // legacy files synthesize it via `fromLegacy`.
    public let id: UUID
    public let displayName: String
    public let createdAt: Date
    public let lastActiveAt: Date

    // Session-scoped tab + sidebar state. Mirrors WorkspaceSnapshot v1
    // fields but lifted onto the session.
    public let sidebarRootPath: String?
    public let openTabs: [TabSnapshot]
    public let selectedTabIndex: Int?

    // Additive session-scoped fields (design §5.3). Optional so future
    // additions stay backward-compatible.
    public let sidebarExpandedPaths: [String]?
    public let sidebarIncludeHidden: Bool?
    public let splitURL: String?

    // Phase-1 carry-over of preferences-style state that used to live
    // on `WorkspaceSnapshot`. We persist these per-session for
    // round-trip parity with `_last.json`; Phase 2 will decide which
    // become truly session-scoped vs. app-global.
    public let zoom: Double?
    public let wordWrap: Bool?
    public let themeOverride: String?

    public init(
        schemaVersion: Int = SessionSnapshot.currentSchema,
        savedAt: Date = Date(),
        id: UUID,
        displayName: String,
        createdAt: Date,
        lastActiveAt: Date,
        sidebarRootPath: String?,
        openTabs: [TabSnapshot] = [],
        selectedTabIndex: Int? = nil,
        sidebarExpandedPaths: [String]? = nil,
        sidebarIncludeHidden: Bool? = nil,
        splitURL: String? = nil,
        zoom: Double? = nil,
        wordWrap: Bool? = nil,
        themeOverride: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.sidebarRootPath = sidebarRootPath
        self.openTabs = openTabs
        self.selectedTabIndex = selectedTabIndex
        self.sidebarExpandedPaths = sidebarExpandedPaths
        self.sidebarIncludeHidden = sidebarIncludeHidden
        self.splitURL = splitURL
        self.zoom = zoom
        self.wordWrap = wordWrap
        self.themeOverride = themeOverride
    }

    /// True when two snapshots carry identical *persisted content*, ignoring
    /// the bookkeeping timestamps (`savedAt`, `lastActiveAt`) that change on
    /// every `makeSnapshot()` even when nothing the user can see changed.
    ///
    /// Used as the debounced-autosave equality guard (REPUB-1): a `@Published`
    /// tick that doesn't actually alter persisted state (e.g. an equal-value
    /// re-publish, a transient highlight-ready) must NOT schedule a disk write.
    /// `displayName` IS compared (a rename is a real content change), but the
    /// LRU/identity timestamps are not.
    public func hasSamePersistedContent(as other: SessionSnapshot) -> Bool {
        id == other.id
            && displayName == other.displayName
            && sidebarRootPath == other.sidebarRootPath
            && openTabs == other.openTabs
            && selectedTabIndex == other.selectedTabIndex
            && sidebarExpandedPaths == other.sidebarExpandedPaths
            && sidebarIncludeHidden == other.sidebarIncludeHidden
            && splitURL == other.splitURL
            && zoom == other.zoom
            && wordWrap == other.wordWrap
            && themeOverride == other.themeOverride
    }
}

/// On-disk shape of the session list ("which sessions exist, which is
/// active"). One file at `Sessions/index.json`. See design §5.2.
///
/// Kept separate from the per-session snapshot so:
///   - launch only needs to read this + the active session's file
///   - reorder / rename / activate doesn't rewrite every snapshot
public struct SessionIndex: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public let version: Int
    public let sessions: [Entry]
    public let lastActiveID: UUID?

    public init(version: Int = SessionIndex.currentSchema,
                sessions: [Entry] = [],
                lastActiveID: UUID? = nil) {
        self.version = version
        self.sessions = sessions
        self.lastActiveID = lastActiveID
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let rootPath: String
        public let displayName: String
        public let lastActiveAt: Date

        public init(id: UUID,
                    rootPath: String,
                    displayName: String,
                    lastActiveAt: Date) {
            self.id = id
            self.rootPath = rootPath
            self.displayName = displayName
            self.lastActiveAt = lastActiveAt
        }
    }
}
