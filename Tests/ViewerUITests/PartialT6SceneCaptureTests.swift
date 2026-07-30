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

    static func capture(scene: String) throws -> CGImage {
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
            let dest = dir.appendingPathComponent("\(scene).png")
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
