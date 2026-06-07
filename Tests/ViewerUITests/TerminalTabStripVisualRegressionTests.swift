import AppKit
import XCTest

/// REAL-PIXEL visibility guard for the terminal tab strip (TSK-488 — the
/// recurring "I see a gap before the terminal but no tabs" report).
///
/// Why this tier exists, and why the headless `TerminalTabStripRenderTests`
/// could NOT catch the bug: the actual defect was COMPOSITOR OCCLUSION. The
/// terminal surface is an opaque, layer-backed `NSViewRepresentable`
/// (`TerminalNSView`); as a plain `HStack`/`VStack` sibling it overdrew the
/// SwiftUI-painted tab strip, so the rail reserved its space (the "gap") but
/// the chips never reached the screen. `ImageRenderer` rasterizes SwiftUI's
/// OWN drawing in isolation — it never instantiates the real opaque AppKit
/// layer, so it rendered the chips fine and reported a FALSE GREEN three
/// times running. Only stage ④ (the WindowServer composite, read via
/// `screencapture(1)`) exposes the occlusion. That is exactly the observable
/// this tier is for.
///
/// The fix (commit "tab strip occluded by opaque surface"): force each strip
/// into its own compositing layer ordered ABOVE the surface
/// (`.compositingGroup().zIndex(1)` vs the surface's `.zIndex(0)`). This test
/// fails if that ordering regresses — the accent-selected chip is a vivid
/// saturated swatch, so a dense block of saturated pixels in the configured
/// rail band proves the chip actually composited on screen.
///
/// Self-skips (same conditions as `SourceViewVisualRegressionTests`):
///   - the headless gate (`MDV_HEADLESS_GATE=1`) — heavy tier, VM/nightly only
///   - the `dist/` app isn't built
///   - Screen Recording is denied (screencapture returns a tiny/empty image)
///   - `MDV_SKIP_VISUAL` is set
///
/// To run interactively (owner lent the host for UI testing):
///   bash scripts/build-app.sh debug
///   swift test --filter TerminalTabStripVisualRegressionTests
///
/// TIER-JUSTIFY: T5 — the observable is stage ④ (WindowServer composite) read
/// via `screencapture(1)`. A `cacheDisplay` / `ImageRenderer` raster renders
/// the strip correctly while the live window is blank (the documented false
/// green), so this CANNOT be demoted to a headless tier.
final class TerminalTabStripVisualRegressionTests: PixelTestCase {

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

    /// The configured strip edge for a scene, used to assert the chip
    /// composited on the RIGHT side of the pane (not merely "somewhere").
    private enum Edge { case left, right, top }

    func test_leftRail_chipComposites() throws {
        try assertChipComposites(scene: "terminal-left", edge: .left)
    }

    func test_rightRail_chipComposites() throws {
        try assertChipComposites(scene: "terminal-right", edge: .right)
    }

    func test_topStrip_chipComposites() throws {
        try assertChipComposites(scene: "terminal-top", edge: .top)
    }

    /// Pane-EDGE placement (TSK-491): a right-DOCKED terminal must (1) composite
    /// its chip in the RIGHT column AND (2) leave the center content WebView
    /// painting (NOT blank). Guards the regression caught during development —
    /// nesting `bodyRow` in the side-dock HStack collapsed the content render;
    /// a chip-only check would have passed while the document went blank.
    func test_rightDockedPane_terminalComposites_andContentNotBlank() throws {
        let cg = try captureSceneCGImage("terminal-paneright")
        let w = cg.width, h = cg.height
        // (1) accent chip block in the RIGHT column band.
        let chip = Self.denseSaturatedBlock(
            in: cg, xRange: Int(Double(w) * 0.82) ..< w,
            yRange: Int(Double(h) * 0.10) ..< Int(Double(h) * 0.55))
        XCTAssertNotNil(chip,
            "right-docked terminal chip didn't composite in the right column (TSK-491)")
        // (2) center content region must NOT be blank (the collapse regression).
        let contentVaried = Self.regionHasVariety(
            in: cg,
            xRange: Int(Double(w) * 0.28) ..< Int(Double(w) * 0.78),
            yRange: Int(Double(h) * 0.12) ..< Int(Double(h) * 0.45))
        XCTAssertTrue(contentVaried,
            "center content went BLANK with a side-docked terminal — the content " +
            "WebView collapsed (side-dock must not nest bodyRow). TSK-491")
    }

