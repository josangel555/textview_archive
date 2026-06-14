import XCTest
import Foundation
@testable import ViewerUI
@testable import ViewerCore

/// Host teeth for the audio spectrum toggle (TSK-533). The on-screen spectrum
/// Canvas is VM-only, but the toggle's STATE OUTCOME — show → a spectrum at the
/// playhead, hide → cleared — is pinned here through the view-model's preloaded
/// test seam, so a wiring regression fails the host gate even though the render
/// is validated on the VM.
@MainActor
final class AudioEditorViewModelSpectrumTests: XCTestCase {

    private func sineModel(
        freq: Double = 1000, sampleRate: Double = 8000, count: Int = 4096
    ) -> AudioEditorViewModel {
        let samples = (0..<count).map {
            Float(0.9) * sinf(Float(2.0 * Double.pi * freq * Double($0) / sampleRate))
        }
        let wf = AudioWaveform(samples: samples, sampleRate: sampleRate)
        return AudioEditorViewModel(
            url: URL(fileURLWithPath: "/tmp/mdv-spectrum-test.caf"), waveform: wf)
    }

    func test_default_spectrumHiddenAndNil() {
        let vm = sineModel()
        XCTAssertFalse(vm.showSpectrum)
        XCTAssertNil(vm.spectrum)
    }

    func test_toggleOn_producesSpectrumAtPlayhead_offClears() {
        let vm = sineModel()
        vm.toggleSpectrum()
        XCTAssertTrue(vm.showSpectrum)
        XCTAssertNotNil(vm.spectrum, "showing computes the playhead spectrum")
        XCTAssertEqual(vm.spectrum?.magnitudesDB.count, 1024, "a real 2048-pt FFT, not a placeholder")

        vm.toggleSpectrum()
        XCTAssertFalse(vm.showSpectrum)
        XCTAssertNil(vm.spectrum, "hiding clears the spectrum so none lingers")
    }

    func test_scrub_whileShown_recomputesSpectrum() {
        let vm = sineModel()
        vm.toggleSpectrum()
        XCTAssertNotNil(vm.spectrum)
        vm.scrub(toFraction: 0.5)
        XCTAssertNotNil(vm.spectrum, "scrubbing while shown recomputes, never clears")
    }

    func test_scrub_whileHidden_doesNotComputeSpectrum() {
        let vm = sineModel()
        vm.scrub(toFraction: 0.5)
        XCTAssertNil(vm.spectrum, "no spectrum work while the panel is hidden")
    }
}
