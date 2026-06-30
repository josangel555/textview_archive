import XCTest
@testable import ViewerUI
import ViewerCore

/// TSK-1323/1324 (slice 1) — host tests for the audio extract/convert view-model: bit-rate applies
/// only to lossy formats; ffmpeg-unavailable (or a bad source) surfaces a graceful error rather
/// than crashing; dropVideo distinguishes extract-from-video vs convert. The successful transcode
/// itself needs host ffmpeg (its argv is host-tested in AudioTranscodeArgsTests).
@MainActor
final class AudioConvertViewModelTests: XCTestCase {

    func test_isBitRateMeaningful_lossyFormatsOnly() {
        let vm = AudioConvertViewModel(sourceURL: URL(fileURLWithPath: "/tmp/x.wav"), dropVideo: false)
        vm.format = .wav;  XCTAssertFalse(vm.isBitRateMeaningful, "PCM uses bit depth, not bit rate")
        vm.format = .aiff; XCTAssertFalse(vm.isBitRateMeaningful)
        vm.format = .caf;  XCTAssertFalse(vm.isBitRateMeaningful)
        vm.format = .aac;  XCTAssertTrue(vm.isBitRateMeaningful, "AAC is lossy — bit rate applies")
        vm.format = .mp3;  XCTAssertTrue(vm.isBitRateMeaningful)
        XCTAssertEqual(vm.availableFormats.count, AudioExportSpec.Format.allCases.count)
    }

    func test_convert_ffmpegUnavailableOrBadSource_setsError_returnsNil() async {
        // A bogus ffmpeg override + a non-existent source → either resolve fails (mp3FFmpegNotFound)
        // or ffmpeg fails on the missing input — both must be caught gracefully (no crash).
        let vm = AudioConvertViewModel(
            sourceURL: URL(fileURLWithPath: "/tmp/clip-\(UUID().uuidString).mp4"),
            dropVideo: true,
            ffmpegOverride: "/nonexistent/ffmpeg-bogus-\(UUID().uuidString)")
        let out = await vm.convert()
        XCTAssertNil(out, "a bogus ffmpeg / missing source must not produce output")
        XCTAssertNotNil(vm.lastError, "the failure must surface a graceful error")
        XCTAssertFalse(vm.isConverting, "isConverting resets after convert()")
    }

    func test_dropVideo_distinguishesExtractVsConvert() {
        let extract = AudioConvertViewModel(sourceURL: URL(fileURLWithPath: "/tmp/v.mp4"), dropVideo: true)
        let convert = AudioConvertViewModel(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"), dropVideo: false)
        XCTAssertTrue(extract.dropVideo)
        XCTAssertFalse(convert.dropVideo)
    }
}
