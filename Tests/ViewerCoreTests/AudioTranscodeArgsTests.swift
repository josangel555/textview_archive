import XCTest
@testable import ViewerCore

/// TSK-1323 (extract audio from video) + TSK-1324 (audio format/quality convert) —
/// both are a file→file ffmpeg transcode, so one `AudioExporter.transcodeArgs` builder
/// serves both (`dropVideo` distinguishes extract vs convert). Pins the argv (codec +
/// container + bit rate/depth), the `--` arg-injection sentinel, and the bit-rate floor.
final class AudioTranscodeArgsTests: XCTestCase {

    func test_extractAudioFromVideo_dropsVideo_wav() {
        let spec = AudioExportSpec(format: .wav, sampleFormat: .int16)
        XCTAssertEqual(
            AudioExporter.transcodeArgs(input: "in.mp4", output: "out.wav", spec: spec, dropVideo: true),
            ["-y", "-hide_banner", "-loglevel", "error", "-i", "in.mp4",
             "-vn", "-codec:a", "pcm_s16le", "-f", "wav", "--", "out.wav"])
    }

    func test_convertAudio_noDropVideo_mp3_bitrate() {
        let spec = AudioExportSpec(format: .mp3, bitRate: 192_000)
        XCTAssertEqual(
            AudioExporter.transcodeArgs(input: "in.wav", output: "out.mp3", spec: spec, dropVideo: false),
            ["-y", "-hide_banner", "-loglevel", "error", "-i", "in.wav",
             "-codec:a", "libmp3lame", "-b:a", "192k", "-f", "mp3", "--", "out.mp3"])
    }

    func test_codecArgs_perFormat() {
        XCTAssertEqual(AudioExporter.codecArgs(for: AudioExportSpec(format: .wav, sampleFormat: .int16)),
                       ["-codec:a", "pcm_s16le", "-f", "wav"])
        XCTAssertEqual(AudioExporter.codecArgs(for: AudioExportSpec(format: .aiff, sampleFormat: .int24)),
                       ["-codec:a", "pcm_s24be", "-f", "aiff"])
        XCTAssertEqual(AudioExporter.codecArgs(for: AudioExportSpec(format: .caf, sampleFormat: .float32)),
                       ["-codec:a", "pcm_f32le", "-f", "caf"])
        XCTAssertEqual(AudioExporter.codecArgs(for: AudioExportSpec(format: .aac, bitRate: 128_000)),
                       ["-codec:a", "aac", "-b:a", "128k", "-f", "mp4"])
        XCTAssertEqual(AudioExporter.codecArgs(for: AudioExportSpec(format: .mp3, bitRate: 128_000)),
                       ["-codec:a", "libmp3lame", "-b:a", "128k", "-f", "mp3"])
    }

    func test_pcmCodec_endiannessAndDepth() {
        XCTAssertEqual(AudioExporter.pcmCodec(.int16, bigEndian: false), "pcm_s16le")
        XCTAssertEqual(AudioExporter.pcmCodec(.int16, bigEndian: true),  "pcm_s16be")
        XCTAssertEqual(AudioExporter.pcmCodec(.int24, bigEndian: false), "pcm_s24le")
        XCTAssertEqual(AudioExporter.pcmCodec(.int32, bigEndian: true),  "pcm_s32be")
        XCTAssertEqual(AudioExporter.pcmCodec(.float32, bigEndian: false), "pcm_f32le")
    }

    func test_outputSentinel_fencesDashLeadingPath() {
        // A malicious/odd output name beginning with '-' must land AFTER '--' so ffmpeg
        // treats it as a positional file, not a flag.
        let spec = AudioExportSpec(format: .mp3)
        let args = AudioExporter.transcodeArgs(input: "in.m4a", output: "-rf.mp3", spec: spec, dropVideo: false)
        XCTAssertEqual(args[args.count - 2], "--")
        XCTAssertEqual(args.last, "-rf.mp3")
        XCTAssertFalse(args.dropLast(2).contains("-rf.mp3"))   // not seen as a flag earlier
    }

    func test_bitRateFloor_8k() {
        // bitRate below 8 kbps clamps to 8k (avoids a nonsensical "0k"/"1k").
        let spec = AudioExportSpec(format: .mp3, bitRate: 2_000)
        XCTAssertEqual(AudioExporter.codecArgs(for: spec), ["-codec:a", "libmp3lame", "-b:a", "8k", "-f", "mp3"])
    }
}
