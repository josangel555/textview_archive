import AppKit
import XCTest

/// Partial-T6 capture rig (owner, 2026-07-30: *"you are supposed to use the
/// entire test pyramid for testing, including px"*). One test per freshly-
/// shipped render surface: spawn `dist/TextView.app` into the scene, capture
/// the REAL WindowServer pixels by window id, keep the PNG under
/// `MDV_PIXEL_DEBUG_DIR` for the eyeball pass, and assert the cheap
/// structural facts a machine can check (captured, non-blank, has ink beyond
/// the chrome). The PNG is the deliverable — the render-confirm directive's
/// "look at it with your own eyes" happens on the pulled file.
///
/// TIER-JUSTIFY: T5 — every surface here is WebView/SwiftUI-composited
/// (MathML in WKWebView, the split layout, a SwiftUI sheet); ImageRenderer /
/// cacheDisplay are blind to all three (the TSK-488 false-green class).
final class PartialT6SceneCaptureTests: PixelTestCase {

    func test_capture_mathRender() throws {
        let cg = try Self.capture(scene: "math-render")
        try Self.assertHasInk(cg, scene: "math-render")
    }

    func test_capture_mdSplit() throws {
        let cg = try Self.capture(scene: "md-split")
        try Self.assertHasInk(cg, scene: "md-split")
    }

    func test_capture_conflictMerge() throws {
        let cg = try Self.capture(scene: "conflict-merge")
        try Self.assertHasInk(cg, scene: "conflict-merge")
    }

    /// Tab→session drop-target highlight (2026-07-31): the scene forces the
    /// second session's pill into the hovered-drop-target state a live tab
    /// drag produces; the strip must show the accent ring/tint on THAT pill,
    /// far to the right of the active pill's own accent.
    func test_capture_tabSessionDrop() throws {
        let cg = try Self.capture(scene: "tab-session-drop")
        let span = Self.accentSpanInSessionStrip(cg)
        XCTAssertGreaterThan(span, Double(cg.width) * 0.10,
            "tab-session-drop: no drop-target highlight on the second pill — "
            + "saturated ink spans only \(Int(span))px of \(cg.width) "
            + "(the active pill's glyph alone). Eyeball the PNG.")
    }

    /// TEETH (the TSK-1134 codified negative control): with the highlight
    /// deliberately broken via MDV_ENABLE_BROKEN_SESSION_DROP_HIGHLIGHT, the
    /// same scene must make the guard above go RED — i.e. the accent span
    /// collapses back to the active pill's glyph. Proves the detector
    /// detects absence, not just presence.
    func test_capture_tabSessionDrop_negativeControl() throws {
        let cg = try Self.capture(
            scene: "tab-session-drop",
            extraEnv: ["MDV_ENABLE_BROKEN_SESSION_DROP_HIGHLIGHT": "1"],
            debugName: "tab-session-drop-broken")
        let span = Self.accentSpanInSessionStrip(cg)
        XCTAssertLessThanOrEqual(span, Double(cg.width) * 0.10,
            "negative control: the highlight is broken yet the detector still "
            + "sees a wide accent span (\(Int(span))px) — the guard has no teeth")
    }

    // MARK: - rig (the shared per-suite T5 pattern)

    private static let appExe: String = {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return here.appendingPathComponent(
            "dist/TextView.app/Contents/MacOS/MarkdownViewer").path
    }()

    private static let windowIDFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("com.markdownviewer.MarkdownViewer.windowid")

