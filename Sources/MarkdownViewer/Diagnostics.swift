import AppKit
import Foundation
import ViewerUI

/// Diagnostic-dump plumbing extracted from `main.swift` (Quality #I,
/// 2026-05-25). Three host-side affordances:
///
///   1. `--diagnose` flag → dump NSView tree as JSON to stdout, exit.
///      Headless smoke for the launch-time UI state.
///   2. `--auto-snapshot SECS` → schedule one JSON+PNG dump after
///      `SECS`, then exit. Avoids the AppleScript / terminal-focus
///      problems of SIGUSR1-driven snapshots.
///   3. `SIGUSR1` handler → dump live state to
///      `/var/folders/.../mdv-diagnostic-<pid>.json` for inspection
///      during an interactive session that's exhibiting a visual bug.
extension AppDelegate {

    /// Is the SIGUSR1 diagnostic trap enabled for this build/run?
    ///
    /// OBS-1: the trap used to be installed unconditionally — meaning a
    /// shipped release binary would, on any `kill -USR1`, write a JSON
    /// view-tree dump *and* a PNG screenshot of the user's window to a
    /// per-user tmp file. Even a contained tmpdir is more attack surface
    /// (and content leakage) than a release build should carry. We now
    /// gate it: on in DEBUG builds, or when the operator opts in via
    /// `MDV_ENABLE_DIAGNOSTICS=1`. When neither holds the handler is
    /// never installed and SIGUSR1 keeps its default disposition.
    static var diagnosticsTrapEnabled: Bool {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment["MDV_ENABLE_DIAGNOSTICS"] == "1"
        #endif
    }