    // MARK: - core

    /// Launch the app into `scene`, screen-capture the window, and assert a
    /// dense saturated chip block composited in the band for `edge`.
    private func assertChipComposites(scene: String, edge: Edge) throws {
        let cg = try captureSceneCGImage(scene)
        let w = cg.width, h = cg.height
        // The terminal pane occupies the bottom of the window; the status
        // bar is the bottom ~50px. The vertical-rail chips sit near the
        // pane's TOP, so the band starts at ~52% of the window height to
        // cover the whole open pane.
        let yLo = Int(Double(h) * 0.52)
        let yHi = max(yLo + 1, h - 50)
        let xRange: Range<Int>
        switch edge {
        case .left:  xRange = 0 ..< (w / 2)            // chip in the left half
        case .right: xRange = (w / 2) ..< w            // chip in the right half
        case .top:   xRange = 0 ..< w                  // horizontal strip spans width
        }

        let block = Self.denseSaturatedBlock(in: cg, xRange: xRange, yRange: yLo ..< yHi)
        XCTAssertNotNil(
            block,
            "No accent-selected chip composited in the \(edge) rail band for scene " +
            "'\(scene)'. The opaque terminal surface is occluding the SwiftUI tab " +
            "strip again (the 'gap but no tabs' regression).")
    }