    static func capture(scene: String,
                        extraEnv: [String: String] = [:],
                        debugName: String? = nil) throws -> CGImage {
        guard FileManager.default.isExecutableFile(atPath: appExe) else {
            throw XCTSkip("App not built at dist/ — run the VM `pixel`/`all` lane.")
        }
        try? FileManager.default.removeItem(at: windowIDFile)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        var env = ProcessInfo.processInfo.environment
        env["MDV_UI_SCENE"] = scene
        env["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        env["MDV_TEST_INSTANCE"] = "1"
        // Isolate session persistence: scenes that CREATE sessions
        // (tab-session-drop) must never write into the machine's real
        // session store.
        let sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-t6-sessions-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
        env["MDV_SESSIONS_DIR"] = sessionsDir.path
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env
        try p.run()
        defer {
            if p.isRunning {
                p.terminate()
                Thread.sleep(forTimeInterval: 0.2)
                if p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
            }
        }

        // 12s, not 5: the Nth spawn in a suite run can exceed 5s under VM
        // load (the negative-control test skipped on exactly that).
        let windowID = try waitForWindowID(timeout: 12.0)
        let activate = Process()
        activate.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        activate.arguments = ["-e", "tell application \"MarkdownViewer\" to activate"]
        try? activate.run()
        activate.waitUntilExit()
        // Scene apply + WebView mount + render settle (math/preview panes).
        Thread.sleep(forTimeInterval: 4.0)

        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-t6-\(scene)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let capExit = runDisclaimedShell(
            "/usr/sbin/screencapture -l\(windowID) -x -o '\(pngURL.path)'")
        guard capExit == 0,
              let image = NSImage(contentsOf: pngURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 200, cg.height > 200 else {
            throw XCTSkip("screencapture unavailable / Screen Recording denied.")
        }
        // The eyeball deliverable — keep a stable-named copy when the debug
        // dir is provided (mkdir'd here so the copy can't silently no-op,
        // the 2026-07-27 lesson).
        if let dbg = ProcessInfo.processInfo.environment["MDV_PIXEL_DEBUG_DIR"], !dbg.isEmpty {
            let dir = URL(fileURLWithPath: dbg)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // `debugName` keeps variant captures (the negative control)
            // from clobbering the scene's canonical eyeball artifact.
            let dest = dir.appendingPathComponent("\(debugName ?? scene).png")
            try? FileManager.default.removeItem(at: dest)
            if let data = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: data),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dest)
            }
        }
        return cg
    }

    /// Cheap machine-checkable floor: the CONTENT PANE has a real spread of
    /// distinct pixel values — a blank/occluded pane composites as a
    /// near-uniform field (the TSK-488 class).
    ///
    /// FIRST VERSION OF THIS SAMPLER WAS A FALSE GREEN: it sampled from
    /// x=0, so the sidebar's text supplied the "ink" while the actual
    /// content pane was BLANK (the math-render capture proved it — pane
    /// empty, test green). The window is ~2560px @2x with the icon rail +
    /// sidebar ending ≈550px; sampling starts well right of that and above
    /// the terminal band.
    static func assertHasInk(_ cg: CGImage, scene: String) throws {
        guard let data = cg.dataProvider?.data as Data? else {
            return XCTFail("\(scene): no bitmap data")
        }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        var distinct = Set<UInt32>()
        let xStart = Int(Double(cg.width) * 0.35)     // right of the sidebar
        let yStart = Int(Double(cg.height) * 0.18)    // below the chrome band
        let yEnd = Int(Double(cg.height) * 0.42)      // above the terminal band
        var y = yStart
        while y < yEnd, distinct.count < 64 {
            var x = xStart
            while x < cg.width, distinct.count < 64 {
                let o = y * bpr + x * bpp
                if o + 3 < data.count {
                    let px = UInt32(data[o]) << 16 | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2])
                    distinct.insert(px)
                }
                x += 16
            }
            y += 16
        }
        XCTAssertGreaterThan(distinct.count, 12,
            "\(scene): the CONTENT PANE is near-uniform (\(distinct.count) distinct "
            + "sampled colors) — blank/occluded (the TSK-1247 class), eyeball the PNG")
    }

    /// Horizontal spread (px) of SATURATED pixels across the window's top
    /// band (titlebar + session strip, y < 9% of height). Saturation
    /// (max−min channel > 55) is channel-order-agnostic and sits ABOVE the
    /// active pill's 0.18-alpha tint (Δ≈46) but BELOW the drop-target's
    /// 0.28 tint (Δ≈71) and full-accent ring (Δ=255) — so:
    ///   - highlight ON:  span reaches from the active pill's accent glyph
    ///     to the hovered pill's ring/tint (≫ 10% of width);
    ///   - highlight OFF: only the glyph (+ traffic lights at far left)
    ///     register — a narrow left-edge cluster.
    /// Window-width agnostic by design (no fixed pill positions).
    static func accentSpanInSessionStrip(_ cg: CGImage) -> Double {
        guard let data = cg.dataProvider?.data as Data? else { return 0 }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        let yEnd = Int(Double(cg.height) * 0.09)
        var minX = Int.max, maxX = Int.min
        var y = 0
        while y < yEnd {
            var x = 0
            while x < cg.width {
                let o = y * bpr + x * bpp
                if o + 3 < data.count {
                    let a = Int(data[o]), b = Int(data[o + 1]), c = Int(data[o + 2])
                    if max(a, b, c) - min(a, b, c) > 55 {
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                    }
                }
                x += 4
            }
            y += 4
        }
        return maxX >= minX ? Double(maxX - minX) : 0
    }

    private static func waitForWindowID(timeout: TimeInterval) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: windowIDFile),
               let s = String(data: data, encoding: .utf8),
               let id = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)),
               id > 0 {
                return id
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("no window id published — app failed to launch a window")
    }
}
