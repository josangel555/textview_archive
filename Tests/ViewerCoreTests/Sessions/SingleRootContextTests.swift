import Combine
import XCTest
@testable import ViewerCore
import ViewerKit

/// Foundation-slice tests for the Sessions-optional epic (TSK-264).
///
/// Cover the no-session core abstraction:
///   - `SingleRootContext` returns exactly one root; `openFolder` rebinds
///     it in place; same-folder re-open is a no-op (no spurious change).
///   - It NEVER writes to a `Sessions/` directory (the whole point of the
///     no-session path) — asserted against a temp Application-Support root.
///   - The `sessionsEnabled` flag round-trips through `PreferencesStore`.
///   - `RootContextFactory` selects the right concrete provider type for
///     each flag value.
///   - `SingleRootContext.exposesSessionUI == false`,
///     `SessionRootContext.exposesSessionUI == true` (drives strip hide/show).
@MainActor
final class SingleRootContextTests: XCTestCase {

    private lazy var tmp: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-singleroot-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }()

    private var cancellables: Set<AnyCancellable> = []

    // MARK: single-root semantics ------------------------------------

    func testInitWithRootBindsExactlyOneRoot() throws {
        let folder = try makeTmpFolder(name: "alpha")
        let ctx = SingleRootContext(initialRoot: folder)
        XCTAssertEqual(ctx.currentRoot?.path, folder.path)
    }

    func testInitWithoutRootIsNil() {
        let ctx = SingleRootContext()
        XCTAssertNil(ctx.currentRoot)
    }

    func testOpenFolderRebindsTheSingleRoot() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        let ctx = SingleRootContext(initialRoot: a)
        XCTAssertEqual(ctx.currentRoot?.path, a.path)
        ctx.openFolder(b)
        // Rebound IN PLACE — still exactly one root, now b. No list grows.
        XCTAssertEqual(ctx.currentRoot?.path, b.path)
    }

    func testOpenSameFolderIsNoOp() throws {
        let a = try makeTmpFolder(name: "alpha")
        let ctx = SingleRootContext(initialRoot: a)
        var changeCount = 0
        ctx.rootDidChange
            .dropFirst()  // the initial @Published replay
            .sink { _ in changeCount += 1 }
            .store(in: &cancellables)
        ctx.openFolder(a)  // same normalized path
        XCTAssertEqual(changeCount, 0, "re-opening the same root must not churn")
        XCTAssertEqual(ctx.currentRoot?.path, a.path)
    }

    func testOpenFolderNormalizesTrailingSlash() throws {
        let a = try makeTmpFolder(name: "alpha")
        let withSlash = URL(fileURLWithPath: a.path + "/", isDirectory: true)
        let ctx = SingleRootContext()
        ctx.openFolder(withSlash)
        XCTAssertEqual(ctx.currentRoot?.path, a.path)
    }

    func testOnRootChangeFiresOnInitAndRebind() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        var observed: [String?] = []
        let ctx = SingleRootContext(initialRoot: a) { url in
            observed.append(url?.path)
        }
        ctx.openFolder(b)
        XCTAssertEqual(observed, [a.path, b.path])
    }

    func testExposesSessionUIIsFalse() {
        XCTAssertFalse(SingleRootContext().exposesSessionUI)
    }

    // MARK: no Sessions/ writes --------------------------------------

    /// The defining no-session property: with sessions OFF, the app must
    /// not accrue ANY `Sessions/` filesystem state. We point a real
    /// `SessionStore.defaultDirectory()` at a temp Application-Support root
    /// (via `MDV_APP_SUPPORT`), drive `SingleRootContext` through a full
    /// open cycle, and assert no `Sessions/` index / snapshot files exist.
    func testSingleRootContextWritesNoSessionsFiles() throws {
        let appSupport = tmp.appendingPathComponent("AppSupport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")

        try withEnv(["MDV_APP_SUPPORT": appSupport.path]) {
            // Drive a SingleRootContext (no SessionStore involved) hard.
            let ctx = SingleRootContext(initialRoot: a)
            ctx.openFolder(b)
            ctx.openFolder(a)
        }

        // The Sessions/ dir under our temp App-Support root must contain no
        // index.json and no <uuid>.json snapshots. (Either the dir doesn't
        // exist at all, or it's empty.)
        let sessionsDir = appSupport.appendingPathComponent("MarkdownViewer/Sessions")
        let index = sessionsDir.appendingPathComponent("index.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: index.path),
            "SingleRootContext must not write a session index"
        )
        let snapshots = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        )) ?? []
        let jsonFiles = snapshots.filter { $0.pathExtension == "json" }
        XCTAssertTrue(
            jsonFiles.isEmpty,
            "SingleRootContext must write no session snapshot files; found \(jsonFiles)"
        )
    }

    // MARK: flag round-trip ------------------------------------------

    func testSessionsEnabledDefaultsTrue() {
        let prefs = PreferencesStore(defaults: ephemeralDefaults())
        XCTAssertTrue(prefs.sessionsEnabled, "default must preserve today's behavior")
    }

    func testSessionsEnabledRoundTrips() {
        let prefs = PreferencesStore(defaults: ephemeralDefaults())
        prefs.sessionsEnabled = false
        XCTAssertFalse(prefs.sessionsEnabled)
        prefs.sessionsEnabled = true
        XCTAssertTrue(prefs.sessionsEnabled)
    }

    // MARK: factory selection ----------------------------------------

    func testFactoryBuildsSessionProviderWhenEnabled() throws {
        let prefs = PreferencesStore(defaults: ephemeralDefaults())
        prefs.sessionsEnabled = true
        let coord = SessionsCoordinator(store: SessionStore(directory: tmp))
        let provider = RootContextFactory.make(
            preferences: prefs, sessionCoordinator: coord
        )
        XCTAssertTrue(provider is SessionRootContext)
        XCTAssertTrue(provider.exposesSessionUI)
    }

    func testFactoryBuildsSingleRootProviderWhenDisabled() throws {
        let folder = try makeTmpFolder(name: "alpha")
        let prefs = PreferencesStore(defaults: ephemeralDefaults())
        prefs.sessionsEnabled = false
        prefs.lastFolderURL = folder
        let coord = SessionsCoordinator(store: SessionStore(directory: tmp))
        let provider = RootContextFactory.make(
            preferences: prefs, sessionCoordinator: coord
        )
        XCTAssertTrue(provider is SingleRootContext)
        XCTAssertFalse(provider.exposesSessionUI)
        // Seeded from lastFolderURL.
        XCTAssertEqual(provider.currentRoot?.path, folder.path)
    }

    func testFactoryDisabledPathPersistsRootBackToPreferences() throws {
        let a = try makeTmpFolder(name: "alpha")
        let b = try makeTmpFolder(name: "beta")
        let prefs = PreferencesStore(defaults: ephemeralDefaults())
        prefs.sessionsEnabled = false
        prefs.lastFolderURL = a
        let provider = RootContextFactory.make(
            preferences: prefs, sessionCoordinator: nil
        )
        provider.openFolder(b)
        // The single-root provider persists its root back to the same pref.
        XCTAssertEqual(prefs.lastFolderURL?.path, b.path)
    }

    func testFactoryFallsBackToSingleRootWhenCoordinatorMissing() {
        let prefs = PreferencesStore(defaults: ephemeralDefaults())
        prefs.sessionsEnabled = true   // wants sessions…
        let provider = RootContextFactory.make(
            preferences: prefs, sessionCoordinator: nil   // …but none supplied
        )
        // Graceful fallback rather than a crash.
        XCTAssertTrue(provider is SingleRootContext)
    }

    // MARK: session-backed adapter -----------------------------------

    func testSessionRootContextReflectsActiveSessionRoot() throws {
        let a = try makeTmpFolder(name: "alpha")
        let coord = SessionsCoordinator(store: SessionStore(directory: tmp))
        let ctx = SessionRootContext(coordinator: coord)
        XCTAssertNil(ctx.currentRoot, "no active session yet")
        ctx.openFolder(a)
        XCTAssertEqual(ctx.currentRoot?.path, a.path)
        XCTAssertTrue(ctx.exposesSessionUI)
    }

    // MARK: helpers --------------------------------------------------

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "mdv-singleroot-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeTmpFolder(name: String = UUID().uuidString) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        // Resolve symlinks so the expected path matches the context's
        // normalized path on macOS (/var → /private/var, etc.).
        return url.resolvingSymlinksInPath()
    }

    /// Run `body` with the given environment variables set, restoring the
    /// prior values afterward. `SessionStore.defaultDirectory()` reads
    /// `MDV_APP_SUPPORT` from the process environment, so we set it for the
    /// duration of the no-writes assertion.
    private func withEnv(_ vars: [String: String], _ body: () throws -> Void) rethrows {
        let prior = vars.keys.reduce(into: [String: String?]()) { acc, key in
            acc[key] = ProcessInfo.processInfo.environment[key]
        }
        for (k, v) in vars { setenv(k, v, 1) }
        defer {
            for (k, old) in prior {
                if let old { setenv(k, old, 1) } else { unsetenv(k) }
            }
        }
        try body()
    }
}
