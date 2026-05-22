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
        let project = URL(fileURLWithPath: String(describing: file))
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
            timeout: timeout
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
