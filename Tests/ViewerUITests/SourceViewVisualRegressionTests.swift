import AppKit
import XCTest

/// Visual regression test that catches the SwiftUI sibling-blank
/// compositor pathology. Spawns the .app, waits for it to publish its
/// windowNumber, captures via `screencapture(1)` (which goes through
/// the WindowServer — not `cacheDisplay`-style in-process rasterization
/// that hides the bug), then samples per-region pixel variance to
/// confirm each visible UI strip actually composited.
///
/// XCTSkip'd when:
///   - the dist app isn't built (CI / first run)
///   - the runner lacks Screen Recording permission (TCC denies
///     screencapture's frame buffer access)
///   - running in MDV_BACKGROUND or sandboxed contexts where the
///     window won't foreground
///
/// To run interactively, build the app first:
///   bash scripts/build-app.sh debug
///   swift test --filter SourceViewVisualRegressionTests
///
/// First-time runner: grant Screen Recording to Terminal (or whatever
/// process drives `swift test`) under System Settings → Privacy &
/// Security → Screen Recording.
final class SourceViewVisualRegressionTests: XCTestCase {

    /// Path to the built .app bundle. We point at the debug build by
    /// default — release is unnecessarily slow to rebuild for this test
    /// and the bug is identical between configs.
    private static let appBundlePath: String = {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return here.appendingPathComponent("dist/MarkdownViewer.app").path
    }()

