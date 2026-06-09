import AppKit
import XCTest

/// Visual-regression (T5) coverage for the sidebar **preview tab** (TSK-306 /
/// TSK-272). The model layer — `TabsState.openPreview/promoteTab` +
/// `DocumentModel.openPreview` slot-reuse + all three promote gestures — is
/// host-tested with teeth in `DocumentModelPreviewTests` / `TabsStatePreviewTests`.
/// What has NO host coverage is the *render path*: does the preview tab + its
/// content actually composite on screen, or does the new SwiftUI view-tree
/// branch trip the compositor-blank pathology that T5 exists to catch (the
/// recurring `NSViewRepresentable`-occludes-sibling / sibling-blank class —
/// see CLAUDE.md)? That is the dominant render risk for any new SwiftUI UI in
/// this app, and it is exactly what `regionHasVariety` (stage-④ WindowServer
/// pixels) detects.
///
/// Drives the live model via `MDV_UI_SCENE=preview` (Diagnostics.swift) so the
/// preview slot is populated deterministically WITHOUT needing to synthesise a
/// sidebar single-click / arrow-key (which SwiftUI gesture routing makes
/// VM-infeasible). Then captures the real window and asserts the TabBar (the
/// italic preview tab) and the content pane both composited.
///
/// SCOPE (honest — verified by a teeth-demo on the VM 2026-06-09): this guards
/// the **compositor-blank class** for the preview-tab render path — i.e. that
/// driving the new openPreview→view branch doesn't blank the SwiftUI region.
/// It does NOT have teeth for the preview-SPECIFIC affordances (the italic
/// title / single-slot reuse): neutering `openPreview` in the scene leaves a
/// blank tab whose chrome + content still composite, so this test stays green.
/// Italic is sub-pixel-fragile and slot-reuse is model state — both are
/// teeth-guarded on the host instead (`DocumentModelPreviewTests` 7/0, all three
/// promote gestures demoed red). Treat this as the render-composite smoke that
/// retires the dominant SwiftUI render risk here, paired with the host model
/// teeth — not as a standalone preview-behaviour guard.
///
/// Self-skips when: no dist build / no Screen-Recording / `MDV_HEADLESS_GATE`.
/// Runs for real only on the VM / nightly lane (PixelTestCase). The teeth for
/// the `regionHasVariety` mechanism itself are demonstrated by
/// `SourceViewVisualRegressionTests.test_meta_brokenRulerIsDetectedAsRegression`
/// (same helper, same blank-detection mechanism).
///
/// TIER-JUSTIFY: T5 — observable is the WindowServer composite read via
/// `screencapture(1)`; a `cacheDisplay`/ImageRenderer raster would draw the
/// preview tab correctly while a live occluded window is blank (false green),
/// so this cannot be demoted (CLAUDE.md ImageRenderer false-green trap).
final class PreviewTabVisualRegressionTests: PixelTestCase {

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

    func test_previewTab_compositesTabStripAndContent() throws {
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

        // A real, committed source file (non-trivial → the content pane has
        // glyph variety once previewed). Reuse the source-view test's fixture.
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let previewFile = here
            .appendingPathComponent("Sources/ViewerCore/Highlight/TreeSitterEngine.swift")
        guard fm.isReadableFile(atPath: previewFile.path) else {
            throw XCTSkip("Test fixture missing: \(previewFile.path)")
        }

        try? fm.removeItem(at: Self.windowIDFile)
        // Reap only leaked TEST instances (MDV_TEST_INSTANCE=1) — never a blanket
        // killall (shared exec name kills the owner's running app).
        AppLauncher.killTestInstances(named: "MarkdownViewer")

        // Launch with NO positional file → start on a blank tab; the
        // `preview` scene then drives that blank into the ephemeral preview
        // slot (openPreview reuses the blank), so the strip holds exactly one
        // ITALIC preview tab showing the fixture.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        p.arguments = []
        var env = ProcessInfo.processInfo.environment
        env["MDV_UI_SCENE"] = "preview"
        env["MDV_PREVIEW_FILE"] = previewFile.path
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

        let windowID = try waitForWindowID(timeout: 2.5)
        _ = try? shell([
            "/usr/bin/osascript", "-e",
            "tell application \"MarkdownViewer\" to activate",
        ])
        // Scene applies after MDV_UI_SCENE_DELAY (~0.6s) + the preview open's
        // file load + first paint — give it a generous beat.
        Thread.sleep(forTimeInterval: 2.0)

        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-preview-tab-\(UUID().uuidString).png")
        let capExit = runDisclaimedShell(
            "/usr/sbin/screencapture -l\(windowID) -x -o '\(pngURL.path)'")
        guard capExit == 0, fm.fileExists(atPath: pngURL.path),
              let image = NSImage(contentsOf: pngURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 200, cg.height > 200 else {
            throw XCTSkip(
                "screencapture unavailable / Screen Recording denied (exit=\(capExit)). " +
                "On macOS 15+, grant Screen Recording to the xctest runner.")
        }
        defer { try? fm.removeItem(at: pngURL) }

        let w = cg.width, h = cg.height
        // Reuse the source-view suite's calibrated helpers (module-internal).
        let scaleY = SourceViewVisualRegressionTests.capturedBackingScale(
            windowID: windowID, imagePixelWidth: w)
        let titleBarPx = 28 * scaleY
        typealias Region = SourceViewVisualRegressionTests.Region
        // The TabBar band holds the italic preview tab (icon + title + close).
        let tabBar = Region(x: 0, y: titleBarPx, w: w, h: 32 * scaleY, name: "TabBar")
        // A content band well below the chrome — the previewed file's source
        // text. If the preview slot didn't drive the content pane (or the new
        // branch blanked the SwiftUI sibling), this region goes uniform.
        let contentTop = titleBarPx + 96 * scaleY
        let content = Region(x: 0, y: contentTop, w: w,
                             h: max(40 * scaleY, h / 3), name: "PreviewContent")

        for region in [tabBar, content] {
            let ok = SourceViewVisualRegressionTests.regionHasVariety(in: cg, region: region)
            XCTAssertTrue(ok,
                "Region '\(region.name)' appears uniform — the preview tab / its content " +
                "did not composite (compositor-blank regression, or the preview slot " +
                "didn't drive the content pane). Screenshot: \(pngURL.path)")
            if !ok {
                let kept = pngURL.deletingPathExtension().appendingPathExtension("fail.png")
                try? fm.copyItem(at: pngURL, to: kept)
                print("  → kept failing screenshot at \(kept.path)")
            }
        }
    }

    // MARK: - helpers (small reimpl; the source-view suite's are private)

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

    @discardableResult
    private func shell(_ argv: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError  = FileHandle(forWritingAtPath: "/dev/null")
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
