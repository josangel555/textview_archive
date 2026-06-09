import AppKit
import XCTest

/// T5 pixel validation for the Claude monitor's transcript content-search
/// RESULTS UI (TSK-520, the render-gated half of the feature). Launches the app
/// straight into content-search mode (`--claude-monitor` +
/// `MDV_MONITOR_CONTENT_QUERY`) over a fixture `~/.claude` tree
/// (`MDV_MONITOR_ROOT`), then reads back stage-④ WindowServer pixels: the
/// master-pane RESULTS region (left column, below the mode picker + field) must
/// composite a non-uniform list of result rows (≥3 distinct colours — the
/// coloured role badge + snippet text + row background).
///
/// This is the teeth the host layer can't give: `ClaudeMonitorModelTests`
/// covers the model (`runContentSearch`/`selectMatch`/the launch-env seed), but
/// the SwiftUI results list's render path has NO host coverage. A green here
/// proves the results actually paint — if the list were empty, occluded, or the
/// seeded search never ran, the region reads uniform and this fails. Reuses
/// `SourceViewVisualRegressionTests`'s pixel helpers
/// (`capturedBackingScale`, `regionHasVariety`, `Region`).
final class ClaudeMonitorVisualRegressionTests: PixelTestCase {

    private static let appBundlePath: String = {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return here.appendingPathComponent("dist/TextView.app").path
    }()

    private static let windowIDFile: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("com.markdownviewer.MarkdownViewer.windowid")
    }()

    func test_monitor_contentSearchResults_composite() throws {
        if ProcessInfo.processInfo.environment["MDV_HEADLESS_GATE"] == "1" {
            throw XCTSkip("T5 heavy tier — VM/nightly lane, not the headless gate.")
        }
        let fm = FileManager.default
        let appExe = Self.appBundlePath + "/Contents/MacOS/MarkdownViewer"
        guard fm.isExecutableFile(atPath: appExe) else { throw XCTSkip("App not built.") }
        guard !ProcessInfo.processInfo.environment.keys.contains("MDV_SKIP_VISUAL") else {
            throw XCTSkip("MDV_SKIP_VISUAL set.")
        }

        // 1. A fixture ~/.claude tree with several events all carrying the
        //    search token, across two sessions → several result rows render.
        let root = try makeFixtureClaudeRoot(token: "BANANA")
        defer { try? fm.removeItem(at: root) }
        try? fm.removeItem(at: Self.windowIDFile)
        AppLauncher.killTestInstances(named: "MarkdownViewer")

        // 2. Spawn straight into content-search mode, seeded to BANANA.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        p.arguments = ["--claude-monitor"]
        var env = ProcessInfo.processInfo.environment
        env["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        env["MDV_TEST_INSTANCE"] = "1"
        env["MDV_MONITOR_ROOT"] = root.path
        env["MDV_MONITOR_CONTENT_QUERY"] = "BANANA"
        p.environment = env
        p.standardOutput = FileHandle.standardError
        p.standardError = FileHandle.standardError
        try p.run()
        defer {
            if p.isRunning {
                p.terminate(); Thread.sleep(forTimeInterval: 0.2)
                if p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
            }
        }

        let windowID = try waitForWindowID(timeout: 2.5)
        _ = runDisclaimedShell(
            "/usr/bin/osascript -e 'tell application \"MarkdownViewer\" to activate'")
        // Give the off-main session scan + content search time to publish.
        Thread.sleep(forTimeInterval: 1.8)

        // 3. Capture stage-④ pixels.
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-monitor-search-\(UUID().uuidString).png")
        let capExit = runDisclaimedShell(
            "/usr/sbin/screencapture -l\(windowID) -x -o '\(pngURL.path)'")
        guard capExit == 0,
              let image = NSImage(contentsOf: pngURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 200, cg.height > 200 else {
            throw XCTSkip("screencapture unavailable / Screen Recording denied.")
        }
        defer { try? fm.removeItem(at: pngURL) }

        let w = cg.width, h = cg.height
        // The master pane is the LEFT column (~320pt of a 960pt window ≈ 33%).
        // Target a band BELOW the mode picker + search field (top ~14%) so the
        // variety we assert comes from the RESULT ROWS, not the chrome.
        let results = SourceViewVisualRegressionTests.Region(
            x: Int(Double(w) * 0.02), y: Int(Double(h) * 0.25),
            w: Int(Double(w) * 0.28), h: Int(Double(h) * 0.55),
            name: "results")

        let resultsOK = SourceViewVisualRegressionTests.regionHasVariety(in: cg, region: results)
        if !resultsOK {
            let kept = pngURL.deletingPathExtension().appendingPathExtension("fail.png")
            try? fm.copyItem(at: pngURL, to: kept)
            print("  → kept failing screenshot at \(kept.path)")
        }
        XCTAssertTrue(resultsOK,
            "Monitor content-search RESULTS region is uniform — the result rows "
            + "didn't composite (empty list, occluded, or the seeded search never "
            + "ran). Screenshot at \(pngURL.path)")
    }

    // MARK: - helpers

    /// Build a `~/.claude`-shaped fixture: `projects/<p>/<stem>.jsonl` with
    /// several events all containing `token`, across two sessions.
    private func makeFixtureClaudeRoot(token: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("CMVRT-\(UUID().uuidString)", isDirectory: true)
        func writeSession(project: String, stem: String, lines: [String]) throws {
            let dir = root
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(project, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try lines.joined(separator: "\n")
                .write(to: dir.appendingPathComponent("\(stem).jsonl"),
                       atomically: true, encoding: .utf8)
        }
        try writeSession(project: "alpha-proj", stem: "aaaa", lines: [
            #"{"type":"user","uuid":"u1","timestamp":"2026-06-04T10:00:00Z","message":{"role":"user","content":"please find the \#(token) in here"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"the \#(token) is on aisle five"}]}}"#,
        ])
        try writeSession(project: "beta-proj", stem: "bbbb", lines: [
            #"{"type":"user","uuid":"u2","timestamp":"2026-06-04T11:30:00Z","message":{"role":"user","content":"a \#(token) split into two"}}"#,
        ])
        return root
    }

    private func waitForWindowID(timeout: TimeInterval) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: Self.windowIDFile),
               let s = String(data: data, encoding: .utf8),
               let id = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0 {
                return id
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("App didn't publish windowNumber within \(timeout)s.")
    }
}
