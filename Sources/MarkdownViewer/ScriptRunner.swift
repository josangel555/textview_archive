import AppKit
import Foundation
import ViewerCore
import ViewerKit
import ViewerUI

/// `--script PATH` interpreter for the L4/L5 VM-driven UI tests.
///
/// Pure code-motion out of `main.swift` (Quality #I, 2026-05-25). The
/// dispatcher reaches into AppDelegate's `model`, `sessions`, and
/// `window` — kept as an extension so the access stays direct and we
/// don't have to widen any internal API surfaces.
extension AppDelegate {

    /// Reads a newline-separated command script and executes it
    /// step-by-step against the model. After each step, writes a JSON
    /// diagnostic + PNG snapshot to `/var/folders/.../mdv-step-NN.{json,png}`.
    /// Exits 0 after the final step. Used by L4 / L5 interaction tests.
    ///
    /// Commands (one per line, # for comments):
    ///   toggle-view             cycle rendered <-> source
    ///   toggle-sidebar
    ///   zoom-in / zoom-out / zoom-reset
    ///   open PATH               open a file or folder
    ///   close-tab
    ///   new-tab
    ///   next-tab / prev-tab
    ///   select-tab N            (1-indexed)
    ///   show-palette / dismiss-palette
    ///   delay SECS              pause without action
    ///   snapshot                explicit snapshot (otherwise done after each command)
    func runScript(at path: String) {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("script: cannot read \(path)\n".utf8))
            exit(2)
        }
        let lines = data.split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        Task { @MainActor in
            // Give launch one full second to settle (window appears, file loads).
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for (step, line) in lines.enumerated() {
                self.runScriptStep(line)
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.captureStepArtifacts(step: step + 1, label: line)
            }
            exit(0)
        }
    }

    func runScriptStep(_ line: String) {
        // Keystone (§3.1): the bulk of the verb dispatch — every model /
        // sessions verb — now lives in the free function
        // `ScriptVerb.apply(verb:to:sessions:)` (ViewerUI), so the same
        // dispatch drives both this VM `--script` path and the in-process
        // `HeadlessHarness`. `apply` returns `false` for the residual
        // window / `NSApp` / AppDelegate-coupled verbs, which we handle
        // here so production `--script` behaviour is unchanged.
        if ScriptVerb.apply(verb: line, to: model, sessions: sessions) {
            return
        }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "resize":
            // "WxH" e.g. "1200x800"
            let dims = arg.split(separator: "x").compactMap { Int($0) }
            if dims.count == 2, let win = self.window {
                var frame = win.frame
                frame.size = NSSize(width: dims[0], height: dims[1])
                win.setFrame(frame, display: true, animate: false)
            }
        case "diagnostic-window":
            // WAVE 2b item 4: open the diagnostic tool window (gated).
            showDiagnosticWindow(nil)
        case "instrumentation-window":
            // WAVE 2b item 5: open the instrumentation tool window (gated).
            showInstrumentationWindow(nil)
        case "find":
            // Invoke the system find action on first responder NSTextView.
            NSApp.sendAction(
                #selector(NSTextView.performFindPanelAction(_:)),
                to: nil, from: nil
            )
        default:
            FileHandle.standardError.write(
                Data("script: unknown command '\(cmd)'\n".utf8))
        }
    }

    func captureStepArtifacts(step: Int, label: String) {
        guard let win = window else { return }
        let n = String(format: "%02d", step)
        // #193: run-scoped artifact dir. `MDV_ARTIFACT_DIR` (set by the
        // harness) gives each parallel live-app test its own directory so
        // `mdv-step-NN.json` writes don't stomp each other; falls back to
        // the per-user tmpdir (/var/folders/..., safe from the symlink-
        // hijack scenario possible in /tmp) for non-test launches.
        let tmp = ArtifactDir.url
        let json = tmp.appendingPathComponent("mdv-step-\(n).json").path
        let png  = tmp.appendingPathComponent("mdv-step-\(n).png").path
        let dump = DiagnosticDump.dump(window: win)
        var enriched = dump
        enriched["step"] = step
        enriched["label"] = label
        // Expose model state so tests can verify zoom / mode / tab
        // count without scraping NSTextView fonts (which don't exist
        // in the pure-SwiftUI source view). The projection itself lives
        // in `ScriptVerb.modelStateDump` (ViewerUI) so the in-process
        // `HeadlessHarness` emits a byte-identical `model` dict.
        enriched["model"] = ScriptVerb.modelStateDump(model: model, sessions: sessions)
        if let data = try? JSONSerialization.data(
            withJSONObject: enriched,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: json))
        }
        _ = DiagnosticDump.captureWindowToPNG(win, path: png)
        // Verification-only: when a separate tool window (Diagnostics /
        // Instrumentation) is the key window, also snapshot it via the
        // same permission-free in-process cacheDisplay path. The main
        // capture above only ever targets `self.window`, so without this
        // the WAVE-2b tool windows are uncapturable by the screencap
        // harness. No effect on app behaviour — purely an extra artifact.
        // Prefer the key window, but fall back to any *other* visible
        // window — in MDV_BACKGROUND / non-activated runs the app has no
        // key window, yet the tool window is still ordered-in and fully
        // laid out, so cacheDisplay snapshots it correctly.
        let otherWindow = NSApp.keyWindow.flatMap { $0 !== win ? $0 : nil }
            ?? NSApp.windows.first { $0 !== win && $0.isVisible && $0.contentView != nil }
        if let other = otherWindow {
            let keyPNG = tmp.appendingPathComponent("mdv-step-\(n)-key.png").path
            if DiagnosticDump.captureWindowToPNG(other, path: keyPNG) {
                FileHandle.standardError.write(
                    Data("step \(n) [\(label)] tool-window '\(other.title)' → \(keyPNG)\n".utf8))
            }
        }
        FileHandle.standardError.write(
            Data("step \(n) [\(label)] → \(json) + \(png)\n".utf8))
    }
}
