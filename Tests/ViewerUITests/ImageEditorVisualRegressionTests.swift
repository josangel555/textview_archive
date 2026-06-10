import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// T5 pixel validation for the image-editor PoC view (TSK-342). Launches the
/// app straight into edit mode (`MDV_START_IMAGE_EDIT=1`) on a multi-colour
/// fixture image and reads back stage-④ WindowServer pixels: both the editor's
/// left PREVIEW and right CONTROLS panel must composite (≥3 distinct colours).
///
/// This is the teeth the host layer can't give (no ViewInspector; the editor's
/// render path has no host coverage). It specifically guards the
/// compositor-occlusion regression — if the opaque `ImageScrollHost`
/// representable were to composite OVER the SwiftUI editor (the recurring
/// sibling-blank pathology), the preview/controls region would read uniform and
/// this fails. Reuses `SourceViewVisualRegressionTests`'s pixel helpers
/// (`capturedBackingScale`, `regionHasVariety`, `Region`).
final class ImageEditorVisualRegressionTests: PixelTestCase {

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

    func test_imageEditor_previewAndControls_composite() throws {
        if ProcessInfo.processInfo.environment["MDV_HEADLESS_GATE"] == "1" {
            throw XCTSkip("T5 heavy tier — VM/nightly lane, not the headless gate.")
        }
        let fm = FileManager.default
        let appExe = Self.appBundlePath + "/Contents/MacOS/MarkdownViewer"
        guard fm.isExecutableFile(atPath: appExe) else { throw XCTSkip("App not built.") }
        guard !ProcessInfo.processInfo.environment.keys.contains("MDV_SKIP_VISUAL") else {
            throw XCTSkip("MDV_SKIP_VISUAL set.")
        }

        // 1. A vivid quadrant fixture so the rendered preview is unambiguously
        //    non-uniform (and the editor must actually decode + render it).
        let imageURL = try writeQuadrantPNG()
        defer { try? fm.removeItem(at: imageURL) }
        try? fm.removeItem(at: Self.windowIDFile)
        AppLauncher.killTestInstances(named: "MarkdownViewer")

        // 2. Spawn straight into edit mode.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        p.arguments = [imageURL.path]
        var env = ProcessInfo.processInfo.environment
        env["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        env["MDV_TEST_INSTANCE"] = "1"
        env["MDV_START_IMAGE_EDIT"] = "1"
        // TSK-618: deterministic chrome. Without this, terminal-pane /
        // zoom / frame state persisted by EARLIER spawns (shared user
        // defaults) crowds the window until the flexible preview
        // collapses and the fractional bands read the wrong panels.
        env["MDV_PRISTINE_CHROME"] = "1"
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
        Thread.sleep(forTimeInterval: 1.5)

        // 3. Capture stage-④ pixels.
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-image-editor-\(UUID().uuidString).png")
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
        // Regions as fractions of the captured pixels (scale-independent). The
        // editor is preview (left ~70%) + a 260pt controls panel (right ~24%).
        let band = { (x0: Double, x1: Double) -> SourceViewVisualRegressionTests.Region in
            SourceViewVisualRegressionTests.Region(
                x: Int(Double(w) * x0), y: Int(Double(h) * 0.30),
                w: Int(Double(w) * (x1 - x0)), h: Int(Double(h) * 0.40),
                name: "")
        }
        let preview = band(0.10, 0.60)
        let controls = band(0.80, 0.96)

        let previewOK = SourceViewVisualRegressionTests.regionHasVariety(in: cg, region: preview)
        let controlsOK = SourceViewVisualRegressionTests.regionHasVariety(in: cg, region: controls)
        if !previewOK || !controlsOK {
            let kept = pngURL.deletingPathExtension().appendingPathExtension("fail.png")
            try? fm.copyItem(at: pngURL, to: kept)
            print("  → kept failing screenshot at \(kept.path)")
        }
        XCTAssertTrue(previewOK,
            "Editor PREVIEW region is uniform — the edited image didn't render "
            + "(or the SwiftUI editor was occluded). Screenshot at \(pngURL.path)")
        XCTAssertTrue(controlsOK,
            "Editor CONTROLS panel is uniform — the sliders/buttons didn't "
            + "composite. Screenshot at \(pngURL.path)")
    }

    // MARK: - helpers

    /// 4-colour quadrant PNG → guaranteed preview variety.
    private func writeQuadrantPNG() throws -> URL {
        let side = 256
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        let half = CGFloat(side / 2)
        let quads: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: half, width: half, height: half), CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)),
            (CGRect(x: half, y: half, width: half, height: half), CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1)),
            (CGRect(x: 0, y: 0, width: half, height: half), CGColor(red: 0.15, green: 0.3, blue: 0.9, alpha: 1)),
            (CGRect(x: half, y: 0, width: half, height: half), CGColor(red: 0.95, green: 0.85, blue: 0.1, alpha: 1)),
        ]
        for (rect, color) in quads { ctx.setFillColor(color); ctx.fill(rect) }
        let cg = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-editor-fixture-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw XCTSkip("Couldn't create PNG destination")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("Couldn't write fixture PNG") }
        return url
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
