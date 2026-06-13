import Foundation

/// Thin wrapper around `UserDefaults` for our small set of persisted prefs.
/// Pure data → easy to unit-test with a custom `UserDefaults(suiteName:)`.
public final class PreferencesStore: @unchecked Sendable {
    /// The backing store. Exposed so sibling value-type stores
    /// (`PanelEdgeAssignment`, `PanelVisibilityOverrides`) that own
    /// their own comma-joined keys can persist into the SAME defaults
    /// instance the app + tests inject here, rather than reaching for a
    /// second `.standard` handle. Read-only on purpose — callers route
    /// preference writes through the typed accessors below.
    public let defaults: UserDefaults

    private enum Key {
        static let sidebarWidth = "MarkdownViewer.sidebarWidth"
        static let sidebarVisible = "MarkdownViewer.sidebarVisible"
        static let lastFolder = "MarkdownViewer.lastFolderPath"
        static let zoom = "MarkdownViewer.zoom"
        static let sourceWordWrap = "MarkdownViewer.sourceWordWrap"
        static let showInvisibleChars = "MarkdownViewer.showInvisibleChars"
        static let editorIndentGuides = "MarkdownViewer.editorIndentGuides"
        static let themeOverride = "MarkdownViewer.themeOverride"
        /// Legacy chrome-scale preference, retired when `uiScale` and
        /// `zoom` were unified onto `zoom`. Still read once for
        /// one-shot migration; never written.
        static let legacyUIScale = "MarkdownViewer.uiScale"
        /// HEX viewer: default bytes-per-row for NEW tabs. Per-tab
        /// overrides live in DocumentModel (in-memory only — they
        /// don't survive an app relaunch on purpose; this default
        /// does).
        static let hexBytesPerRow = "MarkdownViewer.hexBytesPerRow"
        /// User-provided path to an `ffmpeg` executable for MP3 audio export.
        static let audioFFmpegPath = "MarkdownViewer.audioFFmpegPath"
        /// Preview mode's metadata side panel visibility (TSK-608).
        static let previewMetadataVisible = "MarkdownViewer.previewMetadataVisible"
        static let sourceFontName = "MarkdownViewer.sourceFontName"
    }

    /// Defaults to the pristine-aware store (TSK-618): `.standard`
    /// normally, an emptied process suite under `MDV_PRISTINE_CHROME=1`
    /// so harness spawns get factory-default chrome and their writes
    /// can't pollute the next spawn or the user's real preferences.
    /// Everything chrome-stateful chains off this (`TerminalPaneStore`,
    /// `PanelLayoutStore` via `preferences.defaults`).
    public init(defaults: UserDefaults = PristineChrome.launchDefaults()) {
        self.defaults = defaults
    }

    // MARK: Sidebar width

    /// Clamped to `[minSidebarWidth, maxSidebarWidth]` on BOTH read and
    /// write (mirrors `hexBytesPerRow`) so a tampered/legacy `_last.json`
    /// or a direct write that bypasses `setSidebarWidth(_:)` can't persist
    /// or read back an out-of-range value.
    public var sidebarWidth: Double {
        get { Self.clampSidebarWidth(defaults.object(forKey: Key.sidebarWidth) as? Double ?? 240) }
        set { defaults.set(Self.clampSidebarWidth(newValue), forKey: Key.sidebarWidth) }
    }

    public static let minSidebarWidth: Double = 160
    public static let maxSidebarWidth: Double = 480

    private static func clampSidebarWidth(_ width: Double) -> Double {
        min(max(width, minSidebarWidth), maxSidebarWidth)
    }

    public func setSidebarWidth(_ width: Double) {
        sidebarWidth = width
    }

