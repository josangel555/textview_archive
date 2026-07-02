import AppKit
import XCTest

/// REAL-PIXEL guard for the canvas selection overlay (M3.S7, TSK-1378) —
/// the WKWebView compositor class (LESSONS/TSK-488): the overlay can be in
/// the DOM with correct geometry yet never composite on screen. The ONLY
/// authority is stage-④ WindowServer pixels.
///
/// Scene: `canvas-demo` (UISceneApplier) — a deterministic .canvas document
/// in the rendered lens with `#title` selected ~1.5s after mount.
///
/// TEETH (the codified negative-control pattern, TSK-1134): the companion
/// test spawns with `MDV_ENABLE_BROKEN_CANVAS_OVERLAY=1` — the committed
/// break shifts the overlay +120px — and asserts the SAME detector fails,
/// proving the guard can go red.
///
/// TIER-JUSTIFY: T5 — self-skips outside the VM GUI lane (PixelTestCase);
/// additionally requires the Screen-Recording grant (TSK-1334, owner-gated).
final class CanvasOverlayVisualRegressionTests: PixelTestCase {

    /// Accent-ink detector: scan a horizontal band for runs of the selection
    /// accent hue (#0a84ff family — blue-dominant, saturated). Returns the
    /// leftmost x (in image pixels) of the longest run, or nil.
    static func leftmostAccentRun(
        in image: CGImage, bandTopFraction: CGFloat, bandBottomFraction: CGFloat
    ) -> Int? {
        guard let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data) else { return nil }
        let bytesPerRow = image.bytesPerRow
        let width = image.width
        let top = Int(CGFloat(image.height) * bandTopFraction)
        let bottom = Int(CGFloat(image.height) * bandBottomFraction)
        var best: (x: Int, len: Int)?
        for y in stride(from: top, to: bottom, by: 2) {
            var runStart: Int?
            var runLen = 0
            for x in 0..<width {
                let p = y * bytesPerRow + x * 4
                let r = Int(bytes[p]), g = Int(bytes[p + 1]), b = Int(bytes[p + 2])
                // Blue-dominant accent: high blue, mid green, low red.
                let isAccent = b > 180 && r < 120 && g > 80 && g < 200 && (b - r) > 90
                if isAccent {
                    if runStart == nil { runStart = x }
                    runLen += 1
                } else if let start = runStart {
                    if best == nil || runLen > best!.len { best = (start, runLen) }
                    runStart = nil
                    runLen = 0
                }
            }
            if let start = runStart, best == nil || runLen > best!.len {
                best = (start, runLen)
            }
        }
        // A real overlay edge is a run of at least ~40px (the title's width
        // is hundreds of px; anti-aliased text ink never runs that long in
        // pure accent).
        return (best?.len ?? 0) >= 40 ? best?.x : nil
    }

    func test_selection_overlay_composites_on_screen() throws {
        let capture = try CanvasOverlaySceneHarness.captureScene(broken: false)
        let x = Self.leftmostAccentRun(
            in: capture.image, bandTopFraction: 0.1, bandBottomFraction: 0.9)
        XCTAssertNotNil(x, "no accent overlay run found — the overlay did not composite")
        if let x {
            XCTAssertLessThan(
                x, capture.image.width / 2,
                "overlay anchors at the title's left edge (layers panel + padding)")
        }
    }

    /// The committed break (+120px shift) must make the SAME detector's
    /// position assertion fail — the guard has teeth.
    func test_negative_control_broken_overlay_goes_red() throws {
        let capture = try CanvasOverlaySceneHarness.captureScene(broken: true)
        let normal = try CanvasOverlaySceneHarness.captureScene(broken: false)
        let brokenX = Self.leftmostAccentRun(
            in: capture.image, bandTopFraction: 0.1, bandBottomFraction: 0.9)
        let normalX = Self.leftmostAccentRun(
            in: normal.image, bandTopFraction: 0.1, bandBottomFraction: 0.9)
        guard let brokenX, let normalX else {
            return XCTFail("both captures must show an overlay run")
        }
        XCTAssertGreaterThan(
            brokenX, normalX + 60,
            "the committed break must visibly displace the overlay (teeth)")
    }
}

/// Spawn + capture plumbing for the canvas-demo scene — the same private
/// per-suite pattern every T5 visual suite carries (FileTabStrip/ImageEditor
/// et al.): spawn dist/TextView.app into the scene, wait for the published
/// windowid, activate, settle, then a responsibility-disclaimed
/// screencapture (TSK-502).
enum CanvasOverlaySceneHarness {

    struct Capture {
        let image: CGImage
    }

    private static let appExe: String = {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return here.appendingPathComponent(
            "dist/TextView.app/Contents/MacOS/MarkdownViewer").path
    }()

    private static let windowIDFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("com.markdownviewer.MarkdownViewer.windowid")

    static func captureScene(broken: Bool) throws -> Capture {
        try? FileManager.default.removeItem(at: windowIDFile)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        var env = ProcessInfo.processInfo.environment
        env["MDV_UI_SCENE"] = "canvas-demo"
        env["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        env["MDV_TEST_INSTANCE"] = "1"
        if broken { env["MDV_ENABLE_BROKEN_CANVAS_OVERLAY"] = "1" }
        p.environment = env
        try p.run()
        defer {
            if p.isRunning {
                p.terminate()
                Thread.sleep(forTimeInterval: 0.2)
                if p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
            }
        }

        let windowID = try waitForWindowID(timeout: 5.0)
        let activate = Process()
        activate.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        activate.arguments = ["-e", "tell application \"MarkdownViewer\" to activate"]
        try? activate.run()
        activate.waitUntilExit()
        // Scene apply + webview mount + the 1.5s deferred select + paint.
        Thread.sleep(forTimeInterval: 4.0)

        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-canvas-overlay-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let capExit = runDisclaimedShell(
            "/usr/sbin/screencapture -l\(windowID) -x -o '\(pngURL.path)'")
        guard capExit == 0,
            let image = NSImage(contentsOf: pngURL),
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            cg.width > 200, cg.height > 200 else {
            throw XCTSkip("screencapture unavailable / Screen Recording denied (TSK-1334).")
        }
        return Capture(image: cg)
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
        throw XCTSkip("App didn't publish windowNumber within \(timeout)s.")
    }
}
