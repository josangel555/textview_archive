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

    /// Per-file scroll position (UX-K, #231): the 1-based source line that
    /// was at the top of the source/editor viewport when this tab last lost
    /// focus / was closed. Restored on reopen via `scrollSource(toLine:)`.
    ///
    /// **Why a LINE, not a pixel offset.** A line survives a font-size /
    /// zoom / word-wrap change between sessions (the same content reflows to
    /// a different pixel offset, but "line 412" is stable); a raw `offsetY`
    /// would land on the wrong content. It also rides the existing
    /// `scrollSource(toLine:)` plumbing (honored by `.source` / `.editor`),
    /// so no new view-side machinery is needed.
    ///
    /// **Additive-optional** (downgrade-safe): an older reader without the
    /// key decodes to `nil` (no restore — top of file); a newer file with no
    /// key likewise decodes to `nil`. `nil` / `<= 0` ⇒ "don't restore".
    public let scrollTopLine: Int?

    /// TSK-1041: per-file RENDERED-markdown scroll position — the WKWebView's
    /// vertical pixel offset (`window.scrollY`) when this tab last lost focus /
    /// was snapshotted. The rendered preview is a THIRD scroll channel
    /// (`DocumentModel.renderedScrollByURL`), separate from the source/editor
    /// `scrollTopLine`: it lives in-memory only, so a SESSION switch — which
    /// drains the tab list and drops that dict — lost the rendered scroll
    /// entirely (it survived a tab switch only because the in-memory dict is
    /// URL-keyed). Folding it into the snapshot makes rendered scroll
    /// round-trip the same way `scrollTopLine` does for the text views.
    ///
    /// **Why a raw PIXEL offset, not a line** (unlike `scrollTopLine`). The
    /// rendered HTML has no 1:1 source-line mapping — it's reflowed Markdown —
    /// so the only stable handle the WebView exposes is `window.scrollY`. The
    /// trade-off vs `scrollTopLine`: a zoom / content-scale change between
    /// sessions lands at a slightly different spot. Acceptable — it mirrors the
    /// existing in-session `renderedScrollByURL` semantics exactly (same value,
    /// just now durable across the switch).
    ///
    /// **Additive-optional** (downgrade-safe): an older reader without the key
    /// decodes to `nil` (no restore — top); a newer file with no key likewise
    /// decodes to `nil`. `nil` / `<= 0` ⇒ "don't restore". Written as `nil`
    /// (key omitted by the encoder) for a never-rendered-scrolled tab so a
    /// fresh snapshot stays byte-compatible with pre-TSK-1041 files.
    public let renderedScrollY: Double?

    /// Hot exit (TSK-718): the unsaved editor-buffer text for this tab at the
    /// last snapshot boundary, so a relaunch restores in-flight edits the user
    /// never saved (VS Code-style hot exit). `nil` = the buffer was clean (no
    /// unsaved content) — nothing to restore, the file reloads from disk.
    ///
    /// **Additive-optional** (downgrade-safe): an older reader without the key
    /// decodes to `nil` (no restore); a newer file with no key likewise → `nil`.
    /// Capped at `DocumentModel.hotExitMaxBytes` on the capture side so a huge
    /// unsaved buffer can't bloat the per-session JSON.
    public let unsavedText: String?

    /// TSK-1025 hot-exit clobber guard: the `(mtime, size)` baseline the
    /// `unsavedText` edits were made FROM (see `Tab.unsavedBaseMTime`).
    /// Additive-optional (downgrade-safe): a pre-TSK-1025 file has no key and
    /// decodes to nil → restore falls back to the old fresh-from-disk baseline.
    public let unsavedBaseMTime: Date?
    public let unsavedBaseSize: Int?

    /// TSK-1303: the per-image-tab in-progress edit state (tonal/geometry ops +
    /// vector overlay), so image edits survive a session switch like the scroll /
    /// hot-exit fields above. `ImageEditState` carries NO pixels (the source image
    /// is re-decoded from `path`), so it stays cheap in the per-session JSON.
    ///
    /// **Additive-optional** (downgrade-safe): a pre-TSK-1303 reader/file has no
    /// key and decodes to `nil` (no edits to restore); a newer file with no key
    /// likewise → `nil`. Written as `nil` (key omitted) for a non-image / unedited
    /// tab so a fresh snapshot stays byte-compatible with pre-TSK-1303 files.
    public let imageEditState: ImageEditState?

    /// Hex hot-exit (2026-08-01): unsaved HEX-editor bytes, base64. Additive-
    /// optional like `imageEditState` (key omitted when nil); inline-capped
    /// at the capture side so the snapshot stays far under its read cap.
    public let unsavedHexBase64: String?

    /// I-19 (2026-08-11): the tab was in the per-tab SPLIT-EDITING layout
    /// (editor + same-file rendered preview inside the tab). Additive-
    /// optional; written as `true` only (key omitted otherwise) so fresh
    /// snapshots stay byte-compatible with older files.
    public let splitEditing: Bool?

    public init(path: String, viewMode: String,
                categoryOverride: String? = nil,
                scrollTopLine: Int? = nil,
                renderedScrollY: Double? = nil,
                unsavedText: String? = nil,
                unsavedBaseMTime: Date? = nil,
                unsavedBaseSize: Int? = nil,
                imageEditState: ImageEditState? = nil,
                unsavedHexBase64: String? = nil,
                splitEditing: Bool? = nil) {
        self.path = path
        self.viewMode = viewMode
        self.categoryOverride = categoryOverride
        self.scrollTopLine = scrollTopLine
        self.renderedScrollY = renderedScrollY
        self.unsavedText = unsavedText
        self.unsavedBaseMTime = unsavedBaseMTime
        self.unsavedBaseSize = unsavedBaseSize
        self.imageEditState = imageEditState
        self.unsavedHexBase64 = unsavedHexBase64
        self.splitEditing = splitEditing
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

    /// TSK-1016: `true` once the user has MANUALLY renamed this session (via
    /// the inline tab editor or the "Rename Session…" command). When set, the
    /// tab label is the user's text and must NEVER be clobbered by a later root
    /// change (which otherwise auto-relabels the tab to the new folder name).
    ///
    /// Additive-optional (downgrade-safe): a pre-TSK-1016 file has no key and
    /// decodes to `nil`, which the relabel decision treats as "not user-set"
    /// (auto-relabel on root change). Written as `nil` (omitted) for a
    /// folder-derived name so a fresh snapshot stays byte-identical to today;
    /// written `true` only after a manual rename.
    public let displayNameIsUserSet: Bool?

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
        displayNameIsUserSet: Bool? = nil,
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
        self.displayNameIsUserSet = displayNameIsUserSet
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
    ///
    /// `displayNameIsUserSet` uses a double-optional so callers can distinguish
    /// "leave unchanged" (omit the arg) from "explicitly set to a value" — the
    /// rename path passes `.some(true)` to mark a manual rename, and the
    /// auto-relabel path can pass `.some(nil)` to clear the flag back to
    /// folder-derived.
    public func with(
        savedAt: Date? = nil,
        id: UUID? = nil,
        displayName: String? = nil,
        createdAt: Date? = nil,
        lastActiveAt: Date? = nil,
        displayNameIsUserSet: Bool?? = nil
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
            displayNameIsUserSet: displayNameIsUserSet ?? self.displayNameIsUserSet,
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
    ///
    /// UX-K (#231): the per-file scroll position rides inside `openTabs`
    /// (`TabSnapshot.scrollTopLine`), so a captured scroll change IS treated as
    /// a real content change here — the autosave fires to persist it. Capture
    /// happens at focus-loss / close / detach / quit boundaries (never per
    /// scroll tick), so this can't spam the write queue on a scroll storm.
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
            && (displayNameIsUserSet ?? false) == (other.displayNameIsUserSet ?? false)
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // TSK-1028: version is OPTIONAL on decode — a legacy/hand-edited
        // index.json missing it defaults to the v1 schema instead of being
        // classified corrupt (which silently discarded lastActiveID + session
        // ordering). The future-version downgrade guard still applies downstream.
        self.version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentSchema
        self.sessions = (try? c.decodeIfPresent([Entry].self, forKey: .sessions)) ?? []
        self.lastActiveID = try? c.decodeIfPresent(UUID.self, forKey: .lastActiveID)
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
