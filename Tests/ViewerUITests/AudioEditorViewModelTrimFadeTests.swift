import XCTest
import Foundation
@testable import ViewerUI
@testable import ViewerCore

/// Host teeth for the audio trim/fade VM wiring (TSK-534). The draggable handles
/// are the VM render tail, but the selection→ops→export path is host-pinned
/// through the preloaded-source seam: an exported copy must actually carry the
/// trimmed frame count, proving the VM feeds `AudioTrimFade`/`AudioExporter`
/// correctly.
@MainActor
final class AudioEditorViewModelTrimFadeTests: XCTestCase {

    private var scratch: [URL] = []
    override func tearDownWithError() throws {
        for u in scratch { try? FileManager.default.removeItem(at: u) }
        scratch.removeAll()
    }

    private func model(frames: Int = 1000, sampleRate: Double = 8000) -> AudioEditorViewModel {
        let src = AudioPCMBuffer(sampleRate: sampleRate,
                                 channels: [[Float](repeating: 0.5, count: frames)])
        return AudioEditorViewModel(url: URL(fileURLWithPath: "/tmp/mdv-trim-test.caf"), source: src)
    }

    func test_default_noEdits_fullRange() {
        let vm = model()
        XCTAssertFalse(vm.hasEdits)
        XCTAssertTrue(vm.editOps.isEmpty)
        XCTAssertEqual(vm.trimStartFrame, 0)
        XCTAssertEqual(vm.trimEndFrame, 1000)
    }

    func test_trimSelection_buildsTrimOp_andExportsTrimmedLength() throws {
        let vm = model(frames: 1000, sampleRate: 8000)
        vm.trimStartFrame = 100
        vm.trimEndFrame = 600
        XCTAssertTrue(vm.hasEdits)
        XCTAssertEqual(vm.editOps, [.trim(startFrame: 100, endFrame: 600)])

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-trim-\(UUID().uuidString).wav")
        scratch.append(dest)
        try vm.exportCopy(spec: AudioExportSpec(format: .wav, sampleFormat: .int16), to: dest)

        let decoded = try AudioDecoder.decode(contentsOf: dest)
        XCTAssertEqual(decoded.frameCount, 500, "exported copy carries exactly the trimmed frames")
    }

    func test_resetTrim_restoresFullRange() {
        let vm = model(frames: 800)
        vm.trimStartFrame = 100
        vm.trimEndFrame = 400
        vm.resetTrim()
        XCTAssertEqual(vm.trimStartFrame, 0)
        XCTAssertEqual(vm.trimEndFrame, 800)
        XCTAssertFalse(vm.hasEdits)
    }

    func test_setTrimEndToPlayhead_clampsAboveStart() {
        let vm = model(frames: 1000)
        // playheadFrame defaults to 0; end must stay strictly above start.
        vm.setTrimEndToPlayhead()
        XCTAssertEqual(vm.trimEndFrame, 1)
    }

    func test_fadeOnly_exportsSameLength_withSilentStart() throws {
        let vm = model(frames: 1000, sampleRate: 1000)
        vm.fadeInSeconds = 0.1   // 100 frames
        vm.fadeShape = .linear
        XCTAssertTrue(vm.hasEdits)

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-fade-\(UUID().uuidString).wav")
        scratch.append(dest)
        try vm.exportCopy(spec: AudioExportSpec(format: .wav, sampleFormat: .float32), to: dest)

        let decoded = try AudioDecoder.decode(contentsOf: dest)
        XCTAssertEqual(decoded.frameCount, 1000, "fade-only keeps the length")
        XCTAssertEqual(decoded.channels[0].first ?? -1, 0, accuracy: 1e-4, "linear fade-in starts silent")
    }
}