    /// In a shipped release the dump must not embed user document content
    /// (the first 120 chars of whatever's open). DEBUG / opted-in dumps
    /// keep content for forensic value. Mirrors `diagnosticsTrapEnabled`'s
    /// gating but expressed as "should we redact".
    static var redactDiagnosticContent: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// Trap SIGUSR1 to dump the live NSView tree to
    /// /var/folders/.../mdv-diagnostic-<pid>.json. Lets us inspect state
    /// DURING an interactive session that's exhibiting a visual bug,
    /// instead of only on headless launch (which may differ from real use).
    /// Usage: `kill -USR1 $(pgrep MarkdownViewer)`
    ///
    /// Gated by `diagnosticsTrapEnabled` (OBS-1): no-op in a stock
    /// release build unless `MDV_ENABLE_DIAGNOSTICS=1` is set.
    func installDiagnosticSignalHandler() {
        // Best-effort sweep of stale diagnostic artifacts from prior runs
        // (crashed processes leave `mdv-diagnostic-<pid>.json` /
        // `mdv-snapshot-<pid>.png` behind). Runs even when the trap is
        // disabled so an upgrade from an old binary cleans up too (OBS-2).
        Self.cleanStaleDiagnosticArtifacts()

        guard Self.diagnosticsTrapEnabled else { return }
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let win = self.window else { return }
            // FIRST: force window to front and key so AppKit's
            // occlusion-suspends-drawing optimization doesn't yield a
            // stale snapshot. We capture the realized-on-screen state,
            // so the window must actually be on-screen + drawing.
            activateIfForeground()
            showWindow(win)
            // Give the compositor one runloop tick to flush after
            // activation before we capture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let pid = getpid()
                // Per-user tmpdir at /var/folders/... is safe from the
                // symlink-hijack scenario possible in /tmp.
                let tmp = FileManager.default.temporaryDirectory
                let jsonPath = tmp.appendingPathComponent("mdv-diagnostic-\(pid).json").path
                let pngPath  = tmp.appendingPathComponent("mdv-snapshot-\(pid).png").path
                // Redact document content in release dumps; keep it under
                // DEBUG / opt-in for forensic value (OBS-1).
                let dump = DiagnosticDump.dump(
                    window: win,
                    options: DiagnosticDump.Options(
                        redactContent: Self.redactDiagnosticContent
                    )
                )
                do {
                    let data = try JSONSerialization.data(
                        withJSONObject: dump,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    // Write with explicit owner-only (0600) perms so a
                    // co-resident user can't read the dump (OBS-2).
                    try Self.writeDataPrivate(data, toPath: jsonPath)
                } catch {
                    FileHandle.standardError.write(
                        Data("diagnostic dump failed: \(error)\n".utf8))
                }
                let captured = DiagnosticDump.captureWindowToPNG(win, path: pngPath)
                if captured { Self.tightenPermissions(atPath: pngPath) }
                FileHandle.standardError.write(
                    Data("diagnostic → \(jsonPath)\(captured ? " + \(pngPath)" : " (PNG capture failed)")\n".utf8))
            }
        }
        signal(SIGUSR1, SIG_IGN)   // Required so DispatchSource gets it
        src.resume()
        // Retain.
        self.diagnosticSignalSource = src
    }

    /// Wait the given delay (during which we DON'T cede focus to a
    /// caller terminal), then dump JSON + PNG of our own window to
    /// /var/folders/.../mdv-auto.{json,png}, then exit. Avoids the
    /// AppleScript / terminal-focus problems of SIGUSR1-driven snapshots.
    ///
    /// CONTRACT (S4, 2026-06-03): the `exit()` calls below intentionally
    /// bypass `applicationWillTerminate`'s teardown — `sessions
    /// .flushForTermination()`, `JSONFileStore.flushSync()`,
    /// `terminalPane.shutdown()`, bounded LSP `pool.closeAll()`. That is
    /// SAFE here only because `--auto-snapshot` is a dev/test harness flag
    /// that never opens a real workspace, never spawns an LSP server, and
    /// never mutates the Sessions index, so there is no durable state to
    /// flush. If this path is ever made to operate on a real folder, route
    /// the exit through `NSApp.terminate(nil)` (as the MCP `onExit` path
    /// does) — or call the flush trio first — instead of raw `exit()`,
    /// otherwise it leaks the Sessions index unflushed and orphans the
    /// spawned LSP server until launchd reaps it. DO NOT copy a raw
    /// `exit()` from here into any state-bearing code path.
    func scheduleAutoSnapshot(after delay: Double, forceSource: Bool) {
        if forceSource, model.supportsViewModeToggle, model.currentViewMode != .source {
            DispatchQueue.main.async { self.model.toggleViewMode() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let win = self.window else {
                FileHandle.standardError.write(Data("auto-snapshot: no window\n".utf8))
                exit(2)
            }
            activateIfForeground()
            showWindow(win)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Per-user tmpdir at /var/folders/... is safe from the
                // symlink-hijack scenario possible in /tmp.
                let tmp = FileManager.default.temporaryDirectory
                let json = tmp.appendingPathComponent("mdv-auto.json").path
                let png  = tmp.appendingPathComponent("mdv-auto.png").path
                // `--auto-snapshot` is an explicit headless flag (dev /
                // test harness only), so we keep content here — but still
                // write 0600 so the artifact isn't world-readable (OBS-2).
                let dump = DiagnosticDump.dump(window: win)
                let data = (try? JSONSerialization.data(
                    withJSONObject: dump,
                    options: [.prettyPrinted, .sortedKeys]
                )) ?? Data()
                try? Self.writeDataPrivate(data, toPath: json)
                let captured = DiagnosticDump.captureWindowToPNG(win, path: png)
                if captured { Self.tightenPermissions(atPath: png) }
                FileHandle.standardError.write(
                    Data("auto-snapshot → \(json) + \(captured ? png : "PNG-failed")\n".utf8))
                exit(captured ? 0 : 3)
            }
        }
    }

    /// Deterministic UI-scene control for the visual-test harness (TSK-492).
    /// `MDV_UI_SCENE` drives the LIVE model into an EXACT state at launch so a
    /// screenshot harness gets a reproducible frame WITHOUT fragile
    /// `defaults`/AX — today's terminal-tabs debugging proved those
    /// unreliable (persisted layout isn't honored under skip-restore; AX
    /// keystrokes mis-route). Applied after a short delay so it is the LAST
    /// word over session bootstrap + file open. The app stays running; an
    /// external capture (`scripts/ui-snapshot.sh`) screenshots the window by
    /// id, evaluates pixels, then reaps the instance.
    ///
    /// Scenes (extend the catalog as features land):
    ///   terminal[-left|-top|-right][-<N>]
    ///       Open the bottom terminal, place the tab strip (default left),
    ///       seed N tabs (default 2), tall enough that the rail is visible.
    ///   tabs-<N>
    ///       Open N throwaway files as permanent FILE tabs so the top TabBar
    ///       holds exactly N tabs (TSK-261/268/331 pixel tests).
    ///   preview[-promoted]  (needs MDV_PREVIEW_FILE)
    ///       Drive the ephemeral preview-tab slot (TSK-306/272).
    func applyUISceneIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let scene = env["MDV_UI_SCENE"]?.lowercased(), !scene.isEmpty else { return }
        let delay = Double(env["MDV_UI_SCENE_DELAY"] ?? "") ?? 0.6
        // The per-pid tmp dir the `tabs-<N>` scene writes throwaway markdown into
        // (never ~/Documents — see CLAUDE.md; one dir per pid so parallel
        // instances can't collide).
        let tabsBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mdv-scene-tabs-\(ProcessInfo.processInfo.processIdentifier)")
        let previewFile = env["MDV_PREVIEW_FILE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // TSK-492: the scene→model mapping lives in the host-tested
            // ViewerUI.UISceneApplier seam; this shell only supplies env-derived
            // inputs + writes the status line.
            let status = UISceneApplier.apply(
                scene: scene, to: self.model,
                previewFile: previewFile, tabsBaseDir: tabsBaseDir)
            FileHandle.standardError.write(Data((status + "\n").utf8))
        }
    }

    /// Runs after the window/AppDelegate have finished launching and the
    /// file is loaded. Waits a couple of run-loop ticks so SwiftUI has a
    /// chance to lay out and the WKWebView (if any) has had a beat to
    /// start loading. Then dumps the realized NSView tree as JSON to
    /// stdout and exits cleanly with code 0 (or 1 on failure).
    ///
    /// CONTRACT (S4, 2026-06-03): same deliberate flush skip as
    /// `scheduleAutoSnapshot` — the `exit()` calls below bypass
    /// `applicationWillTerminate`'s teardown (Sessions flush, JSON store
    /// sync, terminal shutdown, LSP `pool.closeAll()`). SAFE because
    /// `--diagnose` is a headless launch probe with no durable state. If
    /// this ever drives a real workspace, route through
    /// `NSApp.terminate(nil)` or call the flush trio first. DO NOT copy a
    /// raw `exit()` from here into a state-bearing path.
    func runDiagnoseAndExit(forceSource: Bool) {
        guard let win = window else {
            FileHandle.standardError.write(Data("diagnose: no window\n".utf8))
            exit(2)
        }
        if forceSource {
            // Programmatically flip to source view before measuring.
            // The model's toggleViewMode is the user-facing path.
            if model.supportsViewModeToggle && model.currentViewMode != .source {
                model.toggleViewMode()
            }
        }
        // Two run-loop ticks: one for SwiftUI to flush layout, one for
        // AppKit to perform display. We've already activated above.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                let dump = DiagnosticDump.dump(window: win)
                do {
                    let data = try JSONSerialization.data(
                        withJSONObject: dump,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(
                        Data("diagnose: JSON encode failed: \(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }

    // MARK: - Private artifact I/O (OBS-2)

    /// Write `data` to `path` with owner-only (0600) permissions, created
    /// atomically. We open with `O_CREAT|O_EXCL`-free `O_TRUNC` and an
    /// explicit 0600 mode so the file is never momentarily group/other
    /// readable (a `write` followed by `chmod` would briefly expose it
    /// under the process umask). Existing files are truncated and the
    /// mode re-asserted.
    static func writeDataPrivate(_ data: Data, toPath path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                    "open(\(path)) failed: \(String(cString: strerror(errno)))"]
            )
        }
        defer { close(fd) }
        // Re-assert mode in case the file pre-existed with looser perms
        // (open() honors the mode arg only on creation).
        _ = fchmod(fd, 0o600)
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress, remaining.count)
            }
            if written <= 0 {
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey:
                        "write(\(path)) failed: \(String(cString: strerror(errno)))"]
                )
            }
            remaining = remaining.suffix(remaining.count - written)
        }
    }

    /// Best-effort tighten of an existing file to 0600. Used for PNGs,
    /// which `DiagnosticDump.captureWindowToPNG` writes via `Data.write`
    /// (under the umask) since that helper lives in ViewerUI and can't be
    /// changed from this group.
    static func tightenPermissions(atPath path: String) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path
        )
    }

    /// Sweep stale diagnostic artifacts left by previous (possibly
    /// crashed) processes. We only touch our own `mdv-diagnostic-*.json`
    /// / `mdv-snapshot-*.png` / `mdv-auto.{json,png}` names in the
    /// per-user tmpdir, and we never remove the file for the *current*
    /// pid. Best-effort: failures are ignored (OBS-2).
    static func cleanStaleDiagnosticArtifacts() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let myPID = getpid()
        let mineDiag = "mdv-diagnostic-\(myPID).json"
        let mineSnap = "mdv-snapshot-\(myPID).png"
        for url in entries {
            let name = url.lastPathComponent
            let isOurArtifact =
                (name.hasPrefix("mdv-diagnostic-") && name.hasSuffix(".json"))
                || (name.hasPrefix("mdv-snapshot-") && name.hasSuffix(".png"))
                || name == "mdv-auto.json"
                || name == "mdv-auto.png"
            guard isOurArtifact else { continue }
            // Never clobber the current process's own (about-to-be-written)
            // files.
            if name == mineDiag || name == mineSnap { continue }
            try? fm.removeItem(at: url)
        }
    }
}
