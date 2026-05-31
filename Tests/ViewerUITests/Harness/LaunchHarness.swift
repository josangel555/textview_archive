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
        FileManager.default.isExecutableFile(atPath: appExecutable.path)
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
        self.tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true)
    }

    /// SIGTERM any leftover MarkdownViewer process and remove the
    /// scratch directory. Idempotent.
    func cleanup() {
        _ = AppLauncher.currentPID(of: "MarkdownViewer").map { kill($0, SIGTERM) }
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
        scriptFileName: String = "script.txt"
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
            artifactDir: tmpDir
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
