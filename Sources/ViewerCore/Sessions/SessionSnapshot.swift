import Foundation

/// On-disk shape of a single tab inside a session. Lifted out of the
/// retired `WorkspaceStore` (decision G, 2026-05-25): kept its name +
/// shape so existing `Sessions/<uuid>.json` files round-trip without a
/// schema bump.
public struct TabSnapshot: Codable, Equatable, Sendable {
    public let path: String
    public let viewMode: String     // ViewMode.rawValue
    /// Per-tab "Open As…" category override (WAVE 2b item 6).
    /// `FileCategory.rawValue`, or `nil` for auto-detect. **Additive-
    /// optional**: an older reader (no `categoryOverride` key) decodes
    /// fine (the synthesized optional defaults to `nil`), and a newer
    /// reader faced with a legacy file with no key gets `nil` =
    /// auto-detect — the downgrade-safe default. On hydrate, an unknown
    /// raw string (a future category this build doesn't know) maps back
    /// to `nil` rather than crashing.
    public let categoryOverride: String?

    public init(path: String, viewMode: String, categoryOverride: String? = nil) {
        self.path = path
        self.viewMode = viewMode
        self.categoryOverride = categoryOverride
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

    /// Session kind (`SessionKind.rawValue`) — drives the SEED-ONCE
    /// per-kind default panel layout at creation (#184 scope item 3).
    /// Additive-optional: a pre-#184 file has no `sessionType` and
    /// decodes to `nil` (== `.project`); an unknown future raw value
    /// also maps back to `nil` on the read side. Never overrides a live
    /// session — it's a creation-time template, persisted only so the
    /// kind survives relaunch for display / future per-kind features.
    public let sessionType: String?

    /// Per-session shoulder-rail panel layout (#184 scope item 2). Moved
    /// off the GLOBAL `UserDefaults` so each session keeps its own panel
    /// arrangement. Additive-optional: a pre-#184 file has no
    /// `panelLayout` and decodes to `nil`, leaving the global-default
    /// layout untouched on hydrate (downgrade-safe).
    public let panelLayout: PanelLayoutSnapshot?

    // GLOBAL (owner LOCKED, #184): zoom / wordWrap / themeOverride are
    // app-wide, NOT per-session. These fields are retained in the schema
    // ONLY so pre-#184 on-disk files still decode (additive-optional,
    // downgrade-safe). They are written as `nil` going forward and never
    // applied on hydrate — see `SessionState.makeSnapshot` / `.hydrate`.
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
        sessionType: String? = nil,
        panelLayout: PanelLayoutSnapshot? = nil,
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
        self.sessionType = sessionType
        self.panelLayout = panelLayout
        self.zoom = zoom
        self.wordWrap = wordWrap
        self.themeOverride = themeOverride
    }

    /// Copy-with-overrides. Returns a new snapshot identical to `self`
    /// except for the supplied fields. Centralising the field list here
    /// kills the recurring footgun where a hand-written re-construction
    /// (in `persist` / `touched` / `replaceSnapshot` / `rename`) forgot a
    /// field and silently dropped it — exactly how `sidebarExpandedPaths`
    /// / `splitURL` ended up persisted as `nil` (#184). Add a new field
    /// once, here, and every copy site carries it through automatically.
    public func with(
        savedAt: Date? = nil,
        id: UUID? = nil,
        displayName: String? = nil,
        createdAt: Date? = nil,
        lastActiveAt: Date? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            schemaVersion: schemaVersion,
            savedAt: savedAt ?? self.savedAt,
            id: id ?? self.id,
            displayName: displayName ?? self.displayName,
            createdAt: createdAt ?? self.createdAt,
            lastActiveAt: lastActiveAt ?? self.lastActiveAt,
            sidebarRootPath: sidebarRootPath,
            openTabs: openTabs,
            selectedTabIndex: selectedTabIndex,
            sidebarExpandedPaths: sidebarExpandedPaths,
            sidebarIncludeHidden: sidebarIncludeHidden,
            splitURL: splitURL,
            sessionType: sessionType,
            panelLayout: panelLayout,
            zoom: zoom,
            wordWrap: wordWrap,
            themeOverride: themeOverride
        )
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
            && sessionType == other.sessionType
            && panelLayout == other.panelLayout
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