    /// Launch the app into `scene` via `MDV_UI_SCENE`, capture its real window
    /// through the WindowServer (`screencapture -l<id>`), and return the decoded
    /// CGImage. Throws `XCTSkip` in the headless gate / when the bundle isn't
    /// built / Screen Recording is denied — so the heavy tier self-skips on the
    /// host and runs for real only in the VM/nightly lane.
    private func captureSceneCGImage(_ scene: String) throws -> CGImage {
        if ProcessInfo.processInfo.environment["MDV_HEADLESS_GATE"] == "1" {
            throw XCTSkip("T5 heavy tier — runs in the VM/nightly lane, not the headless gate.")
        }
        let fm = FileManager.default
        let appExe = Self.appBundlePath + "/Contents/MacOS/MarkdownViewer"
        guard fm.isExecutableFile(atPath: appExe) else {
            throw XCTSkip("App not built. Run `bash scripts/build-app.sh debug`.")
        }
        guard !ProcessInfo.processInfo.environment.keys.contains("MDV_SKIP_VISUAL") else {
            throw XCTSkip("MDV_SKIP_VISUAL set.")
        }

        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let openFile = here.appendingPathComponent("DESIGN.md")

        try? fm.removeItem(at: Self.windowIDFile)
        // Reap only leaked TEST instances (MDV_TEST_INSTANCE=1) — never a
        // blanket killall (shared exec name reaps the owner's running app).
        AppLauncher.killTestInstances(named: "MarkdownViewer")

        // Keep the display awake — a slept/locked display can't be captured.
        let caff = Process()
        caff.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caff.arguments = ["-u", "-t", "30"]
        try? caff.run()
        defer { if caff.isRunning { caff.terminate() } }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        p.arguments = [openFile.path]
        var env = ProcessInfo.processInfo.environment
        env["MDV_UI_SCENE"] = scene
        env["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        env["MDV_TEST_INSTANCE"] = "1"
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

        let windowID = try waitForWindowID(timeout: 3.0)
        _ = try? shell([
            "/usr/bin/osascript", "-e",
            "tell application \"MarkdownViewer\" to activate",
        ])
        // Scene-apply delay (0.6s) + open animation + first paint. Matches
        // ui-snapshot.sh's budget.
        Thread.sleep(forTimeInterval: 2.5)

        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-term-\(scene)-\(UUID().uuidString).png")
        let res = try shell([
            "/usr/sbin/screencapture", "-l\(windowID)", "-x", "-o", pngURL.path,
        ])
        defer { try? fm.removeItem(at: pngURL) }
        guard res.exit == 0, fm.fileExists(atPath: pngURL.path),
              let image = NSImage(contentsOf: pngURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 200, cg.height > 200 else {
            throw XCTSkip(
                "screencapture unavailable / Screen Recording denied. On macOS 15+, " +
                "grant Screen Recording to both Terminal AND " +
                "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest.")
        }
        return cg
    }

    // MARK: - pixel eval

    /// Scans `xRange × yRange` for a SATURATED pixel whose 33×33 neighborhood
    /// (sampled every 4px) is ≥60% saturated — a dense vivid block, i.e. the
    /// solid accent chip swatch. This rejects the scattered saturated chrome
    /// pixels (sidebar/status glyphs) that an "any saturated pixel" check
    /// false-passes on. Mirrors `scripts/ui-snapshot.sh`'s eval.
    static func denseSaturatedBlock(in cg: CGImage, xRange: Range<Int>, yRange: Range<Int>) -> (x: Int, y: Int)? {
        let bytesPerPixel = 4
        let bpr = cg.width * bytesPerPixel
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: bpr, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let ptr = buf.bindMemory(to: UInt8.self, capacity: cg.height * bpr)

        func saturated(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < cg.width, y >= 0, y < cg.height else { return false }
            let i = y * bpr + x * 4
            let r = Int(ptr[i]), g = Int(ptr[i + 1]), b = Int(ptr[i + 2])
            return (max(r, g, b) - min(r, g, b)) > 90
        }
        func dense(_ cx: Int, _ cy: Int) -> Bool {
            var tot = 0, sat = 0
            var dy = -16
            while dy <= 16 {
                var dx = -16
                while dx <= 16 {
                    let x = cx + dx, y = cy + dy
                    if x >= 0, x < cg.width, y >= 0, y < cg.height {
                        tot += 1
                        if saturated(x, y) { sat += 1 }
                    }
                    dx += 4
                }
                dy += 4
            }
            return tot > 0 && Double(sat) / Double(tot) >= 0.6
        }

        let xLo = max(0, xRange.lowerBound), xHi = min(cg.width, xRange.upperBound)
        let yLo = max(0, yRange.lowerBound), yHi = min(cg.height, yRange.upperBound)
        var y = yLo
        while y < yHi {
            var x = xLo
            while x < xHi {
                if saturated(x, y) && dense(x, y) { return (x, y) }
                x += 4
            }
            y += 4
        }
        return nil
    }

    /// True if `xRange × yRange` contains ≥4 distinct 4-bit-quantized colors —
    /// i.e. the region is NOT a flat solid blob. Used to prove the content
    /// WebView actually painted (a blank/collapsed pane is one uniform colour).
    /// Same idea as `SourceViewVisualRegressionTests.regionHasVariety`.
    static func regionHasVariety(in cg: CGImage, xRange: Range<Int>, yRange: Range<Int>) -> Bool {
        let bpr = cg.width * 4
        guard let ctx = CGContext(
            data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = ctx.data else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let ptr = buf.bindMemory(to: UInt8.self, capacity: cg.height * bpr)
        let xLo = max(0, xRange.lowerBound), xHi = min(cg.width, xRange.upperBound)
        let yLo = max(0, yRange.lowerBound), yHi = min(cg.height, yRange.upperBound)
        guard xHi > xLo, yHi > yLo else { return false }
        var seen = Set<Int>()
        let xStep = max(1, (xHi - xLo) / 80), yStep = max(1, (yHi - yLo) / 40)
        var y = yLo
        while y < yHi {
            var x = xLo
            while x < xHi {
                let i = y * bpr + x * 4
                let r = Int(ptr[i]) >> 4, g = Int(ptr[i + 1]) >> 4, b = Int(ptr[i + 2]) >> 4
                seen.insert((r << 8) | (g << 4) | b)
                if seen.count >= 4 { return true }
                x += xStep
            }
            y += yStep
        }
        return seen.count >= 4
    }

    // MARK: - harness (mirrors SourceViewVisualRegressionTests)

    private func waitForWindowID(timeout: TimeInterval) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: Self.windowIDFile),
               let s = String(data: data, encoding: .utf8),
               let id = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)),
               id > 0 {
                return id
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("App didn't publish windowNumber within \(timeout)s. Did it launch?")
    }

    private struct ShellResult { let exit: Int32 }
    private func shell(_ argv: [String]) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError  = FileHandle(forWritingAtPath: "/dev/null")
        try p.run()
        p.waitUntilExit()
        return ShellResult(exit: p.terminationStatus)
    }
}
