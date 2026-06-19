import XCTest
@testable import ViewerCore

/// Teeth for the Save-As export-settings model (TSK-535): the format/quality
/// choice maps to the right `AudioExportSpec`, irrelevant knobs are normalized
/// away, the curated menus stay in sync with the format, and the
/// extension-inference + filename helpers behave. Pure logic — host-safe.
final class AudioExportSettingsTests: XCTestCase {

    // MARK: - Applicability of the quality knob

    func test_pcmFormats_applyBitDepth_notBitRate() {
        for fmt in [AudioExportSpec.Format.wav, .aiff, .caf] {
            let s = AudioExportSettings(format: fmt)
            XCTAssertTrue(s.sampleFormatApplies, "\(fmt) is PCM → bit depth applies")
            XCTAssertFalse(s.bitRateApplies, "\(fmt) is PCM → bit rate does not apply")
        }
    }

    func test_lossyFormats_applyBitRate_notBitDepth() {
        for fmt in [AudioExportSpec.Format.aac, .mp3] {
            let s = AudioExportSettings(format: fmt)
            XCTAssertTrue(s.bitRateApplies, "\(fmt) is lossy → bit rate applies")
            XCTAssertFalse(s.sampleFormatApplies, "\(fmt) is lossy → bit depth does not apply")
        }
    }

    // MARK: - spec() mapping

    func test_spec_pcm_carriesBitDepth_andNormalizesBitRateToDefault() {
        let s = AudioExportSettings(format: .wav, sampleFormat: .int24, bitRate: 999_999)
        let spec = s.spec()
        XCTAssertEqual(spec.format, .wav)
        XCTAssertEqual(spec.sampleFormat, .int24)
        XCTAssertEqual(spec.bitRate, 128_000, "PCM ignores bit rate → normalized to default")
    }

    func test_spec_lossy_carriesBitRate_andNormalizesSampleFormatToDefault() {
        let s = AudioExportSettings(format: .aac, sampleFormat: .float32, bitRate: 256_000)
        let spec = s.spec()
        XCTAssertEqual(spec.format, .aac)
        XCTAssertEqual(spec.bitRate, 256_000)
        XCTAssertEqual(spec.sampleFormat, .int16, "lossy ignores sample format → normalized to default")
    }

    func test_spec_snapsNonCuratedBitRate_toNearestRung() {
        // 200k is between 192k and 256k, closer to 192k.
        let s = AudioExportSettings(format: .mp3, bitRate: 200_000)
        XCTAssertEqual(s.spec().bitRate, 192_000)
        // 240k is closer to 256k.
        let s2 = AudioExportSettings(format: .mp3, bitRate: 240_000)
        XCTAssertEqual(s2.spec().bitRate, 256_000)
    }

    func test_snapBitRate_exactCuratedValuesPassThrough() {
        for br in AudioExportSettings.lossyBitRates {
            XCTAssertEqual(AudioExportSettings.snapBitRate(br), br)
        }
    }

    func test_snapBitRate_extremesClampToEnds() {
        XCTAssertEqual(AudioExportSettings.snapBitRate(0), AudioExportSettings.lossyBitRates.first)
        XCTAssertEqual(AudioExportSettings.snapBitRate(10_000_000), AudioExportSettings.lossyBitRates.last)
    }

    // MARK: - Curated menus cover what the spec needs

    func test_curatedMenus_areNonEmpty_andValid() {
        XCTAssertFalse(AudioExportSettings.lossyBitRates.isEmpty)
        XCTAssertFalse(AudioExportSettings.pcmSampleFormats.isEmpty)
        // Default settings' bit rate is on the curated ladder (so the picker can
        // pre-select it without a snap surprise).
        XCTAssertTrue(AudioExportSettings.lossyBitRates.contains(AudioExportSettings().bitRate))
    }

    // MARK: - Extension inference

    func test_formatForExtension_recognizesAll() {
        XCTAssertEqual(AudioExportSettings.format(forExtension: "wav"), .wav)
        XCTAssertEqual(AudioExportSettings.format(forExtension: "WAV"), .wav)
        XCTAssertEqual(AudioExportSettings.format(forExtension: "aiff"), .aiff)
        XCTAssertEqual(AudioExportSettings.format(forExtension: "aif"), .aiff)
        XCTAssertEqual(AudioExportSettings.format(forExtension: "caf"), .caf)
        XCTAssertEqual(AudioExportSettings.format(forExtension: "m4a"), .aac)
        XCTAssertEqual(AudioExportSettings.format(forExtension: "aac"), .aac)
        XCTAssertEqual(AudioExportSettings.format(forExtension: "mp3"), .mp3)
    }

    func test_formatForExtension_unknownDefaultsToWav() {
        XCTAssertEqual(AudioExportSettings.format(forExtension: "flac"), .wav)
        XCTAssertEqual(AudioExportSettings.format(forExtension: ""), .wav)
    }

    // MARK: - Suggested filename tracks the format's extension

    func test_suggestedFileName_usesFormatExtension_andEditedSuffix() {
        XCTAssertEqual(AudioExportSettings(format: .wav).suggestedFileName(forSource: "song"),
                       "song-edited.wav")
        XCTAssertEqual(AudioExportSettings(format: .aac).suggestedFileName(forSource: "song"),
                       "song-edited.m4a", "AAC lives in an .m4a container")
        XCTAssertEqual(AudioExportSettings(format: .mp3).suggestedFileName(forSource: "clip"),
                       "clip-edited.mp3")
    }
}
