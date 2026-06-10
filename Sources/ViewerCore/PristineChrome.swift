import Foundation

/// TSK-618 — deterministic chrome for harness-spawned app instances.
///
/// T5 pixel tests spawn the real app and assert region geometry, but the
/// app reads persisted window chrome (terminal pane layout, tool-window
/// docks, prefs like zoom) from the SHARED user defaults — which prior
/// harness runs and in-suite spawns mutate. The image-editor T5 failure
/// was exactly this: a leaked open-terminal + zoom + narrow frame crowded
/// the window until the editor's flexible preview collapsed to ~0pt.
/// `MDV_SKIP_WORKSPACE_RESTORE` covers sessions/tabs, NOT chrome.
///
/// `MDV_PRISTINE_CHROME=1` routes all chrome-state defaults through a
/// process-scoped suite that is EMPTIED at first touch: reads find
/// nothing (factory-default chrome), and writes die with the suite
/// instead of polluting the next spawn or the owner's real preferences.
public enum PristineChrome {

    /// Suite name for pristine launches. Stable (not per-PID) so repeated
    /// test spawns reuse one small plist instead of littering
    /// ~/Library/Preferences — it is wiped on every pristine launch anyway.
    static let suiteName = "com.markdownviewer.pristine-chrome"

    /// Computed (not cached) so tests can flip the env via `setenv`.
    public static var isActive: Bool {
        ProcessInfo.processInfo.environment["MDV_PRISTINE_CHROME"] == "1"
    }

    /// The defaults store the app should hand to its chrome-state stores
    /// (`PreferencesStore`, and through it `TerminalPaneStore` /
    /// `PanelLayoutStore`). `.standard` normally; the emptied pristine
    /// suite under `MDV_PRISTINE_CHROME=1`.
    public static func launchDefaults() -> UserDefaults {
        guard isActive, let suite = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        // Empty at first touch: a pristine launch must never see the
        // previous pristine launch's writes either.
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }
}
