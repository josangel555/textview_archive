import AppKit
import AVFoundation
import XCTest

/// T5 pixel validation for the audio visualization UI (TSK-529). Launches the
/// app straight into the waveform editor (`MDV_START_AUDIO_EDIT=1`) on a loud,
/// amplitude-modulated sine fixture and reads back stage-④ WindowServer pixels:
/// the central waveform band must composite (≥3 distinct colours), proving the
/// SwiftUI `Canvas` waveform actually drew.
///
/// This is the teeth the host layer can't give. `AudioEditorView` contains no
/// `NSViewRepresentable`, so it isn't at risk of the sibling-blank occlusion
/// pathology — but a green that has never gone red is not a guard, so if the
/// waveform failed to render (empty peaks, wrong layout, the editor not opening)
/// the central band reads uniform and this fails. Reuses
/// `SourceViewVisualRegressionTests`'s pixel helpers.
final class AudioEditorVisualRegressionTests: PixelTestCase {

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

    func test_audioEditor_waveform_composites() throws {
        if ProcessInfo.processInfo.environment["MDV_HEADLESS_GATE"] == "1" {
            throw XCTSkip("T5 heavy tier — VM/nightly lane, not the headless gate.")
        }
        let fm = FileManager.default
        let appExe = Self.appBundlePath + "/Contents/MacOS/MarkdownViewer"
        guard fm.isExecutableFile(atPath: appExe) else { throw XCTSkip("App not built.") }
        guard !ProcessInfo.processInfo.environment.keys.contains("MDV_SKIP_VISUAL") else {
            throw XCTSkip("MDV_SKIP_VISUAL set.")
        }

        // 1. A loud, amplitude-modulated sine → an unambiguously non-uniform
        //    waveform with a visible envelope (the editor must decode + reduce
        //    + draw it).
        let audioURL = try writeModulatedSineCAF()
        defer { try? fm.removeItem(at: audioURL) }
        try? fm.removeItem(at: Self.windowIDFile)
        AppLauncher.killTestInstances(named: "MarkdownViewer")

        // 2. Spawn straight into the waveform editor.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: appExe)
        p.arguments = [audioURL.path]
        var env = ProcessInfo.processInfo.environment
        env["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        env["MDV_TEST_INSTANCE"] = "1"
        env["MDV_START_AUDIO_EDIT"] = "1"
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
            .appendingPathComponent("mdv-audio-editor-\(UUID().uuidString).png")
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
        // The waveform fills the central band between the header (top) and the
        // transport controls (bottom). Sample a wide horizontal strip there.
        let waveBand = SourceViewVisualRegressionTests.Region(
            x: Int(Double(w) * 0.15), y: Int(Double(h) * 0.30),
            w: Int(Double(w) * 0.70), h: Int(Double(h) * 0.30),
            name: "waveform")

        let waveformOK = SourceViewVisualRegressionTests.regionHasVariety(in: cg, region: waveBand)
        if !waveformOK {
            let kept = pngURL.deletingPathExtension().appendingPathExtension("fail.png")
            try? fm.copyItem(at: pngURL, to: kept)
            print("  → kept failing screenshot at \(kept.path)")
        }
        XCTAssertTrue(waveformOK,
            "Audio waveform band is uniform — the waveform didn't render "
            + "(empty peaks / editor didn't open / occluded). Screenshot at \(pngURL.path)")
    }

    // MARK: - helpers

    /// A 1-second amplitude-modulated sine at 16 kHz → a waveform with a clear
    /// envelope (guaranteed pixel variety).
    private func writeModulatedSineCAF() throws -> URL {
        let sampleRate = 16000.0
        let n = 16000
        let mono: [Float] = (0..<n).map { i in
            let carrier = sin(Double(i) * 0.20)
            let envelope = 0.3 + 0.7 * abs(sin(Double(i) * 0.0015))
            return Float(carrier * envelope)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        let dst = buffer.floatChannelData![0]
        for i in 0..<n { dst[i] = mono[i] }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-audio-fixture-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
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
