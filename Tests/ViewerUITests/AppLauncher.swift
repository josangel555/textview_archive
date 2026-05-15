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
        existingProcessName: String = "MarkdownViewer"
    ) throws -> [[String: Any]] {
        for n in 1...99 {
            let s = String(format: "%02d", n)
            try? FileManager.default.removeItem(
                at: tmpDir.appendingPathComponent("mdv-step-\(s).json"))
            try? FileManager.default.removeItem(
                at: tmpDir.appendingPathComponent("mdv-step-\(s).png"))
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
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError  = FileHandle(forWritingAtPath: "/dev/null")
        try p.run()

        // Give the window a beat to appear, then activate via AppleScript.
        // osascript `tell application X to activate` IS a user-equivalent
        // gesture as far as macOS is concerned, so it's allowed to
        // foreground the app even from a background launcher.
        Thread.sleep(forTimeInterval: 0.6)
        _ = runShell([
            "/usr/bin/osascript", "-e",
            "tell application \"\(existingProcessName)\" to activate",
        ], wait: 2)

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

        return collectStepDumps()
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

    /// Collect all `<tmp>/mdv-step-NN.json` files into memory.
    static func collectStepDumps() -> [[String: Any]] {
        var dumps: [[String: Any]] = []
        for n in 1...99 {
            let s = String(format: "%02d", n)
            let url = tmpDir.appendingPathComponent("mdv-step-\(s).json")
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
