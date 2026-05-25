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

    /// Trap SIGUSR1 to dump the live NSView tree to
    /// /var/folders/.../mdv-diagnostic-<pid>.json. Lets us inspect state
    /// DURING an interactive session that's exhibiting a visual bug,
    /// instead of only on headless launch (which may differ from real use).
    /// Usage: `kill -USR1 $(pgrep MarkdownViewer)`
    func installDiagnosticSignalHandler() {
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
                let dump = DiagnosticDump.dump(window: win)
                do {
                    let data = try JSONSerialization.data(
                        withJSONObject: dump,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    try data.write(to: URL(fileURLWithPath: jsonPath))
                } catch {
                    FileHandle.standardError.write(
                        Data("diagnostic dump failed: \(error)\n".utf8))
                }
                let captured = DiagnosticDump.captureWindowToPNG(win, path: pngPath)
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
                let dump = DiagnosticDump.dump(window: win)
                let data = (try? JSONSerialization.data(
                    withJSONObject: dump,
                    options: [.prettyPrinted, .sortedKeys]
                )) ?? Data()
                try? data.write(to: URL(fileURLWithPath: json))
                let captured = DiagnosticDump.captureWindowToPNG(win, path: png)
                FileHandle.standardError.write(
                    Data("auto-snapshot → \(json) + \(captured ? png : "PNG-failed")\n".utf8))
                exit(captured ? 0 : 3)
            }
        }
    }

    /// Runs after the window/AppDelegate have finished launching and the
    /// file is loaded. Waits a couple of run-loop ticks so SwiftUI has a
    /// chance to lay out and the WKWebView (if any) has had a beat to
    /// start loading. Then dumps the realized NSView tree as JSON to
    /// stdout and exits cleanly with code 0 (or 1 on failure).
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
}
