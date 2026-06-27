import Foundation

/// Test-hermeticity guard (TSK-1288). Under XCTest — `XCTestConfigurationFilePath`
/// is set by the test runner and NEVER by the shipping app — on-disk-state default
/// directory helpers redirect to a per-process temp dir, so HOST tests never read or
/// write the developer's REAL `~/Library/Application Support/MarkdownViewer` state.
///
/// Why: tests that construct a store with its default dir (e.g. a bare
/// `DocumentModel()` whose `localHistory`/`history` default to the real dirs) were
/// polluting the dev's real state — test paths ended up in the real `history.json`
/// and the real LocalHistory dir had bloated to ~132 MB. CLAUDE.md forbids writing
/// real user state from automated paths. Production never sets the env var, so the
/// app uses its real app-support dir unchanged.
///
/// Per-PROCESS (keyed by pid) rather than a single shared dir, so the parallel test
/// runner's many xctest processes don't race on one path; the careful tests that
/// already inject a per-test tmp dir are unaffected.
public enum TestStateRedirect {
    /// The per-process temp base when running under XCTest, else `nil` (production).
    /// Callers append their store's subpath (e.g. `MarkdownViewer/LocalHistory`).
    public static func appSupportBase() -> URL? {
        guard isUnderXCTest else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDVTestState-\(pid)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The `MarkdownViewer` app-support dir — the per-process tmp under XCTest (so
    /// HOST tests never touch the dev's real state), else the real
    /// `~/Library/Application Support/MarkdownViewer`. Stores append their own
    /// file/subdir (TSK-1288 slice 2 — the shared seam the per-store default-dir
    /// helpers route through).
    public static func markdownViewerDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        appSupportSubdir("MarkdownViewer", environment: environment)
    }

    /// The bundle-id app-support dir (`com.markdownviewer.MarkdownViewer`) — holds
    /// `Plugins/`, `PluginGrants/`, `Walkthroughs/`, `jdtls-data/`. Same redirect
    /// precedence as `markdownViewerDir`; the sibling subdir under the same root.
    public static func bundleIDDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        appSupportSubdir("com.markdownviewer.MarkdownViewer", environment: environment)
    }

    /// The app-support ROOT, honoring the redirect precedence: explicit
    /// MDV_APP_SUPPORT override (session tests / sandbox — the pre-existing mechanism
    /// AppCacheReset/SessionStore honor) > XCTest auto-redirect (hermetic tmp) > the
    /// real `~/Library/Application Support` (production).
    /// The app-support ROOT, honoring the redirect precedence: explicit
    /// MDV_APP_SUPPORT override > XCTest auto-redirect (hermetic tmp) > the real
    /// `~/Library/Application Support`. Public so callers that manage their OWN
    /// subtree (AppCacheReset's reset domains, SessionStore's MDV_SESSIONS_DIR
    /// special-case) route through one resolver and auto-redirect under XCTest too.
    public static func appSupportRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["MDV_APP_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return appSupportBase()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private static func appSupportSubdir(_ name: String, environment: [String: String]) -> URL {
        let dir = appSupportRoot(environment: environment).appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// True iff running inside a test bundle. `XCTestConfigurationFilePath` is set
    /// only by the Xcode runner (NOT by SwiftPM `swift test`), so the reliable
    /// signal is XCTest LINKAGE: the class resolves in any test bundle (which links
    /// XCTest, even for Swift Testing suites) and never in the shipping app.
    private static var isUnderXCTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil
            || env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
    }
}
