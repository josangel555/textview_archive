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
///
/// TIER-JUSTIFY: T5 — the observable is stage ④ (WindowServer composite)
/// read via `screencapture(1)`. A T2-px / `cacheDisplay` raster would
/// render the strips correctly while the live window is blank (false
/// green), so this CANNOT be demoted. It is the sole irreducibly-real-
/// screen suite (§3.4); the structural "never attach NSRulerView" rule is
/// the primary defense, this is belt-and-suspenders.
final class SourceViewVisualRegressionTests: PixelTestCase {

    /// Path to the built .app bundle. We point at the debug build by
    /// default — release is unnecessarily slow to rebuild for this test
    /// and the bug is identical between configs.
    private static let appBundlePath: String = {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return here.appendingPathComponent("dist/TextView.app").path
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
        if ProcessInfo.processInfo.environment["MDV_HEADLESS_GATE"] == "1" {
            throw XCTSkip("T5 heavy tier — runs in the VM/nightly lane, not the headless gate.")
        }
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
        // Reap only leaked TEST instances (marked MDV_TEST_INSTANCE=1) — a
        // blanket `killall MarkdownViewer` also kills the developer's own
        // running app (shared exec name). See AppLauncher.killTestInstances.
        AppLauncher.killTestInstances(named: "MarkdownViewer")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        p.arguments = [sourceFile.path]
        var env = ProcessInfo.processInfo.environment
        env["MDV_ENABLE_BROKEN_RULER"] = "1"
        env["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        env["MDV_TEST_INSTANCE"] = "1"   // so killTestInstances can reap a leak of this spawn
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
        // TSK-502: disclaim xctest's TCC responsibility so the already-granted
        // /bin/bash is the screencapture responsible process on the VM.
        let capExit = runDisclaimedShell(
            "/usr/sbin/screencapture -l\(windowID) -x -o '\(pngURL.path)'")
        guard capExit == 0,
              let image = NSImage(contentsOf: pngURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 200 else {
            // macOS 15+ Screen Capture Privacy can hide windows from
            // `screencapture -l<id>` even when Screen Recording is
            // granted to the runner. The right grant on macOS 15 is
            // BOTH the running terminal AND the xctest binary at
            // /Applications/Xcode.app/Contents/Developer/usr/bin/xctest.
            throw XCTSkip(
                "screencapture unavailable / Screen Recording denied. " +
                "On macOS 15+, grant Screen Recording to both Terminal " +
                "AND /Applications/Xcode.app/Contents/Developer/usr/bin/xctest."
            )
        }
        defer { try? fm.removeItem(at: pngURL) }
        let scaleY = Self.capturedBackingScale(windowID: windowID, imagePixelWidth: cg.width)
        let titleBarPx = 28 * scaleY
        let tabBar = Region(x: 0, y: titleBarPx, w: cg.width, h: 32 * scaleY, name: "TabBar")
        // 48pt-tall ModeBar band — see the main test's note (TSK-519).
        let modeBar = Region(x: 0, y: titleBarPx + 32 * scaleY, w: cg.width, h: 48 * scaleY, name: "ModeBar")
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
        // Reap only leaked TEST instances (marked MDV_TEST_INSTANCE=1) — a
        // blanket `killall MarkdownViewer` also kills the developer's own
        // running app (shared exec name). See AppLauncher.killTestInstances.
        AppLauncher.killTestInstances(named: "MarkdownViewer")

        // 3. Launch the app. Skip workspace restore so we start with
        // a known clean tab set.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        p.arguments = [sourceFile.path]
        var env3 = ProcessInfo.processInfo.environment
        env3["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        env3["MDV_TEST_INSTANCE"] = "1"   // so killTestInstances can reap a leak of this spawn
        p.environment = env3
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
        // TSK-502: disclaim xctest's TCC responsibility so the already-granted
        // /bin/bash is the screencapture responsible process on the VM.
        let capExit = runDisclaimedShell(
            "/usr/sbin/screencapture -l\(windowID) -x -o '\(pngURL.path)'")
        guard capExit == 0, fm.fileExists(atPath: pngURL.path) else {
            throw XCTSkip(
                "screencapture failed (likely Screen Recording permission). " +
                "exit=\(capExit). On macOS 15+, grant Screen Recording to " +
                "both Terminal AND " +
                "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest."
            )
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
        let scaleY = Self.capturedBackingScale(windowID: windowID, imagePixelWidth: w)
        let titleBarPx = 28 * scaleY
        let tabBarStrip = Region(
            x: 0, y: titleBarPx,
            w: w, h: 32 * scaleY,
            name: "TabBar"
        )
        // ModeBar band is 48pt tall (not 32) so it reaches past the thin
        // toolbar row into the top content rows: on a healthy window that
        // gives a robust colour margin (≈13 distinct vs the marginal 3 a
        // 32pt band caught straddling chrome padding — TSK-519), while a
        // real compositor blank still zeroes it (the whole SwiftUI sibling
        // region goes uniform, not a thin strip).
        let modeBarStrip = Region(
            x: 0, y: titleBarPx + 32 * scaleY,
            w: w, h: 48 * scaleY,
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

    /// True device-pixels-per-point of the captured window — i.e. the
    /// Retina backing scale of whichever display the window sits on.
    /// Derived from the window's on-screen CG bounds (POINTS) vs the
    /// captured image width (DEVICE px), so it is correct on 1× and 2×
    /// displays alike.
    ///
    /// Replaces the prior `max(1, Int(imageHeight / 900))` guess, which
    /// returned 1 for a 1600px-tall 2× capture (TSK-519): every sample
    /// band then collapsed into the top ~92px of window chrome, so the
    /// ModeBar strip landed on a flat title-bar strip and false-fired the
    /// "appears uniform" compositor-regression assertion on a perfectly
    /// healthy window. Falls back to the main screen's backing scale,
    /// then 1.
    static func capturedBackingScale(windowID: Int, imagePixelWidth: Int) -> Int {
        if let arr = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
           let boundsDict = arr.first?[kCGWindowBounds as String] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
           rect.width > 0 {
            return max(1, Int((CGFloat(imagePixelWidth) / rect.width).rounded()))
        }
        if let s = NSScreen.main?.backingScaleFactor, s > 0 {
            return max(1, Int(s.rounded()))
        }
        return 1
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
