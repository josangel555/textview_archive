import Foundation

/// Thin wrapper around `UserDefaults` for our small set of persisted prefs.
/// Pure data → easy to unit-test with a custom `UserDefaults(suiteName:)`.
public final class PreferencesStore: @unchecked Sendable {
    private let defaults: UserDefaults

    private enum Key {
        static let sidebarWidth = "MarkdownViewer.sidebarWidth"
        static let lastFolder = "MarkdownViewer.lastFolderPath"
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
