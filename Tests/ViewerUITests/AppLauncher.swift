import Foundation

/// Shared helpers for spawning the MarkdownViewer .app from L4/L5 tests.
///
/// **Why this exists**: macOS 14+ blocks
/// `NSApp.activate(ignoringOtherApps:)` from a process launched directly
/// via `Process.executableURL = .../MacOS/MarkdownViewer`. The launching
/// shell stays foregrounded, the spawned app's window is occluded, and
/// AppKit suspends drawing for occluded windows. JSON dumps work
/// regardless (they describe the view tree, not pixels), but PNG
/// snapshots come back blank. To get truthful snapshots — useful for
/// human visual review during dev — we need to launch via
/// LaunchServices (`/usr/bin/open -a`), which IS permitted to bring the
/// app to the front.
///
/// All L4/L5 tests funnel through `AppLauncher.runScript` so they share
/// the same focus-correct behavior.
enum AppLauncher {

    /// Run the app with the given script + file argument. Spawns the
    /// app directly (passing args reliably), best-effort attempts to
    /// foreground the window via AppleScript, then polls for the app's
    /// exit and returns the collected step JSON dumps.
    ///
    /// **Known limitation**: macOS 14+ aggressively blocks programmatic
    /// foregrounding when the calling process isn't itself frontmost.
    /// `tell application X to activate` is rate-limited (and the
    /// modern `NSApp.activate()` API explicitly respects this). When the
    /// test runner's terminal stays foregrounded, the spawned
    /// MarkdownViewer window remains occluded — its WindowServer
    /// backing store stays empty. JSON diagnostic dumps (which describe
    /// the view tree, not pixels) are unaffected and tests pass; PNG
    /// snapshots come back blank.
    ///
    /// To get real PNG snapshots in a test harness: run from a fresh
    /// macOS GUI session (UTM VM, fresh login) where MarkdownViewer
    /// IS the foreground app, OR grant Accessibility permission to
    /// xctest and add a `System Events → click on coordinate inside
    /// the window` step to the script. Neither is needed for test
    /// correctness — only for human visual review.
    ///
    /// Why not `/usr/bin/open --args`? LaunchServices silently drops
    /// args that start with `--` in some macOS versions, so
    /// `--script PATH` never reaches the app. Direct exec preserves
    /// argv exactly.
    static func runScript(
        appBundlePath: String,
        scriptContents: String,
        scriptPath: String,
        fileArg: URL,
        timeout: TimeInterval = 30,
        existingProcessName: String = "MarkdownViewer",
        artifactDir: URL? = nil
    ) throws -> [[String: Any]] {
        // #193: run-scoped artifact dir. When the caller threads a unique
        // per-test directory we point the spawned app at it via
        // `MDV_ARTIFACT_DIR` so parallel live-app tests don't overwrite
        // each other's `mdv-step-NN.json`. When nil we fall back to the
        // shared per-user tmpdir — matching the app's own fallback — so a
        // direct `AppLauncher.runScript(...)` caller keeps working.
        let artifacts = artifactDir ?? tmpDir
        try? FileManager.default.createDirectory(
            at: artifacts, withIntermediateDirectories: true)
        for n in 1...99 {
            let s = String(format: "%02d", n)
            try? FileManager.default.removeItem(
                at: artifacts.appendingPathComponent("mdv-step-\(s).json"))
            try? FileManager.default.removeItem(
                at: artifacts.appendingPathComponent("mdv-step-\(s).png"))
        }
        try scriptContents.write(
            to: URL(fileURLWithPath: scriptPath),
            atomically: true, encoding: .utf8
        )
        // Kill any prior instance.
        _ = runShell(["/usr/bin/killall", existingProcessName], wait: 0.5)
        Thread.sleep(forTimeInterval: 0.3)

        // Direct spawn — argv is preserved exactly.
        let exePath = appBundlePath + "/Contents/MacOS/" + existingProcessName
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exePath)
        p.arguments = ["--script", scriptPath, fileArg.path]
        // MDV_BACKGROUND=1 tells main.swift to run in accessory mode:
        // window appears but doesn't take key focus, and we skip the
        // osascript activate below. Without this, every test run
        // grabs whatever the user is typing into.
        var env = ProcessInfo.processInfo.environment
        env["MDV_BACKGROUND"] = "1"
        env["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        // #193: tell the app to write its per-step dumps + `.windowid`
        // into this run's private directory rather than the shared
        // per-user tmpdir.
        env["MDV_ARTIFACT_DIR"] = artifacts.path
        p.environment = env
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError  = FileHandle(forWritingAtPath: "/dev/null")
        try p.run()
        // Give the window a beat to appear. We don't activate via
        // osascript anymore — see env var above. Tradeoff: PNG
        // snapshots will be blank because AppKit suspends drawing for
        // occluded windows. JSON dumps (view-tree introspection) are
        // unaffected and that's what every L3+ test consumes.
        Thread.sleep(forTimeInterval: 0.6)

        // Poll for exit.
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        }

        return collectStepDumps(from: artifacts)
    }

    /// Returns the PID of a running process with the given name, or nil.
    /// Uses `/usr/bin/pgrep` — no AppKit / NSWorkspace dependency.
    static func currentPID(of name: String) -> pid_t? {
        let result = runShell(["/usr/bin/pgrep", "-x", name], capture: true)
        guard let stdout = result.stdout?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(stdout)
        else { return nil }
        return pid
    }

    /// Per-user tmpdir (`/var/folders/.../T/`). The app writes its step
    /// dumps and snapshots here. Matches `FileManager.default.temporaryDirectory`
    /// inside the app and is safe from symlink hijack (unlike `/tmp/`).
    static var tmpDir: URL { FileManager.default.temporaryDirectory }

    /// Collect all `<dir>/mdv-step-NN.json` files into memory. Defaults
    /// to the shared per-user tmpdir; #193 callers pass the run-scoped
    /// artifact dir so concurrent runs read their own dumps.
    static func collectStepDumps(from dir: URL? = nil) -> [[String: Any]] {
        let base = dir ?? tmpDir
        var dumps: [[String: Any]] = []
        for n in 1...99 {
            let s = String(format: "%02d", n)
            let url = base.appendingPathComponent("mdv-step-\(s).json")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { break }
            dumps.append(obj)
        }
        return dumps
    }

    // MARK: - private

    private struct ShellResult {
        let exit: Int32
        let stdout: String?
    }

    private static func runShell(
        _ argv: [String],
        capture: Bool = false,
        wait: TimeInterval = 5
    ) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let outPipe = capture ? Pipe() : nil
        p.standardOutput = outPipe ?? FileHandle(forWritingAtPath: "/dev/null")
        p.standardError  = FileHandle(forWritingAtPath: "/dev/null")
        do { try p.run() } catch { return ShellResult(exit: -1, stdout: nil) }
        let deadline = Date().addingTimeInterval(wait)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning { p.terminate(); p.waitUntilExit() }
        var out: String? = nil
        if let pipe = outPipe {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            out = String(data: data, encoding: .utf8)
        }
        return ShellResult(exit: p.terminationStatus, stdout: out)
    }
}
