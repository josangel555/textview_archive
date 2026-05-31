import Foundation

/// Thin wrapper around `UserDefaults` for our small set of persisted prefs.
/// Pure data → easy to unit-test with a custom `UserDefaults(suiteName:)`.
public final class PreferencesStore: @unchecked Sendable {
    /// The backing store. Exposed so sibling value-type stores
    /// (`PanelEdgeAssignment`, `PanelVisibilityOverrides`) that own
    /// their own comma-joined keys can persist into the SAME defaults
    /// instance the app + tests inject here, rather than reaching for a
    /// second `.standard` handle. Read-only on purpose — callers route
    /// preference writes through the typed accessors above.
    public let defaults: UserDefaults

    private enum Key {
        static let sidebarWidth = "MarkdownViewer.sidebarWidth"
        static let sidebarVisible = "MarkdownViewer.sidebarVisible"
        static let lastFolder = "MarkdownViewer.lastFolderPath"
        static let zoom = "MarkdownViewer.zoom"
        static let sourceWordWrap = "MarkdownViewer.sourceWordWrap"
        static let showInvisibleChars = "MarkdownViewer.showInvisibleChars"
        /// Legacy chrome-scale preference, retired when `uiScale` and
        /// `zoom` were unified onto `zoom`. Still read once for
        /// one-shot migration; never written.
        static let legacyUIScale = "MarkdownViewer.uiScale"
        /// HEX viewer: default bytes-per-row for NEW tabs. Per-tab
        /// overrides live in DocumentModel (in-memory only — they
        /// don't survive an app relaunch on purpose; this default
        /// does).
        static let hexBytesPerRow = "MarkdownViewer.hexBytesPerRow"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Sidebar width

    public var sidebarWidth: Double {
        get { defaults.object(forKey: Key.sidebarWidth) as? Double ?? 240 }
        set { defaults.set(newValue, forKey: Key.sidebarWidth) }
    }

    public static let minSidebarWidth: Double = 160
    public static let maxSidebarWidth: Double = 480

    public func setSidebarWidth(_ width: Double) {
        let clamped = min(max(width, Self.minSidebarWidth), Self.maxSidebarWidth)
        sidebarWidth = clamped
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

    /// Render invisible characters (spaces · tabs → · returns ¶) in the
    /// source view. NSLayoutManager's built-in glyph substitution; off by
    /// default to keep code reading clean. Inspired by Word's pilcrow
    /// toggle but tuned subtler so it's not visually alarming.
    public var showInvisibleChars: Bool {
        get { defaults.object(forKey: Key.showInvisibleChars) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.showInvisibleChars) }
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
