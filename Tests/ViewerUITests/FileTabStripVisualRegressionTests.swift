import AppKit
import XCTest

/// REAL-PIXEL guards for the FILE tab strip (the top `TabBar`) — the three
/// owner-reported visuals that headless model tests cannot prove reached the
/// screen (the TSK-488 ImageRenderer false-green class):
///
///   - TSK-268: a 1-px separator is drawn after EVERY tab — including the
///     last — so the trailing tab has a visible right border.
///   - TSK-261: the "+" new-tab button sits BESIDE the last tab (inside the
///     scrolling content), not pinned at the strip's far-right edge.
///   - TSK-331: under crowding, tabs SHRINK toward the 40-pt floor so the
///     whole population stays on screen instead of overflowing.
///
/// Strategy: launch the app into the deterministic `tabs-<N>` scene
/// (Diagnostics.swift), screencapture the real window by id (stage-④
/// WindowServer pixels), then measure the strip STRUCTURALLY: detect the
/// thin vertical separator columns in the TabBar band and assert on their
/// count/positions, plus "ink" (non-background) presence for the "+" glyph.
/// Structural column detection is robust to theme/appearance; no absolute
/// colors are pinned.
///
/// Pixel-eval helpers are pure `static` functions, unit-tested headlessly on
/// synthetic images in `FileTabStripPixelEvalTests` (host gate); the live
/// captures run in the VM GUI lane only.
///
/// TIER-JUSTIFY: T5 — the observable is the WindowServer composite. The strip
/// is SwiftUI-drawn chrome whose visibility cannot be proven by ImageRenderer
/// or `cacheDisplay` (LESSONS.md compositor class).
final class FileTabStripVisualRegressionTests: PixelTestCase {

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

    /// TabBar band in WINDOW POINTS, measured from the top of the captured
    /// window: title bar (~28 pt) + SessionTabBar (46 pt) + divider, then the
    /// 30-pt TabBar row. The band is deliberately the strip's INNER rows
    /// (skip 2 pt top/bottom) so the strip's own horizontal bounding
    /// dividers don't pollute the vertical-column scan.
    /// Verified against a real VM capture via MDV_PIXEL_DEBUG_DIR.
    private static let stripTopPt = 77
    private static let stripBottomPt = 103

    // MARK: - tests

    /// TSK-268: with 2 tabs, the strip must show 2 full-height separator
    /// columns — one after EACH tab, including the last. The regression
    /// (divider gated `index < count-1`) leaves exactly 1.
    func test_lastTab_hasVisibleRightBorder() throws {
        let shot = try captureScene("tabs-2")
        let seps = Self.separatorColumns(
            in: shot.cg, xRange: 0 ..< shot.cg.width, yRange: shot.stripBand,
            scale: shot.scale)
        XCTAssertGreaterThanOrEqual(
            seps.count, 2,
            "Expected a separator after EVERY tab (2 tabs → ≥2 columns); got " +
            "\(seps.count) at \(seps). The last tab's right border is missing " +
            "again (TSK-268).")
        guard seps.count >= 2 else { return }
        // The two tab-edge separators are ~one tab-width apart (180 pt ideal,
        // uncrowded). Sanity-pin the structure so chrome noise can't fake it:
        // the gap between the first two columns is 100..260 pt.
        let gapPt = (seps[1] - seps[0]) / shot.scale
        XCTAssert(
            (100...260).contains(gapPt),
            "Separator columns at \(seps) (gap \(gapPt) pt) don't look like " +
            "tab edges — band/geometry drift, eyeball MDV_PIXEL_DEBUG_DIR.")
    }

