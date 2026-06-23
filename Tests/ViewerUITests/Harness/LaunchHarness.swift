import XCTest
import Foundation

/// Centralises the L4/L5 live-app launch boilerplate that every
/// `runScript`-driven test class used to duplicate (project-root
/// computation, `dist/TextView.app` path, per-test tmpdir, signal-based
/// teardown of any stray `MarkdownViewer` process).
///
/// Tests can either:
///   1. Inherit from `MultiScenarioTestCase` (preferred — supplies a
///      shared harness and a `runScenarios(...)` entry point).
///   2. Instantiate `LaunchHarness` directly and call `runScript(...)`
///      from a vanilla `XCTestCase`.
///
/// Note on "warm app" semantics: the script-runner exits the .app at
/// end-of-script (see `AppLauncher.runScript`), so there is no
/// long-running XCUIApplication to keep alive. What this harness shares
/// across scenarios in one test method is the **fixture state**
/// (tmpdir, written files) and the launcher configuration — not a
/// persistent process. Workspace restore is disabled
/// (`MDV_SKIP_WORKSPACE_RESTORE=1` is set inside `AppLauncher`) so each
/// scenario sees the previous scenario's persisted state via
/// `PreferencesStore` only (zoom, sidebar width, ...), matching the
/// behaviour of the original per-method tests.
final class LaunchHarness {

    /// Per-instance scratch directory (`/var/folders/...`) for the
    /// caller to write fixture files into. Wiped by `cleanup()`.
    let tmpDir: URL

    /// Absolute path of the built `.app` bundle (`dist/TextView.app`).
    let appBundlePath: String

    /// Absolute URL of the bundled executable; used to early-skip a
    /// test when the build hasn't been produced yet.
    let appExecutable: URL

    /// `true` when `dist/TextView.app/Contents/MacOS/MarkdownViewer`
    /// is present and executable on disk. Tests should `XCTSkip` when
    /// this is `false` (the host-vs-VM rule means most developers run
    /// these only inside the VM).
    var isAppBuilt: Bool {
        Self.shouldRunLiveTiers(
            env: ProcessInfo.processInfo.environment,
            bundleExists: FileManager.default.isExecutableFile(atPath: appExecutable.path))
    }

    /// Pure decision (host-testable, no spawn): may a heavy tier
    /// (T4 LiveAppTestCase / T5 PixelTestCase / scenario / UAT) actually launch
    /// `dist/TextView.app`? It may ONLY when ALL hold:
    ///   - `MDV_HEADLESS_GATE != 1` — the gate is the headless lane by
    ///     definition; force-skip even on a dev host with a built bundle.
    ///   - `MDV_VM_GUI_SESSION == 1` — the EXPLICIT opt-in that `test-in-vm.sh`
    ///     sets (and forwards) for the VM's Aqua GUI lane. **TSK-817:** without
    ///     this, a bare `swift test` on a host that merely happened to have a
    ///     `dist/` bundle (e.g. just after an `/Applications` build) ran a T4
    ///     suite and SPAWNED a window on the owner's screen mid-work. Spawning
    ///     the app is now opt-in to the GUI lane, never an accident of a present
    ///     bundle. (The headless gate forces this false anyway via the first
    ///     check; this second guard closes the bare-`swift test` hole.)
    ///   - the bundle is actually present + executable.
    static func shouldRunLiveTiers(env: [String: String], bundleExists: Bool) -> Bool {
        if env["MDV_HEADLESS_GATE"] == "1" { return false }
        if env["MDV_VM_GUI_SESSION"] != "1" { return false }
        return bundleExists
    }