    /// Whether the sidebar is currently visible. Default true — first
    /// launch with a folder open should show it.
    public var sidebarVisible: Bool {
        get { defaults.object(forKey: Key.sidebarVisible) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.sidebarVisible) }
    }

    /// Whether the source/text viewer soft-wraps long lines at the
    /// viewport edge instead of scrolling horizontally. Default off
    /// (matches Xcode, every code editor) — user toggles via View
    /// menu → Wrap Long Lines.
    public var sourceWordWrap: Bool {
        get { defaults.object(forKey: Key.sourceWordWrap) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.sourceWordWrap) }
    }

    /// Preferred monospace font FAMILY for the text surfaces (TSK-259).
    /// nil = the system monospaced font. Resolution is fail-safe
    /// (`FontPreference.resolvedFont`): a deleted font degrades silently.
    public var sourceFontName: String? {
        get { defaults.string(forKey: Key.sourceFontName) }
        set { defaults.set(newValue, forKey: Key.sourceFontName) }
    }

    /// Whether preview mode shows the metadata side panel (file info,
    /// image dimensions, SQLite table/row counts). Default ON — the
    /// pre-TSK-608 behavior; the BottomAttributesBar "Info" toggle is
    /// the dismiss affordance the panel previously lacked.
    public var previewMetadataVisible: Bool {
        get { defaults.object(forKey: Key.previewMetadataVisible) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.previewMetadataVisible) }
    }

    /// Render invisible characters (spaces · tabs → · returns ¶) in the
    /// source view. NSLayoutManager's built-in glyph substitution; off by
    /// default to keep code reading clean. Inspired by Word's pilcrow
    /// toggle but tuned subtler so it's not visually alarming.
    public var showInvisibleChars: Bool {
        get { defaults.object(forKey: Key.showInvisibleChars) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.showInvisibleChars) }
    }

    /// Render vertical indentation guide lines in the CM6 editor (the
    /// `foldGutter`-adjacent guide rules CodeMirror's `indentationMarkers`
    /// draws). Off by default — opt-in via Settings → Editor so today's
    /// default rendering is unchanged; an owner call could flip the
    /// default to on later (TSK-487).
    public var editorIndentGuides: Bool {
        get { defaults.object(forKey: Key.editorIndentGuides) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.editorIndentGuides) }
    }

    /// Persisted syntax-theme override (Settings → Appearance → Theme). `nil` =
    /// Follow System; otherwise the `SyntaxTheme.Name` raw value. Stored as a
    /// raw string to keep this a primitives-only store — and so a stale/unknown
    /// value degrades to Follow System (`SyntaxTheme.Name(rawValue:)` returns
    /// nil) rather than crashing. App-wide global (owner-locked #184), persisted
    /// like `zoom`/`sourceWordWrap` (previously it lived only in memory, so the
    /// picker forgot the choice on relaunch — TSK-101).
    public var themeOverrideRaw: String? {
        get { defaults.string(forKey: Key.themeOverride) }
        set {
            if let raw = newValue {
                defaults.set(raw, forKey: Key.themeOverride)
            } else {
                defaults.removeObject(forKey: Key.themeOverride)
            }
        }
    }

    // MARK: Zoom
    //
    // One slider drives both document content AND chrome (sidebar /
    // tabs / status bar / mode bar) via `DocumentModel.uiSize(_:)`.
    // Pre-unification there was a separate `uiScale` preference; on
    // first read after upgrade, if `zoom` is absent but the legacy
    // key is present, we adopt the larger of the two as the unified
    // value. Rationale: a user who'd bumped chrome but never touched
    // text-zoom (or vice versa) almost certainly wants the bigger UI
    // they'd been using, not a silent shrink back to 1.0.

    public static let minZoom: Double = 0.5
    public static let maxZoom: Double = 3.0
    public static let zoomStep: Double = 0.1

    public var zoom: Double {
        get {
            let zoomRaw = defaults.object(forKey: Key.zoom) as? Double
            let legacyRaw = defaults.object(forKey: Key.legacyUIScale) as? Double
            let raw: Double
            switch (zoomRaw, legacyRaw) {
            case let (z?, l?): raw = max(z, l)
            case let (z?, nil): raw = z
            case let (nil, l?): raw = l
            case (nil, nil): raw = 1.0
            }
            return min(max(raw, Self.minZoom), Self.maxZoom)
        }
        set {
            let clamped = min(max(newValue, Self.minZoom), Self.maxZoom)
            defaults.set(clamped, forKey: Key.zoom)
            // Drop the legacy key the first time we write the unified
            // value, so subsequent reads don't keep resurrecting it.
            defaults.removeObject(forKey: Key.legacyUIScale)
        }
    }

    // MARK: HEX viewer width

    /// Default bytes-per-row for newly-opened binaries in the HEX
    /// viewer. Clamped to `HexLayout.allowedWidths` (16/32/64) on
    /// read so a stale preference can't break the picker.
    public var hexBytesPerRow: Int {
        get {
            let raw = defaults.object(forKey: Key.hexBytesPerRow) as? Int
                ?? HexLayout.defaultWidth
            return HexLayout.clampWidth(raw)
        }
        set { defaults.set(HexLayout.clampWidth(newValue), forKey: Key.hexBytesPerRow) }
    }

    // MARK: Audio — ffmpeg path (MP3 export)

    /// User-provided path to an `ffmpeg` executable for MP3 audio export
    /// (Settings → Audio). `nil`/empty ⇒ auto-discover on `PATH` + common
    /// install locations (`FFmpegLocator`); if neither resolves an executable
    /// the MP3 export option is simply disabled. Callers pass this value as
    /// `AudioExporter.encode(…, ffmpegOverride:)`. Owner decision 2026-06-09:
    /// ffmpeg is an EXTERNAL host tool, never bundled/vendored.
    ///
    /// Stored as a raw string (primitives-only store); a whitespace/empty value
    /// reads back as `nil` so it degrades cleanly to auto-discovery rather than
    /// feeding `FFmpegLocator` a bogus override. Mirrors `themeOverrideRaw`.
    public var audioFFmpegPath: String? {
        get {
            let raw = defaults.string(forKey: Key.audioFFmpegPath)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                defaults.set(trimmed, forKey: Key.audioFFmpegPath)
            } else {
                defaults.removeObject(forKey: Key.audioFFmpegPath)
            }
        }
    }

    // MARK: Last open folder

    public var lastFolderURL: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastFolder), !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
        set {
            if let url = newValue {
                defaults.set(url.path, forKey: Key.lastFolder)
            } else {
                defaults.removeObject(forKey: Key.lastFolder)
            }
        }
    }
}