    /// TSK-261: the "+" button renders just RIGHT of the last tab's
    /// separator, and the strip's far-right end is EMPTY (the old layout
    /// pinned the "+" at the far-right edge).
    func test_plusButton_sitsBesideLastTab_notFarRight() throws {
        let shot = try captureScene("tabs-2")
        let w = shot.cg.width
        let seps = Self.separatorColumns(
            in: shot.cg, xRange: 0 ..< w, yRange: shot.stripBand, scale: shot.scale)
        guard let last = seps.last, seps.count >= 2 else {
            throw XCTSkip("separator structure not detected — covered red by " +
                          "test_lastTab_hasVisibleRightBorder")
        }
        // "+" glyph ink in the 44-pt band beside the last tab edge.
        let besideBand = (last + 4 * shot.scale) ..< min(w, last + 44 * shot.scale)
        let besideInk = Self.inkPixelCount(
            in: shot.cg, xRange: besideBand, yRange: shot.stripBand)
        XCTAssertGreaterThan(
            besideInk, 8,
            "No '+' glyph ink in the 44-pt band beside the last tab " +
            "(x \(besideBand), band \(shot.stripBand)) — the new-tab button " +
            "is not sitting beside the last tab (TSK-261).")
        // Far-right 12% of the strip: no control there (the old pinned spot).
        let farRight = Int(Double(w) * 0.88) ..< w
        let farInk = Self.inkPixelCount(
            in: shot.cg, xRange: farRight, yRange: shot.stripBand)
        XCTAssertLessThanOrEqual(
            farInk, 8,
            "Unexpected control ink at the strip's far-right edge " +
            "(\(farInk) px) — the '+' looks pinned far-right again (TSK-261).")
    }

    /// TSK-331: 14 tabs in a default-width window must ALL stay on screen by
    /// shrinking (≥13 separator columns, pitch well under the 180-pt ideal).
    /// The regression (no shrink budget) leaves ~6 ideal-width tabs visible.
    func test_crowdedStrip_shrinksTabsInsteadOfOverflowing() throws {
        let shot = try captureScene("tabs-14")
        let w = shot.cg.width
        let seps = Self.separatorColumns(
            in: shot.cg, xRange: 0 ..< w, yRange: shot.stripBand, scale: shot.scale)
        XCTAssertGreaterThanOrEqual(
            seps.count, 13,
            "Only \(seps.count) tab separators visible for 14 tabs — the strip " +
            "is overflowing instead of shrinking (TSK-331). Columns: \(seps)")
        guard seps.count >= 3 else { return }
        // Median pitch must be SHRUNK: well below the 180-pt ideal.
        var pitches: [Int] = []
        for i in 1 ..< seps.count { pitches.append(seps[i] - seps[i - 1]) }
        let medianPt = pitches.sorted()[pitches.count / 2] / shot.scale
        XCTAssertLessThan(
            medianPt, 140,
            "Median tab pitch \(medianPt) pt — tabs did not shrink under " +
            "crowding (TSK-331).")
    }

    // MARK: - pixel eval (pure; headless-tested in FileTabStripPixelEvalTests)

    /// X positions (device px) of thin vertical separator lines spanning the
    /// band: columns whose luminance is darker than BOTH horizontal
    /// neighbours (±3 px) by ≥8/255 for ≥60% of the band rows. Adjacent
    /// qualifying columns (a 1-pt line is `scale` px wide) are clustered to
    /// their first column. Pure structure — no absolute color pinned.
    static func separatorColumns(
        in cg: CGImage, xRange: Range<Int>, yRange: Range<Int>, scale: Int
    ) -> [Int] {
        guard let lum = luminanceMap(cg) else { return [] }
        let w = cg.width
        let yLo = max(0, yRange.lowerBound), yHi = min(cg.height, yRange.upperBound)
        guard yHi > yLo else { return [] }
        let off = 3
        let xLo = max(off, xRange.lowerBound), xHi = min(w - off, xRange.upperBound)
        guard xHi > xLo else { return [] }

        var hits: [Int] = []
        for x in xLo ..< xHi {
            var dark = 0
            for y in yLo ..< yHi {
                let c = lum[y * w + x]
                let l = lum[y * w + (x - off)]
                let r = lum[y * w + (x + off)]
                if c + 8 <= l && c + 8 <= r { dark += 1 }
            }
            if Double(dark) >= 0.6 * Double(yHi - yLo) { hits.append(x) }
        }
        // Cluster adjacent columns (a 1-pt line is `scale` px wide, AA can
        // double it) into one detected line, keyed by the cluster's first x.
        var clustered: [Int] = []
        for x in hits {
            if let prev = clustered.last, x - prev <= 3 * max(1, scale) { continue }
            clustered.append(x)
        }
        return clustered
    }