    init(label: String, file: StaticString = #filePath) {
        // Resolve the project root by walking UP from this source file
        // until we find a directory that actually contains the built
        // bundle (or `Package.swift`). The previous fixed "strip three
        // path components" assumed the caller's file sat exactly at
        // `Tests/ViewerUITests/<file>.swift`. That broke once the shared
        // harness moved one level deeper into `Harness/` and subclasses
        // (MultiScenarioTestCase) construct `LaunchHarness(label:)`
        // *without* forwarding their own `#filePath`: the default
        // `#filePath` then pointed at `Harness/MultiScenarioTestCase.swift`,
        // stripping to `<root>/Tests/` and looking for a `dist/` that
        // doesn't exist — so EVERY live/scenario/interaction test silently
        // XCTSkip'd with "Build .app first" even on a freshly built app.
        // Walking up is robust to the file's depth.
        let fileURL = URL(fileURLWithPath: String(describing: file))
        let relBundle = "dist/TextView.app/Contents/MacOS/MarkdownViewer"
        let fm = FileManager.default
        var dir = fileURL.deletingLastPathComponent()
        var project = dir
        var found = false
        // Bound the walk so a pathological path can't loop to "/".
        for _ in 0..<12 {
            if fm.fileExists(atPath: dir.appendingPathComponent(relBundle).path)
                || fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                project = dir
                found = true
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }  // reached filesystem root
            dir = parent
        }
        if !found {
            // Fall back to the historical strip-3 behaviour so a caller
            // that genuinely sits at Tests/ViewerUITests/<file>.swift
            // still resolves the same way it always did.
            project = fileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        self.appBundlePath = project.appendingPathComponent("dist/TextView.app").path
        self.appExecutable = project.appendingPathComponent(
            "dist/TextView.app/Contents/MacOS/MarkdownViewer")
        // Fixture base. Under the VM GUI lane xctest runs as ROOT (the sudo'd
        // `launchctl asuser` bridge) but the live app spawns as the console
        // user, and TWO constraints must BOTH hold for that app:
        //   (1) it must read+write the fixtures — root's per-user temp
        //       (`/var/folders/zz/.../T`) is 0700 AND SIP-restricted (even root
        //       can't `chmod` it), so it's untraversable by the console user →
        //       every spawned doc lands in `.error`; and
        //   (2) MCP-driven UAT (`open_path`) enforces a containment fence — the
        //       path must be under the APP's home or the app's own per-user temp
        //       (`MCPToolCatalog`). `/tmp` satisfies (1) but FAILS (2); root's
        //       temp fails both.
        // The only base that satisfies BOTH is a scratch dir under the SPAWN
        // user's OWN home: that user can read+write it, and it's under its home
        // so containment passes. `AppLauncher` chowns the run dir to the spawn
        // user at launch (`preShared`) so the root-written fixtures become the
        // app's to read+write. On a normal host (non-root) the per-user temp is
        // correct + symlink-safe (and these tiers self-skip off the VM anyway).
        let fixtureBase = (geteuid() == 0)
            ? AppLauncher.spawnUserHome.appendingPathComponent(".mdv-uat-fixtures")
            : FileManager.default.temporaryDirectory
        self.tmpDir = fixtureBase
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
    }

    /// SIGTERM any leftover TEST-spawned MarkdownViewer process and remove
    /// the scratch directory. Idempotent.
    ///
    /// MUST reap only test spawns (marked `MDV_TEST_INSTANCE=1` by
    /// `AppLauncher.runScript`), never the developer's prod
    /// `/Applications/TextView.app` — it shares the `MarkdownViewer` exec
    /// name, so the old `currentPID(of:) + kill` (a `pgrep -x`-by-name
    /// SIGTERM) terminated the owner's running app whenever this tear-down
    /// fired (heavy-tier tear-downs run even when the body self-skips in the
    /// headless gate). Route through the marker-scoped reaper. See
    /// `AppLauncher.killTestInstances`.
    func cleanup() {
        AppLauncher.killTestInstances(named: "MarkdownViewer")
        // UAT debugging seam: MDV_KEEP_FIXTURES=1 preserves this scenario's
        // per-step dumps + PNG screencaptures (under `tmpDir`) for post-run
        // inspection instead of removing them. Opt-in so normal/CI runs stay
        // clean. The path is echoed to stderr (lands in the persistent
        // mdv-launch-*.log) so a debugger knows where to look.
        if ProcessInfo.processInfo.environment["MDV_KEEP_FIXTURES"] == "1" {
            fputs("MDV_KEEP_FIXTURES: preserved UAT fixtures at \(tmpDir.path)\n", stderr)
            return
        }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Run one script against the bundled .app and return the per-step
    /// JSON dumps. Pass-through to `AppLauncher.runScript` with the
    /// harness's pre-resolved paths.
    @discardableResult
    func runScript(
        _ script: String,
        with fileArg: URL,
        timeout: TimeInterval = 30,
        scriptFileName: String = "script.txt",
        viaOpen: Bool = false
    ) throws -> [[String: Any]] {
        try AppLauncher.runScript(
            appBundlePath: appBundlePath,
            scriptContents: script,
            scriptPath: tmpDir.appendingPathComponent(scriptFileName).path,
            fileArg: fileArg,
            timeout: timeout,
            // #193: the harness's per-instance scratch dir doubles as the
            // run-scoped artifact dir so parallel scenarios don't collide
            // on `mdv-step-NN.json`.
            artifactDir: tmpDir,
            viaOpen: viaOpen,
            // The harness fixtures already live in a world-traversable dir (see
            // init), so AppLauncher hands the tree to the spawn user and runs
            // the app against the REAL paths instead of throwaway copies.
            preShared: true
        )
    }

    // MARK: - Fixture helpers (shared by both inheritance styles)

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
