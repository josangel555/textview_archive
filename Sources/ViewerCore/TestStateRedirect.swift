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