    /// Count of "ink" pixels in the region — pixels darker than the region's
    /// own background (the median luminance) by ≥40/255. Detects small dark
    /// glyphs (the "+" / chevron) against any light chrome background.
    /// Light-on-dark themes flip the sign, so ink is |Δ| ≥ 40 either way.
    static func inkPixelCount(
        in cg: CGImage, xRange: Range<Int>, yRange: Range<Int>
    ) -> Int {
        guard let lum = luminanceMap(cg) else { return 0 }
        let w = cg.width
        let xLo = max(0, xRange.lowerBound), xHi = min(cg.width, xRange.upperBound)
        let yLo = max(0, yRange.lowerBound), yHi = min(cg.height, yRange.upperBound)
        guard xHi > xLo, yHi > yLo else { return 0 }
        var values: [Int] = []
        values.reserveCapacity((xHi - xLo) * (yHi - yLo))
        for y in yLo ..< yHi {
            for x in xLo ..< xHi { values.append(lum[y * w + x]) }
        }
        let median = values.sorted()[values.count / 2]
        return values.reduce(0) { $0 + (abs($1 - median) >= 40 ? 1 : 0) }
    }

    /// 0-255 luminance per pixel, row-major.
    static func luminanceMap(_ cg: CGImage) -> [Int]? {
        let bpr = cg.width * 4
        guard let ctx = CGContext(
            data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let ptr = buf.bindMemory(to: UInt8.self, capacity: cg.height * bpr)
        var lum = [Int](repeating: 0, count: cg.width * cg.height)
        for y in 0 ..< cg.height {
            for x in 0 ..< cg.width {
                let i = y * bpr + x * 4
                lum[y * cg.width + x] =
                    (299 * Int(ptr[i]) + 587 * Int(ptr[i + 1]) + 114 * Int(ptr[i + 2])) / 1000
            }
        }
        return lum
    }

    // MARK: - capture harness (mirrors TerminalTabStripVisualRegressionTests)

    private struct Shot {
        let cg: CGImage
        let scale: Int
        var stripBand: Range<Int> {
            (FileTabStripVisualRegressionTests.stripTopPt * scale)
                ..< (FileTabStripVisualRegressionTests.stripBottomPt * scale)
        }
    }

    /// Launch the app (NO positional file — the scene owns the tab count)
    /// into `MDV_UI_SCENE=<scene>`, capture the real window, return image +
    /// backing scale. XCTSkips in the headless gate / no bundle / no Screen
    /// Recording, so the heavy tier self-skips on the host.
    private func captureScene(_ scene: String) throws -> Shot {
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

        try? fm.removeItem(at: Self.windowIDFile)
        AppLauncher.killTestInstances(named: "MarkdownViewer")

        let caff = Process()
        caff.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caff.arguments = ["-u", "-t", "30"]
        try? caff.run()
        defer { if caff.isRunning { caff.terminate() } }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        p.arguments = []
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
        // Scene apply (0.6 s) + N file opens + first paint.
        Thread.sleep(forTimeInterval: 2.5)

        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-filetabs-\(scene)-\(UUID().uuidString).png")
        let capExit = runDisclaimedShell(
            "/usr/sbin/screencapture -l\(windowID) -x -o '\(pngURL.path)'")
        defer { try? fm.removeItem(at: pngURL) }
        guard capExit == 0, fm.fileExists(atPath: pngURL.path),
              let image = NSImage(contentsOf: pngURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 200, cg.height > 200 else {
            throw XCTSkip(
                "screencapture unavailable / Screen Recording denied. Grant " +
                "Screen Recording to the xctest runner (VM GUI lane).")
        }
        if let dbg = ProcessInfo.processInfo.environment["MDV_PIXEL_DEBUG_DIR"], !dbg.isEmpty {
            let dest = URL(fileURLWithPath: dbg).appendingPathComponent("\(scene).png")
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: pngURL, to: dest)
        }
        let scale = SourceViewVisualRegressionTests.capturedBackingScale(
            windowID: windowID, imagePixelWidth: cg.width)
        return Shot(cg: cg, scale: scale)
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
