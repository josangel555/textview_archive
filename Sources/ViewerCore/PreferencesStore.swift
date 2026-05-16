import Foundation

/// Thin wrapper around `UserDefaults` for our small set of persisted prefs.
/// Pure data → easy to unit-test with a custom `UserDefaults(suiteName:)`.
public final class PreferencesStore: @unchecked Sendable {
    private let defaults: UserDefaults

    private enum Key {
        static let sidebarWidth = "MarkdownViewer.sidebarWidth"
        static let sidebarVisible = "MarkdownViewer.sidebarVisible"
        static let lastFolder = "MarkdownViewer.lastFolderPath"
        static let zoom = "MarkdownViewer.zoom"
        static let sourceWordWrap = "MarkdownViewer.sourceWordWrap"
        static let showInvisibleChars = "MarkdownViewer.showInvisibleChars"
        static let uiScale = "MarkdownViewer.uiScale"
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

    /// Chrome scaling — multiplies the font size of sidebar, tabs,
    /// status bar, mode bar, etc. Distinct from `zoom` which scales
    /// document content. Range 0.85-1.6; default 1.0.
    public static let minUIScale: Double = 0.85
    public static let maxUIScale: Double = 1.6
    public static let uiScaleStep: Double = 0.05
    public var uiScale: Double {
        get {
            let raw = defaults.object(forKey: Key.uiScale) as? Double ?? 1.0
            return min(max(raw, Self.minUIScale), Self.maxUIScale)
        }
        set {
            let clamped = min(max(newValue, Self.minUIScale), Self.maxUIScale)
            defaults.set(clamped, forKey: Key.uiScale)
        }
    }

    // MARK: Zoom

    public static let minZoom: Double = 0.5
    public static let maxZoom: Double = 3.0
    public static let zoomStep: Double = 0.1

    public var zoom: Double {
        get {
            let raw = defaults.object(forKey: Key.zoom) as? Double ?? 1.0
            return min(max(raw, Self.minZoom), Self.maxZoom)
        }
        set {
            let clamped = min(max(newValue, Self.minZoom), Self.maxZoom)
            defaults.set(clamped, forKey: Key.zoom)
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
