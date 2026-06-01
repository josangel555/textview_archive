import Foundation
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// In-process counterpart to `LaunchHarness` — the §3.1 keystone made
/// concrete on the test side.
///
/// `LaunchHarness` spawns `dist/TextView.app`, runs a `--script`, and
/// reads the per-step JSON dumps back off disk (`/var/folders/.../mdv-
/// step-NN.json`). That round-trip is pure ceremony: it exists only
/// because the verb producer (the spawned app) and the assertion
/// consumer (the test) were different processes. `HeadlessHarness`
/// collapses both into the same process:
///
///   - constructs a HERMETIC `DocumentModel` + `SessionsAppCoordinator`
///     (throwaway stores under a per-instance tmpdir, a throwaway
///     `UserDefaults` suite — nothing touches the real
///     `~/Library/Application Support` or `.standard` defaults);
///   - applies each script line via the SAME free function the VM path
///     uses (`ScriptVerb.apply(verb:to:sessions:)`);
///   - after each line, captures the SAME `model` dump dict the VM path
///     embeds (`ScriptVerb.modelStateDump(...)`), so the EXISTING Page
///     Objects (`Pages(dump:)`) consume it unchanged.
///
/// No `NSApplication`, no window, no process spawn, no JSON file. Runs
/// host-headless in microseconds and is permission-free.
///
/// ## What it does NOT produce
///
/// The headless dump carries only the `model` sub-dictionary (and the
/// `step` / `label` markers). It has no realized `window` / `contentView`
/// view tree — those require an `NSHostingView` layout pass (T2') or a
/// real window (T4/T5). Page-Object accessors that walk the view tree
/// (`nodes(ofClass:)`, `subtree(withIdentifier:)`, `windowTitle`,
/// `totalNodeCount`) therefore return empty / nil here, by design: a
/// suite that needs them is asserting on an observable a headless model
/// can't faithfully produce and belongs at a higher tier. Every
/// `model.*` accessor — which is what the migrated T1m suites read —
/// works identically to the spawned-app dump.
@MainActor
final class HeadlessHarness {

    /// Per-instance scratch directory (`/var/folders/...`). Houses the
    /// throwaway history / bookmarks / session stores so a run never
    /// reads or writes real on-disk state. Wiped by `cleanup()`.
    let tmpDir: URL

    /// The hermetic model the verbs are applied to. Exposed so a test
    /// that wants to assert on a property not yet in the dump projection
    /// can reach it directly (the same `model.*` the dump reads).
    let model: DocumentModel

    /// The hermetic sessions coordinator. `bootstrap()` has already run
    /// against an empty store with no `initialRoot`, so the strip starts
    /// empty — matching the launcher's `MDV_SKIP_WORKSPACE_RESTORE=1`
    /// "coordinator starts empty" semantics.
    let sessions: SessionsAppCoordinator

    private let suiteName: String
    private let defaults: UserDefaults

    init(label: String) {
        let id = UUID().uuidString
        self.tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(id)")
        try? FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true)

        // Throwaway defaults suite — never `.standard`.
        self.suiteName = "HeadlessHarness-\(id)"
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard

        // Hermetic stores: every persistence URL points inside tmpDir so
        // a run can't read or clobber real user state.
        let model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            goToPathHistory: GoToPathHistoryStore(
                storeURL: tmpDir.appendingPathComponent("goto.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        self.model = model

        // Empty session store under tmpDir + nil initialRoot ⇒ bootstrap
        // wires the lifecycle bridge (so `session-open-folder` verbs can
        // mount a SessionState) but restores nothing — the empty-strip
        // start the live launcher gets with MDV_SKIP_WORKSPACE_RESTORE=1.
        let store = SessionStore(directory: tmpDir.appendingPathComponent("Sessions"))
        let sessions = SessionsAppCoordinator(
            model: model,
            store: store,
            initialRoot: nil,
            // Tighten the autosave debounce so a stray timer can't fire
            // a write into tmpDir after cleanup; tests don't assert on it.
            autosaveDebounce: 0
        )
        sessions.bootstrap()
        self.sessions = sessions
    }

    /// Remove the scratch directory + throwaway defaults domain.
    /// Idempotent.
    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Script execution

    /// Run a `--script` body in-process and return one dump dict per
    /// script line — the same `[[String: Any]]` shape `LaunchHarness.
    /// runScript` returns, so the existing `Pages(dump:)` Page Objects
    /// and `Scenario.assert` closures consume it unchanged.
    ///
    /// `fileArg` mirrors the live app's "open this file on launch" argv:
    /// it is opened before the first script line runs, so a script that
    /// assumes a loaded document behaves as it does under the VM.
    ///
    /// Line parsing matches `AppDelegate.runScript`: `#` comments and
    /// blank lines are dropped; every remaining line produces one dump
    /// (the VM captures artifacts after each step), so `dumps.count`
    /// assertions carry over unchanged.
    @discardableResult
    func runScript(_ script: String, with fileArg: URL? = nil) -> [[String: Any]] {
        if let fileArg {
            model.openPath(fileArg)
        }
        let lines = script.split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var dumps: [[String: Any]] = []
        for (step, line) in lines.enumerated() {
            ScriptVerb.apply(verb: line, to: model, sessions: sessions)
            var dump: [String: Any] = [:]
            dump["model"] = ScriptVerb.modelStateDump(model: model, sessions: sessions)
            dump["step"] = step + 1
            dump["label"] = line
            dumps.append(dump)
        }
        return dumps
    }

    /// Capture a single dump of the current model state without running a
    /// verb — for tests that mutate `model` directly and want the dump
    /// projection.
    func snapshot() -> [String: Any] {
        ["model": ScriptVerb.modelStateDump(model: model, sessions: sessions)]
    }

    // MARK: - Fixture helpers (mirror LaunchHarness)

    /// Write a UTF-8 file under `tmpDir` and return its URL.
    @discardableResult
    func writeFile(_ relativePath: String, _ body: String = "# x\n") throws -> URL {
        let url = tmpDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Create a subdirectory under `tmpDir` and return its URL.
    @discardableResult
    func makeDir(_ relativePath: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
