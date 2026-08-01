import CoreGraphics
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

    /// Park the pointer in the screen's bottom-left corner before a pixel
    /// capture. Wherever the previous test (or the GUI session) left the
    /// cursor, a hover tooltip can pop over the chrome and photobomb the
    /// shot — live flake 2026-08-01: the ⌘ toolbar button's helpInfo bubble
    /// covered the tab strip's right side and hid 3 of 14 separators. Call
    /// after activation, before the settle sleep, in every capture rig.
    static func parkPointerAwayFromChrome() {
        let h = CGDisplayPixelsHigh(CGMainDisplayID())
        CGWarpMouseCursorPosition(CGPoint(x: 2, y: CGFloat(h) - 2))
    }

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
        artifactDir: URL? = nil,
        viaOpen: Bool = false,
        preShared: Bool = false
    ) throws -> [[String: Any]] {
        // #193: run-scoped artifact dir. When the caller threads a unique
        // per-test directory we point the spawned app at it via
        // `MDV_ARTIFACT_DIR` so parallel live-app tests don't overwrite
        // each other's `mdv-step-NN.json`. When nil we fall back to the
        // shared per-user tmpdir — matching the app's own fallback — so a
        // direct `AppLauncher.runScript(...)` caller keeps working.
        var artifacts = artifactDir ?? tmpDir
        var scriptURL = URL(fileURLWithPath: scriptPath)
        var argURL = fileArg

        // TSK-620 constraint 6: on the VM GUI lane xctest runs as ROOT
        // (the sudo'd `launchctl asuser` bridge), and WindowServer never
        // grants activation/key status to a root-spawned app in the user's
        // Aqua session — so synthesized clicks on SwiftUI controls are
        // swallowed (gesture recognizers run off `sendEvent`, which
        // suppresses mouseDown on a non-key window). Spawning the app AS
        // the console user (same bootstrap namespace, correct uid) makes
        // it a first-class session citizen that CAN become key. Root's
        // per-user tmpdir is 700, unreadable by the target user, so the
        // run's script/arg/artifacts move to a world-accessible /tmp dir.
        let spawnUser: String? = geteuid() == 0 ? consoleUser : nil
        // TSK-953: when the caller (LaunchHarness) has ALREADY rooted its
        // fixtures under the spawn user's home (readable by that user AND inside
        // the MCP containment fence), run the app against the REAL paths IN
        // PLACE rather than copying to a throwaway /tmp dir. Only
        // the copy path breaks editor-save round-trips (the app saves to a copy
        // the test never reads back) and multi-launch path-keyed state — e.g. a
        // bookmark set in launch 1 keys off `/tmp/mdv-uat-AAA/f`, but launch 2
        // copies to `/tmp/mdv-uat-BBB/f`, a different path, so it reads as
        // un-bookmarked. In place, both launches use the same stable path.
        // Direct callers (preShared=false) keep the copy hand-off below.
        let inPlace = preShared && spawnUser != nil
        if (spawnUser != nil || viaOpen) && !inPlace {
            let shared = URL(fileURLWithPath: "/tmp/mdv-uat-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: shared, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o777])
            artifacts = shared
            scriptURL = shared.appendingPathComponent("script.txt")
            argURL = shared.appendingPathComponent(fileArg.lastPathComponent)
            try? FileManager.default.copyItem(at: fileArg, to: argURL)
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: argURL.path, isDirectory: &isDir)
            try? FileManager.default.setAttributes(
                [.posixPermissions: isDir.boolValue ? 0o755 : 0o644],
                ofItemAtPath: argURL.path)
            // Root-owned files are unreadable-enough for git: a copied
            // .git repo trips `fatal: detected dubious ownership` when the
            // console-user app shells git against it. Hand the whole run
            // dir to the spawn user (we are root here; direct chown).
            if let user = spawnUser {
                chownRecursive(shared.path, to: user)
            }
        }
        try? FileManager.default.createDirectory(
            at: artifacts, withIntermediateDirectories: true)
        for n in 1...99 {
            let s = String(format: "%02d", n)
            try? FileManager.default.removeItem(
                at: artifacts.appendingPathComponent("mdv-step-\(s).json"))
            try? FileManager.default.removeItem(
                at: artifacts.appendingPathComponent("mdv-step-\(s).png"))
        }
        try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: scriptURL.path)
        // TSK-953: in-place cross-user hand-off — give the whole run dir
        // (script + arg + every fixture + the artifact slots the app writes its
        // step dumps/saves into) to the spawn user so the console-user app can
        // read AND write them where the test reads back. Re-applied per launch:
        // each scenario's fixtures are (re)written by the root test process, so
        // they revert to root-owned between launches.
        if inPlace, let user = spawnUser {
            chownRecursive(artifacts.path, to: user)
        }
        // Reap any leaked PRIOR TEST instance — never the developer's
        // normally-launched app (it shares this exec name; a blanket
        // `killall` used to kill it, making the gate/live-smoke destructive).
        killTestInstances(named: existingProcessName)
        Thread.sleep(forTimeInterval: 0.3)

        let exePath = appBundlePath + "/Contents/MacOS/" + existingProcessName
        // MDV_BACKGROUND=1 tells main.swift to run in accessory mode:
        // window appears but doesn't take key focus, and we skip the
        // osascript activate below. Without this, every test run
        // grabs whatever the user is typing into. (The `ui-click` verb
        // escalates to key status itself when a script needs real input.)
        // MDV_TEST_INSTANCE=1 marks this as a TEST-spawned instance so
        // `killTestInstances` can reap leaked runs WITHOUT touching the
        // developer's normally-launched app. MDV_ARTIFACT_DIR (#193)
        // points per-step dumps at this run's private directory.
        let mdvEnv = [
            "MDV_BACKGROUND=1",
            "MDV_SKIP_WORKSPACE_RESTORE=1",
            "MDV_TEST_INSTANCE=1",
            "MDV_ARTIFACT_DIR=\(artifacts.path)",
            // BUG-027: redirect the SessionStore to per-run scratch so scripted
            // session verbs (persist() fires under skip-restore) never append
            // pills to the user's real ~/Library/Application Support store.
            "MDV_SESSIONS_DIR=\(artifacts.appendingPathComponent("SessionsScratch").path)",
        ]
        let p = Process()
        if viaOpen {
            // LaunchServices launch — the ONLY way the app can genuinely
            // self-activate on macOS 14+ (fork/exec'd processes are denied
            // cooperative activation), and real activation → real key
            // window is what synthesized SwiftUI clicks require (probed:
            // sendEvent's non-key suppression cannot be faked away, and
            // SwiftUI's gesture system ignores direct responder dispatch).
            // LS drops `--`-prefixed argv, so the script + file ride in
            // env vars (`open --env`, read back in main.swift). NO
            // MDV_BACKGROUND here — activation is the point; this mode is
            // for the VM GUI lane where focus-stealing doesn't matter.
            // `-W` makes `open` wait for the app's exit, so the existing
            // poll loop tracks the run; `-n` forces a fresh instance.
            let openEnv = [
                "MDV_SKIP_WORKSPACE_RESTORE=1",
                "MDV_TEST_INSTANCE=1",
                "MDV_ARTIFACT_DIR=\(artifacts.path)",
                "MDV_SCRIPT_PATH=\(scriptURL.path)",
                "MDV_OPEN_FILE=\(argURL.path)",
                // BUG-027: per-run scratch session store (see mdvEnv above).
                "MDV_SESSIONS_DIR=\(artifacts.appendingPathComponent("SessionsScratch").path)",
            ]
            // TSK-1243: `open --env` does NOT deliver env to the LS-launched app
            // under `sudo -u <consoleUser>` (the VM GUI lane), so the app dropped
            // MDV_SCRIPT_PATH / MDV_ARTIFACT_DIR / MDV_SKIP_WORKSPACE_RESTORE and
            // ran workspace-restore instead of the script. ALSO persist the same
            // knobs to the deterministic config file the app reads early
            // (AppDelegate.applyLaunchConfigFileIfPresent), chowned to the spawn
            // user so the console-user app can read+delete it. This is the
            // delivery that actually works under sudo; the `--env` below stays for
            // the (rare) non-sudo viaOpen path.
            if let user = spawnUser {
                // FIXED ABSOLUTE path (not HOME-relative): the LS-launched app
                // doesn't inherit `open`'s HOME, so NSHomeDirectory() is
                // unpredictable — write where the app can deterministically find
                // it. /tmp is world-visible; chown so the console-user app can
                // read AND delete it (the one-shot delete is the read breadcrumb).
                let cfg = URL(fileURLWithPath: "/tmp/mdv-launch-config.env")
                try? openEnv.joined(separator: "\n").write(
                    to: cfg, atomically: true, encoding: .utf8)
                AppLauncher.chownRecursive(cfg.path, to: user)
            }
            var argv = ["/usr/bin/open", "-n", "-W"]
            for pair in openEnv { argv += ["--env", pair] }
            argv += ["-a", appBundlePath]
            if let user = spawnUser {
                // -H: set HOME to the TARGET user's home. Without it sudo keeps the
                // caller's HOME (=/var/root under the launchctl-asuser ROOT xctest),
                // so the LS-launched app got NSHomeDirectory()=/var/root and wrote
                // prefs/artifacts into root's home — invisible to the harness
                // (TSK-1243; proven by mdv-*.plist in /var/root/Library/Preferences).
                // NB: this fixes the HOME half only; env delivery via `open --env`
                // under sudo may still need a config-file fallback — see TSK-1243.
                argv = ["/usr/bin/sudo", "-n", "-H", "-u", user] + argv
            }
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
        } else if let user = spawnUser {
            // Root → console user, env threaded through /usr/bin/env
            // (sudo's env_reset strips the caller's; HOME comes from the
            // target user's record, which is exactly what "~" must mean).
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", "-u", user, "/usr/bin/env"] + mdvEnv
                + [exePath, "--script", scriptURL.path, argURL.path]
        } else {
            // Direct spawn — argv is preserved exactly.
            p.executableURL = URL(fileURLWithPath: exePath)
            p.arguments = ["--script", scriptURL.path, argURL.path]
            var env = ProcessInfo.processInfo.environment
            for pair in mdvEnv {
                let kv = pair.split(separator: "=", maxSplits: 1)
                env[String(kv[0])] = String(kv[1])
            }
            p.environment = env
        }
        // TSK-1243: capture the launch process's stderr to a stable per-run log
        // instead of /dev/null. The viaOpen GUI-lane launch
        // (`sudo -n -u <consoleUser> open -n -W -a <app>`) can fail silently — a
        // sudo/open/LaunchServices error in the asuser-root context yields 0 step
        // dumps + a 30s poll-timeout with NO clue why (the KEY-02/SAP-01 symptom).
        // Leaving the error on disk (/tmp survives the artifacts cleanup; the
        // artifacts UUID keys it so parallel runs don't clobber) makes the next VM
        // run diagnosable. Working (direct-spawn) modes write little/nothing here.
        let launchLog = "/tmp/mdv-launch-\(artifacts.lastPathComponent).log"
        FileManager.default.createFile(atPath: launchLog, contents: nil)
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError  = FileHandle(forWritingAtPath: launchLog) ?? FileHandle(forWritingAtPath: "/dev/null")
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
            // In viaOpen mode `p` is /usr/bin/open, not the app — reap the
            // app itself by its test-instance marker on timeout.
            if viaOpen { killTestInstances(named: existingProcessName) }
        }

        let dumps = collectStepDumps(from: artifacts)
        if (spawnUser != nil || viaOpen) && !inPlace {
            // The throwaway /tmp run dir created for the COPY hand-off is reaped
            // here, once the dumps are in memory. The in-place run dir belongs
            // to the caller (LaunchHarness.cleanup) and must survive across a
            // method's scenarios — e.g. the launch-1→launch-2 persistence flow.
            try? FileManager.default.removeItem(at: artifacts)
        }
        return dumps
    }

    /// Owner of /dev/console — the user whose Aqua session is on screen.
    static var consoleUser: String? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: "/dev/console")
        return attrs?[.ownerAccountName] as? String
    }

    /// `chown -R <user> <path>` (best-effort). Used by the root VM GUI lane to
    /// hand a fixture/run directory to the console user the app spawns as, so a
    /// root-created tree becomes readable AND writable by that user. A failure
    /// must not abort the test (the caller surfaces the real assertion).
    static func chownRecursive(_ path: String, to user: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/chown")
        p.arguments = ["-R", user, path]
        try? p.run()
        p.waitUntilExit()
    }

    /// HOME of the user the app is actually spawned as. Tests asserting
    /// "~"-rooted behavior must use THIS, not the harness's own home:
    /// under the root asuser bridge the app runs as the console user
    /// (`/Users/<console>`), while the test process's home is /var/root.
    static var spawnUserHome: URL {
        if geteuid() == 0, let user = consoleUser,
           let pw = getpwnam(user) {
            return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
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

    /// Reap leaked TEST-spawned instances of `name` — and ONLY those.
    ///
    /// A blanket `killall <name>` also killed the developer's normally-
    /// launched app, which shares this executable name, making the headless
    /// gate / live smoke destructive (it terminated whatever the user had
    /// open). Test spawns carry `MDV_TEST_INSTANCE=1` in their environment
    /// (set in `runScript`); we list candidate PIDs with `pgrep -x` and
    /// SIGTERM only the ones whose `ps eww` environment shows that marker.
    /// The user's app (launched via Finder/LaunchServices, no marker) is
    /// never touched.
    static func killTestInstances(named name: String) {
        let listing = runShell(["/usr/bin/pgrep", "-x", name], capture: true)
        let pids = (listing.stdout ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        for pid in pids {
            // `ps eww` appends the process environment after the command.
            let env = runShell(["/bin/ps", "eww", "-p", "\(pid)"], capture: true)
                .stdout ?? ""
            guard env.contains("MDV_TEST_INSTANCE=1") else { continue }
            kill(pid, SIGTERM)
        }
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
            // TSK-617: readDataToEndOfFile() raises an UNCATCHABLE ObjC
            // NSFileHandleOperationException ("Bad file descriptor") when the
            // pipe fd is dead (terminated child / fd exhaustion in the big VM
            // suite), crashing the whole xctest process instead of letting the
            // caller self-skip. readToEnd() reports the same condition as a
            // catchable Swift error — a dead pipe degrades to nil stdout.
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            out = String(data: data, encoding: .utf8)
        }
        return ShellResult(exit: p.terminationStatus, stdout: out)
    }
}
