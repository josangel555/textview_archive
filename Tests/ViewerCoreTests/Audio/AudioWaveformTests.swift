import XCTest
import AVFoundation
@testable import ViewerCore

/// Host teeth for the audio-visualization model layer (TSK-529): the decoded
/// mono overview (`AudioWaveform`) and the pure zoom/scroll/playhead geometry
/// (`AudioWaveformGeometry`) the render-gated `AudioEditorView` binds to. The
/// on-screen Canvas drawing is VM-only, but every coordinate the view computes
/// routes through these, so a logic regression fails the host gate.
final class AudioWaveformTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDownWithError() throws {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
    }

    /// Write deinterleaved float channels to a lossless CAF (headless-safe — no
    /// audio session / hardware). Mirrors `AudioDecoderTests`.
    private func writeFloatPCM(_ channels: [[Float]], sampleRate: Double) throws -> URL {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count))!
        let n = channels.first?.count ?? 0
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        let dst = buffer.floatChannelData!
        for c in channels.indices { for i in 0..<n { dst[c][i] = channels[c][i] } }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-waveform-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        scratch.append(url)
        return url
    }

    // MARK: - AudioWaveform.load

    func test_load_monoSine_roundTripsMetrics() throws {
        let mono = (0..<2048).map { sin(Float($0) * 0.05) }
        let url = try writeFloatPCM([mono], sampleRate: 44100)

        let wf = try AudioWaveform.load(contentsOf: url)
        XCTAssertEqual(wf.sampleRate, 44100, accuracy: 1e-6)
        XCTAssertEqual(wf.frameCount, 2048)
        XCTAssertEqual(wf.duration, 2048.0 / 44100.0, accuracy: 1e-6)
    }

    func test_load_stereo_averagesToMono() throws {
        // L = +0.5 constant, R = −0.5 constant → mono average ≈ 0.
        let left = [Float](repeating: 0.5, count: 64)
        let right = [Float](repeating: -0.5, count: 64)
        let url = try writeFloatPCM([left, right], sampleRate: 8000)

        let wf = try AudioWaveform.load(contentsOf: url)
        XCTAssertEqual(wf.frameCount, 64)
        for s in wf.samples { XCTAssertEqual(s, 0, accuracy: 1e-5) }
    }

    func test_peaks_producesRequestedColumns_withSpread() throws {
        let mono = (0..<1000).map { sin(Float($0) * 0.1) }
        let url = try writeFloatPCM([mono], sampleRate: 16000)
        let wf = try AudioWaveform.load(contentsOf: url)

        let peaks = wf.peaks(columns: 40)
        XCTAssertEqual(peaks.count, 40)
        XCTAssertTrue(peaks.contains { $0.max > $0.min }, "a non-silent sine must spread")
    }

    func test_peaks_visibleWindow_differsFromFull() throws {
        // First half silent, second half a loud tone → a window over the first
        // half is flat; over the second half it spreads.
        let mono = (0..<400).map { i in i < 200 ? Float(0) : sin(Float(i) * 0.3) }
        let url = try writeFloatPCM([mono], sampleRate: 16000)
        let wf = try AudioWaveform.load(contentsOf: url)

        let firstHalf = wf.peaks(columns: 8, visible: 0..<200)
        let secondHalf = wf.peaks(columns: 8, visible: 200..<400)
        XCTAssertFalse(firstHalf.contains { $0.max > $0.min }, "silent window stays flat")
        XCTAssertTrue(secondHalf.contains { $0.max > $0.min }, "tone window spreads")
    }

    func test_frameTime_roundTrips() {
        let wf = AudioWaveform(samples: [Float](repeating: 0, count: 44100), sampleRate: 44100)
        XCTAssertEqual(wf.time(ofFrame: 22050), 0.5, accuracy: 1e-9)
        XCTAssertEqual(wf.frame(atTime: 0.5), 22050)
        XCTAssertEqual(wf.frame(atTime: -1), 0, "clamps below zero")
        XCTAssertEqual(wf.frame(atTime: 999), 44100, "clamps to frameCount")
    }

    // MARK: - AudioWaveformGeometry.visibleRange

    func test_visibleRange_zoom1_isWholeFile() {
        XCTAssertEqual(
            AudioWaveformGeometry.visibleRange(totalFrames: 1000, zoom: 1, scrollFraction: 0),
            0..<1000)
        // scroll is irrelevant at zoom 1 (nothing to scroll).
        XCTAssertEqual(
            AudioWaveformGeometry.visibleRange(totalFrames: 1000, zoom: 1, scrollFraction: 1),
            0..<1000)
    }

    func test_visibleRange_zoom2_scrollEnds() {
        XCTAssertEqual(
            AudioWaveformGeometry.visibleRange(totalFrames: 100, zoom: 2, scrollFraction: 0),
            0..<50)
        XCTAssertEqual(
            AudioWaveformGeometry.visibleRange(totalFrames: 100, zoom: 2, scrollFraction: 1),
            50..<100)
        XCTAssertEqual(
            AudioWaveformGeometry.visibleRange(totalFrames: 100, zoom: 2, scrollFraction: 0.5),
            25..<75, "mid scroll centres the window")
    }

    func test_visibleRange_emptyBuffer() {
        XCTAssertEqual(
            AudioWaveformGeometry.visibleRange(totalFrames: 0, zoom: 4, scrollFraction: 0.5),
            0..<0)
    }

    func test_visibleRange_clampsZoomAndScroll() {
        // zoom below 1 clamps to 1 (whole file); scroll past 1 clamps to the end.
        XCTAssertEqual(
            AudioWaveformGeometry.visibleRange(totalFrames: 80, zoom: 0.1, scrollFraction: 0.5),
            0..<80)
        XCTAssertEqual(
            AudioWaveformGeometry.visibleRange(totalFrames: 80, zoom: 4, scrollFraction: 9.0),
            60..<80, "scroll clamps to last window")
    }

    func test_visibleRange_extremeZoom_neverCollapsesBelowOneFrame() {
        let r = AudioWaveformGeometry.visibleRange(totalFrames: 10, zoom: 200, scrollFraction: 0)
        XCTAssertGreaterThanOrEqual(r.count, 1)
    }

    // MARK: - playhead mapping

    func test_playheadFraction_inWindow() {
        let f = AudioWaveformGeometry.playheadFraction(frame: 50, visible: 0..<100)
        XCTAssertEqual(f ?? -1, 0.5, accuracy: 1e-9)
    }

    func test_playheadFraction_nilOutsideWindow() {
        XCTAssertNil(AudioWaveformGeometry.playheadFraction(frame: 150, visible: 0..<100))
        XCTAssertNil(AudioWaveformGeometry.playheadFraction(frame: -1, visible: 0..<100))
        XCTAssertNil(AudioWaveformGeometry.playheadFraction(frame: 100, visible: 0..<100),
                     "upper bound is exclusive")
    }

    func test_frameAtFraction_isInverseOfPlayhead() {
        let visible = 200..<600
        let frame = AudioWaveformGeometry.frame(atFraction: 0.25, visible: visible)
        XCTAssertEqual(frame, 300)   // 200 + 0.25*400
        let back = AudioWaveformGeometry.playheadFraction(frame: frame, visible: visible)
        XCTAssertEqual(back ?? -1, 0.25, accuracy: 1e-9)
    }

    func test_frameAtFraction_clampsToWindow() {
        let visible = 10..<20
        XCTAssertEqual(AudioWaveformGeometry.frame(atFraction: -5, visible: visible), 10)
        XCTAssertEqual(AudioWaveformGeometry.frame(atFraction: 5, visible: visible), 19,
                       "clamps to last visible frame, not the exclusive end")
        XCTAssertEqual(AudioWaveformGeometry.frame(atFraction: 0.5, visible: 0..<0), 0,
                       "empty window is safe")
    }

    func test_scrollFraction_toCenter_keepsFrameVisible() {
        let total = 1000, zoom = 4.0
        let frac = AudioWaveformGeometry.scrollFraction(toCenter: 500, totalFrames: total, zoom: zoom)
        let visible = AudioWaveformGeometry.visibleRange(
            totalFrames: total, zoom: zoom, scrollFraction: frac)
        XCTAssertTrue(visible.contains(500), "centring scroll keeps the frame in view")
    }

    func test_clampZoom_bounds() {
        XCTAssertEqual(AudioWaveformGeometry.clampZoom(0.01), AudioWaveformGeometry.minZoom)
        XCTAssertEqual(AudioWaveformGeometry.clampZoom(9999), AudioWaveformGeometry.maxZoom)
        XCTAssertEqual(AudioWaveformGeometry.clampZoom(3), 3)
    }

    // MARK: - spectrum window (TSK-533)

    /// A ramp (`samples[i] == i`) makes the window's frame indices self-evident.
    private func rampWaveform(_ count: Int, sampleRate: Double = 8000) -> AudioWaveform {
        AudioWaveform(samples: (0..<count).map { Float($0) }, sampleRate: sampleRate)
    }

    func test_spectrumWindow_centresOnFrame() {
        let wf = rampWaveform(10_000)
        let win = wf.spectrumWindow(centeredOn: 5000, fftSize: 2048)
        XCTAssertEqual(win.count, 2048)
        XCTAssertEqual(win.first, 3976, "window starts half an fftSize before the frame")
        XCTAssertEqual(win[1024], 5000, "the centre sample is the requested frame")
    }

    func test_spectrumWindow_clampsAtStartAndEnd() {
        let wf = rampWaveform(10_000)
        let head = wf.spectrumWindow(centeredOn: 10, fftSize: 2048)
        XCTAssertEqual(head.count, 2048)
        XCTAssertEqual(head.first, 0, "near the start the window pins to frame 0")

        let tail = wf.spectrumWindow(centeredOn: 9999, fftSize: 2048)
        XCTAssertEqual(tail.count, 2048)
        XCTAssertEqual(tail.last, 9999, "near the end the window pins to the last frame")
    }

    func test_spectrumWindow_shortBuffer_returnsWholeBuffer() {
        let wf = rampWaveform(100)
        let win = wf.spectrumWindow(centeredOn: 40, fftSize: 2048)
        XCTAssertEqual(win.count, 100, "shorter than fftSize → the whole buffer (analyzer zero-pads)")
        XCTAssertEqual(win.first, 0)
        XCTAssertEqual(win.last, 99)
    }

    func test_spectrumWindow_emptyBuffer_isEmpty() {
        let wf = AudioWaveform(samples: [], sampleRate: 8000)
        XCTAssertTrue(wf.spectrumWindow(centeredOn: 0, fftSize: 2048).isEmpty)
    }

    func test_spectrum_sine_peaksAtTone() {
        // A 1 kHz tone at 8 kHz → the playhead spectrum must peak at ~1 kHz,
        // proving the window-extract + analyze compose correctly end to end.
        let sr = 8000.0, f = 1000.0, n = 4096
        let samples = (0..<n).map { Float(0.9) * sinf(Float(2.0 * Double.pi * f * Double($0) / sr)) }
        let wf = AudioWaveform(samples: samples, sampleRate: sr)
        let bins = wf.spectrum(at: 2048, fftSize: 2048)!
        XCTAssertEqual(Double(bins.binFrequencies[bins.peakBin]), f,
                       accuracy: bins.binResolution * 1.5)
    }

    func test_spectrum_emptyBuffer_isNil() {
        let wf = AudioWaveform(samples: [], sampleRate: 8000)
        XCTAssertNil(wf.spectrum(at: 0))
    }

    func test_spectrum_silence_carriesFloor() {
        let wf = AudioWaveform(samples: [Float](repeating: 0, count: 2048), sampleRate: 8000)
        let bins = wf.spectrum(at: 0, fftSize: 2048, floorDB: -100)!
        XCTAssertEqual(bins.floorDB, -100, "the floor is carried on the bins for the renderer")
        XCTAssertTrue(bins.magnitudesDB.allSatisfy { $0 == -100 }, "silence sits at the floor")
    }
}
