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
