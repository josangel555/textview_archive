import Foundation

/// Theme catalog + persisted selection (TSK-641 stage 1). Built-ins plus
/// user definitions from `Application Support/MarkdownViewer/Themes/*.json`
/// (the dir TSK-642's VS Code import writes into). Selection persists in
/// UserDefaults; unknown/missing ids fall back to appearance-paired
/// built-ins, so a deleted user theme degrades, never breaks.
public final class ThemeStore: @unchecked Sendable {

    public static let shared = ThemeStore()
    public static let selectionKey = "MarkdownViewer.theme.selected"

    private let defaults: UserDefaults
    private let userDir: URL
    private let lock = NSLock()
    private var cachedUserThemes: [ThemeDefinition]?

    public init(userDir: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // TSK-1288: markdownViewerDir() redirects to tmp under XCTest (real dir in prod).
        self.userDir = userDir ?? TestStateRedirect.markdownViewerDir()
            .appendingPathComponent("Themes", isDirectory: true)
    }

    /// All available themes: built-ins first, then user themes sorted by id.
    public func all() -> [ThemeDefinition] {
        ThemeDefinition.builtIns + userThemes()
    }

    /// The persisted selection id (nil = follow system appearance).
    ///
    /// Capture-lane override (MDV_FORCE_THEME_ID): scene runs share one VM
    /// user, so the LAST run's persisted selection leaks into the next
    /// launch's chrome first-paint (the mixed light/dark capture class,
    /// 2026-08-08). An id pins the launch selection; "none" pins
    /// system-following. Absent/empty env → the persisted value.
    public var selectedID: String? {
        get {
            if let forced = ProcessInfo.processInfo.environment["MDV_FORCE_THEME_ID"],
               !forced.isEmpty {
                return forced == "none" ? nil : forced
            }
            return defaults.string(forKey: Self.selectionKey)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.selectionKey)
            } else {
                defaults.removeObject(forKey: Self.selectionKey)
            }
        }
    }

    /// Resolve the active definition: explicit selection if it still
    /// exists, else the appearance-paired built-in.
    public func active(isDarkAppearance: Bool) -> ThemeDefinition {
        if let id = selectedID, let match = all().first(where: { $0.id == id }) {
            return match
        }
        return ThemeDefinition.builtIns.first { $0.isDark == isDarkAppearance }
            ?? ThemeDefinition.builtIns[0]
    }

    /// Persist a user theme definition (TSK-642's import lands here).
    /// Returns the written URL.
    @discardableResult
    public func saveUserTheme(_ def: ThemeDefinition) throws -> URL {
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let url = userDir.appendingPathComponent("\(def.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(def).write(to: url, options: .atomic)
        lock.lock()
        cachedUserThemes = nil
        lock.unlock()
        return url
    }

    /// Drop the cache (file-system changes outside saveUserTheme).
    public func invalidate() {
        lock.lock()
        cachedUserThemes = nil
        lock.unlock()
    }

    private func userThemes() -> [ThemeDefinition] {
        lock.lock()
        if let cached = cachedUserThemes {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let decoder = JSONDecoder()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: userDir, includingPropertiesForKeys: nil)) ?? []
        let themes = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ThemeDefinition? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ThemeDefinition.self, from: data)
            }
            .sorted { $0.id < $1.id }
        lock.lock()
        cachedUserThemes = themes
        lock.unlock()
        return themes
    }
}