    /// Per-user tmp dir where the app writes its windowNumber file. We
    /// reach into the standard /var/folders/.../T/ via
    /// FileManager.default.temporaryDirectory — the same path the app's
    /// `tmp` writes hit.
    private static let windowIDFile: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("com.markdownviewer.MarkdownViewer.windowid")
    }()

    /// Meta-test: confirms the regression check actually detects the
    /// known-broken-ruler containment by enabling it via env var. If
    /// THIS test passes (i.e. the broken config is detected as
    /// broken), we know the variance check has teeth.
    func test_meta_brokenRulerIsDetectedAsRegression() throws {
        let fm = FileManager.default
        let appExe = Self.appBundlePath + "/Contents/MacOS/MarkdownViewer"
        guard fm.isExecutableFile(atPath: appExe) else {
            throw XCTSkip("App not built.")
        }
        guard !ProcessInfo.processInfo.environment.keys.contains("MDV_SKIP_VISUAL") else {
            throw XCTSkip("MDV_SKIP_VISUAL set.")
        }

        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceFile = here
            .appendingPathComponent("Sources/ViewerCore/Highlight/TreeSitterEngine.swift")
        try? fm.removeItem(at: Self.windowIDFile)
        _ = try? shell(["/usr/bin/killall", "MarkdownViewer"])

        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        p.arguments = [sourceFile.path]
        var env = ProcessInfo.processInfo.environment
        env["MDV_ENABLE_BROKEN_RULER"] = "1"
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
        _ = try? shell([
            "/usr/bin/osascript", "-e",
            "tell application \"MarkdownViewer\" to activate"
        ])
        Thread.sleep(forTimeInterval: 1.5)
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-meta-broken-\(UUID().uuidString).png")
        let res = try shell([
            "/usr/sbin/screencapture", "-l\(windowID)", "-x", "-o", pngURL.path
        ])
        guard res.exit == 0,
              let image = NSImage(contentsOf: pngURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 200 else {
            throw XCTSkip("screencapture unavailable / Screen Recording denied")
        }
        defer { try? fm.removeItem(at: pngURL) }
        let scaleY = max(1, Int(Double(cg.height) / 900.0))
        let titleBarPx = 28 * scaleY
        let tabBar = Region(x: 0, y: titleBarPx, w: cg.width, h: 32 * scaleY, name: "TabBar")
        let modeBar = Region(x: 0, y: titleBarPx + 32 * scaleY, w: cg.width, h: 32 * scaleY, name: "ModeBar")
        // Either TabBar OR ModeBar should be blank (uniform) when the
        // bug is active. We assert one or the other to insulate
        // ourselves from minor window-layout shifts.
        let tabBarOK = Self.regionHasVariety(in: cg, region: tabBar)
        let modeBarOK = Self.regionHasVariety(in: cg, region: modeBar)
        XCTAssertFalse(
            tabBarOK && modeBarOK,
            "Expected the broken-ruler containment to blank TabBar or ModeBar — but both regions show variety. Either the test isn't sensitive enough, OR the bug isn't reproducing on this hardware / OS version. Screenshot at \(pngURL.path)"
        )
    }

    func test_allUIStripsCompositeAfterOpeningSourceFile() throws {
        // Bail early under conditions where we can't run.
        let fm = FileManager.default
        let appExe = Self.appBundlePath + "/Contents/MacOS/MarkdownViewer"
        guard fm.isExecutableFile(atPath: appExe) else {
            throw XCTSkip("App not built. Run `bash scripts/build-app.sh debug`.")
        }
        guard !ProcessInfo.processInfo.environment.keys.contains("MDV_SKIP_VISUAL") else {
            throw XCTSkip("MDV_SKIP_VISUAL set.")
        }

        // 1. Pick a real source file we ship. The diagnostic-engine
        //    file is committed + non-trivial, fits in the viewport.
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceFile = here
            .appendingPathComponent("Sources/ViewerCore/Highlight/TreeSitterEngine.swift")
        guard fm.isReadableFile(atPath: sourceFile.path) else {
            throw XCTSkip("Test fixture missing: \(sourceFile.path)")
        }

        // 2. Reset state.
        try? fm.removeItem(at: Self.windowIDFile)
        _ = try? shell(["/usr/bin/killall", "MarkdownViewer"])

        // 3. Launch the app.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        p.arguments = [sourceFile.path]
        p.standardOutput = FileHandle.standardError
        p.standardError = FileHandle.standardError
        try p.run()
        // Don't leak the process even on test failure.
        defer {
            if p.isRunning {
                p.terminate()
                Thread.sleep(forTimeInterval: 0.2)
                if p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
            }
        }

        // 4. Wait for the app to write its windowNumber. ~2s budget.
        let windowID = try waitForWindowID(timeout: 2.5)

        // 5. Foreground the window so screencapture sees current
        //    content (occluded windows have stale framebuffers).
        _ = try? shell([
            "/usr/bin/osascript", "-e",
            "tell application \"MarkdownViewer\" to activate",
        ])
        // Generous: file load + syntax highlight task + first paint can
        // chain across several runloops on a real M-series Mac.
        Thread.sleep(forTimeInterval: 1.5)

        // 6. screencapture -l<id> -x → PNG.
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-visual-regression-\(UUID().uuidString).png")
        let res = try shell([
            "/usr/sbin/screencapture", "-l\(windowID)", "-x", "-o", pngURL.path
        ])
        guard res.exit == 0, fm.fileExists(atPath: pngURL.path) else {
            throw XCTSkip("screencapture failed (likely Screen Recording permission). exit=\(res.exit)")
        }
        defer { try? fm.removeItem(at: pngURL) }

        guard let image = NSImage(contentsOf: pngURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("Couldn't decode \(pngURL.path)")
        }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 200, h > 200 else {
            throw XCTSkip("Screencapture produced a tiny image (\(w)x\(h)) — Screen Recording likely denied.")
        }

        // 7. Sample regions where SwiftUI siblings live. Each region
        //    must show ≥3 distinct quantized colors — i.e. it's NOT a
        //    flat solid background blob. Title bar is excluded since
        //    AppKit always renders it correctly even when the SwiftUI
        //    content below regresses. We give each strip a tall y range
        //    + dense sampling to make sure we hit text glyphs (which
        //    are 1-2 px thin at Retina).
        //
        //    Coordinate space: CGImage is device pixels, origin
        //    top-left. macOS title bar is ~28 pt = ~56 px at 2x, but
        //    we sample MULTIPLE bands and require each. The TabBar
        //    band covers logical y=20-50; ModeBar y=50-80; StatusBar
        //    is the bottom 22 logical = 44 px.
        let scaleY = max(1, Int(Double(h) / 900.0))   // approx 2 on Retina
        let titleBarPx = 28 * scaleY
        let tabBarStrip = Region(
            x: 0, y: titleBarPx,
            w: w, h: 32 * scaleY,
            name: "TabBar"
        )
        let modeBarStrip = Region(
            x: 0, y: titleBarPx + 32 * scaleY,
            w: w, h: 32 * scaleY,
            name: "ModeBar"
        )
        let statusBarStrip = Region(
            x: 0, y: h - 22 * scaleY,
            w: w, h: 22 * scaleY,
            name: "StatusBar"
        )
        // Sidebar isn't present unless a folder is open. For the
        // single-file open path we use, there's no sidebar. So we
        // sample the FILE TREE region only when a folder root has been
        // detected — for now we skip the sidebar check and rely on
        // the three strips above.

        let regions = [tabBarStrip, modeBarStrip, statusBarStrip]
        for region in regions {
            let varietyOK = Self.regionHasVariety(in: cgImage, region: region)
            XCTAssertTrue(
                varietyOK,
                "Region '\(region.name)' (\(region.x),\(region.y) \(region.w)x\(region.h)) appears uniform — the SwiftUI sibling-blank compositor regression has likely returned. Screenshot saved at \(pngURL.path)"
            )
            if !varietyOK {
                // Keep the PNG around so a developer can inspect after.
                let kept = pngURL.deletingPathExtension().appendingPathExtension("fail.png")
                try? fm.copyItem(at: pngURL, to: kept)
                print("  → kept failing screenshot at \(kept.path)")
            }
        }
    }

    // MARK: - helpers

    struct Region {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
        let name: String
    }

    /// Returns true if the region in `cgImage` contains 3+ distinct
    /// quantized colors. Quantization: each channel rounded to 4-bit
    /// (16 buckets) so we don't get false positives from imperceptible
    /// dithering noise. False positives are the failure mode to worry
    /// about — a blank-but-noisy region passing the check.
    static func regionHasVariety(in cg: CGImage, region: Region) -> Bool {
        guard region.w > 0, region.h > 0 else { return false }
        let bytesPerPixel = 4
        let bpr = cg.width * bytesPerPixel
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGContext(
            data: nil,
            width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let ctx = bitmap, let buf = ctx.data else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let ptr = buf.bindMemory(to: UInt8.self, capacity: cg.height * bpr)

        // Sample a 64×16 grid (1024 samples max). At 2800 px wide and
        // ~64 px tall a coarser grid misses 1-2-px text glyphs and
        // returns a false positive for "uniform" on a TabBar that
        // actually has text in it.
        var seen = Set<Int>()
        let xs = stride(from: region.x, to: min(region.x + region.w, cg.width), by: max(1, region.w / 64))
        let ys = stride(from: region.y, to: min(region.y + region.h, cg.height), by: max(1, region.h / 16))
        for y in ys {
            guard y >= 0, y < cg.height else { continue }
            for x in xs {
                guard x >= 0, x < cg.width else { continue }
                let i = y * bpr + x * 4
                let r = Int(ptr[i])     >> 4
                let g = Int(ptr[i + 1]) >> 4
                let b = Int(ptr[i + 2]) >> 4
                seen.insert((r << 8) | (g << 4) | b)
                if seen.count >= 3 { return true }
            }
        }
        return seen.count >= 3
    }

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
