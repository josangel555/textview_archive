import AppKit
import Foundation
import ViewerCore
import ViewerKit
import ViewerUI
import WebKit

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
    ///   confirm-dirty-close save|discard|cancel
    ///                           pre-arm the next dirty-close prompt (one-shot)
    ///   close-tab
    ///   new-tab
    ///   next-tab / prev-tab
    ///   select-tab N            (1-indexed)
    ///   show-palette / dismiss-palette
    ///   delay SECS              pause without action
    ///   snapshot                explicit snapshot (otherwise done after each command)
    ///   ui-click ID [cmd] [shift] [at FX FY]
    ///                           REAL click on the view with accessibility
    ///                           id ID (FX/FY = bounds fractions, default
    ///                           center); ui-double-click for count 2
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
                await self.runScriptStep(line)
                // Settle window per step before snapshotting. A `delay SECS`
                // verb pauses for its arg (parsed as seconds) so FSEvents /
                // the accordion / a git re-list can settle past 300 ms; every
                // other verb keeps the fixed 300 ms inter-step settle that the
                // model-assertion smokes rely on. Clamp to a sane window so a
                // malformed arg can neither under-sleep (0) nor hang the run.
                try? await Task.sleep(nanoseconds: Self.settleNanos(for: line))
                self.captureStepArtifacts(step: step + 1, label: line)
            }
            exit(0)
        }
    }

    /// Per-step settle duration, in nanoseconds, before the post-step
    /// snapshot. For a `delay SECS` verb this is the arg parsed as seconds
    /// (clamped to `[0.3s, 30s]` so a malformed/negative arg can't drop the
    /// settle to zero nor hang the run); every other verb keeps the fixed
    /// 300 ms baseline. An unparseable `delay` arg falls back to the baseline.
    static func settleNanos(for line: String) -> UInt64 {
        let baseline: UInt64 = 300_000_000
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first == "delay", parts.count > 1,
              let secs = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              secs.isFinite
        else { return baseline }
        let clamped = min(max(secs, 0.3), 30.0)
        return UInt64(clamped * 1_000_000_000)
    }

    func runScriptStep(_ line: String) async {
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
        case "resize-sweep":
            // "minW maxW N" — oscillate the window width minW → maxW → minW
            // in N setFrame increments at ~30 Hz, ALL inside this one verb
            // so the per-step snapshot doesn't pollute a profiling capture
            // (TSK-592). Fire-and-forget: pair with a `delay SECS` line
            // covering the sweep duration (~N/30 s). Programmatic setFrame
            // drives the same SwiftUI/AppKit layout as a live drag, modulo
            // NSWindow.inLiveResize-gated paths — caveat noted on the ticket.
            let p = arg.split(separator: " ").compactMap { Int($0) }
            if p.count == 3, let win = self.window {
                let (minW, maxW, steps) = (Double(p[0]), Double(p[1]), max(1, p[2]))
                Task { @MainActor in
                    for i in 0...steps {
                        var f = win.frame
                        f.size.width = ResizeSweep.width(
                            at: i, minW: minW, maxW: maxW, steps: steps)
                        win.setFrame(f, display: true, animate: false)
                        try? await Task.sleep(nanoseconds: 33_000_000)
                    }
                }
            }
        case "wait-editor-line":
            // TSK-1047 (VM scroll-restore test SETUP): block this step until the
            // LIVE CM6 viewport top line reaches ~N, polling the real WebView —
            // NOT a fixed `delay` gamble. The prior harness issued
            // `editor-scroll-to-line` then read a dump at a FIXED index that often
            // landed BEFORE CM6's async DOM scroll + `scrollChanged` settled, so
            // the precondition ("CM6 scrolled to N") was never PROVEN and every
            // run was a false red (`got top line 1`). This wait-for-settle makes
            // the precondition observable: it returns only once the editor's true
            // on-screen viewport top reaches the target (within tolerance) or a
            // bounded timeout elapses — and stashes the settled live value into
            // `LiveScrollProbe` so the following dump surfaces `liveEditorTopLine`.
            if let n = Int(arg), n >= 1 {
                await waitForEditorTopLine(atLeast: n)
            }
        case "wait-rendered-scroll":
            // TSK-1047 (VM scroll-restore test SETUP): the rendered-preview twin
            // of `wait-editor-line` — block until the LIVE `window.scrollY`
            // reaches ~N (the genuine on-screen offset), stashing the settled
            // value into `LiveScrollProbe.renderedScrollY` for the next dump.
            if let y = Double(arg), y >= 0 {
                await waitForRenderedScroll(atLeast: y)
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
        case "ui-click", "ui-double-click":
            // REAL-event interaction layer (UIEventSynth): locate a view
            // by accessibility id and drive NSEvents through the window's
            // sendEvent — full hit-testing + responder chain + SwiftUI
            // gesture routing. Grammar: <ax-id> [cmd] [shift] [at FX FY].
            // Failures are LOUD on stderr so an assertion harness can
            // refuse a run that clicked nothing.
            guard let spec = UIClickSpec.parse(verb: cmd, arg: arg) else {
                FileHandle.standardError.write(
                    Data("script: bad \(cmd) syntax '\(line)'\n".utf8))
                return
            }
            guard let win = self.window else {
                FileHandle.standardError.write(
                    Data("script: \(cmd) with no window\n".utf8))
                return
            }
            // The harness launches with MDV_BACKGROUND (no activation), so
            // the window is never KEY — and a click on a non-key window is
            // consumed as an activating click (SwiftUI views default
            // acceptsFirstMouse == false), i.e. silently swallowed (found
            // empirically: both first VM scenarios clicked nothing). Two
            // refinements from the second VM run (key was STILL false):
            // `NSApp.activate` is ASYNCHRONOUS — pump the run loop until
            // key status actually lands — and `.accessory` policy can deny
            // key outright, so escalate to `.regular` for the click.
            // Script-path only; the VM GUI lane is precisely where
            // activation is permitted. (If key never lands — root app in a
            // user GUI session can be refused by WindowServer —
            // UIEventSynth falls back to direct responder dispatch and the
            // trace says which path ran.)
            UIEventSynth.makeWindowKey(win)
            if !UIEventSynth.click(spec: spec, in: win) {
                FileHandle.standardError.write(
                    Data("script: \(cmd) target '\(spec.identifier)' not found\n".utf8))
            }
        case "ui-type", "ui-key":
            // REAL-keydown interaction layer (UIEventSynth.typeKeys, TSK-818):
            // post genuine CGEvent keyDown/keyUp (+ modifier chords) into the
            // focused field of the live app — the keyboard sibling of ui-click.
            //   ui-type <literal text>          (one keystroke per char)
            //   ui-key  <chord> [<chord> ...]   (cmd+c, shift+a, left, enter …)
            // VM GUI lane only (CGEvent posting needs a WindowServer + GUI
            // session); on host these tiers self-skip. LOUD on a bad parse so
            // an assertion harness refuses a run that typed nothing.
            guard let spec = UIKeySpec.parse(verb: cmd, arg: arg) else {
                FileHandle.standardError.write(
                    Data("script: bad \(cmd) syntax '\(line)'\n".utf8))
                return
            }
            guard let win = self.window else {
                FileHandle.standardError.write(
                    Data("script: \(cmd) with no window\n".utf8))
                return
            }
            if !UIEventSynth.typeKeys(spec: spec, in: win) {
                FileHandle.standardError.write(
                    Data("script: \(cmd) posted no events '\(line)'\n".utf8))
            }
        default:
            FileHandle.standardError.write(
                Data("script: unknown command '\(cmd)'\n".utf8))
        }
    }

    /// TSK-1047 — poll the LIVE CM6 editor viewport top line until it reaches
    /// `target` (within `tolerance` lines) or `timeout` elapses, then stash the
    /// final settled value in `LiveScrollProbe` so the next dump surfaces it.
    ///
    /// Why a poll, not a fixed delay: `editor-scroll-to-line` dispatches a CM6
    /// `scrollToLine`, but the DOM scroll + CM6's `scrollChanged` re-emit settle
    /// ASYNCHRONOUSLY on a microtask AFTER the WebView lays out — a fixed `delay`
    /// can read before that, leaving the precondition (and thus the whole
    /// scenario) a false red. This pumps the main run loop between samples so the
    /// async JS read + CM6's own settle make progress, and only returns once the
    /// editor's TRUE on-screen top line has arrived (the provable precondition).
    private func waitForEditorTopLine(
        atLeast target: Int,
        tolerance: Int = 8,
        // TSK-1046: 25s (was 6s). Under the VM GUI lane the WKWebView WebContent
        // IPC for evaluateJavaScript is slow/cold — the probe diag showed done=false
        // at the old 0.5s sample budget / 6s timeout, with only occasional done=true.
        // Generous budgets (sample 4s, poll 25s) make the live read reliable; the
        // per-scenario timeout is 90s.
        timeout: TimeInterval = 25.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // TSK-1047: RE-ISSUE the scroll each poll. CM6's WebContent can crash +
            // recover under the VM GUI lane (resets to the top), dropping the one-shot
            // editor-scroll-to-line — so keep re-applying scrollToLine(target) until
            // the live top line actually reaches it. Idempotent; safe because
            // wait-editor-line is SETUP-only (the restore read uses capture-editor-scroll).
            for wv in CodeMirrorEditorRegistry.shared.liveWebViews {
                _ = await evalString(wv, "(function(){try{if(window.cmDispatch){window.cmDispatch({type:'scrollToLine',line:\(target)});return 'ok';}return 'no';}catch(e){return 'e';}})()")
            }
            if let line = await sampleLiveEditorTopLine(), line >= target - tolerance {
                // Settled within tolerance — record the live value for the dump.
                LiveScrollProbe.editorScrollTop = Double(max(0, line))
                LiveScrollProbe.editorTopLine = line
                return
            }
            // Yield ~150ms so the async JS read + CM6's own scroll settle can
            // advance before the next sample (await, not a nested RunLoop pump).
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        // Timed out — leave the LAST observed value in the probe (a final read so
        // the dump shows where it actually got, surfacing a genuine failure
        // instead of a stale -1).
        if let line = await sampleLiveEditorTopLine() {
            LiveScrollProbe.editorScrollTop = Double(max(0, line))
            LiveScrollProbe.editorTopLine = line
        }
    }

    /// TSK-1047 — rendered-preview twin of `waitForEditorTopLine`: poll the LIVE
    /// `window.scrollY` until it reaches `target` (within `tolerance` px) or
    /// `timeout` elapses, stashing the final value in `LiveScrollProbe`.
    private func waitForRenderedScroll(
        atLeast target: Double,
        tolerance: Double = 40,
        // TSK-1046: 25s (was 6s) — see waitForEditorTopLine; slow GUI-lane
        // WebContent IPC needs a generous budget for the live window.scrollY read.
        timeout: TimeInterval = 25.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let y = await sampleLiveRenderedScroll(), y >= target - tolerance {
                LiveScrollProbe.renderedScrollY = y
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        if let y = await sampleLiveRenderedScroll() {
            LiveScrollProbe.renderedScrollY = y
        }
    }

    /// Synchronously sample the live CM6 viewport top line by evaluating the
    /// shared read JS and pumping the run loop until the async result lands (or a
    /// short per-sample budget elapses). Returns nil when no editor is mounted /
    /// CM6 isn't up yet / the read times out.
    private func sampleLiveEditorTopLine() async -> Int? {
        // TSK-1047: iterate ALL live CM6 webviews — current() can hand back a blank /
        // parked / pre-init one (key-window or entries.last) whose JS context is empty
        // (url=nil, eval→nil). The one with CM6 actually up (ok=true) is the authority.
        let webViews = CodeMirrorEditorRegistry.shared.liveWebViews
        guard !webViews.isEmpty else {
            LiveScrollProbe.lastEditorProbeDiag = "no-current entries=0"
            return nil
        }
        var diags: [String] = []
        for wv in webViews {
            let (ok, line) = await evalEditorLine(wv, LiveScrollProbe.editorScrollReadJS)
            if ok, let line {
                LiveScrollProbe.lastEditorProbeDiag = "ok=true line=\(line) n=\(webViews.count)"
                return line
            }
            let dom = await evalString(wv, """
            (function(){try{return 'mdv='+(!!window.__mdvView)+' rs='+document.readyState\
            +' cm='+document.querySelectorAll('.cm-editor').length\
            +' blen='+(document.body?document.body.innerHTML.length:-1);}catch(e){return 'e:'+e;}})()
            """) ?? "evalnil"
            diags.append("[url=\(wv.url?.lastPathComponent ?? "nil") key=\(wv.window?.isKeyWindow ?? false) \(dom)]")
        }
        LiveScrollProbe.lastEditorProbeDiag = "ok=false n=\(webViews.count) " + diags.joined(separator: " ") + " nav=[\(LiveScrollProbe.editorNavLog)]"
        return nil
    }

    /// Synchronously sample the live rendered `window.scrollY`, pumping the run
    /// loop until the async read lands. nil when no preview is mounted / times out.
    /// Bridge the COMPLETION-HANDLER evaluateJavaScript into async via a checked
    /// continuation. TSK-1046/1047: deliberately NOT `try await
    /// webView.evaluateJavaScript(_:)` — that async variant throws WKError Code 5
    /// ("result of an unsupported type") for the CM6 dict read under the VM GUI lane,
    /// while the completion-handler variant bridges it fine. The continuation also
    /// avoids the nested-RunLoop pump that starved the IPC reply. The result is
    /// extracted to a Sendable value INSIDE the handler so no non-Sendable `Any`
    /// crosses the continuation. WKWebView guarantees the handler fires once.
    private func evalDouble(_ webView: WKWebView, _ js: String) async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            webView.evaluateJavaScript(js) { value, _ in
                cont.resume(returning: (value as? NSNumber)?.doubleValue)
            }
        }
    }

    private func evalEditorLine(_ webView: WKWebView, _ js: String) async -> (ok: Bool, line: Int?) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, Int?), Never>) in
            webView.evaluateJavaScript(js) { value, _ in
                let dict = value as? [String: Any]
                let ok = (dict?["ok"] as? Bool) ?? false
                let line = (dict?["line"] as? NSNumber)?.intValue
                cont.resume(returning: (ok, line))
            }
        }
    }

    private func evalString(_ webView: WKWebView, _ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(js) { value, _ in cont.resume(returning: value as? String) }
        }
    }

    private func sampleLiveRenderedScroll() async -> Double? {
        let n = MarkdownRenderedRegistry.shared.liveEntryCount
        guard let webView = MarkdownRenderedRegistry.shared.current() else {
            LiveScrollProbe.lastProbeDiag = "sample:no-current entries=\(n)"
            return nil
        }
        let y = await evalDouble(webView, "window.scrollY")
        LiveScrollProbe.lastProbeDiag =
            "sample y=\(y.map { String($0) } ?? "nil") entries=\(n) key=\(webView.window?.isKeyWindow ?? false) url=\(webView.url?.lastPathComponent ?? "nil")"
        return y
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
        // TSK-620: surface the last ui-click resolution in the dump so a
        // failing interaction scenario shows what was clicked and where.
        if !UIEventSynth.lastTrace.isEmpty {
            enriched["uiClickTrace"] = UIEventSynth.lastTrace
        }
        // TSK-818: same self-describing-failure channel for the ui-type/ui-key
        // real-keydown layer — a failing VM key scenario shows what was posted.
        if !UIEventSynth.lastKeyTrace.isEmpty {
            enriched["uiKeyTrace"] = UIEventSynth.lastKeyTrace
        }
        // TSK-522/523: same self-describing-failure channel for the Git
        // Log action closures (root → range → git body → write → tab).
        if !GitLogDiffActions.lastTrace.isEmpty {
            enriched["gitLogTrace"] = GitLogDiffActions.lastTrace
        }
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
